--!strict
-- Server-authoritative combat core, keyed by the combatant's character Model
-- (never Player): NPCs attack and block through the same
-- CombatService.Attack/SetBlocking entry points a Player's remotes use.
--
-- AttackStart begins a swing and broadcasts it; the client plays the animation
-- and fires one AttackHit per hit marker, in order. The server validates each
-- report's timing window, order and the attacker's position (anti-teleport).
-- The client never reports what it hit; the server re-derives the target.
--
-- Every weapon is a Combat.Style (see Shared/Data/Combat.luau): a chain of hits
-- plus traits. Every hit applies LightStun and has no knockback of its own;
-- every `Combat.Knockback.everyHits` landed hits on a target fire one impulse.
-- Any landed hit interrupts the target's own attack, as do Stun/TrueStun/
-- Knocked. Cancel is per-hit and, per the style's cancelInto, returns to
-- neutral ("Any") or throws a feint jab ("Jab") that costs Recovery if blocked.
-- Bleed is applied here and ticked by HealthService.
--
-- Combat is gated by a stance: SetStance(true) is the only way AttackStart/
-- AttackCancel/Block become reachable (Dash/Run stay available). It needs
-- CombatUnlocked and no "can't fight" status. The equipped style comes from a
-- weapon Tool's `Weapon` attribute.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Config = require(ReplicatedStorage.Shared.Config)
local SaveSchema = require(ReplicatedStorage.Shared.SaveSchema)
local Combat = require(ReplicatedStorage.Shared.Data.Combat)
local PlayerService = require(script.Parent.PlayerService)
local StatusService = require(script.Parent.StatusService)
local MovementService = require(script.Parent.MovementService)
local HealthService = require(script.Parent.HealthService)
local DevService = require(script.Parent.DevService)
-- Safe to require: DataService never requires CombatService.
local DataService = require(script.Parent.DataService)

local log = Log.new("CombatService")

-- Statuses that block AttackStart/AttackHit (death is checked via Humanoid.Health).
local BLOCKS_ATTACK: { [string]: boolean } =
	{ Stun = true, TrueStun = true, Knocked = true, Block = true, Recovery = true, Carrying = true, Carried = true, Jailed = true }
-- Statuses that forbid starting a block.
local BLOCKS_BLOCK_START: { [string]: boolean } = {
	Stun = true,
	TrueStun = true,
	Knocked = true,
	BlockBroken = true,
	LightStun = true,
	Recovery = true,
	Carrying = true,
	Carried = true,
	Jailed = true,
}
-- Statuses that force Block off the instant they turn on.
local ENDS_BLOCK: { [string]: boolean } =
	{ Stun = true, TrueStun = true, Knocked = true, LightStun = true, Carrying = true, Jailed = true }
-- Statuses that interrupt an in-progress attack the instant they turn on,
-- whatever caused them. A landed hit's own interrupt is in ApplyHit. Not
-- LightStun (doesn't gate attacks) or Recovery (starts only after the feint's
-- chain has already ended).
local INTERRUPTS_ATTACK: { [string]: boolean } = { Stun = true, TrueStun = true, Knocked = true, Carrying = true, Jailed = true }

-- One named MovementService modifier per status, set/cleared alongside
-- StatusService. LightStun and Recovery don't slow movement.
local MOVEMENT_MULT_FOR: { [string]: number } = {
	Stun = 0,
	TrueStun = 0,
	Knocked = 0,
	Hit = 0.5,
}

local KNOCKBACK_DURATION = 0.25
-- Same run speed MovementService uses, for the attacker-teleport check.
local RUN_SPEED = 16 * Combat.Run.speedMult

-- One in-progress swing. A chain is a run of segments, one per hit: segment 1
-- starts at AttackStart; once hit k lands the attack sits in
-- `waitingForContinue` until AttackContinue(k + 1) is accepted. Per-hit timings
-- are measured from `segmentStartedAt`, and the anti-teleport baseline
-- (`swingPosition`) is re-taken at each segment start. `phase` bumps on every
-- state change so a timer armed for an earlier phase can tell it is stale.
-- The chain loops: after the last hit `nextHit` wraps to 1 and `pass` bumps;
-- hit 1 on later passes sits `style.loopOffset` later (see segmentOffset).
-- `feint` marks an attack the server started itself (cancel-into-jab).
-- `hitsLanded` counts landed hits across the whole chain.
type PendingAttack = {
	style: Combat.Style,
	startedAt: number,
	segmentStartedAt: number,
	nextHit: number,
	pass: number,
	hitsLanded: number,
	swingPosition: Vector3,
	feint: boolean,
	waitingForContinue: boolean,
	lastHitAt: number?,
	phase: number,
}

type Entry = {
	owner: Player?,
	weaponSet: string,
	lastCombatAt: number?,
	parryCooldownUntil: number?,
	attack: PendingAttack?,
	-- Bumped on every AttackStart; timers capture it so a stale one can't touch a
	-- later attack.
	attackGeneration: number,
	-- Count-based knockback state (Combat.Knockback).
	hitCount: number,
	lastHitCountAt: number?,
	ancestryConn: RBXScriptConnection?,
	diedConn: RBXScriptConnection?,
	toolAddedConn: RBXScriptConnection?,
	toolRemovedConn: RBXScriptConnection?,
}

local registered: { [Model]: Entry } = {}
local combatLogEnabled = false

local CombatService = {}

-- Fires on every landed hit (target, attacker, hitName).
local hitLandedBindable = Instance.new("BindableEvent")
CombatService.HitLanded = hitLandedBindable.Event :: RBXScriptSignal

-- ==================== pure helpers (self-tested directly) ====================

-- The target is only protected while blocking AND facing the attacker (their
-- look vector dotted with the attacker-to-target direction is negative).
function CombatService.IsFacingAttacker(targetLook: Vector3, targetPos: Vector3, attackerPos: Vector3): boolean
	local towardTarget = (targetPos - attackerPos)
	if towardTarget.Magnitude < 1e-4 then
		return false
	end
	return targetLook:Dot(towardTarget.Unit) < 0
end

-- Pure parry/block decision.
function CombatService.ResolveBlock(parrying: boolean, cooldownActive: boolean, meterHeld: boolean): "Parried" | "Blocked" | "BlockBroken"
	if parrying and not cooldownActive then
		return "Parried"
	end
	if meterHeld then
		return "Blocked"
	end
	return "BlockBroken"
end

-- Resolves a hit part to the character Model wearing it, so hitting a held prop still counts.
local function resolveCombatant(part: BasePart): Model?
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		if model:FindFirstChildOfClass("Humanoid") then
			return model
		end
		local parentModel = model.Parent
		model = if parentModel then parentModel:FindFirstAncestorOfClass("Model") else nil
	end
	return nil
end

-- HealthService accepts a Player or a character Model (NPC); pick the real identity.
local function healthCombatant(character: Model): HealthService.Combatant
	return Players:GetPlayerFromCharacter(character) or character
end

-- ==================== attack-state helpers ====================

-- Ends any in-progress attack and sets the next allowed AttackStart time.
-- Broadcasts nothing; callers decide whether to fire AttackCancelled.
local function clearAttack(character: Model, entry: Entry, nextAttackDelay: number)
	entry.attack = nil
	pcall(function()
		character:SetAttribute("Attacking", false)
		-- Trainer dummies read this: the 1-based hit being thrown, nil when none.
		character:SetAttribute("CurrentHitIndex", nil)
		character:SetAttribute("NextAttackAt", Workspace:GetServerTimeNow() + nextAttackDelay)
	end)
end

-- Ends an attack because the combatant was interrupted (a landed hit, or
-- Stun/TrueStun/Knocked turning on). No-op without an attack. Pays
-- Chain.Recovery as the next cooldown.
local function interruptAttack(character: Model)
	local entry = registered[character]
	if entry == nil or entry.attack == nil then
		return
	end
	local nextAttackDelay = Config.Combat.Chain.Recovery

	clearAttack(character, entry, nextAttackDelay)
	Remotes.Server.FireAll("CombatEvent", "AttackCancelled", { character = character, reason = "interrupted" })
	if combatLogEnabled then
		log:Info(string.format("%s's attack interrupted (next attack in %.2fs)", character.Name, nextAttackDelay))
	end
end

-- Resets the count-based knockback tracker. Called from onStatusChanged so
-- every knockout resets it.
local function resetHitCount(target: Model)
	local entry = registered[target]
	if entry == nil then
		return
	end
	entry.hitCount = 0
	entry.lastHitCountAt = nil
	pcall(function()
		target:SetAttribute("HitCount", 0)
	end)
end

-- ==================== movement/status/health coupling ====================

-- Sets the HealthService tier: Combat on any hit dealt or taken until
-- Config.Health.CombatTierSeconds passes, Knocked while knocked. Meaningful
-- only for real Players.
local function reconcileTier(character: Model)
	local combatant = healthCombatant(character)
	if StatusService.Has(character, "Knocked") then
		HealthService.SetTier(combatant, "Knocked")
		return
	end
	local entry = registered[character]
	local lastCombatAt = entry and entry.lastCombatAt
	if lastCombatAt and Workspace:GetServerTimeNow() - lastCombatAt < Config.Health.CombatTierSeconds then
		HealthService.SetTier(combatant, "Combat")
	else
		HealthService.SetTier(combatant, "Idle")
	end
end

local function markCombatActivity(character: Model)
	local entry = registered[character]
	local now = Workspace:GetServerTimeNow()
	if entry then
		entry.lastCombatAt = now
	end
	reconcileTier(character)
	task.delay(Config.Health.CombatTierSeconds, function()
		reconcileTier(character)
	end)
end

-- The one place that reacts to a status turning on or off, whatever caused
-- it; also interrupts an attack when Stun/TrueStun/Knocked turns on.
local function onStatusChanged(character: Model, status: string, active: boolean)
	local mult = MOVEMENT_MULT_FOR[status]
	if mult ~= nil then
		if active then
			MovementService.SetModifier(character, status, mult)
		else
			MovementService.ClearModifier(character, status)
		end
	end

	if status == "Block" then
		if active then
			MovementService.SetModifier(character, "Block", Combat.Block.blockSpeedMult)
		else
			MovementService.ClearModifier(character, "Block")
		end
		HealthService.SetBlocking(healthCombatant(character), active)
	elseif active and ENDS_BLOCK[status] then
		-- Re-fires with ("Block", false), which clears the speed modifier and the
		-- HealthService flag.
		StatusService.Remove(character, "Block")
	end

	if active and INTERRUPTS_ATTACK[status] then
		interruptAttack(character)
	end

	if status == "Knocked" then
		if active then
			resetHitCount(character)
			-- A knockout drops a player (never an NPC, always InCombat) out of the stance.
			local entry = registered[character]
			if entry and entry.owner ~= nil then
				pcall(function()
					character:SetAttribute("InCombat", false)
				end)
			end
		end
		reconcileTier(character)
		if not active then
			-- Come back up at the fixed health floor.
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				humanoid.Health = math.max(humanoid.Health, Combat.Knockout.healthOnGetUp * humanoid.MaxHealth)
				Remotes.Server.FireAll("CombatEvent", "Recovered", { target = character })
			end
		end
	end
end

-- ==================== hit application ====================

local function knockback(attacker: Model, target: Model, speed: number)
	local attackerHrp = attacker:FindFirstChild("HumanoidRootPart")
	local targetHrp = target:FindFirstChild("HumanoidRootPart")
	if attackerHrp == nil or targetHrp == nil or not attackerHrp:IsA("BasePart") or not targetHrp:IsA("BasePart") then
		return
	end

	local away = ((targetHrp :: BasePart).Position - (attackerHrp :: BasePart).Position)
	away = Vector3.new(away.X, 0, away.Z)
	if away.Magnitude < 1e-3 then
		-- Self-overlapping hit: skip the impulse rather than push in an undefined direction.
		return
	end
	local direction = away.Unit

	local ok, err = pcall(function()
		local attachment = Instance.new("Attachment")
		attachment.Name = "KnockbackAttachment"
		attachment.Parent = targetHrp

		local velocity = Instance.new("LinearVelocity")
		velocity.Name = "KnockbackVelocity"
		velocity.Attachment0 = attachment
		velocity.MaxForce = math.huge
		velocity.RelativeTo = Enum.ActuatorRelativeTo.World
		velocity.VectorVelocity = direction * speed
		velocity.Parent = targetHrp

		task.delay(KNOCKBACK_DURATION, function()
			velocity:Destroy()
			attachment:Destroy()
		end)
	end)
	if not ok then
		log:Warn(string.format("knockback on %s failed: %s", target.Name, tostring(err)))
	end
end

local function attackerLabel(attacker: Model): string
	local player = Players:GetPlayerFromCharacter(attacker)
	return if player then player.Name else attacker.Name
end

-- Resolved by UserId, never by name; nil for an NPC attacker.
local function attackerUserId(attacker: Model): number?
	local player = Players:GetPlayerFromCharacter(attacker)
	return if player then player.UserId else nil
end

-- Count-based knockback: every `everyHits`th hit fires one impulse away from
-- the attacker and resets the count; an idle timer resets it too.
-- `lastHitCountAt` stops a stale timer resetting a newer count.
local function registerHitCount(attacker: Model, target: Model)
	local entry = registered[target]
	if entry == nil then
		return
	end

	entry.hitCount += 1
	local hitAt = Workspace:GetServerTimeNow()
	entry.lastHitCountAt = hitAt
	pcall(function()
		target:SetAttribute("HitCount", entry.hitCount)
	end)

	if entry.hitCount >= Combat.Knockback.everyHits then
		knockback(attacker, target, Combat.Knockback.impulse)
		Remotes.Server.FireAll("CombatEvent", "KnockedBack", { target = target })
		entry.hitCount = 0
		pcall(function()
			target:SetAttribute("HitCount", 0)
		end)
		if combatLogEnabled then
			log:Info(string.format("%s's hit count reached %d - knocked back, count reset", target.Name, Combat.Knockback.everyHits))
		end
	end

	task.delay(Combat.Knockback.resetAfterSeconds, function()
		if registered[target] == entry and entry.lastHitCountAt == hitAt and entry.hitCount > 0 then
			entry.hitCount = 0
			pcall(function()
				target:SetAttribute("HitCount", 0)
			end)
		end
	end)
end

-- Stacks bleed up to the style's maxStacks and refreshes (not extends) the
-- duration. The config rides in the status data so HealthService needn't know
-- the style.
local function applyBleed(target: Model, style: Combat.Style, stacks: number)
	local bleed = style.bleed
	if bleed == nil then
		return
	end
	local current = StatusService.Get(target, "Bleed")
	local currentStacks = if current and type(current.data) == "table" then (current.data :: any).stacks or 0 else 0
	local newStacks = math.min(currentStacks + stacks, bleed.maxStacks)
	StatusService.Apply(target, "Bleed", bleed.seconds, { stacks = newStacks, config = bleed })
	Remotes.Server.FireAll("CombatEvent", "Bleed", { target = target, stacks = newStacks })
	if combatLogEnabled then
		log:Info(string.format("%s now has %d bleed stack(s)", target.Name, newStacks))
	end
end

-- A facing block makes the hit harmless; a broken block, back hit or no block
-- lets it through. A blocked (not parried) feint punishes the attacker.
local function applyBlockedHit(attacker: Model, target: Model, style: Combat.Style, hit: Combat.ChainHit, isFeint: boolean)
	local blockInfo = StatusService.Get(target, "Block")
	local parrying = blockInfo ~= nil and type(blockInfo.data) == "table" and (blockInfo.data :: any).value == 1
	local entry = registered[target]
	local cooldownActive = entry ~= nil and entry.parryCooldownUntil ~= nil and Workspace:GetServerTimeNow() < entry.parryCooldownUntil
	local wouldParry = parrying and not cooldownActive

	-- A parry is resolved before the block meter is touched and costs no block HP.
	local meterHeld = if wouldParry then true else HealthService.SpendBlock(healthCombatant(target), hit.blockDrain)

	local outcome = CombatService.ResolveBlock(parrying, cooldownActive, meterHeld)

	if outcome == "Parried" then
		if entry then
			entry.parryCooldownUntil = Workspace:GetServerTimeNow() + Combat.Block.parryCooldown
		end
		-- The parried attacker is stunned, which also interrupts their own attack via
		-- onStatusChanged.
		StatusService.Apply(attacker, "Stun", Combat.Block.breakStun / 2)
		Remotes.Server.FireAll("CombatEvent", "Parried", { attacker = attacker, target = target })
		if combatLogEnabled then
			log:Info(string.format("%s parried %s", target.Name, attacker.Name))
		end
	elseif outcome == "Blocked" then
		Remotes.Server.FireAll("CombatEvent", "Blocked", { target = target, attacker = attacker })
		if isFeint then
			local recoverySeconds = style.feintRecoverySeconds or 0
			if recoverySeconds > 0 then
				StatusService.Apply(attacker, "Recovery", recoverySeconds)
			end
			-- A blocked (not parried) feint ends the feinter's whole chain; Recovery alone
			-- could expire while a later hit's window is still open.
			local attackerEntry = registered[attacker]
			if attackerEntry and attackerEntry.attack then
				clearAttack(attacker, attackerEntry, 0)
				Remotes.Server.FireAll("CombatEvent", "AttackCancelled", { character = attacker, reason = "interrupted" })
			end
			if combatLogEnabled then
				log:Info(string.format("%s's feint was blocked (not parried) - %.2fs of Recovery, chain ended", attacker.Name, recoverySeconds))
			end
		end
		if combatLogEnabled then
			log:Info(string.format("%s blocked %s's hit", target.Name, attacker.Name))
		end
	else
		-- onStatusChanged clears the speed modifier and blocking flag.
		StatusService.Remove(target, "Block")
		StatusService.Apply(target, "TrueStun", Combat.Block.breakStun)
		StatusService.Apply(target, "BlockBroken", Combat.Block.breakStun)
		Remotes.Server.FireAll("CombatEvent", "BlockBroken", { target = target })
		if combatLogEnabled then
			log:Info(string.format("%s's block broke against %s", target.Name, attacker.Name))
		end
	end
end

-- Exported for the self-test. `feint` marks hit 1 of a server-started
-- cancel-into-jab attack.
function CombatService.ApplyHit(attacker: Model, target: Model, style: Combat.Style, hit: Combat.ChainHit, hitIndex: number, feint: boolean?)
	local isFeint = feint == true
	local targetHumanoid = target:FindFirstChildOfClass("Humanoid")
	local attackerHrp = attacker:FindFirstChild("HumanoidRootPart")
	local targetHrp = target:FindFirstChild("HumanoidRootPart")
	if targetHumanoid == nil or attackerHrp == nil or targetHrp == nil then
		return
	end
	if targetHumanoid.Health <= 0 then
		return
	end
	-- A downed target takes no further hits.
	if StatusService.Has(target, "Knocked") then
		return
	end

	markCombatActivity(attacker)
	markCombatActivity(target)

	if StatusService.Has(target, "Block") and not StatusService.Has(target, "BlockBroken") then
		local facing = CombatService.IsFacingAttacker(
			(targetHrp :: BasePart).CFrame.LookVector,
			(targetHrp :: BasePart).Position,
			(attackerHrp :: BasePart).Position
		)
		if facing then
			applyBlockedHit(attacker, target, style, hit, isFeint)
			return
		end
		-- A back hit ends the block.
		StatusService.Remove(target, "Block")
	end

	-- Any connecting hit interrupts the target's own attack, including a chain
	-- frozen between clicks. Parry and block returned above.
	interruptAttack(target)

	local by = attackerLabel(attacker)
	local byUserId = attackerUserId(attacker)

	-- Fired for every landed hit, including one that knocks out.
	hitLandedBindable:Fire(target, attacker, hit.name)

	-- Health must never reach 0 (Roblox fires Died immediately), so compute the
	-- result before touching Health.
	local wouldBeHealth = targetHumanoid.Health - hit.damage
	if wouldBeHealth <= 0 then
		targetHumanoid.Health = 1
		-- onStatusChanged's Knocked handler also resets HitCount.
		StatusService.Apply(target, "Knocked", Combat.Knockout.getUpSeconds, { by = by, byUserId = byUserId })
		Remotes.Server.FireAll("CombatEvent", "Knocked", { target = target, by = by })
		if combatLogEnabled then
			log:Info(string.format("%s knocked out %s", attacker.Name, target.Name))
		end
		return
	end

	HealthService.TakeDamage(healthCombatant(target), hit.damage, by)

	-- Every landed hit applies LightStun and nothing else.
	if hit.lightStun > 0 then
		StatusService.Apply(target, "LightStun", hit.lightStun)
	end
	if hit.bleedStacks > 0 and style.bleed then
		applyBleed(target, style, hit.bleedStacks)
	end

	registerHitCount(attacker, target)

	Remotes.Server.FireAll("CombatEvent", "Hit", { attacker = attacker, target = target, hitIndex = hitIndex, hitName = hit.name, feint = isFeint })
	if combatLogEnabled then
		log:Info(string.format("%s hit %s with %s's %s for %d", attacker.Name, target.Name, style.displayName, hit.name, hit.damage))
	end
end

-- ==================== hit-check ====================

-- Clear line of sight; excludes every registered combatant so a crowd doesn't
-- block its own members.
local function hasLineOfSight(attackerPos: Vector3, targetPos: Vector3, attacker: Model, target: Model): boolean
	local exclude: { Instance } = { attacker, target }
	for character in registered do
		if character ~= attacker and character ~= target then
			table.insert(exclude, character)
		end
	end

	local params = RaycastParams.new()
	params.FilterDescendantsInstances = exclude
	params.FilterType = Enum.RaycastFilterType.Exclude

	local direction = targetPos - attackerPos
	local result = Workspace:Raycast(attackerPos, direction, params)
	return result == nil
end

-- A single sphere covering the hit's reach, centred half the range ahead of
-- the torso. Exported for the self-test. Only registered combatants qualify;
-- the closest one in front of the attacker with line of sight wins.
function CombatService.FindTarget(attacker: Model, hit: Combat.ChainHit): Model?
	local torso = attacker:FindFirstChild("HumanoidRootPart")
	if torso == nil or not torso:IsA("BasePart") then
		return nil
	end
	local attackerPos = (torso :: BasePart).Position
	local attackerLook = (torso :: BasePart).CFrame.LookVector
	local origin = attackerPos + attackerLook * (hit.range / 2)
	local searchRadius = hit.range / 2 + hit.radius

	local overlapParams = OverlapParams.new()
	overlapParams.FilterDescendantsInstances = { attacker }
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude

	local ok, parts = pcall(function()
		return Workspace:GetPartBoundsInRadius(origin, searchRadius, overlapParams)
	end)
	if not ok then
		log:Warn(string.format("hit-check for %s failed: %s", attacker.Name, tostring(parts)))
		return nil
	end

	local seen: { [Model]: boolean } = {}
	local closest: Model? = nil
	local closestDistance = math.huge

	for _, part in parts :: { BasePart } do
		local target = resolveCombatant(part)
		if target and target ~= attacker and not seen[target] and registered[target] ~= nil then
			seen[target] = true
			local targetHrp = target:FindFirstChild("HumanoidRootPart")
			if targetHrp and targetHrp:IsA("BasePart") then
				local targetPos = (targetHrp :: BasePart).Position
				if (targetPos - attackerPos):Dot(attackerLook) > 0 then
					local d = (targetPos - attackerPos).Magnitude
					if d < closestDistance then
						closest = target
						closestDistance = d
					end
				end
			end
		end
	end

	if closest == nil then
		return nil
	end
	local closestHrp = (closest :: Model):FindFirstChild("HumanoidRootPart")
	if closestHrp and closestHrp:IsA("BasePart") and not hasLineOfSight(attackerPos, (closestHrp :: BasePart).Position, attacker, closest :: Model) then
		return nil
	end
	return closest
end

-- Rejects a hit if the attacker moved further than a dash plus run speed
-- allows over `elapsed` seconds since the segment start.
local function didNotTeleport(swingPosition: Vector3, currentPosition: Vector3, elapsed: number): boolean
	local maxMoved = RUN_SPEED * elapsed + Combat.Dash.distance
	return (currentPosition - swingPosition).Magnitude <= maxMoved
end

-- ==================== attack flow ====================

-- True while `attack` is still live and `phase` is unchanged; every timer
-- checks it so a stale one is a no-op.
local function attackStillInPhase(entry: Entry, attack: PendingAttack, phase: number): boolean
	return entry.attack == attack and attack.phase == phase
end

-- Seconds added to the next hit's timings: loopOffset for hit 1 on any pass
-- after the first, else 0.
local function segmentOffset(attack: PendingAttack): number
	return if attack.nextHit == 1 and attack.pass > 1 then attack.style.loopOffset else 0
end

-- If the client never reports the hit, end the attack silently with the
-- normal cooldown. Armed at AttackStart and at every accepted AttackContinue.
local function armSegmentWatchdog(character: Model, entry: Entry, attack: PendingAttack)
	local hit = attack.style.chain[attack.nextHit]
	local phase = attack.phase
	local delay = segmentOffset(attack) + hit.hitWindow.max + Config.Combat.HitTolerance + Config.Combat.Chain.WatchdogMargin
	task.delay(delay, function()
		if attackStillInPhase(entry, attack, phase) then
			if combatLogEnabled then
				log:Warn(string.format("%s's attack timed out waiting for the AttackHit(%d) report", character.Name, attack.nextHit))
			end
			clearAttack(character, entry, Config.Combat.Chain.Recovery)
		end
	end)
end

-- After a hit lands with more chain to go, drop the combo (AttackCancelled
-- reason "dropped", Chain.DropRecovery) if no AttackContinue comes within
-- ClickTimeout.
local function armContinueTimeout(character: Model, entry: Entry, attack: PendingAttack)
	local phase = attack.phase
	local delay = Config.Combat.Chain.ClickTimeout + Config.Combat.HitTolerance
	task.delay(delay, function()
		if attackStillInPhase(entry, attack, phase) then
			if combatLogEnabled then
				log:Info(string.format("%s's combo dropped: no click for hit %d in time", character.Name, attack.nextHit))
			end
			clearAttack(character, entry, Config.Combat.Chain.DropRecovery)
			Remotes.Server.FireAll("CombatEvent", "AttackCancelled", { character = character, reason = "dropped" })
		end
	end)
end

-- Shared by AttackStart, the cancel-into-jab follow-up and
-- CombatService.Attack (NPCs). Returns whether an attack started and its style.
local function beginAttack(character: Model, feint: boolean): (boolean, Combat.Style?)
	local entry = registered[character]
	if entry == nil then
		return false, nil
	end
	-- Clicks outside the combat stance do nothing. NPCs are always InCombat.
	if character:GetAttribute("InCombat") ~= true then
		return false, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return false, nil
	end
	for status in BLOCKS_ATTACK do
		if StatusService.Has(character, status) then
			return false, nil
		end
	end
	if entry.attack ~= nil then
		if combatLogEnabled then
			log:Warn(string.format("%s's AttackStart dropped: already attacking", character.Name))
		end
		return false, nil
	end

	local now = Workspace:GetServerTimeNow()
	local nextAttackAt = character:GetAttribute("NextAttackAt")
	if type(nextAttackAt) == "number" and now < nextAttackAt then
		if combatLogEnabled then
			log:Warn(string.format("%s's AttackStart dropped: on cooldown for %.2fs", character.Name, (nextAttackAt :: number) - now))
		end
		return false, nil
	end

	local style = Combat.styleFor(entry.weaponSet)
	if style == nil or #style.chain == 0 then
		log:Error(string.format("%s's weapon set %s has no style data", character.Name, entry.weaponSet))
		return false, nil
	end

	local torso = character:FindFirstChild("HumanoidRootPart")
	local swingPosition = if torso and torso:IsA("BasePart") then (torso :: BasePart).Position else Vector3.zero

	-- A swing ends a run; the client never re-sends Run(true).
	if character:GetAttribute("Running") == true then
		MovementService.SetRunning(character, false)
	end

	entry.attackGeneration += 1
	local attack: PendingAttack = {
		style = style,
		startedAt = now,
		segmentStartedAt = now,
		nextHit = 1,
		pass = 1,
		hitsLanded = 0,
		swingPosition = swingPosition,
		feint = feint,
		waitingForContinue = false,
		lastHitAt = nil,
		phase = 0,
	}
	entry.attack = attack

	pcall(function()
		character:SetAttribute("Attacking", true)
		character:SetAttribute("ComboStep", 1)
		character:SetAttribute("CurrentHitIndex", 1)
	end)

	Remotes.Server.FireAll("CombatEvent", "Swing", { character = character, style = entry.weaponSet, hitCount = #style.chain })
	if combatLogEnabled then
		log:Info(
			string.format(
				"%s starts %s%s (%d hits)",
				character.Name,
				style.displayName,
				if feint then " [feint]" else "",
				#style.chain
			)
		)
	end

	armSegmentWatchdog(character, entry, attack)

	return true, style
end

-- Shared by the AttackStart remote and NPCs.
function CombatService.AttackStart(character: Model): (boolean, Combat.Style?)
	return beginAttack(character, false)
end

-- Shared by the AttackHit remote and NPCs.
function CombatService.AttackHit(character: Model, index: number)
	local entry = registered[character]
	if entry == nil or entry.attack == nil then
		if combatLogEnabled then
			log:Warn(string.format("%s's AttackHit(%d) dropped: no attack in progress", character.Name, index))
		end
		return
	end
	local attack = entry.attack :: PendingAttack

	if index ~= attack.nextHit then
		if combatLogEnabled then
			log:Warn(string.format("%s's AttackHit(%d) dropped: expected hit %d (out of order or a duplicate)", character.Name, index, attack.nextHit))
		end
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return
	end
	-- Defense in depth: a status applied this frame may not have run its Changed
	-- handler yet. Also stops the rest of a chain after a blocked feint's Recovery.
	for status in BLOCKS_ATTACK do
		if StatusService.Has(character, status) then
			if combatLogEnabled then
				log:Warn(string.format("%s's AttackHit(%d) dropped: %s", character.Name, index, status))
			end
			return
		end
	end

	if attack.waitingForContinue then
		if combatLogEnabled then
			log:Warn(string.format("%s's AttackHit(%d) dropped: waiting for the click that throws it", character.Name, index))
		end
		return
	end

	local now = Workspace:GetServerTimeNow()
	-- Minus the follow-through before a looped hit 1, so the window matches Combat.luau.
	local elapsed = now - attack.segmentStartedAt - segmentOffset(attack)
	local hit = attack.style.chain[index]
	local tolerance = Config.Combat.HitTolerance

	if elapsed < hit.hitWindow.min - tolerance then
		if combatLogEnabled then
			log:Warn(
				string.format(
					"%s's AttackHit(%d) dropped: too early (elapsed %.2fs, window %.2f-%.2f)",
					character.Name,
					index,
					elapsed,
					hit.hitWindow.min,
					hit.hitWindow.max
				)
			)
		end
		return
	end
	if elapsed > hit.hitWindow.max + tolerance then
		if combatLogEnabled then
			log:Warn(
				string.format(
					"%s's AttackHit(%d) dropped: too late (elapsed %.2fs, window %.2f-%.2f)",
					character.Name,
					index,
					elapsed,
					hit.hitWindow.min,
					hit.hitWindow.max
				)
			)
		end
		return
	end

	local torso = character:FindFirstChild("HumanoidRootPart")
	if torso == nil or not torso:IsA("BasePart") or not didNotTeleport(attack.swingPosition, (torso :: BasePart).Position, now - attack.segmentStartedAt) then
		if combatLogEnabled then
			log:Warn(string.format("%s's AttackHit(%d) dropped: moved too far since the swing", character.Name, index))
		end
		return
	end

	if combatLogEnabled then
		log:Info(string.format("%s's AttackHit(%d) accepted (elapsed %.2fs, %s)", character.Name, index, elapsed, hit.name))
	end

	local target = CombatService.FindTarget(character, hit)
	if target then
		local isFeintHit = attack.feint and index == 1 and attack.pass == 1
		CombatService.ApplyHit(character, target, attack.style, hit, index, isFeintHit)
	else
		Remotes.Server.FireAll("CombatEvent", "Miss", { attacker = character, hitIndex = index, hitName = hit.name })
		if combatLogEnabled then
			log:Info(string.format("%s's %s (hit %d) whiffed", character.Name, attack.style.displayName, index))
		end
	end

	-- StatusService.Changed is deferred, so ApplyHit's effects on this attacker
	-- (parry Stun, feint Recovery) haven't run yet; the next AttackHit's
	-- BLOCKS_ATTACK check catches them. The chain now waits for the next click
	-- (CurrentHitIndex is nil meanwhile); after the last hit nextHit wraps to 1.
	attack.hitsLanded += 1
	attack.phase += 1
	if index >= #attack.style.chain then
		attack.nextHit = 1
		attack.pass += 1
	else
		attack.nextHit = index + 1
	end
	attack.waitingForContinue = true
	attack.lastHitAt = now
	pcall(function()
		character:SetAttribute("CurrentHitIndex", nil)
	end)
	armContinueTimeout(character, entry, attack)
end

-- Ends a chain between hits (only while it waits for a click): Chain.Recovery
-- cooldown and CombatEvent AttackEnded. NPCs call it after one pass; a
-- player's chain drops on timeout instead.
function CombatService.AttackEnd(character: Model)
	local entry = registered[character]
	if entry == nil or entry.attack == nil then
		return
	end
	local attack = entry.attack :: PendingAttack
	if not attack.waitingForContinue then
		return
	end
	clearAttack(character, entry, Config.Combat.Chain.Recovery)
	Remotes.Server.FireAll("CombatEvent", "AttackEnded", { character = character })
	if combatLogEnabled then
		log:Info(string.format("%s's attack complete (%d hits), recovery %.2fs", character.Name, attack.hitsLanded, Config.Combat.Chain.Recovery))
	end
end

-- The second (third, ...) click of a combo; shared by the AttackContinue
-- remote and NPCs. Accepted only while waiting for exactly hit `index`, between
-- Chain.HitGap and Chain.ClickTimeout (+/- tolerance) after the last hit.
-- Starts that hit's segment: the timing clock and anti-teleport baseline
-- restart.
function CombatService.AttackContinue(character: Model, index: number): boolean
	local entry = registered[character]
	if entry == nil or entry.attack == nil then
		if combatLogEnabled then
			log:Warn(string.format("%s's AttackContinue(%d) dropped: no attack in progress", character.Name, index))
		end
		return false
	end
	if character:GetAttribute("InCombat") ~= true then
		return false
	end
	local attack = entry.attack :: PendingAttack
	if not attack.waitingForContinue or index ~= attack.nextHit then
		if combatLogEnabled then
			log:Warn(
				string.format(
					"%s's AttackContinue(%d) dropped: %s",
					character.Name,
					index,
					if attack.waitingForContinue then string.format("expected hit %d", attack.nextHit) else "not waiting for a click"
				)
			)
		end
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return false
	end
	for status in BLOCKS_ATTACK do
		if StatusService.Has(character, status) then
			if combatLogEnabled then
				log:Warn(string.format("%s's AttackContinue(%d) dropped: %s", character.Name, index, status))
			end
			return false
		end
	end

	local now = Workspace:GetServerTimeNow()
	local sinceHit = now - (attack.lastHitAt or attack.segmentStartedAt)
	local tolerance = Config.Combat.HitTolerance
	if sinceHit < Config.Combat.Chain.HitGap - tolerance then
		if combatLogEnabled then
			log:Warn(string.format("%s's AttackContinue(%d) dropped: too soon (%.2fs after the last hit, gap %.2fs)", character.Name, index, sinceHit, Config.Combat.Chain.HitGap))
		end
		return false
	end
	if sinceHit > Config.Combat.Chain.ClickTimeout + tolerance then
		if combatLogEnabled then
			log:Warn(string.format("%s's AttackContinue(%d) dropped: too late (%.2fs after the last hit, timeout %.2fs)", character.Name, index, sinceHit, Config.Combat.Chain.ClickTimeout))
		end
		return false
	end

	local torso = character:FindFirstChild("HumanoidRootPart")
	attack.swingPosition = if torso and torso:IsA("BasePart") then (torso :: BasePart).Position else attack.swingPosition
	attack.waitingForContinue = false
	attack.segmentStartedAt = now
	attack.phase += 1
	local hit = attack.style.chain[index]
	pcall(function()
		character:SetAttribute("ComboStep", index)
		character:SetAttribute("CurrentHitIndex", index)
	end)
	if combatLogEnabled then
		log:Info(string.format("%s continues into hit %d (%s, %.2fs after the last hit)", character.Name, index, hit.name, sinceHit))
	end
	-- Other clients' copy of an NPC's combo animation needs this; the attacker's
	-- own client already unfroze on click.
	Remotes.Server.FireAll("CombatEvent", "SwingContinue", { character = character, hit = index })
	armSegmentWatchdog(character, entry, attack)
	return true
end

-- Cancel is per-hit (the next unlanded hit's cancelUntil). What follows depends
-- on the style's cancelInto.
function CombatService.AttackCancel(character: Model)
	local entry = registered[character]
	if entry == nil or entry.attack == nil then
		if combatLogEnabled then
			log:Warn(string.format("%s's AttackCancel dropped: no attack in progress", character.Name))
		end
		return
	end
	if character:GetAttribute("InCombat") ~= true then
		return
	end
	local attack = entry.attack :: PendingAttack
	local hit = attack.style.chain[attack.nextHit]
	if hit == nil then
		return
	end

	local now = Workspace:GetServerTimeNow()
	local elapsed = now - attack.segmentStartedAt - segmentOffset(attack)
	local tolerance = Config.Combat.HitTolerance
	-- While waiting for the next click a cancel is always honoured; cancelUntil
	-- applies only to a live segment.
	if not attack.waitingForContinue and elapsed > hit.cancelUntil + tolerance then
		if combatLogEnabled then
			log:Warn(
				string.format(
					"%s's AttackCancel dropped: past hit %d's cancel window (elapsed %.2fs, cancelUntil %.2fs)",
					character.Name,
					attack.nextHit,
					elapsed,
					hit.cancelUntil
				)
			)
		end
		return
	end

	local style = attack.style
	local cancelledAtHit = attack.nextHit

	-- Cancelling is free only before any hit has landed (the bait); after that it
	-- costs Chain.Recovery. Counted by hitsLanded since the chain loops.
	-- beginAttack checks NextAttackAt, so a cancel-into-jab waits on it.
	if attack.hitsLanded > 0 then
		clearAttack(character, entry, Config.Combat.Chain.Recovery)
	else
		clearAttack(character, entry, 0)
	end
	Remotes.Server.FireAll("CombatEvent", "AttackCancelled", { character = character, reason = "cancelled" })
	if combatLogEnabled then
		log:Info(string.format("%s's attack cancelled at hit %d (elapsed %.2fs, %d landed)", character.Name, cancelledAtHit, elapsed, attack.hitsLanded))
	end

	if style.cancelInto == "Jab" then
		beginAttack(character, true)
	end
end

-- NPC entry point: starts the swing like a player's AttackStart, then plays the
-- client's part: AttackHit at each hit window's midpoint and AttackContinue
-- Config.Npc.ContinueDelay after each hit. One pass, then AttackEnd; an NPC
-- never loops.
function CombatService.Attack(character: Model)
	local started, style = beginAttack(character, false)
	if not started or style == nil then
		return
	end
	local entry = registered[character]
	if entry == nil then
		return
	end
	-- Captured so a stale timer can't consume a later attack's hit.
	local generation = entry.attackGeneration

	local function playSegment(index: number)
		local hit = style.chain[index]
		local midpoint = (hit.hitWindow.min + hit.hitWindow.max) / 2
		task.delay(midpoint, function()
			if entry.attackGeneration ~= generation then
				return
			end
			CombatService.AttackHit(character, index)
			task.delay(Config.Npc.ContinueDelay, function()
				if entry.attackGeneration ~= generation then
					return
				end
				if index >= #style.chain then
					CombatService.AttackEnd(character)
					return
				end
				if CombatService.AttackContinue(character, index + 1) then
					playSegment(index + 1)
				end
			end)
		end)
	end
	playSegment(1)
end

-- Shared by the Block() remote and NpcService.
function CombatService.SetBlocking(character: Model, on: boolean)
	local entry = registered[character]
	if entry == nil then
		return
	end

	if on then
		-- Only starting a block is gated by InCombat; releasing must always work.
		if character:GetAttribute("InCombat") ~= true then
			return
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid == nil or humanoid.Health <= 0 then
			return
		end
		for status in BLOCKS_BLOCK_START do
			if StatusService.Has(character, status) then
				return
			end
		end
		if StatusService.Has(character, "Block") then
			return
		end
		if entry.attack ~= nil then
			return
		end
		StatusService.Apply(character, "Block", nil, { value = 1 })
	else
		if not StatusService.Has(character, "Block") then
			return
		end
		StatusService.Remove(character, "Block")
	end
end

-- Entry point for `.weapon` and equip flows. Ends any in-progress attack.
function CombatService.SetWeapon(character: Model, styleName: string): boolean
	local entry = registered[character]
	if entry == nil then
		return false
	end
	local style = Combat.styleFor(styleName)
	if style == nil then
		return false
	end

	entry.weaponSet = styleName
	if entry.attack ~= nil then
		clearAttack(character, entry, 0)
		Remotes.Server.FireAll("CombatEvent", "AttackCancelled", { character = character, reason = "cancelled" })
	end
	pcall(function()
		character:SetAttribute("WeaponSet", styleName)
	end)
	MovementService.SetStyle(character, styleName)
	return true
end

-- Combat stance: AttackStart/AttackCancel/Block require InCombat (Dash/Run
-- don't). Leaving always works; entering needs the owner's CombatUnlocked,
-- alive, and not Knocked/TrueStun/Recovery. NPCs never call this. Returns
-- whether the state was applied.
function CombatService.SetStance(character: Model, on: boolean): boolean
	local entry = registered[character]
	if entry == nil then
		return false
	end

	if not on then
		pcall(function()
			character:SetAttribute("InCombat", false)
		end)
		return true
	end

	local owner = entry.owner
	if owner == nil then
		return false
	end
	if owner:GetAttribute("CombatUnlocked") ~= true then
		return false
	end
	-- The age-death scene: frozen, about to respawn.
	if owner:GetAttribute("Dying") == true then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return false
	end
	if StatusService.Has(character, "Knocked") or StatusService.Has(character, "TrueStun") or StatusService.Has(character, "Recovery") then
		return false
	end

	pcall(function()
		character:SetAttribute("InCombat", true)
	end)
	return true
end

-- ==================== tool -> style ====================
-- The equipped style comes from a weapon Tool's string `Weapon` attribute
-- naming a Combat.Style. `.weapon` is a dev override that the next equip or
-- unequip replaces.

local function onToolEquipped(character: Model, tool: Tool)
	local weaponName = tool:GetAttribute("Weapon")
	if type(weaponName) ~= "string" then
		return
	end
	if Combat.styleFor(weaponName) == nil then
		-- A Weapon string naming no real style is a misconfiguration: warn and fall
		-- back to Fist.
		log:Warn(string.format("%s's Tool %q has an unknown Weapon attribute %q; falling back to Fist", character.Name, tool.Name, weaponName))
		CombatService.SetWeapon(character, "Fist")
		return
	end
	CombatService.SetWeapon(character, weaponName)
end

-- Unequipping any weapon Tool drops the style back to Fist.
local function onToolUnequipped(character: Model, tool: Tool)
	local weaponName = tool:GetAttribute("Weapon")
	if type(weaponName) ~= "string" or Combat.styleFor(weaponName) == nil then
		return
	end
	CombatService.SetWeapon(character, "Fist")
end

-- ==================== register / unregister ====================

function CombatService.Register(character: Model, owner: Player?, weaponSet: string?)
	local existing = registered[character]
	if existing then
		existing.owner = owner
		return
	end

	local resolvedWeaponSet = weaponSet or "Fist"
	local entry: Entry = {
		owner = owner,
		weaponSet = resolvedWeaponSet,
		attack = nil,
		attackGeneration = 0,
		hitCount = 0,
	}
	registered[character] = entry

	pcall(function()
		character:SetAttribute("WeaponSet", resolvedWeaponSet)
		character:SetAttribute("ComboStep", 1)
		character:SetAttribute("NextAttackAt", 0)
		character:SetAttribute("Attacking", false)
		character:SetAttribute("CurrentHitIndex", nil)
		character:SetAttribute("HitCount", 0)
		-- NPCs flip this to true right after Register; players start out of the stance.
		character:SetAttribute("InCombat", false)
	end)
	MovementService.SetStyle(character, resolvedWeaponSet)

	local okAncestry, ancestryConn = pcall(function()
		return character.AncestryChanged:Connect(function(_child, parent)
			if parent == nil then
				CombatService.Unregister(character)
			end
		end)
	end)
	if okAncestry then
		entry.ancestryConn = ancestryConn
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local okDied, diedConn = pcall(function()
			return humanoid.Died:Connect(function()
				-- A dead player's corpse stops showing the stance; NPCs are always InCombat
				-- and are unregistered anyway.
				if entry.owner ~= nil then
					pcall(function()
						character:SetAttribute("InCombat", false)
					end)
				end
				CombatService.Unregister(character)
			end)
		end)
		if okDied then
			entry.diedConn = diedConn
		end
	end

	for _, child in character:GetChildren() do
		if child:IsA("Tool") then
			onToolEquipped(character, child)
		end
	end
	local okToolAdded, toolAddedConn = pcall(function()
		return character.ChildAdded:Connect(function(child: Instance)
			if child:IsA("Tool") then
				onToolEquipped(character, child)
			end
		end)
	end)
	if okToolAdded then
		entry.toolAddedConn = toolAddedConn
	end
	local okToolRemoved, toolRemovedConn = pcall(function()
		return character.ChildRemoved:Connect(function(child: Instance)
			if child:IsA("Tool") then
				onToolUnequipped(character, child)
			end
		end)
	end)
	if okToolRemoved then
		entry.toolRemovedConn = toolRemovedConn
	end
end

function CombatService.Unregister(character: Model)
	local entry = registered[character]
	if entry == nil then
		return
	end
	registered[character] = nil
	-- An attack dies with the combatant, with no event; clearing entry.attack
	-- stops stale watchdogs.
	entry.attack = nil
	pcall(function()
		character:SetAttribute("Attacking", false)
	end)
	if entry.ancestryConn then
		entry.ancestryConn:Disconnect()
	end
	if entry.diedConn then
		entry.diedConn:Disconnect()
	end
	if entry.toolAddedConn then
		entry.toolAddedConn:Disconnect()
	end
	if entry.toolRemovedConn then
		entry.toolRemovedConn:Disconnect()
	end
end

-- ==================== unlock ====================
-- CombatUnlocked mirrors Meta.Unlocks.Combat OR Config.Combat.UnlockedByDefault.
-- Meta, not Progress: per-player forever, carried over by DataService.NewLife
-- and cleared only by Wipe.

-- `.lock combat` is a session-only override that beats the default and the
-- save flag; `.unlock combat` clears it. Never saved.
local devLocked: { [Player]: boolean? } = {}

local function refreshCombatUnlockedAttribute(player: Player, data: SaveSchema.Data)
	if devLocked[player] then
		player:SetAttribute("CombatUnlocked", false)
		return
	end
	player:SetAttribute("CombatUnlocked", data.Meta.Unlocks.Combat or Config.Combat.UnlockedByDefault)
end

function CombatService.SetDevLocked(player: Player, locked: boolean)
	devLocked[player] = if locked then true else nil
end

-- Recomputes the attribute from `data` and any dev lock.
function CombatService.RefreshUnlocked(player: Player, data: SaveSchema.Data)
	refreshCombatUnlockedAttribute(player, data)
end

-- `devOverride` (dev commands only): true = session lock that beats the default,
-- false = clear it. nil leaves any dev lock as it is.
function CombatService.SetUnlocked(player: Player, unlocked: boolean, devOverride: boolean?)
	if devOverride == true then
		CombatService.SetDevLocked(player, true)
	elseif devOverride == false then
		CombatService.SetDevLocked(player, false)
	end
	local data = DataService.Get(player)
	if data == nil then
		log:Warn(string.format("SetUnlocked(%s, %s): no save loaded", player.Name, tostring(unlocked)))
		return
	end
	data.Meta.Unlocks.Combat = unlocked
	refreshCombatUnlockedAttribute(player, data)
	log:Info(string.format("%s's combat unlock: %s", player.Name, tostring(unlocked)))

	-- Locking someone in the stance must leave it; SetStance only checks
	-- CombatUnlocked on the way in.
	if not unlocked and player.Character then
		CombatService.SetStance(player.Character, false)
	end
end

-- ==================== dev commands ====================

local function formatStyle(styleName: string, style: Combat.Style): string
	local lines: { string } = {}
	table.insert(
		lines,
		string.format(
			"%s (%s): cancelInto=%s speedMult=%.2f dashCooldownMult=%.2f%s",
			style.displayName,
			styleName,
			style.cancelInto,
			style.speedMult,
			style.dashCooldownMult,
			if style.feintRecoverySeconds then string.format(" feintRecoverySeconds=%.2f", style.feintRecoverySeconds) else ""
		)
	)
	if style.bleed then
		table.insert(
			lines,
			string.format(
				"  bleed: %.2f dmg/stack/s for %.2fs, max %d stacks",
				style.bleed.damagePerStackPerSecond,
				style.bleed.seconds,
				style.bleed.maxStacks
			)
		)
	end
	for i, hit in style.chain do
		table.insert(
			lines,
			string.format(
				"  %d. %s: windupAt=%.2f cancelUntil=%.2f hitWindow=%.2f-%.2f damage=%d lightStun=%.2f blockDrain=%d bleedStacks=%d",
				i,
				hit.name,
				hit.windupAt,
				hit.cancelUntil,
				hit.hitWindow.min,
				hit.hitWindow.max,
				hit.damage,
				hit.lightStun,
				hit.blockDrain,
				hit.bleedStacks
			)
		)
	end
	return table.concat(lines, "\n")
end

local function registerDevCommands()
	DevService.Register("combat", "log on|off - log every hit decision", function(_caller, args)
		local mode = if args[1] == "log" then args[2] and args[2]:lower() else nil
		if mode == "on" then
			combatLogEnabled = true
			return "Combat log: on"
		elseif mode == "off" then
			combatLogEnabled = false
			return "Combat log: off"
		end
		return "usage: .combat log on|off"
	end)

	DevService.Register("knock", "[player] - force a knockout", function(caller, args)
		local target, err = DevService.ResolvePlayer(caller, args[1])
		if target == nil then
			return err or "player not found"
		end
		local character = target.Character
		if character == nil then
			return string.format("%s has no character", target.Name)
		end
		StatusService.Apply(character, "Knocked", Combat.Knockout.getUpSeconds, { by = caller.Name, byUserId = caller.UserId })
		Remotes.Server.FireAll("CombatEvent", "Knocked", { target = character, by = caller.Name })
		return string.format("%s knocked out", target.Name)
	end)

	DevService.Register("stun", "<s> [player] - force a stun", function(caller, args)
		local seconds = tonumber(args[1])
		if seconds == nil then
			return "usage: .stun <s> [player]"
		end
		local target, err = DevService.ResolvePlayer(caller, args[2])
		if target == nil then
			return err or "player not found"
		end
		local character = target.Character
		if character == nil then
			return string.format("%s has no character", target.Name)
		end
		StatusService.Apply(character, "Stun", seconds)
		return string.format("%s stunned for %gs", target.Name, seconds)
	end)

	DevService.Register("weapon", "<Fist|Dagger> [player] - set the fighting style", function(caller, args)
		local styleName = args[1]
		if styleName == nil or Combat.styleFor(styleName) == nil then
			return "usage: .weapon <Fist|Dagger> [player]"
		end
		local target, err = DevService.ResolvePlayer(caller, args[2])
		if target == nil then
			return err or "player not found"
		end
		local character = target.Character
		if character == nil then
			return string.format("%s has no character", target.Name)
		end
		if not CombatService.SetWeapon(character, styleName) then
			return string.format("couldn't set %s's style to %s", target.Name, styleName)
		end
		return string.format("%s's style: %s", target.Name, styleName)
	end)

	DevService.Register("style", "[player] - print the equipped style's chain and traits", function(caller, args)
		local target, err = DevService.ResolvePlayer(caller, args[1])
		if target == nil then
			return err or "player not found"
		end
		local character = target.Character
		local entry = character and registered[character]
		if entry == nil then
			return string.format("%s isn't registered with CombatService", target.Name)
		end
		local style = Combat.styleFor(entry.weaponSet)
		if style == nil then
			return string.format("%s's style %s has no data", target.Name, entry.weaponSet)
		end
		return formatStyle(entry.weaponSet, style)
	end)

	DevService.Register("unlock", "combat [player] - unlock combat", function(caller, args)
		if args[1] ~= "combat" then
			return "usage: .unlock combat [player]"
		end
		local target, err = DevService.ResolvePlayer(caller, args[2])
		if target == nil then
			return err or "player not found"
		end
		CombatService.SetUnlocked(target, true, false)
		return string.format("%s's combat: unlocked", target.Name)
	end)

	DevService.Register("lock", "combat [player] - lock combat", function(caller, args)
		if args[1] ~= "combat" then
			return "usage: .lock combat [player]"
		end
		local target, err = DevService.ResolvePlayer(caller, args[2])
		if target == nil then
			return err or "player not found"
		end
		CombatService.SetUnlocked(target, false, true)
		return string.format("%s's combat: locked", target.Name)
	end)
end

-- ==================== service ====================

function CombatService:Init()
	registerDevCommands()

	Remotes.Server.On("AttackStart", function(player: Player)
		local character = player.Character
		if character then
			CombatService.AttackStart(character)
		end
	end)

	Remotes.Server.On("AttackHit", function(player: Player, index: number)
		local character = player.Character
		if character then
			CombatService.AttackHit(character, index)
		end
	end)

	Remotes.Server.On("AttackContinue", function(player: Player, index: number)
		local character = player.Character
		if character then
			CombatService.AttackContinue(character, index)
		end
	end)

	Remotes.Server.On("AttackCancel", function(player: Player)
		local character = player.Character
		if character then
			CombatService.AttackCancel(character)
		end
	end)

	Remotes.Server.On("Block", function(player: Player, on: boolean)
		local character = player.Character
		if character then
			CombatService.SetBlocking(character, on)
		end
	end)

	Remotes.Server.On("SetStance", function(player: Player, on: boolean)
		local character = player.Character
		if character then
			CombatService.SetStance(character, on)
		end
	end)

	PlayerService.Ready:Connect(function(player: Player, character: Model)
		CombatService.Register(character, player, "Fist")
	end)

	StatusService.Changed:Connect(onStatusChanged)

	Players.PlayerRemoving:Connect(function(player: Player)
		devLocked[player] = nil
		local character = player.Character
		if character then
			CombatService.Unregister(character)
		end
	end)
end

function CombatService:Start()
	-- Catch-up for players whose save loaded before this connection was made.
	DataService.Loaded:Connect(function(player: Player)
		local data = DataService.Get(player)
		if data then
			refreshCombatUnlockedAttribute(player, data)
		end
	end)

	for _, player in Players:GetPlayers() do
		if DataService.IsLoaded(player) then
			local data = DataService.Get(player)
			if data then
				refreshCombatUnlockedAttribute(player, data)
			end
		end
	end
end

return CombatService

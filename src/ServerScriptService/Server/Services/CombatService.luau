--!strict
-- The server-authoritative combat core (M3-03, TRIAGE #10, fixes AUDIT
-- C2/H5/H6/M1/M2/M3-P2). Keyed by the combatant's character Model, never
-- by Player: NPCs attack and block through the exact same
-- CombatService.Attack/SetBlocking entry points a Player's remote calls use.
--
-- M3-FIX3-S (Bryan, 2026-09-28) replaced the old single server-timed swing
-- with an animation-driven punch sequence: AttackStart begins a swing (one
-- or more punches, Shared/Data/Combat.luau's Swing/Punch shape) and
-- broadcasts it; the client plays the animation and fires one AttackHit
-- report per hit marker, in order; AttackCancel is only honoured before the
-- first punch lands. The client STILL never reports what it hit (C2 stays
-- fixed) - only that a marker played - the server re-derives the target
-- with its own hit-check, exactly as before, and validates every report's
-- timing window, order and the attacker's own position (anti-teleport)
-- before it counts for anything.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Config = require(ReplicatedStorage.Shared.Config)
local Combat = require(ReplicatedStorage.Shared.Data.Combat)
local PlayerService = require(script.Parent.PlayerService)
local StatusService = require(script.Parent.StatusService)
local MovementService = require(script.Parent.MovementService)
local HealthService = require(script.Parent.HealthService)
local DevService = require(script.Parent.DevService)

local log = Log.new("CombatService")

-- Statuses that gate an AttackStart/Block entirely (dead is checked
-- separately, via Humanoid.Health).
local BLOCKS_ATTACK: { [string]: boolean } = { Stun = true, TrueStun = true, Knocked = true, Block = true }
local BLOCKS_BLOCK_START: { [string]: boolean } = { Stun = true, TrueStun = true, Knocked = true, BlockBroken = true }
-- Statuses that force Block off outright the instant they turn on
-- (REVIEW-M3-03 M3) - onStatusChanged below reacts to all three.
local ENDS_BLOCK: { [string]: boolean } = { Stun = true, TrueStun = true, Knocked = true }
-- Statuses that also interrupt an in-progress attack the instant they turn
-- on (M3-FIX3-S), regardless of what caused them (a real hit, a dev
-- command, anything) - onStatusChanged below reacts to all three.
local INTERRUPTS_ATTACK: { [string]: boolean } = { Stun = true, TrueStun = true, Knocked = true }

-- Statuses that also freeze/slow movement while active - a single named
-- MovementService modifier per status, set/cleared alongside StatusService
-- (M3-02's own modifier-name list already reserves these names). Kept
-- here, not in MovementService, so CombatService stays the one place that
-- decides when a status starts or ends (M3-01's own design note).
local MOVEMENT_MULT_FOR: { [string]: number } = {
	Stun = 0,
	TrueStun = 0,
	Knocked = 0,
	Hit = 0.5,
}

-- A short knockback impulse, same duration the old DamageHandler used
-- (`Debris:AddItem(force, .25)`).
local KNOCKBACK_DURATION = 0.25
-- REVIEW-M3-03 L3: the same run-speed MovementService itself uses, for the
-- attacker-teleport sanity check below (kept as a local constant rather
-- than importing MovementService's own private one - both are just this
-- same formula).
local RUN_SPEED = 16 * Combat.Run.speedMult

-- One in-progress swing: which punch is still owed, when it started, and
-- where the attacker's HRP was then (the anti-teleport baseline).
type PendingAttack = {
	swing: Combat.Swing,
	startedAt: number,
	nextPunch: number,
	swingPosition: Vector3,
}

type Entry = {
	owner: Player?,
	weaponSet: string,
	lastCombatAt: number?,
	parryCooldownUntil: number?,
	attack: PendingAttack?,
	-- Bumped on every AttackStart; a watchdog closure captures its own
	-- value and checks it still matches before acting, so a stale watchdog
	-- from an attack that already ended (landed, cancelled, interrupted)
	-- can never reach into a LATER attack's state.
	attackGeneration: number,
	ancestryConn: RBXScriptConnection?,
	diedConn: RBXScriptConnection?,
}

local registered: { [Model]: Entry } = {}
local combatLogEnabled = false

local CombatService = {}

-- ==================== pure helpers (self-tested directly) ====================

-- The target is only protected while Blocking AND facing the attacker
-- (old code's own convention: the direction from attacker to target,
-- dotted with the target's own look vector, is negative when the target
-- is turned toward the attacker).
function CombatService.IsFacingAttacker(targetLook: Vector3, targetPos: Vector3, attackerPos: Vector3): boolean
	local towardTarget = (targetPos - attackerPos)
	if towardTarget.Magnitude < 1e-4 then
		return false
	end
	return targetLook:Dot(towardTarget.Unit) < 0
end

-- Pure parry/block decision, pulled out of applyBlockedHit so it's
-- self-testable without a real Player (HealthService's block meter needs
-- one, which a fake self-test Model can't provide - AUDIT H5/M2).
function CombatService.ResolveBlock(parrying: boolean, cooldownActive: boolean, meterHeld: boolean): "Parried" | "Blocked" | "BlockBroken"
	if parrying and not cooldownActive then
		return "Parried"
	end
	if meterHeld then
		return "Blocked"
	end
	return "BlockBroken"
end

-- Walks up from a hit BasePart to the nearest ancestor Model that owns a
-- Humanoid, so hitting a weapon, backpack or delivery pack still resolves
-- to the character wearing it (AUDIT M3/P2), not a stuck wait on that
-- prop's own (nonexistent) Effects folder.
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

-- REVIEW-M3-04 H1/L1: HealthService now accepts a Player OR a character
-- Model (an NPC registered via HealthService.Register) - this just picks
-- whichever identity is the real one for `character`, so the two are
-- never mixed for the same combatant.
local function healthCombatant(character: Model): HealthService.Combatant
	return Players:GetPlayerFromCharacter(character) or character
end

-- ==================== attack-state helpers ====================

-- Ends whatever attack `entry` has in progress (if any) and sets the next
-- allowed AttackStart time. Never broadcasts anything itself - callers
-- decide whether an AttackCancelled event (or nothing, for a normal
-- completion/timeout) goes out.
local function clearAttack(character: Model, entry: Entry, nextAttackDelay: number)
	entry.attack = nil
	pcall(function()
		character:SetAttribute("Attacking", false)
		character:SetAttribute("NextAttackAt", Workspace:GetServerTimeNow() + nextAttackDelay)
	end)
end

-- Shared by AttackCancel (reason = "cancelled") and getting hit / a status
-- that ends an attack outright (reason = "interrupted"). A no-op if there's
-- no attack in progress (safe to call speculatively, e.g. from
-- onStatusChanged on every Stun/TrueStun/Knocked, whether or not the
-- combatant was mid-swing).
local function interruptAttack(character: Model, reason: "cancelled" | "interrupted")
	local entry = registered[character]
	if entry == nil or entry.attack == nil then
		return
	end
	local attack = entry.attack

	local nextAttackDelay: number
	if reason == "interrupted" then
		-- The punch that got cut short pays its own stun as the cooldown -
		-- getting hit mid-swing costs more than a clean cancel does.
		local punch = attack.swing.punches[attack.nextPunch]
		nextAttackDelay = if punch then punch.stun else attack.swing.recovery
	else
		nextAttackDelay = attack.swing.cancelRecovery
	end

	clearAttack(character, entry, nextAttackDelay)
	Remotes.Server.FireAll("CombatEvent", "AttackCancelled", { character = character, reason = reason })
	if combatLogEnabled then
		log:Info(string.format("%s's attack %s (next attack in %.2fs)", character.Name, reason, nextAttackDelay))
	end
end

-- ==================== movement/status/health coupling ====================

-- REVIEW-M3-03 M2: HealthService.SetTier(player, "Combat") on any hit
-- dealt or taken, falling back to "Idle" after Config.Health.
-- CombatTierSeconds of no further combat activity - "Knocked" always wins
-- while it's active (see reconcileTier). Only meaningful for a real
-- Player; HealthService's tiers don't exist for an NPC.
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

-- REVIEW-M3-03 M3: one place owns what happens when a status turns on or
-- off, regardless of which code path caused it (a direct StatusService
-- call, a dev command, the shared expiry loop...). M3-FIX3-S: also the one
-- place that interrupts an in-progress attack when Stun/TrueStun/Knocked
-- turns on, however it turned on.
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
		-- Re-fires this same function with ("Block", false), which is what
		-- actually clears the speed modifier/HealthService flag above -
		-- one place owns that cleanup no matter which status ended it.
		StatusService.Remove(character, "Block")
	end

	if active and INTERRUPTS_ATTACK[status] then
		interruptAttack(character, "interrupted")
	end

	if status == "Knocked" then
		reconcileTier(character)
		if not active then
			-- Recovered, whether by the getUpSeconds timer or an early
			-- Remove (a dev command, say): come back up at the fixed
			-- floor, never however much health TakeDamage would otherwise
			-- have left.
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
		-- A self-overlapping hit (AUDIT C2's NaN velocity bug): just skip
		-- the impulse instead of pushing in an undefined direction.
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

-- AUDIT M1: blocking makes you immune to the hit entirely - no damage, no
-- stun, no slow, no knockback - while the block holds. Only a broken
-- block, a back hit or no block at all lets any of that through.
local function applyBlockedHit(attacker: Model, target: Model)
	local blockInfo = StatusService.Get(target, "Block")
	local parrying = blockInfo ~= nil and type(blockInfo.data) == "table" and (blockInfo.data :: any).value == 1
	local entry = registered[target]
	local cooldownActive = entry ~= nil and entry.parryCooldownUntil ~= nil and Workspace:GetServerTimeNow() < entry.parryCooldownUntil
	local wouldParry = parrying and not cooldownActive

	-- REVIEW-M3-03 M1: a parry is resolved BEFORE the block meter is ever
	-- touched - it costs no block HP at all, not even a refunded drain.
	-- REVIEW-M3-04 L1: HealthService owns the meter for a real Player AND
	-- an NPC now (its own MaxBlock cap too - AUDIT M2: nothing here ever
	-- adds block back on a parry, so there's no cap to overshoot any more).
	local meterHeld = if wouldParry then true else HealthService.SpendBlock(healthCombatant(target), Combat.Block.drainPerHit)

	local outcome = CombatService.ResolveBlock(parrying, cooldownActive, meterHeld)

	if outcome == "Parried" then
		if entry then
			entry.parryCooldownUntil = Workspace:GetServerTimeNow() + Combat.Block.parryCooldown
		end
		-- The parried attacker's own swing is punished twice over: stunned,
		-- AND (below, via onStatusChanged reacting to that Stun) their own
		-- in-progress attack is interrupted if they hadn't finished it yet.
		StatusService.Apply(attacker, "Stun", Combat.Block.breakStun / 2)
		Remotes.Server.FireAll("CombatEvent", "Parried", { attacker = attacker, target = target })
		if combatLogEnabled then
			log:Info(string.format("%s parried %s", target.Name, attacker.Name))
		end
	elseif outcome == "Blocked" then
		Remotes.Server.FireAll("CombatEvent", "Blocked", { target = target, attacker = attacker })
		if combatLogEnabled then
			log:Info(string.format("%s blocked %s's hit", target.Name, attacker.Name))
		end
	else
		-- Just Remove: onStatusChanged (above) clears the speed modifier
		-- and HealthService's blocking flag on ANY path that ends Block
		-- (REVIEW-M3-03 M3), so there's nothing else to do here for that.
		StatusService.Remove(target, "Block")
		StatusService.Apply(target, "TrueStun", Combat.Block.breakStun)
		StatusService.Apply(target, "BlockBroken", Combat.Block.breakStun)
		Remotes.Server.FireAll("CombatEvent", "BlockBroken", { target = target })
		if combatLogEnabled then
			log:Info(string.format("%s's block broke against %s", target.Name, attacker.Name))
		end
	end
end

-- Exported (not just local) so the self-test can drive it directly with
-- fake models, without going through the full AttackStart/AttackHit
-- pipeline.
function CombatService.ApplyHit(attacker: Model, target: Model, punch: Combat.Punch, punchIndex: number)
	local targetHumanoid = target:FindFirstChildOfClass("Humanoid")
	local attackerHrp = attacker:FindFirstChild("HumanoidRootPart")
	local targetHrp = target:FindFirstChild("HumanoidRootPart")
	if targetHumanoid == nil or attackerHrp == nil or targetHrp == nil then
		return
	end
	if targetHumanoid.Health <= 0 then
		return
	end
	-- REVIEW-M3-03 H1: a target already down doesn't take another hit or
	-- get re-knocked - wait for Recovered first.
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
			applyBlockedHit(attacker, target)
			return
		end
		-- A back hit bypasses (and ends) the block entirely; onStatusChanged
		-- clears the speed modifier/HealthService flag (REVIEW-M3-03 M3).
		StatusService.Remove(target, "Block")
	end

	-- M3-FIX3-S: a hit that actually lands (a block/parry returned above
	-- already) interrupts whatever punch sequence the TARGET was mid-way
	-- through - "if the attacker gets hit, the attack is interrupted".
	interruptAttack(target, "interrupted")

	local by = attackerLabel(attacker)

	-- AUDIT C2's "knock them out instead of dying" path must never let
	-- Humanoid.Health actually reach 0: Roblox fires Humanoid.Died itself
	-- the instant Health hits 0, which would kill the character before
	-- any of this code could set it back to 1. So the would-be result is
	-- computed BEFORE touching Health at all.
	local wouldBeHealth = targetHumanoid.Health - punch.damage
	if wouldBeHealth <= 0 then
		targetHumanoid.Health = 1
		StatusService.Apply(target, "Knocked", Combat.Knockout.getUpSeconds, { by = by })
		Remotes.Server.FireAll("CombatEvent", "Knocked", { target = target, by = by })
		if combatLogEnabled then
			log:Info(string.format("%s knocked out %s", attacker.Name, target.Name))
		end
		return
	end

	-- REVIEW-M3-04 H1: routes through HealthService.TakeDamage either way
	-- now - a registered NPC has its own HealthService state (NpcService
	-- calls HealthService.Register), the identical path a player's own
	-- damage takes.
	HealthService.TakeDamage(healthCombatant(target), punch.damage, by)

	StatusService.Apply(target, "Hit", Combat.Stagger.hitStun, { kind = "Fist" })
	StatusService.Apply(target, "Stun", punch.stun)
	knockback(attacker, target, punch.knockback)

	Remotes.Server.FireAll("CombatEvent", "Hit", { attacker = attacker, target = target, punchIndex = punchIndex, knockback = punch.knockback })
	if combatLogEnabled then
		log:Info(string.format("%s hit %s with %s's %s for %d", attacker.Name, target.Name, punch.name, punch.name, punch.damage))
	end
end

-- ==================== hit-check ====================

-- Clear line of sight from the attacker's HRP to the target's HRP (REVIEW-
-- M3-03 L1): excludes every registered combatant (so a crowd doesn't block
-- its own members) rather than just the two involved, since a shapecast
-- from a torso can otherwise clip a third character standing in between.
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

-- A single generous sphere covering the punch's reach, centred half its
-- range in front of the attacker's torso: a simple, well-supported
-- approximation of a forward capsule swing that doesn't depend on the
-- third-party ShapecastHitbox module's (unverified) server-side behavior.
-- Exported (not just local) so the self-test can exercise the geometry
-- directly with fake models - in range, out of range, and behind the
-- attacker. REVIEW-M3-03 M5: only a registered combatant can be hit at
-- all, and among every candidate the sphere finds, the CLOSEST one to the
-- attacker's own HRP wins (not just whichever GetPartBoundsInRadius
-- happened to list first). L2: also requires the candidate be roughly in
-- front of the attacker's own facing, not just within the sphere's reach
-- (the sphere's back edge can bulge slightly behind the attacker for a
-- wide-radius/short-range move).
function CombatService.FindTarget(attacker: Model, punch: Combat.Punch): Model?
	local torso = attacker:FindFirstChild("HumanoidRootPart")
	if torso == nil or not torso:IsA("BasePart") then
		return nil
	end
	local attackerPos = (torso :: BasePart).Position
	local attackerLook = (torso :: BasePart).CFrame.LookVector
	local origin = attackerPos + attackerLook * (punch.range / 2)
	local searchRadius = punch.range / 2 + punch.radius

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
		-- Blocked by a wall (L1): not a hit, even though it's the closest
		-- candidate geometrically.
		return nil
	end
	return closest
end

-- REVIEW-M3-03 L3: rejects a hit if the attacker moved further than a
-- legitimate combatant could have in `elapsed` seconds (a dash mid-swing,
-- plus ordinary run speed for the rest) - catches a speed-hacked/teleported
-- attacker landing a hit its swing position could never actually have
-- reached. `elapsed` is however long it's actually been since Swing, not a
-- fixed per-punch number, since punches now land at client-reported times.
local function didNotTeleport(swingPosition: Vector3, currentPosition: Vector3, elapsed: number): boolean
	local maxMoved = RUN_SPEED * elapsed + Combat.Dash.distance
	return (currentPosition - swingPosition).Magnitude <= maxMoved
end

-- ==================== attack flow ====================

-- Shared by the AttackStart remote and CombatService.Attack (NPCs).
-- Returns whether an attack was actually started, and the swing it started
-- if so (so a caller that needs to know the punch timings - NpcService -
-- doesn't have to look it back up).
function CombatService.AttackStart(character: Model): (boolean, Combat.Swing?)
	local entry = registered[character]
	if entry == nil then
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

	local swing = Combat.swingFor(entry.weaponSet)
	if swing == nil or #swing.punches == 0 then
		log:Error(string.format("%s's weapon set %s has no swing data", character.Name, entry.weaponSet))
		return false, nil
	end

	local torso = character:FindFirstChild("HumanoidRootPart")
	local swingPosition = if torso and torso:IsA("BasePart") then (torso :: BasePart).Position else Vector3.zero

	entry.attackGeneration += 1
	local generation = entry.attackGeneration
	entry.attack = {
		swing = swing,
		startedAt = now,
		nextPunch = 1,
		swingPosition = swingPosition,
	}

	pcall(function()
		character:SetAttribute("Attacking", true)
		character:SetAttribute("ComboStep", 1)
	end)

	Remotes.Server.FireAll("CombatEvent", "Swing", { character = character, setName = entry.weaponSet, punchCount = #swing.punches })
	if combatLogEnabled then
		log:Info(string.format("%s starts %s (%d punches)", character.Name, swing.name, #swing.punches))
	end

	-- Watchdog: if the client never reports the final punch (desync, drop,
	-- a client that just stopped responding), don't leave the attacker
	-- stuck "Attacking" forever - end it silently, no CombatEvent, and
	-- start the normal cooldown as if it had landed.
	local lastPunch = swing.punches[#swing.punches]
	local watchdogDelay = lastPunch.hitWindow.max + Config.Combat.HitTolerance + swing.timeout
	task.delay(watchdogDelay, function()
		if entry.attack ~= nil and entry.attackGeneration == generation then
			if combatLogEnabled then
				log:Warn(string.format("%s's attack timed out waiting for the final AttackHit report", character.Name))
			end
			clearAttack(character, entry, swing.recovery)
		end
	end)

	return true, swing
end

-- Shared by the AttackHit remote and CombatService.Attack (NPCs).
function CombatService.AttackHit(character: Model, index: number)
	local entry = registered[character]
	if entry == nil or entry.attack == nil then
		if combatLogEnabled then
			log:Warn(string.format("%s's AttackHit(%d) dropped: no attack in progress", character.Name, index))
		end
		return
	end
	local attack = entry.attack :: PendingAttack

	if index ~= attack.nextPunch then
		if combatLogEnabled then
			log:Warn(string.format("%s's AttackHit(%d) dropped: expected punch %d (out of order or a duplicate)", character.Name, index, attack.nextPunch))
		end
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return
	end
	-- Defense in depth: onStatusChanged already interrupts (clears
	-- entry.attack) the instant Stun/TrueStun/Knocked turns on, and Block
	-- can't start while entry.attack ~= nil - so this should already be
	-- unreachable via those paths, but Roblox's deferred signal behavior
	-- means a status applied in the same frame might not have run its
	-- Changed handler yet.
	for status in BLOCKS_ATTACK do
		if StatusService.Has(character, status) then
			if combatLogEnabled then
				log:Warn(string.format("%s's AttackHit(%d) dropped: %s", character.Name, index, status))
			end
			return
		end
	end

	local now = Workspace:GetServerTimeNow()
	local elapsed = now - attack.startedAt
	local punch = attack.swing.punches[index]
	local tolerance = Config.Combat.HitTolerance

	if elapsed < punch.hitWindow.min - tolerance then
		if combatLogEnabled then
			log:Warn(
				string.format(
					"%s's AttackHit(%d) dropped: too early (elapsed %.2fs, window %.2f-%.2f)",
					character.Name,
					index,
					elapsed,
					punch.hitWindow.min,
					punch.hitWindow.max
				)
			)
		end
		return
	end
	if elapsed > punch.hitWindow.max + tolerance then
		if combatLogEnabled then
			log:Warn(
				string.format(
					"%s's AttackHit(%d) dropped: too late (elapsed %.2fs, window %.2f-%.2f)",
					character.Name,
					index,
					elapsed,
					punch.hitWindow.min,
					punch.hitWindow.max
				)
			)
		end
		return
	end

	local torso = character:FindFirstChild("HumanoidRootPart")
	if torso == nil or not torso:IsA("BasePart") or not didNotTeleport(attack.swingPosition, (torso :: BasePart).Position, elapsed) then
		if combatLogEnabled then
			log:Warn(string.format("%s's AttackHit(%d) dropped: moved too far since the swing", character.Name, index))
		end
		return
	end

	if combatLogEnabled then
		log:Info(string.format("%s's AttackHit(%d) accepted (elapsed %.2fs)", character.Name, index, elapsed))
	end

	local target = CombatService.FindTarget(character, punch)
	if target then
		CombatService.ApplyHit(character, target, punch, index)
	elseif combatLogEnabled then
		log:Info(string.format("%s's %s (punch %d) whiffed", character.Name, attack.swing.name, index))
	end

	-- CombatService.ApplyHit above may have interrupted the TARGET's own
	-- attack (a different Entry) or, on a parry, stunned this very
	-- attacker - but StatusService.Changed is a deferred BindableEvent, so
	-- that stun's own interrupt hasn't run yet; `entry`/`attack` here are
	-- still this attacker's live state either way.
	attack.nextPunch = index + 1
	if attack.nextPunch > #attack.swing.punches then
		clearAttack(character, entry, attack.swing.recovery)
		if combatLogEnabled then
			log:Info(string.format("%s's attack complete, recovery %.2fs", character.Name, attack.swing.recovery))
		end
	end
end

-- Shared by the AttackCancel remote and CombatService.Attack (NPCs, in
-- principle - NpcService doesn't cancel today, but nothing stops it later).
function CombatService.AttackCancel(character: Model)
	local entry = registered[character]
	if entry == nil or entry.attack == nil then
		if combatLogEnabled then
			log:Warn(string.format("%s's AttackCancel dropped: no attack in progress", character.Name))
		end
		return
	end
	local attack = entry.attack :: PendingAttack

	if attack.nextPunch ~= 1 then
		if combatLogEnabled then
			log:Warn(string.format("%s's AttackCancel dropped: punch 1 already landed", character.Name))
		end
		return
	end

	local now = Workspace:GetServerTimeNow()
	local elapsed = now - attack.startedAt
	local tolerance = Config.Combat.HitTolerance
	if elapsed > attack.swing.cancelWindow + tolerance then
		if combatLogEnabled then
			log:Warn(
				string.format(
					"%s's AttackCancel dropped: past the cancel window (elapsed %.2fs, window %.2fs)",
					character.Name,
					elapsed,
					attack.swing.cancelWindow
				)
			)
		end
		return
	end

	interruptAttack(character, "cancelled")
end

-- The NPC entry point (same signature as before M3-FIX3-S): starts the
-- swing exactly like a player's AttackStart, then schedules AttackHit
-- itself at the middle of each punch's hitWindow, so NPC punches go
-- through the identical validation (and can be interrupted the same way)
-- a player's own client-reported punches do.
function CombatService.Attack(character: Model)
	local started, swing = CombatService.AttackStart(character)
	if not started or swing == nil then
		return
	end

	for index, punch in swing.punches do
		local midpoint = (punch.hitWindow.min + punch.hitWindow.max) / 2
		task.delay(midpoint, function()
			CombatService.AttackHit(character, index)
		end)
	end
end

-- Shared by the Block() remote and NpcService (M3-04).
function CombatService.SetBlocking(character: Model, on: boolean)
	local entry = registered[character]
	if entry == nil then
		return
	end

	if on then
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
		-- M3-FIX3-S: can't start blocking while an attack (any punch of it)
		-- is still in progress - replaces the old H2 pendingHitUntil check
		-- now that a "swing" can span multiple punches.
		if entry.attack ~= nil then
			return
		end
		-- onStatusChanged applies the speed modifier/HealthService.SetBlocking
		-- (REVIEW-M3-03 M3) once this Changed(true) fires.
		StatusService.Apply(character, "Block", nil, { value = 1 })
	else
		if not StatusService.Has(character, "Block") then
			return
		end
		StatusService.Remove(character, "Block")
	end
end

-- ==================== register / unregister ====================

function CombatService.Register(character: Model, owner: Player?, weaponSet: string?)
	local existing = registered[character]
	if existing then
		existing.owner = owner
		return
	end

	local entry: Entry = {
		owner = owner,
		weaponSet = weaponSet or "Fist",
		attack = nil,
		attackGeneration = 0,
	}
	registered[character] = entry

	pcall(function()
		character:SetAttribute("WeaponSet", weaponSet or "Fist")
		character:SetAttribute("ComboStep", 1)
		character:SetAttribute("NextAttackAt", 0)
		character:SetAttribute("Attacking", false)
	end)

	-- REVIEW-M3-03 M4: unregistered on death or on leaving the game
	-- entirely, the same two triggers StatusService uses.
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
				CombatService.Unregister(character)
			end)
		end)
		if okDied then
			entry.diedConn = diedConn
		end
	end
end

function CombatService.Unregister(character: Model)
	local entry = registered[character]
	if entry == nil then
		return
	end
	registered[character] = nil
	-- M3-FIX3-S: an in-progress attack dies with the combatant - no event,
	-- nothing left to tell (the character is gone or leaving); this just
	-- stops a stale watchdog from touching a re-registered entry later
	-- (attackGeneration on THIS entry no longer matters once it's orphaned).
	entry.attack = nil
	if entry.ancestryConn then
		entry.ancestryConn:Disconnect()
	end
	if entry.diedConn then
		entry.diedConn:Disconnect()
	end
end

-- ==================== dev commands ====================

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
		StatusService.Apply(character, "Knocked", Combat.Knockout.getUpSeconds, { by = caller.Name })
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

	PlayerService.Ready:Connect(function(player: Player, character: Model)
		CombatService.Register(character, player, "Fist")
	end)

	StatusService.Changed:Connect(onStatusChanged)

	Players.PlayerRemoving:Connect(function(player: Player)
		local character = player.Character
		if character then
			CombatService.Unregister(character)
		end
	end)
end

function CombatService:Start() end

return CombatService

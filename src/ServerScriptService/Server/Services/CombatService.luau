--!strict
-- The server-authoritative combat core (M3-03, TRIAGE #10, fixes AUDIT
-- C2/H5/H6/M1/M2/M3-P2). Keyed by the combatant's character Model, never
-- by Player: NPCs attack and block through the exact same
-- CombatService.Attack/SetBlocking entry points a Player's remote calls use.
--
-- M3-FIX3-S (Bryan, 2026-09-28) replaced the old single server-timed swing
-- with an animation-driven hit sequence: AttackStart begins a swing and
-- broadcasts it; the client plays the animation and fires one AttackHit
-- report per hit marker, in order; the server validates every report's
-- timing window, order and the attacker's own position (anti-teleport)
-- before it counts for anything. The client STILL never reports what it
-- hit (C2 stays fixed) - only that a marker played - the server re-derives
-- the target with its own hit-check.
--
-- M3-FIX4-S (Bryan, 2026-09-28) built the fighting-style framework on top
-- of that: every weapon is a Combat.Style - a chain of Light/Heavy hits,
-- plus traits (Shared/Data/Combat.luau has the full rock-paper-scissors
-- writeup). Light: fast, can't be interrupted, no knockback of its own,
-- applies LightStun (blocks Block/parry only) on a landed hit. Heavy: slow,
-- big damage/block drain, and - while it's still the target's own next
-- unlanded hit - ANY hit landing on them interrupts their attack. Cancel is
-- now per-hit (each hit's own cancelUntil) and, depending on the style's
-- cancelInto trait, either returns the attacker to neutral ("Any") or
-- immediately throws a feint jab ("Jab") that punishes them with Recovery
-- if it gets blocked. Knockback is no longer per-hit: a shared HitCount
-- attribute triggers one impulse every `Combat.Knockback.everyHits` landed
-- hits, from any source, then resets. Bleed stacks on hits that carry it;
-- HealthService ticks it, floored at 1 HP so it never knocks out alone.
--
-- M3B-01 (Bryan, 2026-09-28) added the combat stance: combat is earned, not
-- automatic. SetStance(true) is the ONLY way AttackStart/AttackCancel/Block
-- ever become reachable (Dash/Run stay available regardless) - it needs
-- CombatUnlocked (Meta.Unlocks.Combat, or the blanket
-- Config.Combat.UnlockedByDefault until the tutorial ships) and a few
-- "can't fight right now" statuses to be clear. The equipped style now
-- comes from a weapon Tool in the character (a string `Weapon` attribute
-- naming the style), not just Register's own default - see
-- onToolEquipped/onToolUnequipped.

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
-- M3B-01: CombatUnlocked (Meta.Unlocks.Combat). Safe to require - the
-- reverse would be the cycle (DataService never requires CombatService).
local DataService = require(script.Parent.DataService)

local log = Log.new("CombatService")

-- Statuses that gate an AttackStart/AttackHit entirely (dead is checked
-- separately, via Humanoid.Health). M3-FIX4-S: Recovery (a punished feint)
-- joins the three that already blocked an attack outright.
local BLOCKS_ATTACK: { [string]: boolean } = { Stun = true, TrueStun = true, Knocked = true, Block = true, Recovery = true }
-- M3-FIX4-S: LightStun ("can't block or parry") and Recovery ("can't...
-- block") both forbid STARTING a block, same as the original three.
local BLOCKS_BLOCK_START: { [string]: boolean } = {
	Stun = true,
	TrueStun = true,
	Knocked = true,
	BlockBroken = true,
	LightStun = true,
	Recovery = true,
}
-- Statuses that force Block off outright the instant they turn on
-- (REVIEW-M3-03 M3) - onStatusChanged below reacts to all of these.
-- M3-FIX4-S: LightStun ends an active block/parry too ("blocks Block and
-- parry" - rule 1).
local ENDS_BLOCK: { [string]: boolean } = { Stun = true, TrueStun = true, Knocked = true, LightStun = true }
-- Statuses that also interrupt an in-progress attack the instant they turn
-- on, regardless of what caused them (a real hit, a dev command, anything)
-- - onStatusChanged below reacts to all three. This is what actually
-- interrupts a target whenever a HEAVY lands on them, whatever they were
-- doing (a Heavy always applies a real Stun - see ApplyHit) - confirmed
-- intended, REVIEW-M3-FIX4-S M2: heavy stun overrides even a Light in
-- progress. A LANDED LIGHT never reaches this table (every Light's own
-- `stun` is 0) - it can only interrupt a target through the separate,
-- kind-conditional check in ApplyHit below (only when the target's own
-- next unlanded hit is a Heavy), matching rule 1: "a Light cannot be
-- interrupted [by another Light]". NOT LightStun or Recovery here: rule 1
-- doesn't gate an attack on LightStun at all, and Recovery only ever turns
-- on once a feint's own AttackHit has already resolved and ended that
-- chain itself (see applyBlockedHit, H2).
local INTERRUPTS_ATTACK: { [string]: boolean } = { Stun = true, TrueStun = true, Knocked = true }

-- Statuses that also freeze/slow movement while active - a single named
-- MovementService modifier per status, set/cleared alongside StatusService
-- (M3-02's own modifier-name list already reserves these names). Kept
-- here, not in MovementService, so CombatService stays the one place that
-- decides when a status starts or ends (M3-01's own design note). No entry
-- for LightStun/Recovery (M3-FIX4-S): neither slows movement.
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

-- One in-progress swing: which chain hit is still owed, when it started,
-- and where the attacker's HRP was then (the anti-teleport baseline).
-- M3-FIX4-S: `style` replaces the old flat `swing`; `feint` marks an attack
-- the server itself started (a cancel-into-jab), used to tag hit 1's own
-- Hit event and to punish a blocked hit 1 with Recovery.
type PendingAttack = {
	style: Combat.Style,
	startedAt: number,
	nextHit: number,
	swingPosition: Vector3,
	feint: boolean,
}

type Entry = {
	owner: Player?,
	weaponSet: string,
	lastCombatAt: number?,
	parryCooldownUntil: number?,
	attack: PendingAttack?,
	-- Bumped on every AttackStart (including a feint's own internal one); a
	-- watchdog closure captures its own value and checks it still matches
	-- before acting, so a stale watchdog from an attack that already ended
	-- (landed, cancelled, interrupted) can never reach into a LATER
	-- attack's state.
	attackGeneration: number,
	-- M3-FIX4-S: the count-based knockback (Combat.Knockback). +1 per
	-- landed hit taken from any source; resets on a knockback impulse, on
	-- knockout, or on its own after Combat.Knockback.resetAfterSeconds of
	-- no further hits.
	hitCount: number,
	lastHitCountAt: number?,
	ancestryConn: RBXScriptConnection?,
	diedConn: RBXScriptConnection?,
	-- M3B-01: watches the character for an equipped/unequipped weapon Tool
	-- (a string `Weapon` attribute naming a style) - see onToolEquipped/
	-- onToolUnequipped.
	toolAddedConn: RBXScriptConnection?,
	toolRemovedConn: RBXScriptConnection?,
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
		-- M3B-02: the trainer dummies read this to know whether a Light or a
		-- Heavy is the one currently swinging (their own reaction window) -
		-- "" once nothing is.
		character:SetAttribute("CurrentHit", "")
		character:SetAttribute("NextAttackAt", Workspace:GetServerTimeNow() + nextAttackDelay)
	end)
end

-- Ends an in-progress attack because the combatant got interrupted: either
-- ApplyHit's own kind-conditional check below (their next unlanded hit was
-- a Heavy), or Stun/TrueStun/Knocked turning on for any reason at all (a
-- dev command, a broken block's TrueStun, anything - via onStatusChanged).
-- A no-op if there's no attack in progress (safe to call speculatively).
-- The cut-short hit's own `stun` pays the next cooldown - getting hit mid-
-- swing costs more than a clean cancel does (which is always free, see
-- AttackCancel below).
local function interruptAttack(character: Model)
	local entry = registered[character]
	if entry == nil or entry.attack == nil then
		return
	end
	local attack = entry.attack
	local hit = attack.style.chain[attack.nextHit]
	local nextAttackDelay = if hit then hit.stun else attack.style.recovery

	clearAttack(character, entry, nextAttackDelay)
	Remotes.Server.FireAll("CombatEvent", "AttackCancelled", { character = character, reason = "interrupted" })
	if combatLogEnabled then
		log:Info(string.format("%s's attack interrupted (next attack in %.2fs)", character.Name, nextAttackDelay))
	end
end

-- M3-FIX4-S: resets the count-based knockback tracker (Combat.Knockback -
-- see registerHitCount below). Defined up here, ahead of onStatusChanged,
-- which is the ONE place that calls it (REVIEW-M3-FIX4-S L1: a knockout
-- resets HitCount no matter what caused it - a landed hit, `.knock`, or
-- any other StatusService.Apply(..., "Knocked") - matching this file's own
-- "one place owns what happens when a status turns on" rule, the same one
-- onStatusChanged itself already follows for everything else).
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
-- call, a dev command, the shared expiry loop...). Also the one place that
-- interrupts an in-progress attack when Stun/TrueStun/Knocked turns on,
-- however it turned on.
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
		interruptAttack(character)
	end

	if status == "Knocked" then
		if active then
			-- REVIEW-M3-FIX4-S L1: every knockout resets the count-based
			-- knockback tracker, not just the ones ApplyHit itself causes.
			resetHitCount(character)
			-- REVIEW-M3B-01 H1: knockout drops a PLAYER out of the combat
			-- stance ("knockout, death and the death scene clear it") -
			-- never an NPC, which is always InCombat by design (NpcService
			-- sets it once at registration and never toggles it).
			local entry = registered[character]
			if entry and entry.owner ~= nil then
				pcall(function()
					character:SetAttribute("InCombat", false)
				end)
			end
		end
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

-- M3-FIX4-S: the count-based knockback (Combat.Knockback) - +1 per landed
-- hit taken, from any source; every `everyHits`th hit fires one impulse
-- (away from whoever landed THIS hit) and resets to 0. Also reschedules
-- its own idle-reset check (Combat.Knockback.resetAfterSeconds without a
-- further hit) - `entry.lastHitCountAt` is captured so a stale check from
-- an earlier hit can't reset a count a NEWER hit has since moved on from.
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

-- M3-FIX4-S: stacks a hit's own bleedStacks onto the target's Bleed status,
-- capped at the causing style's own maxStacks, refreshing (not extending)
-- the duration on every new stack - the config (tick rate/duration/cap)
-- rides along in the status data itself so HealthService's tick doesn't
-- need to know which style caused it.
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

-- AUDIT M1: blocking makes you immune to the hit's damage/stun/knockback
-- entirely while the block holds. Only a broken block, a back hit or no
-- block at all lets any of that through. M3-FIX4-S: `hit.blockDrain`
-- replaces the old flat Combat.Block.drainPerHit; a blocked FEINT (not
-- parried) punishes the attacker with Recovery (rule 4).
local function applyBlockedHit(attacker: Model, target: Model, style: Combat.Style, hit: Combat.ChainHit, isFeint: boolean)
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
	local meterHeld = if wouldParry then true else HealthService.SpendBlock(healthCombatant(target), hit.blockDrain)

	local outcome = CombatService.ResolveBlock(parrying, cooldownActive, meterHeld)

	if outcome == "Parried" then
		if entry then
			entry.parryCooldownUntil = Workspace:GetServerTimeNow() + Combat.Block.parryCooldown
		end
		-- The parried attacker's own swing is punished twice over: stunned,
		-- AND (below, via onStatusChanged reacting to that Stun) their own
		-- in-progress attack is interrupted if they hadn't finished it yet.
		-- Parry beats a Light and a Heavy alike (rule 5) - unconditional.
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
			-- REVIEW-M3-FIX4-S H2: a blocked (not parried) feint ends the
			-- feinter's WHOLE chain outright, not just this one hit -
			-- Recovery alone isn't enough, since it's short (feintRecovery-
			-- Seconds) and entry.attack would otherwise still be "in
			-- progress": once Recovery's own duration ran out, a later
			-- chain hit still inside its own hitWindow (+tolerance) could
			-- land anyway, letting the feinter's combo continue right past
			-- the punish it was supposed to eat.
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
-- pipeline. `feint` (default false) marks hit 1 of an attack the server
-- itself started via a cancel-into-jab (Combat.Style.cancelInto == "Jab").
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
			applyBlockedHit(attacker, target, style, hit, isFeint)
			return
		end
		-- A back hit bypasses (and ends) the block entirely; onStatusChanged
		-- clears the speed modifier/HealthService flag (REVIEW-M3-03 M3).
		StatusService.Remove(target, "Block")
	end

	-- M3-FIX4-S rule 2: this kind-conditional check only covers a LIGHT
	-- landing while the target's own next unlanded hit is a Heavy - rule
	-- 1's "a Light cannot be interrupted" is about what kind of hit the
	-- TARGET is throwing, not what kind just landed on them. A HEAVY
	-- landing interrupts the target's attack EITHER WAY, Light or Heavy
	-- pending: not through this check, but because every Heavy applies a
	-- real `Stun` below, and Stun turning on interrupts unconditionally via
	-- onStatusChanged (INTERRUPTS_ATTACK). REVIEW-M3-FIX4-S M2, confirmed
	-- intended (Bryan): heavy stun overrides a Light in progress; only a
	-- Light can never interrupt a Light. A parry/block returned above
	-- already, so this only ever runs for a hit that actually connects.
	local targetEntry = registered[target]
	if targetEntry and targetEntry.attack then
		local pendingHit = targetEntry.attack.style.chain[targetEntry.attack.nextHit]
		if pendingHit and pendingHit.kind == "Heavy" then
			interruptAttack(target)
		end
	end

	local by = attackerLabel(attacker)

	-- AUDIT C2's "knock them out instead of dying" path must never let
	-- Humanoid.Health actually reach 0: Roblox fires Humanoid.Died itself
	-- the instant Health hits 0, which would kill the character before
	-- any of this code could set it back to 1. So the would-be result is
	-- computed BEFORE touching Health at all.
	local wouldBeHealth = targetHumanoid.Health - hit.damage
	if wouldBeHealth <= 0 then
		targetHumanoid.Health = 1
		-- Resets HitCount too, via onStatusChanged's own Knocked handler
		-- (REVIEW-M3-FIX4-S L1) - one place, regardless of what caused it.
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
	HealthService.TakeDamage(healthCombatant(target), hit.damage, by)

	-- M3-FIX4-S: Stagger's brief "Hit" flinch/slow is Heavy-only now; a
	-- landed Light applies its own softer LightStun instead (rule 1), and
	-- a full Stun only if this hit's own `stun` is nonzero (every Light in
	-- the data below is 0 - only Heavies carry a real Stun).
	if hit.kind == "Heavy" then
		StatusService.Apply(target, "Hit", Combat.Stagger.hitStun, { kind = style.displayName })
	end
	if hit.stun > 0 then
		StatusService.Apply(target, "Stun", hit.stun)
	end
	if hit.lightStun > 0 then
		StatusService.Apply(target, "LightStun", hit.lightStun)
	end
	if hit.bleedStacks > 0 and style.bleed then
		applyBleed(target, style, hit.bleedStacks)
	end

	-- M3-FIX4-S: no more per-hit knockback impulse - only the count-based
	-- one (Combat.Knockback), which fires (or doesn't) from inside here.
	registerHitCount(attacker, target)

	Remotes.Server.FireAll("CombatEvent", "Hit", { attacker = attacker, target = target, hitIndex = hitIndex, kind = hit.kind, feint = isFeint })
	if combatLogEnabled then
		log:Info(string.format("%s hit %s with %s's %s for %d", attacker.Name, target.Name, style.displayName, hit.name, hit.damage))
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

-- A single generous sphere covering the hit's reach, centred half its
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
-- wide-radius/short-range hit).
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
-- fixed per-hit number, since chain hits now land at client-reported times.
local function didNotTeleport(swingPosition: Vector3, currentPosition: Vector3, elapsed: number): boolean
	local maxMoved = RUN_SPEED * elapsed + Combat.Dash.distance
	return (currentPosition - swingPosition).Magnitude <= maxMoved
end

-- ==================== attack flow ====================

-- Shared by AttackStart, AttackCancel's cancel-into-jab follow-up, and
-- CombatService.Attack (NPCs). Returns whether an attack was actually
-- started, and the style it started if so (so a caller that needs to know
-- the chain timings - NpcService - doesn't have to look it back up).
-- `feint` (from AttackCancel's cancelInto == "Jab" path) is carried onto
-- the new PendingAttack untouched; every other gating rule is identical
-- either way.
local function beginAttack(character: Model, feint: boolean): (boolean, Combat.Style?)
	local entry = registered[character]
	if entry == nil then
		return false, nil
	end
	-- M3B-01: clicks outside the combat stance are nothing, on the server
	-- as well as on the client. NPCs are always InCombat (NpcService sets
	-- it at registration), so this never gates them.
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

	entry.attackGeneration += 1
	local generation = entry.attackGeneration
	entry.attack = {
		style = style,
		startedAt = now,
		nextHit = 1,
		swingPosition = swingPosition,
		feint = feint,
	}

	pcall(function()
		character:SetAttribute("Attacking", true)
		character:SetAttribute("ComboStep", 1)
		character:SetAttribute("CurrentHit", style.chain[1].kind)
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

	-- Watchdog: if the client never reports the final hit (desync, drop, a
	-- client that just stopped responding), don't leave the attacker stuck
	-- "Attacking" forever - end it silently, no CombatEvent, and start the
	-- normal cooldown as if it had landed.
	local lastHit = style.chain[#style.chain]
	local watchdogDelay = lastHit.hitWindow.max + Config.Combat.HitTolerance + style.timeout
	task.delay(watchdogDelay, function()
		if entry.attack ~= nil and entry.attackGeneration == generation then
			if combatLogEnabled then
				log:Warn(string.format("%s's attack timed out waiting for the final AttackHit report", character.Name))
			end
			clearAttack(character, entry, style.recovery)
		end
	end)

	return true, style
end

-- Shared by the AttackStart remote and CombatService.Attack (NPCs).
function CombatService.AttackStart(character: Model): (boolean, Combat.Style?)
	return beginAttack(character, false)
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
	-- Defense in depth: onStatusChanged already interrupts (clears
	-- entry.attack) the instant Stun/TrueStun/Knocked turns on, and Block/
	-- LightStun/Recovery can't start while entry.attack ~= nil or while
	-- already active - so this should already be unreachable via those
	-- paths, but Roblox's deferred signal behavior means a status applied
	-- in the same frame might not have run its Changed handler yet. This
	-- ALSO doubles as the mechanism that stops a blocked feint's own
	-- Recovery (applied mid-chain, below) from letting the rest of the
	-- chain continue.
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
	if torso == nil or not torso:IsA("BasePart") or not didNotTeleport(attack.swingPosition, (torso :: BasePart).Position, elapsed) then
		if combatLogEnabled then
			log:Warn(string.format("%s's AttackHit(%d) dropped: moved too far since the swing", character.Name, index))
		end
		return
	end

	if combatLogEnabled then
		log:Info(string.format("%s's AttackHit(%d) accepted (elapsed %.2fs, %s)", character.Name, index, elapsed, hit.kind))
	end

	local target = CombatService.FindTarget(character, hit)
	if target then
		local isFeintHit = attack.feint and index == 1
		CombatService.ApplyHit(character, target, attack.style, hit, index, isFeintHit)
	elseif combatLogEnabled then
		log:Info(string.format("%s's %s (hit %d) whiffed", character.Name, attack.style.displayName, index))
	end

	-- CombatService.ApplyHit above may have interrupted the TARGET's own
	-- attack (a different Entry), stunned this very attacker on a parry, or
	-- applied Recovery to this very attacker on a blocked feint - but
	-- StatusService.Changed is a deferred BindableEvent, so none of THOSE
	-- side effects has run its own handler yet; `entry`/`attack` here are
	-- still this attacker's live state either way, and the very next
	-- AttackHit call (if the chain continues) is what the BLOCKS_ATTACK
	-- check above actually catches Recovery/Stun with.
	attack.nextHit = index + 1
	if attack.nextHit > #attack.style.chain then
		clearAttack(character, entry, attack.style.recovery)
		if combatLogEnabled then
			log:Info(string.format("%s's attack complete, recovery %.2fs", character.Name, attack.style.recovery))
		end
	else
		local nextChainHit = attack.style.chain[attack.nextHit]
		pcall(function()
			character:SetAttribute("CurrentHit", nextChainHit.kind)
		end)
	end
end

-- Shared by the AttackCancel remote and CombatService.Attack (NPCs, in
-- principle - NpcService doesn't cancel today, but nothing stops it later).
-- M3-FIX4-S: cancel is per-hit now (the next unlanded hit's own
-- cancelUntil, not a single swing-level window). Free before any hit has
-- landed (the bait); costs a full chain's own cooldown once at least one
-- has (REVIEW-M3-FIX4-S H3, below). What happens next depends on the
-- style's cancelInto trait (see the comment above Combat.Styles.Fist in
-- Shared/Data/Combat.luau).
function CombatService.AttackCancel(character: Model)
	local entry = registered[character]
	if entry == nil or entry.attack == nil then
		if combatLogEnabled then
			log:Warn(string.format("%s's AttackCancel dropped: no attack in progress", character.Name))
		end
		return
	end
	-- M3B-01: matches AttackStart's own gate. In practice this should
	-- already be unreachable while an attack is genuinely in progress
	-- (nothing turns InCombat off mid-swing on its own), but the contract
	-- is explicit that AttackCancel is rejected outside the stance too.
	if character:GetAttribute("InCombat") ~= true then
		return
	end
	local attack = entry.attack :: PendingAttack
	local hit = attack.style.chain[attack.nextHit]
	if hit == nil then
		return
	end

	local now = Workspace:GetServerTimeNow()
	local elapsed = now - attack.startedAt
	local tolerance = Config.Combat.HitTolerance
	if elapsed > hit.cancelUntil + tolerance then
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

	-- REVIEW-M3-FIX4-S H3: cancelling is free ONLY before any hit in this
	-- chain has landed (cancelledAtHit == 1 still) - that's the intended
	-- bait, a swing that never committed to anything. Cancelling once at
	-- least one hit already landed is a different move (finish a Jab, then
	-- bail on the rest of the chain) and must cost the same cooldown a full
	-- chain would, or "land hit 1, cancel, restart" beats a full chain's
	-- own DPS for free every time. NextAttackAt = startedAt + style.recovery
	-- + chain[1].hitWindow.min: the earliest the NEXT swing's own first hit
	-- could land is then startedAt + recovery + 2 x chain[1].hitWindow.min,
	-- matching a full chain's own first-hit-to-first-hit cadence instead of
	-- beating it. beginAttack (including the cancel-into-jab path just
	-- below) already checks NextAttackAt, so setting it here is enough - a
	-- feint that follows a landed hit simply waits for it; a feint after a
	-- free cancel (no hit landed) stays free, which is the bait.
	if cancelledAtHit > 1 then
		local cooldownEndsAt = attack.startedAt + style.recovery + style.chain[1].hitWindow.min
		clearAttack(character, entry, cooldownEndsAt - now)
	else
		clearAttack(character, entry, 0)
	end
	Remotes.Server.FireAll("CombatEvent", "AttackCancelled", { character = character, reason = "cancelled" })
	if combatLogEnabled then
		log:Info(string.format("%s's attack cancelled at hit %d (elapsed %.2fs)", character.Name, cancelledAtHit, elapsed))
	end

	if style.cancelInto == "Jab" then
		beginAttack(character, true)
	end
end

-- The NPC entry point (same signature as before M3-FIX3-S): starts the
-- swing exactly like a player's AttackStart, then schedules AttackHit
-- itself at the middle of each chain hit's hitWindow, so NPC hits go
-- through the identical validation (and can be interrupted the same way)
-- a player's own client-reported hits do.
function CombatService.Attack(character: Model)
	local started, style = beginAttack(character, false)
	if not started or style == nil then
		return
	end
	local entry = registered[character]
	if entry == nil then
		return
	end
	-- REVIEW-M3-FIX3-S L2: captured so a stale timer from an attack that got
	-- interrupted/cancelled/re-started can't consume a LATER attack's hit.
	local generation = entry.attackGeneration

	for index, hit in style.chain do
		local midpoint = (hit.hitWindow.min + hit.hitWindow.max) / 2
		task.delay(midpoint, function()
			if entry.attackGeneration ~= generation then
				return
			end
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
		-- M3B-01: only gates STARTING a block - releasing one always has to
		-- work regardless of InCombat, or a player who leaves the stance
		-- (or gets Dying-frozen) mid-block would be stuck holding it
		-- forever with no way to ever call this with `on = false` again.
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
		-- Can't start blocking while an attack (any hit of it) is still in
		-- progress.
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

-- M3-FIX4-S: the `.weapon` dev command's own entry point - also usable
-- later by a shop/equip flow. Ends any in-progress attack outright rather
-- than trying to carry a chain index over into a style that might not even
-- have that many hits.
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

-- M3B-01: the combat stance. AttackStart/AttackCancel/Block all require
-- InCombat to be true (Dash/Run don't). Leaving is always accepted;
-- entering needs the owning Player's own CombatUnlocked (a real registered
-- Player only - an NPC never calls this, it's always InCombat from
-- NpcService instead), alive, and clear of a short list of "can't fight
-- right now" states. Returns whether the requested state was applied.
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
	-- The age-death scene (AgeService.startDeathSequence): frozen, about to
	-- respawn into a fresh life - not a state to start a fight from.
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
-- M3B-01: the equipped style comes from a weapon Tool in the character (a
-- string `Weapon` attribute naming a Combat.Style) - CharacterService/
-- backpack code decides what a player can equip, this just reacts to it.
-- `.weapon [style] [player]` (below) keeps working as a dev override, but
-- the next tool equip or unequip always wins over it, same as a real one
-- would.

local function onToolEquipped(character: Model, tool: Tool)
	local weaponName = tool:GetAttribute("Weapon")
	if type(weaponName) ~= "string" then
		-- The common case: most Tools (non-weapons) don't carry this
		-- attribute at all - nothing to warn about.
		return
	end
	if Combat.styleFor(weaponName) == nil then
		-- REVIEW-M3B-01 M1: unlike a missing attribute, a Weapon string that
		-- names no real style (a typo, or a style retired later) is a real
		-- misconfiguration - warn instead of silently leaving whatever style
		-- was equipped before, and fall back to Fist so the combatant is
		-- never left on a style the client can't actually see a Tool for.
		log:Warn(string.format("%s's Tool %q has an unknown Weapon attribute %q; falling back to Fist", character.Name, tool.Name, weaponName))
		CombatService.SetWeapon(character, "Fist")
		return
	end
	CombatService.SetWeapon(character, weaponName)
end

-- Unequipping ANY weapon tool drops the style back to Fist outright - not
-- "whatever it was before this one," which nothing here tracks and the
-- design doesn't ask for (rule 2: "unequip -> Fist").
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
		character:SetAttribute("CurrentHit", "")
		character:SetAttribute("HitCount", 0)
		-- M3B-01: NPCs are always InCombat - NpcService flips this right
		-- after this same Register call; a player starts out of the stance.
		character:SetAttribute("InCombat", false)
	end)
	MovementService.SetStyle(character, resolvedWeaponSet)

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
				-- REVIEW-M3B-01 H1: a dead PLAYER's corpse shouldn't keep
				-- playing the InCombat stance idle for other clients (an NPC
				-- is always InCombat and Unregister tears its whole entry
				-- down right after this regardless, so this is a no-op for
				-- one).
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

	-- M3B-01: the equipped style tracks whichever weapon Tool (if any) is
	-- parented into the character right now, and every equip/unequip after.
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
	-- An in-progress attack dies with the combatant - no event, nothing
	-- left to tell (the character is gone or leaving); this just stops a
	-- stale watchdog from touching a re-registered entry later
	-- (attackGeneration on THIS entry no longer matters once it's orphaned).
	-- Clear the attribute too, for tidiness, while the character instance
	-- still exists (a corpse, or a leaving player).
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
-- M3B-01: CombatUnlocked mirrors `data.Meta.Unlocks.Combat OR
-- Config.Combat.UnlockedByDefault` - the blanket default lets everyone
-- fight until the tutorial (a later milestone) actually exists to earn it
-- properly; once Bryan flips that to false, this starts reflecting the
-- save flag alone. Meta, not Progress: the unlock is per-player forever,
-- not per-life (DataService.NewLife carries it over; only DataService.Wipe
-- clears it, same as a brand-new player). RankService-style: a public API
-- (for the future tutorial to call, same as AddMagoi/AddDeed) plus the same
-- DataService.Loaded wiring RankService uses to refresh the attribute on
-- load.

local function refreshCombatUnlockedAttribute(player: Player, data: SaveSchema.Data)
	player:SetAttribute("CombatUnlocked", data.Meta.Unlocks.Combat or Config.Combat.UnlockedByDefault)
end

function CombatService.SetUnlocked(player: Player, unlocked: boolean)
	local data = DataService.Get(player)
	if data == nil then
		log:Warn(string.format("SetUnlocked(%s, %s): no save loaded", player.Name, tostring(unlocked)))
		return
	end
	data.Meta.Unlocks.Combat = unlocked
	refreshCombatUnlockedAttribute(player, data)
	log:Info(string.format("%s's combat unlock: %s", player.Name, tostring(unlocked)))

	-- REVIEW-M3B-01 L1: locking someone already in the stance has to
	-- actually leave it - CombatUnlocked going false doesn't do that on its
	-- own (SetStance only ever checks it on the way IN).
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
				"  %d. %s (%s): windupAt=%.2f cancelUntil=%.2f hitWindow=%.2f-%.2f damage=%d stun=%.2f lightStun=%.2f blockDrain=%d bleedStacks=%d windupSpeed=%.2f",
				i,
				hit.name,
				hit.kind,
				hit.windupAt,
				hit.cancelUntil,
				hit.hitWindow.min,
				hit.hitWindow.max,
				hit.damage,
				hit.stun,
				hit.lightStun,
				hit.blockDrain,
				hit.bleedStacks,
				hit.windupSpeed
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
		CombatService.SetUnlocked(target, true)
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
		CombatService.SetUnlocked(target, false)
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
		local character = player.Character
		if character then
			CombatService.Unregister(character)
		end
	end)
end

function CombatService:Start()
	-- M3B-01: same catch-up pattern RankService uses for its own attributes
	-- - a player whose save already loaded before this connection was made
	-- (Start() runs after every service's Init()) still gets CombatUnlocked
	-- set from their own data, not left unset.
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

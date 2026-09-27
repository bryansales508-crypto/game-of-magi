--!strict
-- The server-authoritative combat core (M3-03, TRIAGE #10, fixes AUDIT
-- C2/H5/H6/M1/M2/M3-P2). Keyed by the combatant's character Model, never
-- by Player: NPCs attack and block through the exact same
-- CombatService.Attack/SetBlocking entry points a Player's Attack()/Block()
-- remote calls use. The client only ever sends an intention (Attack,
-- Block(on)); it never reports what it hit (C2) - every hit is a real
-- server-side spatial query run at the move's own hit time.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Combat = require(ReplicatedStorage.Shared.Data.Combat)
local PlayerService = require(script.Parent.PlayerService)
local StatusService = require(script.Parent.StatusService)
local MovementService = require(script.Parent.MovementService)
local HealthService = require(script.Parent.HealthService)
local DevService = require(script.Parent.DevService)

local log = Log.new("CombatService")

-- Statuses that gate an Attack/Block entirely (dead is checked
-- separately, via Humanoid.Health).
local BLOCKS_ATTACK: { [string]: boolean } = { Stun = true, TrueStun = true, Knocked = true, Block = true }
local BLOCKS_BLOCK_START: { [string]: boolean } = { Stun = true, TrueStun = true, Knocked = true, BlockBroken = true }

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

type Entry = {
	owner: Player?,
	weaponSet: string,
	comboStep: number,
	lastHitAt: number?,
	parryCooldownUntil: number?,
}

local registered: { [Model]: Entry } = {}
local combatLogEnabled = false

local CombatService = {}

-- ==================== pure helpers (self-tested directly) ====================

-- Whether the swing that just landed at `previousMoveIndex` still counts
-- as the same combo chain `now` (server clock) seconds later.
function CombatService.NextComboStep(previousStep: number, comboWindow: number, lastHitAt: number?, now: number): number
	if lastHitAt and (now - lastHitAt) <= comboWindow then
		return previousStep + 1
	end
	return 1
end

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

-- ==================== movement/status coupling ====================

local function onStatusChanged(character: Model, status: string, active: boolean)
	local mult = MOVEMENT_MULT_FOR[status]
	if mult == nil then
		return
	end
	if active then
		MovementService.SetModifier(character, status, mult)
	else
		MovementService.ClearModifier(character, status)
	end

	if status == "Knocked" and not active then
		-- Recovered, whether by the getUpSeconds timer or an early
		-- Remove (a dev command, say): come back up at the fixed floor,
		-- never however much health TakeDamage would otherwise have left.
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			humanoid.Health = math.max(humanoid.Health, Combat.Knockout.healthOnGetUp * humanoid.MaxHealth)
			Remotes.Server.FireAll("CombatEvent", "Recovered", { target = character })
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

	-- Held (not a parry): drains the block meter; HealthService owns that
	-- number and its own MaxBlock cap (AUDIT M2: nothing here ever adds
	-- block back on a parry, so there's no cap to overshoot any more). A
	-- target with no real Player behind it (pre-M3-04, no NPC is ever a
	-- real combat target yet) has no meter to drain, so its block just
	-- always holds.
	local targetPlayer = Players:GetPlayerFromCharacter(target)
	local meterHeld = if targetPlayer then HealthService.SpendBlock(targetPlayer, Combat.Block.drainPerHit) else true

	local outcome = CombatService.ResolveBlock(parrying, cooldownActive, meterHeld)

	if outcome == "Parried" then
		if entry then
			entry.parryCooldownUntil = Workspace:GetServerTimeNow() + Combat.Block.parryCooldown
		end
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
		StatusService.Remove(target, "Block")
		MovementService.ClearModifier(target, "Block")
		StatusService.Apply(target, "TrueStun", Combat.Block.breakStun)
		StatusService.Apply(target, "BlockBroken", Combat.Block.breakStun)
		Remotes.Server.FireAll("CombatEvent", "BlockBroken", { target = target })
		if combatLogEnabled then
			log:Info(string.format("%s's block broke against %s", target.Name, attacker.Name))
		end
	end
end

-- Exported (not just local) so the self-test can drive it directly with
-- fake models, without going through the full Attack()/hit-check pipeline.
function CombatService.ApplyHit(attacker: Model, target: Model, move: Combat.Move, moveIndex: number)
	local targetHumanoid = target:FindFirstChildOfClass("Humanoid")
	local attackerHrp = attacker:FindFirstChild("HumanoidRootPart")
	local targetHrp = target:FindFirstChild("HumanoidRootPart")
	if targetHumanoid == nil or attackerHrp == nil or targetHrp == nil then
		return
	end
	if targetHumanoid.Health <= 0 then
		return
	end

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
		-- A back hit bypasses (and ends) the block entirely.
		StatusService.Remove(target, "Block")
		MovementService.ClearModifier(target, "Block")
	end

	local by = attackerLabel(attacker)

	-- AUDIT C2's "knock them out instead of dying" path must never let
	-- Humanoid.Health actually reach 0: Roblox fires Humanoid.Died itself
	-- the instant Health hits 0, which would kill the character before
	-- any of this code could set it back to 1. So the would-be result is
	-- computed BEFORE touching Health at all.
	local wouldBeHealth = targetHumanoid.Health - move.damage
	if wouldBeHealth <= 0 then
		targetHumanoid.Health = 1
		StatusService.Apply(target, "Knocked", Combat.Knockout.getUpSeconds, { by = by })
		Remotes.Server.FireAll("CombatEvent", "Knocked", { target = target, by = by })
		if combatLogEnabled then
			log:Info(string.format("%s knocked out %s", attacker.Name, target.Name))
		end
		return
	end

	local targetPlayer = Players:GetPlayerFromCharacter(target)
	if targetPlayer then
		HealthService.TakeDamage(targetPlayer, move.damage, by)
	else
		-- Pre-M3-04: no NPC is ever a real combat target yet (NpcService
		-- registers them with HealthService itself once it exists).
		targetHumanoid.Health = wouldBeHealth
	end

	StatusService.Apply(target, "Hit", Combat.Stagger.hitStun, { kind = "Fist" })
	StatusService.Apply(target, "Stun", move.stun)
	knockback(attacker, target, move.knockback)

	Remotes.Server.FireAll(
		"CombatEvent",
		"Hit",
		{ attacker = attacker, target = target, moveIndex = moveIndex, finisher = move.finisher == true, knockback = move.knockback }
	)
	if combatLogEnabled then
		log:Info(string.format("%s hit %s with %s for %d", attacker.Name, target.Name, move.name, move.damage))
	end
end

-- ==================== hit-check ====================

-- A single generous sphere covering the move's reach, centred half its
-- range in front of the attacker's torso: a simple, well-supported
-- approximation of a forward capsule swing that doesn't depend on the
-- third-party ShapecastHitbox module's (unverified) server-side behavior.
-- GetPartBoundsInRadius returns parts nearest-first, so the first
-- resolved combatant found really is the first one struck. Exported (not
-- just local) so the self-test can exercise the geometry directly with
-- fake models - in range, out of range, and behind the attacker.
function CombatService.FindTarget(attacker: Model, move: Combat.Move): Model?
	local torso = attacker:FindFirstChild("HumanoidRootPart")
	if torso == nil or not torso:IsA("BasePart") then
		return nil
	end
	local origin = (torso :: BasePart).Position + (torso :: BasePart).CFrame.LookVector * (move.range / 2)
	local searchRadius = move.range / 2 + move.radius

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

	for _, part in parts :: { BasePart } do
		local target = resolveCombatant(part)
		if target and target ~= attacker then
			return target
		end
	end
	return nil
end

local function runHitCheck(attacker: Model, move: Combat.Move, moveIndex: number)
	if registered[attacker] == nil or attacker.Parent == nil then
		return
	end
	if StatusService.Has(attacker, "Stun") or StatusService.Has(attacker, "TrueStun") or StatusService.Has(attacker, "Knocked") then
		-- Interrupted mid-swing: the Swing already played, it just
		-- doesn't connect.
		return
	end

	local target = CombatService.FindTarget(attacker, move)
	if target then
		CombatService.ApplyHit(attacker, target, move, moveIndex)
	elseif combatLogEnabled then
		log:Info(string.format("%s's %s whiffed", attacker.Name, move.name))
	end
end

-- ==================== public API ====================

-- Shared by the Attack() remote and NpcService (M3-04): identical rules
-- either way, keyed by character Model only.
function CombatService.Attack(character: Model)
	local entry = registered[character]
	if entry == nil then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return
	end
	for status in BLOCKS_ATTACK do
		if StatusService.Has(character, status) then
			return
		end
	end

	local now = Workspace:GetServerTimeNow()
	local nextAttackAt = character:GetAttribute("NextAttackAt")
	if type(nextAttackAt) == "number" and now < nextAttackAt then
		return
	end

	local previousMove = Combat.move(entry.weaponSet, entry.comboStep)
	local comboWindow = if previousMove then previousMove.comboWindow else 0
	entry.comboStep = CombatService.NextComboStep(entry.comboStep, comboWindow, entry.lastHitAt, now)

	local move = Combat.move(entry.weaponSet, entry.comboStep)
	if move == nil then
		return
	end

	entry.lastHitAt = now
	character:SetAttribute("ComboStep", entry.comboStep)
	character:SetAttribute("NextAttackAt", now + move.windup + move.recovery)

	local moveIndex = entry.comboStep
	Remotes.Server.FireAll("CombatEvent", "Swing", { character = character, setName = entry.weaponSet, moveIndex = moveIndex })
	if combatLogEnabled then
		log:Info(string.format("%s swings %s (%s)", character.Name, move.name, entry.weaponSet))
	end

	task.delay(move.hitTime, function()
		runHitCheck(character, move, moveIndex)
	end)
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
		StatusService.Apply(character, "Block", nil, { value = 1 })
		MovementService.SetModifier(character, "Block", Combat.Block.blockSpeedMult)
	else
		if not StatusService.Has(character, "Block") then
			return
		end
		StatusService.Remove(character, "Block")
		MovementService.ClearModifier(character, "Block")
	end
end

-- ==================== register / unregister ====================

function CombatService.Register(character: Model, owner: Player?, weaponSet: string?)
	local existing = registered[character]
	if existing then
		existing.owner = owner
		return
	end

	registered[character] = {
		owner = owner,
		weaponSet = weaponSet or "Fist",
		comboStep = 1,
	}
	pcall(function()
		character:SetAttribute("WeaponSet", weaponSet or "Fist")
		character:SetAttribute("ComboStep", 1)
		character:SetAttribute("NextAttackAt", 0)
	end)
end

function CombatService.Unregister(character: Model)
	registered[character] = nil
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

	Remotes.Server.On("Attack", function(player: Player)
		local character = player.Character
		if character then
			CombatService.Attack(character)
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

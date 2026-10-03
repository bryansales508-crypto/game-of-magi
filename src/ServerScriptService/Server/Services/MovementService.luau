--!strict
-- The one owner of WalkSpeed (M3-02, TRIAGE #9, fixes AUDIT H10/M4/M5/M6/D2).
-- Keyed by the combatant's character Model, never by Player, same as
-- StatusService: NPCs move exactly like players. Players are registered
-- automatically on PlayerService.Ready; NPCs will be registered by
-- M3-04's NpcService.
--
-- A single named-multiplier stack per combatant (AUDIT M6: the old code
-- updated its "stable" base speeds but never re-applied WalkSpeed until
-- something else touched it; this writes WalkSpeed immediately on every
-- change). Effective multiplier = the SMALLEST active modifier (0 means
-- frozen); with none active, 1.0. `Run` isn't in that min-pool the same
-- way: it picks the baseline (walk 16 or run 16*Combat.Run.speedMult)
-- BEFORE the stack is applied, since "half of run speed" and "a quarter
-- of walk speed" (LowHealth, old SYSTEMS 8 numbers) are two different
-- final speeds for the exact same low multiplier, not one flat scalar a
-- pure min() could express.
--
-- Bridge: character.IntFold.MovementSpeed keeps one child per active
-- modifier (old readers watched ChildAdded/ChildRemoved there), and
-- IntFold["Running?"] mirrors the run flag, so MissionHandler's heavy
-- cargo slow, EffectsService's TrueStun freeze (both via the
-- RS/Modules/SpeedHandler.luau shim), and M3-03's FootstepService (reads
-- Running? verbatim from the old footstep code) keep working. Unlike
-- StatusService's Effects folder, MovementService creates IntFold itself
-- if it's missing (InteractionsDesign used to, but M3-03 deletes it).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Combat = require(ReplicatedStorage.Shared.Data.Combat)
local PlayerService = require(script.Parent.PlayerService)
local StatusService = require(script.Parent.StatusService)

local log = Log.new("MovementService")

local WALK_SPEED = 16
local RUN_SPEED = WALK_SPEED * Combat.Run.speedMult

-- Statuses that cancel/forbid Run and Dash (StatusService names, not the
-- client-facing attribute names). M3-FIX4-S: Recovery (a punished feint)
-- also forbids a dash, same as the three that already did; LightStun does
-- NOT (rule 1: "they CAN attack and dash" while light-stunned).
local BLOCKS_RUN: { [string]: boolean } = { Stun = true, TrueStun = true, Knocked = true, Block = true }
local BLOCKS_DASH: { [string]: boolean } = { Stun = true, TrueStun = true, Knocked = true, Recovery = true }

type Entry = {
	owner: Player?,
	modifiers: { [string]: number },
	running: boolean,
	lastDashAt: number?,
	-- M3-FIX4-S: the equipped style's own traits (Combat.Style.speedMult/
	-- dashCooldownMult), set by SetStyle. Kept OUTSIDE the `modifiers` min-
	-- pool (below) since a style can be a genuine speed BOOST (Dagger's
	-- 1.10) - EffectiveMultiplier's "smallest active modifier wins" is a
	-- debuff-stacking rule, not something a boost should ever have to beat;
	-- these multiply the walk/run baseline directly instead, same as
	-- `running` already picking walk vs. run baseline before the stack
	-- applies. 1.0/1.0 (Fist's own numbers) until SetStyle says otherwise.
	styleSpeedMult: number,
	styleDashCooldownMult: number,
	intFold: Folder?,
	movementSpeed: Folder?,
	runningValue: BoolValue?,
	bridgeChildren: { [string]: Instance },
	humanoidConns: { RBXScriptConnection },
}

local registered: { [Model]: Entry } = {}

local MovementService = {}

-- ==================== pure helpers (self-tested directly) ====================

-- The smallest active modifier, or 1.0 with none active. 0 freezes.
function MovementService.EffectiveMultiplier(modifiers: { [string]: number }): number
	local smallest = 1.0
	for _, mult in modifiers do
		if mult < smallest then
			smallest = mult
		end
	end
	return smallest
end

function MovementService.CanDash(now: number, lastDashAt: number?, cooldown: number): boolean
	return lastDashAt == nil or (now - lastDashAt) >= cooldown
end

-- Old SYSTEMS 8: health scales the "stable" base speed between a floor
-- (0 health) and the full baseline (full health) - half of run, a
-- quarter of walk. `ratio` is Health/MaxHealth, clamped to [0, 1].
--
-- BUG-23 (M3-FIX-S): the floor used to be a flat 0.5/0.25 constant, not
-- derived from `top` - correct by coincidence while walking (top is 1.0,
-- so a quarter of it IS 0.25), but wrong while running: half of
-- Combat.Run.speedMult (1.75) is 0.875, not the old hardcoded 0.5. The
-- self-test caught this (LowHealthMult(true, 0) was 0.5, not 0.875).
--
-- BUG-36 (M3-C playtest, Bryan 2026-10-02): this is a MULTIPLIER on the
-- baseline that applyWalkSpeed already picks (walk 16 or run 16 *
-- Combat.Run.speedMult), so it must be relative: 1.0 at full health down
-- to 0.5 (running) or 0.25 (walking) at 0 health. BUG-23's version scaled
-- the running case by Combat.Run.speedMult a SECOND time (1.75 at full
-- health, 0.875 at 0), so a hurt runner went up to 28 * 1.75 = 49 instead
-- of down toward 14.
function MovementService.LowHealthMult(running: boolean, ratio: number): number
	local clamped = math.clamp(ratio, 0, 1)
	local floor = if running then 0.5 else 0.25
	return floor + (1.0 - floor) * clamped
end

-- ==================== bridge (IntFold.MovementSpeed / Running?) ====================

local function resolveIntFold(character: Model, entry: Entry)
	local existingFold = character:FindFirstChild("IntFold")
	if existingFold and existingFold:IsA("Folder") then
		entry.intFold = existingFold
	end

	task.spawn(function()
		if entry.intFold == nil then
			local waited = character:WaitForChild("IntFold", 5)
			if registered[character] ~= entry then
				return
			end
			if waited and waited:IsA("Folder") then
				entry.intFold = waited
			elseif character.Parent ~= nil then
				local ok, result = pcall(function()
					local f = Instance.new("Folder")
					f.Name = "IntFold"
					f.Parent = character
					return f
				end)
				if ok then
					entry.intFold = result :: Folder
				else
					log:Warn(string.format("couldn't create %s's IntFold: %s", character.Name, tostring(result)))
					return
				end
			else
				return
			end
		end

		if registered[character] ~= entry or entry.intFold == nil then
			return
		end
		local intFold = entry.intFold :: Folder

		local existingMovement = intFold:FindFirstChild("MovementSpeed")
		if existingMovement and existingMovement:IsA("Folder") then
			entry.movementSpeed = existingMovement
		else
			local ok, result = pcall(function()
				local f = Instance.new("Folder")
				f.Name = "MovementSpeed"
				f.Parent = intFold
				return f
			end)
			if ok then
				entry.movementSpeed = result :: Folder
			end
		end

		local existingRunning = intFold:FindFirstChild("Running?")
		if existingRunning and existingRunning:IsA("BoolValue") then
			entry.runningValue = existingRunning
		else
			local ok, result = pcall(function()
				local v = Instance.new("BoolValue")
				v.Name = "Running?"
				v.Value = entry.running
				v.Parent = intFold
				return v
			end)
			if ok then
				entry.runningValue = result :: BoolValue
			end
		end

		-- Backfill: modifiers already applied before the bridge resolved
		-- never got a legacy child.
		for name, mult in entry.modifiers do
			local hasChild = entry.bridgeChildren[name]
			if not hasChild and entry.movementSpeed then
				local ok, child = pcall(function()
					local v = Instance.new("NumberValue")
					v.Name = name
					v.Value = mult
					v.Parent = entry.movementSpeed :: Folder
					return v
				end)
				if ok then
					entry.bridgeChildren[name] = child :: Instance
				end
			end
		end
	end)
end

local function writeBridgeModifier(character: Model, entry: Entry, name: string, mult: number)
	if entry.movementSpeed == nil then
		return
	end
	local existing = entry.bridgeChildren[name]
	if existing and existing.Parent then
		(existing :: NumberValue).Value = mult
		return
	end
	local ok, child = pcall(function()
		local v = Instance.new("NumberValue")
		v.Name = name
		v.Value = mult
		v.Parent = entry.movementSpeed :: Folder
		return v
	end)
	if ok then
		entry.bridgeChildren[name] = child :: Instance
	else
		log:Warn(string.format("couldn't write %s's %s movement bridge child: %s", character.Name, name, tostring(child)))
	end
end

local function clearBridgeModifier(entry: Entry, name: string)
	local existing = entry.bridgeChildren[name]
	if existing then
		entry.bridgeChildren[name] = nil
		pcall(function()
			existing:Destroy()
		end)
	end
end

-- ==================== speed application ====================

local function applyWalkSpeed(character: Model, entry: Entry)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end
	local baseline = (if entry.running then RUN_SPEED else WALK_SPEED) * entry.styleSpeedMult
	local mult = MovementService.EffectiveMultiplier(entry.modifiers)
	local speed = math.max(0, baseline * mult)
	humanoid.WalkSpeed = speed

	pcall(function()
		character:SetAttribute("SpeedMult", mult)
		character:SetAttribute("Running", entry.running)
	end)
end

-- ==================== public API ====================

-- M3-FIX4-S: applies a fighting style's own speedMult/dashCooldownMult
-- traits (Shared/Data/Combat.luau). Unknown style name: a no-op, logged,
-- so a bad `.weapon` argument or a data typo can't silently strand a
-- combatant on stale multipliers. Safe to call before MovementService.
-- Register has run for `character` (a no-op then too, matching every other
-- setter here) - CombatService.Register calls this right after its own
-- registration, whichever order the two services' PlayerService.Ready
-- listeners happen to fire in.
function MovementService.SetStyle(character: Model, styleName: string)
	local entry = registered[character]
	if entry == nil then
		return
	end
	local style = Combat.styleFor(styleName)
	if style == nil then
		log:Warn(string.format("SetStyle(%s, %s): unknown style", character.Name, styleName))
		return
	end
	entry.styleSpeedMult = style.speedMult
	entry.styleDashCooldownMult = style.dashCooldownMult
	applyWalkSpeed(character, entry)
end

function MovementService.SetModifier(character: Model, name: string, mult: number)
	local entry = registered[character]
	if entry == nil then
		return
	end
	entry.modifiers[name] = mult
	writeBridgeModifier(character, entry, name, mult)
	applyWalkSpeed(character, entry)
end

function MovementService.ClearModifier(character: Model, name: string)
	local entry = registered[character]
	if entry == nil or entry.modifiers[name] == nil then
		return
	end
	entry.modifiers[name] = nil
	clearBridgeModifier(entry, name)
	applyWalkSpeed(character, entry)
end

-- Ignored while stunned/knocked/blocking (M3-05's CombatController is
-- expected to not even send Run(true) then, but the server decides).
-- Returns whether it actually applied.
function MovementService.SetRunning(character: Model, on: boolean): boolean
	local entry = registered[character]
	if entry == nil then
		return false
	end

	if on then
		for status in BLOCKS_RUN do
			if StatusService.Has(character, status) then
				return false
			end
		end
	end

	entry.running = on
	if entry.runningValue then
		pcall(function()
			(entry.runningValue :: BoolValue).Value = on
		end)
	end
	applyWalkSpeed(character, entry)

	Remotes.Server.FireAll("CombatEvent", "Run", { character = character, on = on })
	return true
end

-- Server cooldown (AUDIT M4), rejected while stunned/knocked, no first-
-- punch requirement (H10); x/z are in the character's own local space and
-- need not be pre-normalised (diagonals fine). Returns whether it dashed.
function MovementService.Dash(character: Model, x: number, z: number): boolean
	local entry = registered[character]
	if entry == nil then
		return false
	end

	for status in BLOCKS_DASH do
		if StatusService.Has(character, status) then
			return false
		end
	end

	-- M3-FIX4-S: the equipped style's own dashCooldownMult scales the
	-- cooldown (Dagger's 0.75 = a quarter shorter); Fist's 1.0 leaves it
	-- unchanged.
	local cooldown = Combat.Dash.cooldown * entry.styleDashCooldownMult
	local now = Workspace:GetServerTimeNow()
	if not MovementService.CanDash(now, entry.lastDashAt, cooldown) then
		return false
	end

	-- Bryan (2026-09-30): no dashing out of a swing - the chain commits you.
	if character:GetAttribute("Attacking") == true then
		return false
	end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp == nil or not hrp:IsA("BasePart") then
		return false
	end

	local localDir = Vector3.new(x, 0, z)
	if localDir.Magnitude < 1e-3 then
		return false
	end
	local worldDir = (hrp :: BasePart).CFrame:VectorToWorldSpace(localDir).Unit

	-- Bryan (2026-09-30): no flinging off walls. The dash is a LinearVelocity
	-- at unlimited force; against a wall that force used to shove the
	-- character up and over it. Sweep a sphere along the path first and
	-- shorten the dash to stop Combat.Dash.wallMargin short of whatever it
	-- hits; nothing to dash into at all = no dash and no cooldown spent.
	-- BUG-37 / BUG-56 (Bryan, 2026-10-02/03): a dash shortens by the same
	-- modifiers walk and run already use - LowHealth (1.0 at full health,
	-- 0.25 at none) and HeavyCargo (Config.Missions.HeavyCargoSpeedMult) -
	-- so every movement reads the same wound and the same load. Combined
	-- the same way applyWalkSpeed combines them.
	local distance = Combat.Dash.distance * MovementService.EffectiveMultiplier(entry.modifiers)
	local castParams = RaycastParams.new()
	castParams.FilterType = Enum.RaycastFilterType.Exclude
	castParams.FilterDescendantsInstances = { character }
	castParams.RespectCanCollide = true
	local sweep = Workspace:Spherecast((hrp :: BasePart).Position, Combat.Dash.castRadius, worldDir * distance, castParams)
	if sweep then
		distance = math.max(sweep.Distance - Combat.Dash.wallMargin, 0)
	end
	if distance < Combat.Dash.minDistance then
		return false
	end

	entry.lastDashAt = now
	pcall(function()
		character:SetAttribute("NextDashAt", now + cooldown)
	end)

	local ok, err = pcall(function()
		local attachment = Instance.new("Attachment")
		attachment.Name = "DashAttachment"
		attachment.Parent = hrp

		local velocity = Instance.new("LinearVelocity")
		velocity.Name = "DashVelocity"
		velocity.Attachment0 = attachment
		velocity.MaxForce = math.huge
		velocity.RelativeTo = Enum.ActuatorRelativeTo.World
		velocity.VectorVelocity = worldDir * (distance / Combat.Dash.duration)
		velocity.Parent = hrp

		task.delay(Combat.Dash.duration, function()
			velocity:Destroy()
			attachment:Destroy()
		end)
	end)
	if not ok then
		log:Warn(string.format("%s's dash impulse failed: %s", character.Name, tostring(err)))
	end

	-- Transient bridge child (PhysicalHandler.client.luau cancels its own
	-- swing on ChildAdded "Dash"; M3-05 replaces that file, but until then
	-- this keeps the cancel working). REVIEW-M3-02 #3: routed through the
	-- real SetModifier/ClearModifier (not a direct writeBridgeModifier
	-- call) so entry.modifiers actually has a "Dash" key for
	-- ClearModifier to find - a value of 1.0 never wins the
	-- EffectiveMultiplier min anyway, so this never slows the dash itself.
	MovementService.SetModifier(character, "Dash", 1.0)
	task.delay(Combat.Dash.duration, function()
		if registered[character] == entry then
			MovementService.ClearModifier(character, "Dash")
		end
	end)

	Remotes.Server.FireAll("CombatEvent", "Dash", { character = character, x = x, z = z })
	return true
end

-- ==================== low health ====================

local function updateLowHealth(character: Model, entry: Entry, humanoid: Humanoid)
	if humanoid.MaxHealth <= 0 then
		return
	end
	local ratio = humanoid.Health / humanoid.MaxHealth
	if ratio >= 1 then
		MovementService.ClearModifier(character, "LowHealth")
	else
		MovementService.SetModifier(character, "LowHealth", MovementService.LowHealthMult(entry.running, ratio))
	end
end

-- ==================== register / unregister ====================

function MovementService.Register(character: Model, owner: Player?)
	local existing = registered[character]
	if existing then
		existing.owner = owner
		return
	end

	local entry: Entry = {
		owner = owner,
		modifiers = {},
		running = false,
		-- Fist's own numbers (1.0/1.0, i.e. "no change") until SetStyle says
		-- otherwise - the common case, since every combatant starts on Fist.
		styleSpeedMult = 1.0,
		styleDashCooldownMult = 1.0,
		bridgeChildren = {},
		humanoidConns = {},
	}
	registered[character] = entry

	resolveIntFold(character, entry)
	applyWalkSpeed(character, entry)
	pcall(function()
		character:SetAttribute("NextDashAt", 0)
	end)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		table.insert(
			entry.humanoidConns,
			humanoid.HealthChanged:Connect(function()
				updateLowHealth(character, entry, humanoid)
			end)
		)
		table.insert(
			entry.humanoidConns,
			humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function()
				updateLowHealth(character, entry, humanoid)
			end)
		)
		table.insert(
			entry.humanoidConns,
			humanoid.Died:Connect(function()
				MovementService.Unregister(character)
			end)
		)
		updateLowHealth(character, entry, humanoid)
	end
end

function MovementService.Unregister(character: Model)
	local entry = registered[character]
	if entry == nil then
		return
	end
	registered[character] = nil

	for _, conn in entry.humanoidConns do
		conn:Disconnect()
	end
end

-- ==================== service ====================

function MovementService:Init()
	Remotes.Server.On("Run", function(player: Player, on: boolean)
		local character = player.Character
		if character == nil or registered[character] == nil then
			return
		end
		MovementService.SetRunning(character, on)
	end)

	Remotes.Server.On("Dash", function(player: Player, x: number, z: number)
		local character = player.Character
		if character == nil or registered[character] == nil then
			return
		end
		MovementService.Dash(character, x, z)
	end)

	PlayerService.Ready:Connect(function(player: Player, character: Model)
		MovementService.Register(character, player)
	end)

	StatusService.Changed:Connect(function(character: Model, status: string, active: boolean)
		if active and BLOCKS_RUN[status] and registered[character] then
			MovementService.SetRunning(character, false)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		local character = player.Character
		if character then
			MovementService.Unregister(character)
		end
	end)
end

function MovementService:Start() end

return MovementService

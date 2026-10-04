--!strict
-- The one owner of WalkSpeed. Keyed by the combatant's character Model (players and NPCs
-- alike).
--
-- One named-multiplier stack per combatant; WalkSpeed is rewritten immediately on every change.
-- Effective multiplier = the smallest active modifier (0 = frozen), 1.0 with none. Run picks
-- its baseline (walk 16 or run 16*Combat.Run.speedMult) BEFORE the stack applies, since
-- LowHealth gives different final speeds per baseline.
--
-- Bridge: character.IntFold.MovementSpeed has one child per active modifier and
-- IntFold["Running?"] mirrors the run flag, for older readers (MissionHandler, EffectsService
-- via the SpeedHandler shim, FootstepService). IntFold is created here if missing.

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

-- Statuses that cancel/forbid Run and Dash (StatusService names). LightStun does not:
-- light-stunned combatants can still attack and dash.
local BLOCKS_RUN: { [string]: boolean } =
	{ Stun = true, TrueStun = true, Knocked = true, Block = true, Carrying = true, Carried = true, Jailed = true, Gripping = true, Gripped = true }
local BLOCKS_DASH: { [string]: boolean } =
	{ Stun = true, TrueStun = true, Knocked = true, Recovery = true, Carrying = true, Carried = true, Jailed = true, Gripping = true, Gripped = true }

type Entry = {
	owner: Player?,
	modifiers: { [string]: number },
	running: boolean,
	lastDashAt: number?,
	-- The equipped style's own speedMult/dashCooldownMult (set by SetStyle). Kept outside the
	-- `modifiers` min-pool because a style can be a speed boost; these multiply the walk/run
	-- baseline directly. 1.0/1.0 for Fist.
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

-- Health scales speed: a MULTIPLIER on the baseline applyWalkSpeed picks, 1.0 at full health
-- down to 0.5 (running) or 0.25 (walking) at 0 health. `ratio` is Health/MaxHealth, clamped to
-- [0, 1].
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

		-- Backfill: modifiers applied before the bridge resolved have no child yet.
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

-- Applies a fighting style's speedMult/dashCooldownMult (Shared/Data/Combat.luau). Unknown
-- style: logged no-op. Safe to call before Register has run (also a no-op), so the order of
-- services' Ready listeners doesn't matter.
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

-- Ignored while stunned/knocked/blocking; the server decides whatever the client sends. Returns
-- whether it applied.
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

-- Server cooldown; rejected while stunned/knocked. x/z are in the character's local space and
-- need not be normalised. Returns whether it dashed.
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

	-- The style's dashCooldownMult scales the cooldown.
	local cooldown = Combat.Dash.cooldown * entry.styleDashCooldownMult
	local now = Workspace:GetServerTimeNow()
	if not MovementService.CanDash(now, entry.lastDashAt, cooldown) then
		return false
	end

	-- No dashing out of a swing.
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

	-- No flinging off walls: sweep a sphere along the path and shorten the dash to stop
	-- Combat.Dash.wallMargin short of what it hits; nothing to dash into = no dash and no
	-- cooldown spent. The dash also shortens with LowHealth and HeavyCargo
	-- (Config.Missions.HeavyCargoSpeedMult), combined as applyWalkSpeed does.
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

	-- Transient bridge child (PhysicalHandler.client.luau cancels its swing on ChildAdded
	-- 'Dash'). Goes through SetModifier/ClearModifier so entry.modifiers has a 'Dash' key to
	-- clear; 1.0 never wins the min, so it doesn't slow the dash.
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

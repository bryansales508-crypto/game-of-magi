--!strict
-- Carrying a knocked-out player, delivering them to the jail, being carried, and the jailed panel.
--
-- Server contract (Shared/Remotes.luau, SYSTEMS.md section 18):
--   CarryState (server -> client): { carrying = { userId, name }?, carriedBy = { userId, name }?,
--     canDeliver, dropoffPath? } (both nil = a carry ended).
--   CarryPickUp(userId), CarryDrop(), JailDeliver() (client -> server intentions; the server decides).
--   Character attributes: Knocked, Carried, Carrying, Jailed. Player attribute: JailUntil (server
--   time in unix seconds, 0 = free).
-- The prompts are client-made and only ever send intentions. Containment is the server's; the
-- jailed panel is display only and never touches input.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared:WaitForChild("Log"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Config = require(Shared:WaitForChild("Config"))

local log = Log.new("CarryController")
local player = Players.LocalPlayer

local CarryController = {}

local REACH = Config.Bounty.Carry.ReachStuds
local DELIVER_REACH = Config.Bounty.Jail.ReachStuds
local DELIVERY_INTERVAL = 0.2 -- only while a delivery is possible
local JAIL_INTERVAL = 0.5 -- only while jailed
local DROPOFF_WAIT = 10

local GOLD = Color3.fromRGB(239, 187, 65)
local PANEL_COLOR = Color3.fromRGB(20, 20, 20)
local MERRIWEATHER_BOLD = Font.new(Font.fromEnum(Enum.Font.Merriweather).Family, Enum.FontWeight.Bold, Enum.FontStyle.Normal)

type Person = { userId: number, name: string }
type CarryStateData = {
	carrying: Person?,
	carriedBy: Person?,
	canDeliver: boolean?,
	dropoffPath: string?,
}

local carryState: CarryStateData = {}

-- Pick-up prompts on other players' knocked-out characters ---

local pickupPrompts: { [Player]: ProximityPrompt } = {}
local playerConnections: { [Player]: { RBXScriptConnection } } = {}
local characterConnections: { [Player]: { RBXScriptConnection } } = {}
local localConnections: { RBXScriptConnection } = {}

local function localCharacter(): Model?
	return player.Character
end

local function localRoot(): BasePart?
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- True while this player may not pick anyone up.
local function localBlocked(): boolean
	local character = localCharacter()
	if not character then
		return true
	end
	return carryState.carrying ~= nil
		or character:GetAttribute("Knocked") == true
		or character:GetAttribute("Carried") == true
		or character:GetAttribute("Jailed") == true
end

local function destroyPickup(other: Player)
	local prompt = pickupPrompts[other]
	if prompt then
		prompt:Destroy()
		pickupPrompts[other] = nil
	end
end

local function refreshPickup(other: Player)
	local character = other.Character
	if not (character and character:GetAttribute("Knocked") == true) then
		destroyPickup(other)
		return
	end
	local prompt = pickupPrompts[other]
	if not prompt then
		local root = character:FindFirstChild("HumanoidRootPart")
		if not (root and root:IsA("BasePart")) then
			return
		end
		local made = Instance.new("ProximityPrompt")
		made.Name = "CarryPickUp"
		made.ActionText = "Pick up"
		made.ObjectText = other.DisplayName
		made.KeyboardKeyCode = Enum.KeyCode.E
		made.HoldDuration = 0
		made.MaxActivationDistance = REACH
		made.RequiresLineOfSight = false
		made.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
		made.Triggered:Connect(function()
			Remotes.Client.Fire("CarryPickUp", other.UserId)
		end)
		made.Parent = root
		pickupPrompts[other] = made
		prompt = made
	end
	local ready = not localBlocked()
		and character:GetAttribute("Carried") ~= true
		and character:GetAttribute("Jailed") ~= true
	prompt.Enabled = ready
end

local function refreshAllPickups()
	for other in playerConnections do
		refreshPickup(other)
	end
end

local function disconnectAll(list: { RBXScriptConnection }?)
	if list then
		for _, connection in list do
			connection:Disconnect()
		end
	end
end

local function unwatchCharacter(other: Player)
	disconnectAll(characterConnections[other])
	characterConnections[other] = nil
	destroyPickup(other)
end

local function watchCharacter(other: Player, character: Model)
	unwatchCharacter(other)
	local list: { RBXScriptConnection } = {}
	characterConnections[other] = list
	for _, attribute in { "Knocked", "Carried", "Jailed" } do
		table.insert(
			list,
			character:GetAttributeChangedSignal(attribute):Connect(function()
				refreshPickup(other)
			end)
		)
	end
	-- The root can stream in after the character; retry once when a part shows up.
	table.insert(
		list,
		character.ChildAdded:Connect(function(child)
			if child.Name == "HumanoidRootPart" then
				refreshPickup(other)
			end
		end)
	)
	refreshPickup(other)
end

local function watchPlayer(other: Player)
	if other == player or playerConnections[other] then
		return
	end
	local list: { RBXScriptConnection } = {}
	playerConnections[other] = list
	table.insert(list, other.CharacterAdded:Connect(function(character)
		watchCharacter(other, character)
	end))
	table.insert(list, other.CharacterRemoving:Connect(function()
		unwatchCharacter(other)
	end))
	if other.Character then
		watchCharacter(other, other.Character)
	end
end

local function unwatchPlayer(other: Player)
	unwatchCharacter(other)
	disconnectAll(playerConnections[other])
	playerConnections[other] = nil
end

-- Drop prompt (carrier) and delivery (drop-off glow + Deliver prompt) ---

local dropPrompt: ProximityPrompt? = nil
local deliveryToken = 0
local deliveryHighlight: Highlight? = nil
local deliveryPrompt: ProximityPrompt? = nil
local deliveryPart: BasePart? = nil
local deliveryPath: string? = nil

local function newPrompt(action: string, objectText: string, distance: number): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = action
	prompt.ObjectText = objectText
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = distance
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	return prompt
end

local function destroyDropPrompt()
	if dropPrompt then
		dropPrompt:Destroy()
		dropPrompt = nil
	end
end

local function clearDelivery()
	deliveryToken += 1
	deliveryPath = nil
	deliveryPart = nil
	if deliveryHighlight then
		deliveryHighlight:Destroy()
		deliveryHighlight = nil
	end
	if deliveryPrompt then
		deliveryPrompt:Destroy()
		deliveryPrompt = nil
	end
	if dropPrompt then
		dropPrompt.Enabled = true
	end
end

-- Distance from `position` to the part's box (the same measure the server uses).
local function distanceToBox(part: BasePart, position: Vector3): number
	local relative = part.CFrame:PointToObjectSpace(position)
	local half = part.Size / 2
	local clamped = Vector3.new(
		math.clamp(relative.X, -half.X, half.X),
		math.clamp(relative.Y, -half.Y, half.Y),
		math.clamp(relative.Z, -half.Z, half.Z)
	)
	return (relative - clamped).Magnitude
end

local function resolvePath(path: string): BasePart?
	local segments = string.split(path, ".")
	local current: Instance? = if segments[1] == "Workspace" then Workspace else game:FindFirstChild(segments[1])
	for i = 2, #segments do
		if not current then
			return nil
		end
		current = current:WaitForChild(segments[i], DROPOFF_WAIT)
	end
	return if current and current:IsA("BasePart") then current else nil
end

-- Deliver and Drop share E, so only one is enabled: Deliver inside the drop-off's reach, Drop elsewhere.
local function runDeliveryLoop(token: number)
	while token == deliveryToken and deliveryPart and deliveryPrompt do
		local root = localRoot()
		local inReach = root ~= nil and distanceToBox(deliveryPart, root.Position) <= DELIVER_REACH
		deliveryPrompt.Enabled = inReach
		if dropPrompt then
			dropPrompt.Enabled = not inReach
		end
		task.wait(DELIVERY_INTERVAL)
	end
end

local function setupDelivery(path: string)
	clearDelivery()
	deliveryPath = path
	local token = deliveryToken
	task.spawn(function()
		local part = resolvePath(path)
		if token ~= deliveryToken then
			return
		end
		if not part then
			log:Warn("drop-off not found: " .. path)
			return
		end
		deliveryPart = part

		local glow = Instance.new("Highlight")
		glow.Name = "JailDropoffGlow"
		glow.FillColor = GOLD
		glow.FillTransparency = 0.5
		glow.OutlineColor = GOLD
		glow.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		glow.Adornee = part
		glow.Parent = part
		deliveryHighlight = glow

		local prompt = newPrompt("Deliver", "Jail", 200)
		prompt.Name = "JailDeliver"
		prompt.Enabled = false
		prompt.Triggered:Connect(function()
			Remotes.Client.Fire("JailDeliver")
		end)
		prompt.Parent = part
		deliveryPrompt = prompt

		runDeliveryLoop(token)
	end)
end

local function updateCarrierUi()
	local carrying = carryState.carrying
	local root = localRoot()
	if not (carrying and root) then
		destroyDropPrompt()
		clearDelivery()
		return
	end
	if not dropPrompt then
		local prompt = newPrompt("Drop", carrying.name, 10)
		prompt.Name = "CarryDrop"
		prompt.Triggered:Connect(function()
			Remotes.Client.Fire("CarryDrop")
		end)
		prompt.Parent = root
		dropPrompt = prompt
	end
	local path = carryState.dropoffPath
	if carryState.canDeliver == true and type(path) == "string" then
		if deliveryPath ~= path then
			setupDelivery(path)
		end
	else
		clearDelivery()
	end
end

-- Being carried: dim, caption, input freeze ---

local carriedGui: ScreenGui? = nil
local carriedDim: Frame? = nil
local carriedLabel: TextLabel? = nil
local inputFrozen: any = nil

local function getControls(): any
	local scripts = player:FindFirstChild("PlayerScripts")
	local module = scripts and scripts:FindFirstChild("PlayerModule")
	if not module then
		return nil
	end
	local ok, loaded = pcall(require, module)
	if not ok then
		log:Warn("require(PlayerModule) failed: " .. tostring(loaded))
		return nil
	end
	local okControls, controls = pcall(function()
		return (loaded :: any):GetControls()
	end)
	return if okControls then controls else nil
end

local function unfreezeInput()
	local controls = inputFrozen
	inputFrozen = nil
	if controls then
		local ok, err = pcall(function()
			controls:Enable()
		end)
		if not ok then
			log:Warn("Controls:Enable() failed: " .. tostring(err))
		end
	end
end

local function freezeInput()
	if inputFrozen then
		return
	end
	local controls = getControls()
	if not controls then
		return
	end
	local ok, err = pcall(function()
		controls:Disable()
	end)
	if ok then
		inputFrozen = controls
	else
		log:Warn("Controls:Disable() failed: " .. tostring(err))
	end
end

local function ensureCarriedGui(): ScreenGui?
	if carriedGui and carriedGui.Parent then
		return carriedGui
	end
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "CarriedScreen"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 20
	gui.Enabled = false

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 0.55
	dim.BorderSizePixel = 0
	dim.Parent = gui

	local label = Instance.new("TextLabel")
	label.Name = "Caption"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.78)
	label.Size = UDim2.fromOffset(500, 40)
	label.BackgroundTransparency = 1
	label.FontFace = MERRIWEATHER_BOLD
	label.TextSize = 24
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.4
	label.Parent = gui

	gui.Parent = playerGui
	carriedGui, carriedDim, carriedLabel = gui, dim, label
	return gui
end

local function updateCarriedUi()
	local carriedBy = carryState.carriedBy
	local character = localCharacter()
	if not (carriedBy and character) then
		if carriedGui then
			carriedGui.Enabled = false
		end
		unfreezeInput()
		return
	end
	local gui = ensureCarriedGui()
	if not (gui and carriedDim and carriedLabel) then
		return
	end
	-- A knocked-out player already has the blind screen and frozen input (EffectsController).
	local knocked = character:GetAttribute("Knocked") == true
	carriedDim.Visible = not knocked
	carriedLabel.Text = "You are being carried by " .. carriedBy.name
	gui.Enabled = true
	if knocked then
		unfreezeInput()
	else
		freezeInput()
	end
end

-- Jailed panel ---

local jailGui: ScreenGui? = nil
local jailTimeLabel: TextLabel? = nil
local jailRunning = false

local function jailActive(): boolean
	local character = localCharacter()
	local until_ = player:GetAttribute("JailUntil")
	return (character ~= nil and character:GetAttribute("Jailed") == true)
		or (type(until_) == "number" and until_ > Workspace:GetServerTimeNow())
end

local function ensureJailGui(): ScreenGui?
	if jailGui and jailGui.Parent then
		return jailGui
	end
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "JailPanel"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 10
	gui.Enabled = false

	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, 12)
	frame.Size = UDim2.fromOffset(180, 64)
	frame.BackgroundColor3 = PANEL_COLOR
	frame.BackgroundTransparency = 0.25
	frame.BorderSizePixel = 0
	frame.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = frame

	local title = Instance.new("TextLabel")
	title.Size = UDim2.fromScale(1, 0.5)
	title.BackgroundTransparency = 1
	title.FontFace = MERRIWEATHER_BOLD
	title.TextSize = 20
	title.TextColor3 = GOLD
	title.Text = "Jailed"
	title.Parent = frame

	local time = Instance.new("TextLabel")
	time.Position = UDim2.fromScale(0, 0.5)
	time.Size = UDim2.fromScale(1, 0.5)
	time.BackgroundTransparency = 1
	time.FontFace = MERRIWEATHER_BOLD
	time.TextSize = 18
	time.TextColor3 = Color3.new(1, 1, 1)
	time.Parent = frame

	gui.Parent = playerGui
	jailGui, jailTimeLabel = gui, time
	return gui
end

local function formatClock(seconds: number): string
	local whole = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", whole // 60, whole % 60)
end

local function refreshJail()
	if jailRunning or not jailActive() then
		return
	end
	jailRunning = true
	task.spawn(function()
		while jailActive() do
			local gui = ensureJailGui()
			local label = jailTimeLabel
			if gui and label then
				local until_ = player:GetAttribute("JailUntil")
				gui.Enabled = true
				label.Text = if type(until_) == "number" then formatClock(until_ - Workspace:GetServerTimeNow()) else ""
			end
			task.wait(JAIL_INTERVAL)
		end
		if jailGui then
			jailGui.Enabled = false
		end
		jailRunning = false
	end)
end

-- Wiring ---

local function applyCarryState()
	updateCarrierUi()
	updateCarriedUi()
	refreshAllPickups()
end

local function onCarryState(payload: any)
	if type(payload) ~= "table" then
		log:Warn("CarryState: unexpected payload")
		return
	end
	carryState = payload :: CarryStateData
	applyCarryState()
end

local function onLocalCharacter(character: Model)
	disconnectAll(localConnections)
	table.clear(localConnections)
	-- A new character carries and is carried by no one; the server ends carries on respawn.
	carryState = {}
	destroyDropPrompt()
	clearDelivery()
	for _, attribute in { "Knocked", "Carried", "Jailed" } do
		table.insert(
			localConnections,
			character:GetAttributeChangedSignal(attribute):Connect(function()
				refreshAllPickups()
				if attribute == "Knocked" then
					updateCarriedUi()
				elseif attribute == "Jailed" then
					refreshJail()
				end
			end)
		)
	end
	applyCarryState()
	refreshJail()
end

function CarryController:Init() end

function CarryController:Start()
	Remotes.Client.On("CarryState", onCarryState)

	player:GetAttributeChangedSignal("JailUntil"):Connect(refreshJail)
	player.CharacterAdded:Connect(onLocalCharacter)
	if player.Character then
		onLocalCharacter(player.Character)
	end

	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(unwatchPlayer)
	for _, other in Players:GetPlayers() do
		watchPlayer(other)
	end

	log:Info("ready")
end

return CarryController

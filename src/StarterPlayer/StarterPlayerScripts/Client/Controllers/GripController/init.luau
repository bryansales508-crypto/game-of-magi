--!strict
-- Gripping a knocked-out player: the Grip prompt, the code-posed grip on both characters, the choke
-- bar, the gripped screen and the interrupt line.
--
-- Server contract (Shared/Remotes.luau, SYSTEMS.md section 19):
--   GripState (server -> client): { gripping = { userId, name }?, grippedBy = { userId, name }?,
--     progress (0..1), reason? } (both nil = the grip ended; reason says why).
--   GripStart(userId), GripStop() (client -> server intentions; the server decides everything).
--   Character attributes: Gripping / GrippingTarget (gripper), Gripped / GripProgress (victim).
-- The pose is visual only: it nudges Motor6D C0 on the local copy of each character (players and
-- NPC dummies alike, driven by the replicated attributes) and puts everything back on stop. The
-- victim's knockout blind screen and input freeze stay EffectsController's; nothing here toggles them.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared:WaitForChild("Log"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Config = require(Shared:WaitForChild("Config"))
local ChatLines = require(script.Parent.ChatLines)

local log = Log.new("GripController")
local player = Players.LocalPlayer

local GripController = {}

local GripConfig = Config.Bounty.Grip
local REACH = GripConfig.ReachStuds
-- Config.Bounty.Grip.Key is the server builder's to add; fall back to G until it exists.
local configuredKey = (GripConfig :: any).Key
local GRIP_KEY: Enum.KeyCode = if typeof(configuredKey) == "EnumItem" then configuredKey :: any else Enum.KeyCode.G
local GRIP_BUTTON = Enum.KeyCode.ButtonY
local NPC_TAG = "NPC"
local HOLD_SECONDS = 0.15 -- a short hold so the prompt's hold-end event is reliable on touch and gamepad

local GOLD = Color3.fromRGB(239, 187, 65)
local BLOOD = Color3.fromRGB(150, 10, 10)
local PANEL_COLOR = Color3.fromRGB(20, 20, 20)
local MERRIWEATHER_BOLD = Font.new(Font.fromEnum(Enum.Font.Merriweather).Family, Enum.FontWeight.Bold, Enum.FontStyle.Normal)

type Person = { userId: number, name: string }
type GripStateData = { gripping: Person?, grippedBy: Person?, progress: number?, reason: string? }

local function disconnectAll(list: { RBXScriptConnection }?)
	if list then
		for _, connection in list do
			connection:Disconnect()
		end
	end
end

-- The grip pose (both characters) ---

local PITCH = math.rad(50) -- gripper's torso leans over the victim
local KNEEL_DROP = 1.4 -- how far the gripper's torso sits lower, studs
local ARM_REACH = math.rad(65) -- gripper's arms reach forward and down to the neck
local ARM_IN = math.rad(15)
local VICTIM_ARM_OUT = math.rad(35) -- victim's arms slightly out

type Posed = {
	originals: { [Motor6D]: CFrame },
	enabled: { [Motor6D]: boolean },
	track: AnimationTrack?,
}

local posed: { [Model]: Posed } = {}

-- Rotates a joint's C0 about its own pivot, in the parent part's space.
local function rotateAboutPivot(c0: CFrame, rotation: CFrame): CFrame
	local pivot = CFrame.new(c0.Position)
	return pivot * rotation * pivot:Inverse() * c0
end

local function findMotor(character: Model, parentName: string, motorName: string): Motor6D?
	local parent = character:FindFirstChild(parentName)
	local motor = parent and parent:FindFirstChild(motorName)
	return if motor and motor:IsA("Motor6D") then motor else nil
end

-- `forceEnabled` switches the joint on for this client only: the knockout ragdoll disables the victim's
-- limb joints, and Enabled is local (it is not sent to the server), so the pose can show.
local function setC0(entry: Posed, motor: Motor6D?, build: (CFrame) -> CFrame, forceEnabled: boolean?)
	if not motor then
		return
	end
	if forceEnabled == true then
		if entry.enabled[motor] == nil then
			entry.enabled[motor] = motor.Enabled
		end
		motor.Enabled = true
	end
	local original = entry.originals[motor]
	if not original then
		original = motor.C0
		entry.originals[motor] = original
	end
	motor.C0 = build(original)
end

local function playAsset(character: Model, id: string): AnimationTrack?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return nil
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = id
	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	animation:Destroy()
	if not ok then
		log:Warn("grip animation failed to load: " .. tostring(track))
		return nil
	end
	local loaded = track :: AnimationTrack
	loaded.Priority = Enum.AnimationPriority.Action4
	loaded.Looped = true
	loaded:Play(0.2)
	return loaded
end

local function clearPose(character: Model)
	local entry = posed[character]
	if not entry then
		return
	end
	posed[character] = nil
	for motor, c0 in entry.originals do
		if motor.Parent then
			motor.C0 = c0
		end
	end
	for motor, wasEnabled in entry.enabled do
		if motor.Parent then
			motor.Enabled = wasEnabled
		end
	end
	if entry.track then
		entry.track:Stop(0.2)
		entry.track:Destroy()
	end
end

local function poseGripper(character: Model)
	local entry: Posed = { originals = {}, enabled = {}, track = nil }
	posed[character] = entry
	local id = GripConfig.Animations.Gripper
	if id ~= "" then
		entry.track = playAsset(character, id)
		return
	end
	-- Torso pitched forward and lowered, arms down and in toward the victim's neck.
	setC0(entry, findMotor(character, "HumanoidRootPart", "RootJoint"), function(c0)
		return CFrame.new(0, -KNEEL_DROP, 0) * CFrame.Angles(-PITCH, 0, 0) * c0
	end)
	setC0(entry, findMotor(character, "Torso", "Right Shoulder"), function(c0)
		return rotateAboutPivot(c0, CFrame.Angles(ARM_REACH, 0, ARM_IN))
	end)
	setC0(entry, findMotor(character, "Torso", "Left Shoulder"), function(c0)
		return rotateAboutPivot(c0, CFrame.Angles(ARM_REACH, 0, -ARM_IN))
	end)
end

local function poseVictim(character: Model)
	local entry: Posed = { originals = {}, enabled = {}, track = nil }
	posed[character] = entry
	local id = GripConfig.Animations.Victim
	if id ~= "" then
		entry.track = playAsset(character, id)
		return
	end
	-- Flat on the back (the knockout ragdoll lays them down), arms slightly out.
	setC0(entry, findMotor(character, "Torso", "Right Shoulder"), function(c0)
		return rotateAboutPivot(c0, CFrame.Angles(0, 0, VICTIM_ARM_OUT))
	end, true)
	setC0(entry, findMotor(character, "Torso", "Left Shoulder"), function(c0)
		return rotateAboutPivot(c0, CFrame.Angles(0, 0, -VICTIM_ARM_OUT))
	end, true)
end

-- "gripper", "victim" or nil, read from the replicated attributes.
local function roleOf(character: Model): string?
	if character:GetAttribute("Gripping") == true or type(character:GetAttribute("GrippingTarget")) == "string" then
		return "gripper"
	end
	if character:GetAttribute("Gripped") == true then
		return "victim"
	end
	return nil
end

local watched: { [Model]: { RBXScriptConnection } } = {}
local posedRole: { [Model]: string } = {}

local function refreshPose(character: Model)
	local role = roleOf(character)
	if role == posedRole[character] then
		return
	end
	clearPose(character)
	posedRole[character] = role :: any
	if role == "gripper" then
		poseGripper(character)
	elseif role == "victim" then
		poseVictim(character)
	end
end

local function unwatchCharacter(character: Model)
	disconnectAll(watched[character])
	watched[character] = nil
	posedRole[character] = nil
	clearPose(character)
end

local function watchCharacter(character: Model)
	if watched[character] then
		return
	end
	local list: { RBXScriptConnection } = {}
	watched[character] = list
	for _, attribute in { "Gripping", "GrippingTarget", "Gripped" } do
		table.insert(
			list,
			character:GetAttributeChangedSignal(attribute):Connect(function()
				refreshPose(character)
			end)
		)
	end
	table.insert(
		list,
		character.Destroying:Connect(function()
			unwatchCharacter(character)
		end)
	)
	refreshPose(character)
end

-- The prompt on knocked-out players ---

local gripPrompts: { [Player]: ProximityPrompt } = {}
local playerConnections: { [Player]: { RBXScriptConnection } } = {}
local characterConnections: { [Player]: { RBXScriptConnection } } = {}
local localConnections: { RBXScriptConnection } = {}
local holding = false -- this client pressed Grip and has not released yet

local function localBlocked(): boolean
	local character = player.Character
	if not character then
		return true
	end
	for _, status in { "Knocked", "Carried", "Carrying", "Jailed", "Gripping", "Gripped" } do
		if character:GetAttribute(status) == true then
			return true
		end
	end
	return false
end

local function releaseGrip()
	if holding then
		holding = false
		Remotes.Client.Fire("GripStop")
	end
end

local function destroyPrompt(other: Player)
	local prompt = gripPrompts[other]
	if prompt then
		prompt:Destroy()
		gripPrompts[other] = nil
	end
end

local function refreshPrompt(other: Player)
	local character = other.Character
	if not (character and character:GetAttribute("Knocked") == true) then
		destroyPrompt(other)
		return
	end
	local prompt = gripPrompts[other]
	if not prompt then
		local root = character:FindFirstChild("HumanoidRootPart")
		if not (root and root:IsA("BasePart")) then
			return
		end
		local made = Instance.new("ProximityPrompt")
		made.Name = "GripPrompt"
		made.ActionText = "Grip"
		made.ObjectText = other.DisplayName
		made.KeyboardKeyCode = GRIP_KEY
		made.GamepadKeyCode = GRIP_BUTTON
		made.HoldDuration = HOLD_SECONDS
		made.MaxActivationDistance = REACH
		made.RequiresLineOfSight = false
		made.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
		-- Pressing starts the grip; releasing (key, button or touch) ends it.
		made.Triggered:Connect(function()
			holding = true
			Remotes.Client.Fire("GripStart", other.UserId)
		end)
		made.PromptButtonHoldEnded:Connect(releaseGrip)
		made.Parent = root
		gripPrompts[other] = made
		prompt = made
	end
	prompt.Enabled = not localBlocked()
		and character:GetAttribute("Carried") ~= true
		and character:GetAttribute("Jailed") ~= true
		and character:GetAttribute("Gripped") ~= true
end

local function refreshAllPrompts()
	for other in playerConnections do
		refreshPrompt(other)
	end
end

local function unwatchPlayerCharacter(other: Player)
	disconnectAll(characterConnections[other])
	characterConnections[other] = nil
	destroyPrompt(other)
end

local function watchPlayerCharacter(other: Player, character: Model)
	unwatchPlayerCharacter(other)
	local list: { RBXScriptConnection } = {}
	characterConnections[other] = list
	for _, attribute in { "Knocked", "Carried", "Jailed", "Gripped" } do
		table.insert(
			list,
			character:GetAttributeChangedSignal(attribute):Connect(function()
				refreshPrompt(other)
			end)
		)
	end
	-- The root can stream in after the character; retry when it shows up.
	table.insert(
		list,
		character.ChildAdded:Connect(function(child)
			if child.Name == "HumanoidRootPart" then
				refreshPrompt(other)
			end
		end)
	)
	refreshPrompt(other)
end

local function watchPlayer(other: Player)
	if playerConnections[other] then
		return
	end
	local list: { RBXScriptConnection } = {}
	playerConnections[other] = list
	-- Poses apply to every player's character, the local one included.
	table.insert(
		list,
		other.CharacterAdded:Connect(function(character)
			watchCharacter(character)
			if other ~= player then
				watchPlayerCharacter(other, character)
			end
		end)
	)
	table.insert(
		list,
		other.CharacterRemoving:Connect(function(character)
			unwatchCharacter(character)
			unwatchPlayerCharacter(other)
		end)
	)
	local current = other.Character
	if current then
		watchCharacter(current)
		if other ~= player then
			watchPlayerCharacter(other, current)
		end
	end
end

local function unwatchPlayer(other: Player)
	local current = other.Character
	if current then
		unwatchCharacter(current)
	end
	unwatchPlayerCharacter(other)
	disconnectAll(playerConnections[other])
	playerConnections[other] = nil
end

local function watchNpc(instance: Instance)
	if instance:IsA("Model") then
		watchCharacter(instance)
	end
end

-- The screens: choke bar (gripper) and gripped dim + vignette (victim) ---

local gui: ScreenGui? = nil
local barFrame: Frame? = nil
local barFill: Frame? = nil
local barLabel: TextLabel? = nil
local dimFrame: Frame? = nil
local vignetteEdges: { Frame } = {}
local captionLabel: TextLabel? = nil

local function edge(parent: Instance, anchor: Vector2, position: UDim2, size: UDim2, rotation: number): Frame
	local frame = Instance.new("Frame")
	frame.AnchorPoint = anchor
	frame.Position = position
	frame.Size = size
	frame.BackgroundColor3 = BLOOD
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = rotation
	gradient.Transparency = NumberSequence.new(0, 1)
	gradient.Parent = frame
	frame.Parent = parent
	return frame
end

local function ensureGui(): ScreenGui?
	if gui and gui.Parent then
		return gui
	end
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end
	local screen = Instance.new("ScreenGui")
	screen.Name = "GripScreen"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 21
	screen.Enabled = false

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 1
	dim.BorderSizePixel = 0
	dim.Visible = false
	dim.Parent = screen

	-- Red vignette: four edges fading toward the middle.
	vignetteEdges = {
		edge(dim, Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.3), 90),
		edge(dim, Vector2.new(0, 1), UDim2.fromScale(0, 1), UDim2.fromScale(1, 0.3), -90),
		edge(dim, Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(0.25, 1), 0),
		edge(dim, Vector2.new(1, 0), UDim2.fromScale(1, 0), UDim2.fromScale(0.25, 1), 180),
	}

	local caption = Instance.new("TextLabel")
	caption.Name = "Caption"
	caption.AnchorPoint = Vector2.new(0.5, 0.5)
	caption.Position = UDim2.fromScale(0.5, 0.78)
	caption.Size = UDim2.fromOffset(500, 40)
	caption.BackgroundTransparency = 1
	caption.FontFace = MERRIWEATHER_BOLD
	caption.TextSize = 24
	caption.TextColor3 = Color3.new(1, 1, 1)
	caption.TextStrokeTransparency = 0.4
	caption.Visible = false
	caption.Parent = screen

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -90)
	bar.Size = UDim2.fromOffset(280, 44)
	bar.BackgroundColor3 = PANEL_COLOR
	bar.BackgroundTransparency = 0.25
	bar.BorderSizePixel = 0
	bar.Visible = false
	bar.Parent = screen
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = bar

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 26)
	label.BackgroundTransparency = 1
	label.FontFace = MERRIWEATHER_BOLD
	label.TextSize = 18
	label.TextColor3 = GOLD
	label.Parent = bar

	local track = Instance.new("Frame")
	track.AnchorPoint = Vector2.new(0.5, 1)
	track.Position = UDim2.new(0.5, 0, 1, -7)
	track.Size = UDim2.new(1, -20, 0, 6)
	track.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	track.BorderSizePixel = 0
	track.Parent = bar
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = GOLD
	fill.BorderSizePixel = 0
	fill.Parent = track

	screen.Parent = playerGui
	gui, barFrame, barFill, barLabel, dimFrame, captionLabel = screen, bar, fill, label, dim, caption
	return screen
end

local function hideScreens()
	if gui then
		gui.Enabled = false
	end
	-- Leave the next grip starting from a clean screen.
	if barFill then
		barFill.Size = UDim2.fromScale(0, 1)
	end
	if dimFrame then
		dimFrame.BackgroundTransparency = 1
	end
	for _, frame in vignetteEdges do
		frame.BackgroundTransparency = 1
	end
	if barFrame then
		barFrame.Visible = false
	end
	if dimFrame then
		dimFrame.Visible = false
	end
	if captionLabel then
		captionLabel.Visible = false
	end
end

local function showGripping(victim: Person, progress: number)
	local screen = ensureGui()
	if not (screen and barFrame and barFill and barLabel) then
		return
	end
	screen.Enabled = true
	barFrame.Visible = true
	barLabel.Text = "Gripping " .. victim.name
	barFill.Size = UDim2.fromScale(progress, 1)
end

local function showGripped(gripper: Person, progress: number)
	local screen = ensureGui()
	if not (screen and dimFrame and captionLabel) then
		return
	end
	screen.Enabled = true
	dimFrame.Visible = true
	captionLabel.Visible = true
	captionLabel.Text = gripper.name .. " is choking you"
	-- The knockout blind screen is already up; this darkens further as the choke fills.
	dimFrame.BackgroundTransparency = 1 - 0.6 * progress
	local red = math.clamp((progress - 0.5) / 0.5, 0, 1)
	for _, frame in vignetteEdges do
		frame.BackgroundTransparency = 1 - 0.85 * red
	end
end

-- Plain lines for the server's stop reasons, per role; reasons not listed (completed, a party is gone,
-- death scene, dev command, ...) stay silent.
local GRIPPER_LINES: { [string]: string } = {
	released = "You let go.",
	hit = "You were hit.",
	["moved away"] = "You moved away.",
	["victim no longer knocked out"] = "They got up.",
	["victim carried"] = "Someone picked them up.",
	["victim jailed"] = "They were taken to jail.",
	["victim left"] = "They left.",
	["gripper knocked"] = "You were knocked down.",
	["gripper stun"] = "You were stunned.",
	["gripper truestun"] = "You were stunned.",
	["gripper jailed"] = "You were jailed.",
	["gripper carried"] = "You were picked up.",
	["gripper carrying"] = "You picked someone up.",
}
local VICTIM_LINES: { [string]: string } = {
	released = "They let go.",
	hit = "Someone hit them.",
	["moved away"] = "They moved away.",
	["victim no longer knocked out"] = "You got up.",
	["victim carried"] = "Someone picked you up.",
	["victim jailed"] = "You were taken to jail.",
	["gripper left"] = "They left.",
	["gripper knocked"] = "They were knocked down.",
	["gripper stun"] = "They were stunned.",
	["gripper truestun"] = "They were stunned.",
	["gripper jailed"] = "They were jailed.",
	["gripper carried"] = "They were picked up.",
	["gripper carrying"] = "They picked someone up.",
}

local function onGripState(payload: any)
	if type(payload) ~= "table" then
		log:Warn("GripState: unexpected payload")
		return
	end
	local state = payload :: GripStateData
	local progress = if type(state.progress) == "number" then math.clamp(state.progress, 0, 1) else 0
	if state.gripping then
		showGripping(state.gripping, progress)
	elseif state.grippedBy then
		showGripped(state.grippedBy, progress)
	else
		holding = false
		-- Which role just ended is known from what was on screen.
		local wasGripping = barFrame ~= nil and barFrame.Visible
		hideScreens()
		local reason = state.reason
		if type(reason) == "string" then
			local line = (if wasGripping then GRIPPER_LINES else VICTIM_LINES)[reason]
			if line then
				ChatLines.Post(line)
			end
		end
	end
	refreshAllPrompts()
end

local function onLocalCharacter(character: Model)
	disconnectAll(localConnections)
	table.clear(localConnections)
	-- A new character is gripping and gripped by no one; let go of any grip still held first.
	releaseGrip()
	hideScreens()
	for _, attribute in { "Knocked", "Carried", "Carrying", "Jailed", "Gripping", "Gripped" } do
		table.insert(
			localConnections,
			character:GetAttributeChangedSignal(attribute):Connect(refreshAllPrompts)
		)
	end
	refreshAllPrompts()
end

function GripController:Init() end

function GripController:Start()
	Remotes.Client.On("GripState", onGripState)

	-- Letting go of the key breaks the grip; the prompt may be gone by then, so listen globally.
	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == GRIP_KEY or input.KeyCode == GRIP_BUTTON then
			releaseGrip()
		end
	end)
	-- Alt-tabbing away mid-hold never delivers the key release.
	UserInputService.WindowFocusReleased:Connect(releaseGrip)

	player.CharacterAdded:Connect(onLocalCharacter)
	if player.Character then
		onLocalCharacter(player.Character)
	end

	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(unwatchPlayer)
	for _, other in Players:GetPlayers() do
		watchPlayer(other)
	end

	-- NPC dummies (Target gripper) are posed by the same attributes.
	CollectionService:GetInstanceAddedSignal(NPC_TAG):Connect(watchNpc)
	CollectionService:GetInstanceRemovedSignal(NPC_TAG):Connect(function(instance)
		if instance:IsA("Model") then
			unwatchCharacter(instance)
		end
	end)
	for _, instance in CollectionService:GetTagged(NPC_TAG) do
		watchNpc(instance)
	end

	log:Info("ready")
end

return GripController

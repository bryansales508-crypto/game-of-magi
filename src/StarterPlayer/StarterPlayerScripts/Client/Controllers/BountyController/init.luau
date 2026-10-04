--!strict
-- Bounty hunting, hunter side: tells the server when the "Bounty: <name>" Tool is in hand, shows
-- the quest tracker at the target's last known spot, and red-highlights the target once revealed.
--
-- Server contract (Shared/Remotes.luau, SYSTEMS.md section 17):
--   BountyState (server -> client): { target = { userId, name, bounty }?, lastKnown = { x, y, z }?,
--     revealed, reason? }. target nil = the bounty is gone (reason is shown as a chat line).
--   BountyNotice (server -> client): { text } shown as a chat system line.
--   BountyToolEquipped(boolean) (client -> server): the Tool went into / out of the hands.
-- Everything shown is local to this client. Unequipping hides the tracker and highlight at once.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared:WaitForChild("Log"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local ChatLines = require(script.Parent.ChatLines)

local log = Log.new("BountyController")
local player = Players.LocalPlayer

local BountyController = {}

local TOOL_NAME_PREFIX = "Bounty: "
local TRACKER_WIDTH = 120
local TRACKER_HEIGHT = 90
local DISTANCE_INTERVAL = 0.2 -- only while the tracker is up
local HIGHLIGHT_COLOR = Color3.fromRGB(255, 40, 40)
local NAME_COLOR = Color3.fromRGB(239, 187, 65)
local MERRIWEATHER_BOLD = Font.new(Font.fromEnum(Enum.Font.Merriweather).Family, Enum.FontWeight.Bold, Enum.FontStyle.Normal)

type Target = { userId: number, name: string, bounty: number }
type BountyStateData = {
	target: Target?,
	lastKnown: { [any]: number }?,
	revealed: boolean?,
	reason: string?,
}
type Tracker = {
	anchor: Part,
	distanceLabel: TextLabel,
	nameLabel: TextLabel,
	thread: thread?,
}

local trackerTemplate: BillboardGui? = nil
local state: BountyStateData? = nil
local equipped = false

local tracker: Tracker? = nil
local highlight: Highlight? = nil
local highlightedUserId: number? = nil
local highlightConnections: { RBXScriptConnection } = {}
local characterConnections: { RBXScriptConnection } = {}

local postSystemLine = ChatLines.Post

local function toVector3(position: { [any]: number }?): Vector3?
	if type(position) ~= "table" then
		return nil
	end
	local x, y, z = position.x, position.y, position.z
	if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
		return nil
	end
	return Vector3.new(x, y, z)
end

local function isBountyTool(instance: Instance): boolean
	return instance:IsA("Tool")
		and (instance:GetAttribute("BountyTarget") ~= nil or string.sub(instance.Name, 1, #TOOL_NAME_PREFIX) == TOOL_NAME_PREFIX)
end

-- Tracker (the delivery tracker template, fixed pixel size so camera FOV never stretches it) ---

local function updateDistance(active: Tracker)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return
	end
	local studs = (root.Position - active.anchor.Position).Magnitude
	active.distanceLabel.Text = string.format("%dm", math.floor(studs))
end

local function hideTracker()
	local active = tracker
	if not active then
		return
	end
	tracker = nil
	if active.thread then
		task.cancel(active.thread)
	end
	active.anchor:Destroy()
end

local function createTracker(): Tracker?
	if not trackerTemplate then
		return nil
	end
	local anchor = Instance.new("Part")
	anchor.Name = "BountyTrackerAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)

	local gui = trackerTemplate:Clone()
	gui.Size = UDim2.fromOffset(TRACKER_WIDTH, TRACKER_HEIGHT)
	gui.StudsOffset = Vector3.zero
	gui.StudsOffsetWorldSpace = Vector3.zero
	gui.ExtentsOffset = Vector3.zero
	gui.SizeOffset = Vector2.zero
	gui.AlwaysOnTop = true
	gui.ClipsDescendants = false
	gui.MaxDistance = math.huge
	gui.Adornee = anchor
	for _, descendant in gui:GetDescendants() do
		if descendant:IsA("ImageLabel") then
			descendant.ScaleType = Enum.ScaleType.Fit
		end
	end

	local distanceLabel = (gui :: any).Frame.Distance :: TextLabel

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "TargetName"
	nameLabel.AnchorPoint = Vector2.new(0.5, 1)
	nameLabel.Position = UDim2.new(0.5, 0, 0, -2)
	nameLabel.Size = UDim2.fromOffset(TRACKER_WIDTH + 40, 20)
	nameLabel.BackgroundTransparency = 1
	nameLabel.FontFace = MERRIWEATHER_BOLD
	nameLabel.TextSize = 16
	nameLabel.TextColor3 = NAME_COLOR
	nameLabel.TextStrokeTransparency = 0.5
	nameLabel.Parent = gui

	gui.Parent = anchor
	anchor.Parent = Workspace

	return { anchor = anchor, distanceLabel = distanceLabel, nameLabel = nameLabel, thread = nil }
end

local function showTracker(position: Vector3, targetName: string)
	local active: Tracker? = tracker
	if active == nil then
		local created = createTracker()
		if created == nil then
			return
		end
		tracker = created
		created.thread = task.spawn(function()
			while created.anchor.Parent do
				updateDistance(created)
				task.wait(DISTANCE_INTERVAL)
			end
		end)
		active = created
	end
	local current: Tracker = active :: Tracker
	current.anchor.Position = position
	current.nameLabel.Text = targetName
	updateDistance(current)
end

-- Reveal highlight (this client only) ---

local function clearHighlight()
	for _, connection in highlightConnections do
		connection:Disconnect()
	end
	table.clear(highlightConnections)
	if highlight then
		highlight:Destroy()
		highlight = nil
	end
	highlightedUserId = nil
end

local function attachHighlight(character: Model?)
	if highlight then
		highlight:Destroy()
		highlight = nil
	end
	if not character then
		return
	end
	local made = Instance.new("Highlight")
	made.Name = "BountyHighlight"
	made.FillColor = HIGHLIGHT_COLOR
	made.FillTransparency = 0.6
	made.OutlineColor = HIGHLIGHT_COLOR
	made.OutlineTransparency = 0
	made.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	made.Adornee = character
	made.Parent = character
	highlight = made
end

local function showHighlight(userId: number)
	if highlightedUserId == userId then
		return
	end
	clearHighlight()
	local targetPlayer = Players:GetPlayerByUserId(userId)
	if not targetPlayer then
		return
	end
	highlightedUserId = userId
	table.insert(highlightConnections, targetPlayer.CharacterAdded:Connect(attachHighlight))
	attachHighlight(targetPlayer.Character)
end

-- State -> visuals ---

local function render()
	local current = state
	local target = current and current.target
	if not (current and target and equipped) then
		hideTracker()
		clearHighlight()
		return
	end
	if current.revealed == true then
		hideTracker()
		showHighlight(target.userId)
		return
	end
	clearHighlight()
	local position = toVector3(current.lastKnown)
	if position then
		showTracker(position, target.name)
	else
		hideTracker()
	end
end

local function setEquipped(value: boolean)
	if equipped == value then
		return
	end
	equipped = value
	Remotes.Client.Fire("BountyToolEquipped", value)
	render()
end

local function onBountyState(payload: any)
	if type(payload) ~= "table" then
		log:Warn("BountyState: unexpected payload")
		return
	end
	local data = payload :: BountyStateData
	if data.target == nil and type(data.reason) == "string" and data.reason ~= "" then
		postSystemLine(data.reason)
	end
	state = data
	render()
end

local function onBountyNotice(payload: any)
	if type(payload) == "table" and type((payload :: any).text) == "string" then
		postSystemLine((payload :: any).text)
	end
end

-- Tool detection: a Tool in the Character is equipped ---

local function disconnectCharacter()
	for _, connection in characterConnections do
		connection:Disconnect()
	end
	table.clear(characterConnections)
end

local function onCharacterAdded(character: Model)
	disconnectCharacter()
	-- A new character holds nothing; the server already knows (it dropped or kept the hunt itself).
	equipped = false
	render()

	table.insert(
		characterConnections,
		character.ChildAdded:Connect(function(child)
			if isBountyTool(child) then
				setEquipped(true)
			end
		end)
	)
	table.insert(
		characterConnections,
		character.ChildRemoved:Connect(function(child)
			if isBountyTool(child) then
				setEquipped(false)
			end
		end)
	)
	for _, child in character:GetChildren() do
		if isBountyTool(child) then
			setEquipped(true)
		end
	end
end

function BountyController:Init() end

function BountyController:Start()
	local gui = ReplicatedFirst:WaitForChild("GUI", 15)
	local missionGui = gui and gui:WaitForChild("MissionGUI", 15)
	local template = missionGui and missionGui:WaitForChild("QuestTracker", 15)
	if template and template:IsA("BillboardGui") then
		trackerTemplate = template
	else
		log:Warn("MissionGUI.QuestTracker missing; bounty tracker disabled")
	end

	Remotes.Client.On("BountyState", onBountyState)
	Remotes.Client.On("BountyNotice", onBountyNotice)

	player.CharacterAdded:Connect(onCharacterAdded)
	player.CharacterRemoving:Connect(function()
		disconnectCharacter()
		equipped = false
		render()
	end)
	if player.Character then
		onCharacterAdded(player.Character)
	end

	log:Info("ready")
end

return BountyController

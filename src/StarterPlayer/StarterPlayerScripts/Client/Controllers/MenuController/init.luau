--!strict
-- The M-key character menu card. Clones ReplicatedFirst.GUI.UIGUI.MenuGUI
-- once (kept for the whole session; ResetOnSpawn is off), destroys its
-- Studio-only `MenuMechanics` LocalScript, and fills it from player attributes.
--
-- Reads (may be nil for a moment at join; rendered as "..." until set):
--   FirstName, Kingdom (1/2/3), Age, HeightStuds, Rank, Epithet, Alignment,
--   Lives.
--
-- The stat line scales to fit (UITextSizeConstraint); a second line
-- (alignment + lives) is added in code under it in the same style.

local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared:WaitForChild("Log"))

local log = Log.new("MenuController")

local player = Players.LocalPlayer

local GUI = ReplicatedFirst:WaitForChild("GUI")
local UIGUI = GUI:WaitForChild("UIGUI")
local MENU_TEMPLATE = UIGUI:WaitForChild("MenuGUI") :: ScreenGui
-- Assets/init.luau isn't --!strict; `:: any` keeps its loose inference from
-- leaking into this strict file.

local KINGDOM_NAMES: { [number]: string } = {
	[1] = "MIDLANDER",
	[2] = "EASTERNER",
	[3] = "WESTERNER",
}

-- The height scale runs 0.725..1.450 (4'5" to 7'0"), with 1.000 = 5'6".
-- HeightStuds = scale * a base-height-in-studs constant: read from
-- Config.Character.BaseHeightStuds when present, else a fallback estimate.
local Config = require(Shared:WaitForChild("Config"))
local DEFAULT_BASE_HEIGHT_STUDS = 5.708
local function baseHeightStuds(): number
	local characterConfig = (Config :: any).Character
	if typeof(characterConfig) == "table" and typeof(characterConfig.BaseHeightStuds) == "number" then
		return characterConfig.BaseHeightStuds
	end
	return DEFAULT_BASE_HEIGHT_STUDS
end

-- Two linear segments through the endpoints and the 1.000 anchor, rounded to
-- the nearest inch.
local function heightScaleToFeetInches(scale: number): string
	local inches: number
	if scale <= 1.0 then
		inches = 53 + (scale - 0.725) / (1.0 - 0.725) * (66 - 53)
	else
		inches = 66 + (scale - 1.0) / (1.45 - 1.0) * (84 - 66)
	end
	inches = math.clamp(math.round(inches), 53, 84)
	local feet = math.floor(inches / 12)
	local remainder = inches - feet * 12
	return string.format("%d'%d", feet, remainder)
end

local function ordinalSuffix(n: number): string
	local mod100 = n % 100
	if mod100 >= 11 and mod100 <= 13 then
		return "TH"
	end
	local mod10 = n % 10
	if mod10 == 1 then
		return "ST"
	elseif mod10 == 2 then
		return "ND"
	elseif mod10 == 3 then
		return "RD"
	end
	return "TH"
end

local function applyTextScale(label: TextLabel, maxTextSize: number)
	label.TextScaled = true
	local existing = label:FindFirstChildOfClass("UITextSizeConstraint")
	local constraint: UITextSizeConstraint
	if existing then
		constraint = existing :: UITextSizeConstraint
	else
		constraint = Instance.new("UITextSizeConstraint")
		constraint.Parent = label
	end
	constraint.MaxTextSize = maxTextSize
end

local MenuController = {}

local menuOpen = false
local apparelOpen = false
local apparelInstances: { Instance } = {}

local function playSound(template: Sound?)
	local character = player.Character
	if not template or not character then
		return
	end
	local torso = character:FindFirstChild("Torso")
		or character:FindFirstChild("UpperTorso")
		or character:FindFirstChild("HumanoidRootPart")
	if not torso then
		return
	end
	local sound = template:Clone()
	sound.Parent = torso
	sound:Play()
	sound.Ended:Connect(function()
		sound:Destroy()
	end)
end

-- A ViewportFrame showing a clone of the local character in a WorldModel,
-- with the camera looking at the head.
local function buildCharacterPreview(viewCharaFrame: Instance)
	local character = player.Character
	if not character then
		return
	end
	local head = character:FindFirstChild("Head") :: BasePart?
	if not head then
		return
	end

	-- Player characters aren't Archivable by default, so Clone() would return
	-- nil; enable it for the clone, then restore it.
	local wasArchivable = character.Archivable
	character.Archivable = true
	local clone = character:Clone()
	character.Archivable = wasArchivable

	if not clone then
		log:Warn("character:Clone() returned nil; skipping the menu preview")
		return
	end

	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant:Destroy()
		end
	end

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Preview"
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.BackgroundTransparency = 1

	local worldModel = Instance.new("WorldModel")
	worldModel.Parent = viewport
	clone.Parent = worldModel

	-- A mirror view: the camera sits in front of the face (along the head's
	-- LookVector) and looks back at it, whichever way the character faces.
	local headCFrame = head.CFrame
	local cameraPosition = headCFrame.Position + headCFrame.LookVector * 2.5 + Vector3.new(0, 0.3, 0)

	local camera = Instance.new("Camera")
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(cameraPosition, headCFrame.Position)
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	viewport.Parent = viewCharaFrame
end

-- Placeholder: nothing publishes inventory yet, so the apparel tab shows no
-- tokens.
local function fillInventoryTokens(_inventoryFrame: Instance)
	return
end

local function closeApparel(appPressed: BoolValue)
	if not apparelOpen then
		return
	end
	apparelOpen = false
	appPressed.Value = false
	for _, instance in apparelInstances do
		instance:Destroy()
	end
	table.clear(apparelInstances)
end

local function openApparel(masterFrame: Frame, appPressed: BoolValue)
	if apparelOpen then
		return
	end
	apparelOpen = true
	appPressed.Value = true

	local clones: { [string]: Instance } = {}
	for _, templateName in { "InventoryFrame", "PlacementFrame", "ViewCharaFrame", "WordFrame" } do
		local template = UIGUI:FindFirstChild(templateName)
		if not template then
			log:Warn(string.format("apparel template %q missing under ReplicatedFirst.GUI.UIGUI", templateName))
			continue
		end
		local clone = template:Clone()
		clone.Parent = masterFrame
		table.insert(apparelInstances, clone)
		clones[templateName] = clone
	end

	local viewChara = clones["ViewCharaFrame"]
	if viewChara then
		buildCharacterPreview(viewChara)
	end

	local inventoryFrame = clones["InventoryFrame"]
	if inventoryFrame then
		fillInventoryTokens(inventoryFrame)
	end
end

function MenuController:Init() end

function MenuController:Start()
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

	local gui = MENU_TEMPLATE:Clone()
	gui.ResetOnSpawn = false
	-- MenuMechanics sits under MasterFrame.MenuGUIFrame, so the search is
	-- recursive; it must run before the clone is parented.
	local menuMechanics = gui:FindFirstChild("MenuMechanics", true)
	if menuMechanics then
		menuMechanics:Destroy()
	end

	local appPressed = gui:WaitForChild("AppPressed") :: BoolValue
	local masterFrame = gui:WaitForChild("MasterFrame") :: Frame
	local menuGUIFrame = masterFrame:WaitForChild("MenuGUIFrame") :: Frame
	local titleBox = menuGUIFrame:WaitForChild("TitleBox") :: TextLabel
	local nameBox = menuGUIFrame:WaitForChild("NameBox") :: TextLabel
	local statBox = menuGUIFrame:WaitForChild("StatBox") :: TextLabel
	local buttons = menuGUIFrame:WaitForChild("Buttons") :: Frame
	local appButton = buttons:WaitForChild("App") :: ImageButton

	-- TextScaled with a max size keeps the line inside the box at any length.
	applyTextScale(statBox, 12)

	local statLine2 = statBox:Clone()
	statLine2.Name = "StatBoxLine2"
	local statBoxPos = statBox.Position
	statLine2.Position = UDim2.new(statBoxPos.X.Scale, statBoxPos.X.Offset, statBoxPos.Y.Scale + 0.06, statBoxPos.Y.Offset)
	statLine2.Parent = menuGUIFrame
	applyTextScale(statLine2, 11)

	local sfxFolder = ReplicatedFirst:FindFirstChild("SFX")
	local uiSounds = sfxFolder and sfxFolder:FindFirstChild("UISounds")
	local selectSound1 = (uiSounds and uiSounds:FindFirstChild("SelectSound1")) :: Sound?
	local selectSound3 = (uiSounds and uiSounds:FindFirstChild("SelectSound3")) :: Sound?
	if not selectSound1 or not selectSound3 then
		log:Warn("ReplicatedFirst.SFX.UISounds.SelectSound1/3 missing; apparel button will be silent")
	end

	local function render()
		local firstName = player:GetAttribute("FirstName")
		nameBox.Text = if typeof(firstName) == "string" and firstName ~= "" then string.upper(firstName) else "..."

		local epithet = player:GetAttribute("Epithet")
		local rank = player:GetAttribute("Rank")
		if typeof(epithet) == "string" and epithet ~= "" then
			titleBox.Text = string.upper(epithet)
		elseif typeof(rank) == "string" and rank ~= "" then
			titleBox.Text = string.upper(rank)
		else
			titleBox.Text = "THE MERCHANT'S CHILD"
		end

		local kingdom = player:GetAttribute("Kingdom")
		local kingdomText = if typeof(kingdom) == "number" and KINGDOM_NAMES[kingdom] then KINGDOM_NAMES[kingdom] else "..."

		local age = player:GetAttribute("Age")
		local ageText = if typeof(age) == "number"
			then string.format("THE %d%s YEAR SINCE BIRTH", age, ordinalSuffix(age))
			else "..."

		local heightStuds = player:GetAttribute("HeightStuds")
		local heightText = if typeof(heightStuds) == "number"
			then heightScaleToFeetInches(heightStuds / baseHeightStuds())
			else "..."

		statBox.Text = string.format("%s \u{2756} %s \u{2756} %s", kingdomText, ageText, heightText)

		local alignment = player:GetAttribute("Alignment")
		local alignmentText = if typeof(alignment) == "string" and alignment ~= "" then string.upper(alignment) else "..."
		local lives = player:GetAttribute("Lives")
		local livesText = if typeof(lives) == "number" then tostring(lives) else "..."

		statLine2.Text = string.format("%s \u{2756} LIFE %s", alignmentText, livesText)
	end

	for _, attributeName in { "FirstName", "Epithet", "Rank", "Kingdom", "Age", "HeightStuds", "Alignment", "Lives" } do
		player:GetAttributeChangedSignal(attributeName):Connect(render)
	end
	render()

	appButton.Activated:Connect(function()
		playSound(selectSound1)
		if apparelOpen then
			closeApparel(appPressed)
		else
			openApparel(masterFrame, appPressed)
		end
	end)
	appButton.MouseEnter:Connect(function()
		playSound(selectSound3)
	end)

	local function toggleMenu()
		menuOpen = not menuOpen
		gui.Enabled = menuOpen
		if menuOpen then
			render()
		else
			closeApparel(appPressed)
		end
	end

	ContextActionService:BindAction("ToggleCharacterMenu", function(_actionName, inputState, _inputObject)
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		toggleMenu()
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.M)

	gui.Enabled = false
	gui.Parent = playerGui

	log:Info("ready (M to toggle)")
end

return MenuController

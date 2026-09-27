--!strict
-- The Rukh flutter and the epithet card (M4-02, DESIGN.md section 3a).
--
-- Contract with the server (M4-01, Shared/Remotes.luau):
--   RankUp(title: string, rankIndex: number, alignment: string,
--          choices: {string, string, string}, origin: boolean) -- server -> client.
--   AlignmentChanged(alignment: string) -- server -> client, flutter only.
--   ChooseEpithet(index: number 1-3) -- client -> server; the server holds
--     the real choices and only ever trusts the index.
-- Player attributes read: Alignment (indirectly, via the remote payloads)
-- and EpithetPending. The client never computes rank/alignment/epithet
-- itself -- it only shows what RankUp/AlignmentChanged send and reacts to
-- EpithetPending going false.
--
-- Both remotes are sent to the player concerned only (never broadcast), so
-- the flutter here is local-player-only; playing another player's flutter
-- for onlookers is a later polish (not this task).
--
-- Card look: reuses the exact menu-card assets (m2-studio-dump.md section
-- 2) -- the Outline/BackgroundFill images and fill colour -- but its fonts
-- are copied live from the real MenuGUI template's TitleBox/NameBox/
-- StatBox (their FontFace, not a guessed Font.new(...)): HighwayGothic and
-- Balthazar are custom uploaded fonts, and only the template's own
-- instances are guaranteed to carry the right one.

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared:WaitForChild("Log"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Config = require(Shared:WaitForChild("Config"))

local log = Log.new("RankController")

local player = Players.LocalPlayer

local GUI = ReplicatedFirst:WaitForChild("GUI")
local UIGUI = GUI:WaitForChild("UIGUI")
local MENU_TEMPLATE = UIGUI:WaitForChild("MenuGUI") :: ScreenGui

local RankController = {}

-- ==================== alignment label -> Config.Rukh.Emitters key ====================

local ALIGNMENT_KEYS: { [string]: string } = {
	["White Rukh"] = "White",
	["Gold Rukh"] = "Gold",
	["Black Rukh"] = "Black",
	["Gold & Black Rukh"] = "GoldBlack",
}

-- ==================== the Rukh flutter ====================

-- Never two flutters at once: a fresh one always cancels whatever's
-- currently running, whichever remote asked for it.
local flutterGeneration = 0
local flutterCleanup: (() -> ())? = nil

local function cancelFlutter()
	flutterGeneration += 1
	local cleanup = flutterCleanup
	flutterCleanup = nil
	if cleanup then
		local results = table.pack(pcall(cleanup))
		if not results[1] then
			log:Warn("flutter cleanup failed: " .. tostring(results[2]))
		end
	end
end

local function playFlutter(alignment: string)
	cancelFlutter()
	local myGeneration = flutterGeneration

	local key = ALIGNMENT_KEYS[alignment]
	if not key then
		log:Warn("unknown alignment label: " .. tostring(alignment))
		return
	end

	local emitterNames = Config.Rukh.Emitters[key]
	if not emitterNames then
		log:Warn("Config.Rukh.Emitters has no list for " .. key)
		return
	end

	local character = player.Character
	if not character then
		return
	end
	local torso = character:FindFirstChild("Torso") or character:FindFirstChild("UpperTorso") or character:FindFirstChild("HumanoidRootPart")
	if not torso then
		log:Warn("no Torso/UpperTorso/HumanoidRootPart; skipping the flutter")
		return
	end

	local vfx = ReplicatedFirst:FindFirstChild("VFX")
	local rukhEffects = vfx and vfx:FindFirstChild("RukhEffects")
	if not rukhEffects then
		log:Warn("ReplicatedFirst.VFX.RukhEffects missing; skipping the flutter")
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "RukhFlutterAttachment"
	attachment.Parent = torso

	local emitted = 0
	for _, emitterName in emitterNames do
		local template = rukhEffects:FindFirstChild(emitterName)
		if template and template:IsA("ParticleEmitter") then
			local clone = template:Clone()
			clone.Rate = clone.Rate * Config.Rukh.EmitRate
			clone.Enabled = true
			clone.Parent = attachment
			emitted += 1
		else
			log:Warn(string.format("RukhEffects has no ParticleEmitter named %q", emitterName))
		end
	end

	flutterCleanup = function()
		attachment:Destroy()
	end

	task.delay(Config.Rukh.FlutterSeconds, function()
		if flutterGeneration ~= myGeneration then
			return
		end
		flutterCleanup = nil
		attachment:Destroy()
	end)

	log:Info(string.format("Rukh flutter: %s (%d emitter(s))", key, emitted))
end

-- ==================== the epithet card: constants and font lookup ====================

local CARD_SIZE = UDim2.fromScale(0.24, 0.34)
local CARD_ASPECT_RATIO = 0.24 / 0.34
local FILL_COLOR = Color3.fromRGB(144, 127, 86)
local OUTLINE_IMAGE = "rbxassetid://81599903982206"
local FILL_IMAGE = "rbxassetid://99814341310974"
local NAME_COLOR = Color3.fromRGB(255, 224, 152)
local BUTTON_IDLE = Color3.fromRGB(121, 106, 72)
local BUTTON_HOVER = Color3.fromRGB(255, 244, 189)
local BUTTON_CHOSEN = Color3.fromRGB(53, 46, 32)
local FADE_SECONDS = 1.2

local KEY_INDEX: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
}
local CHOOSE_ACTION = "ChooseEpithetKey"

local function findTemplateLabel(name: string): TextLabel?
	local found = MENU_TEMPLATE:FindFirstChild(name, true)
	return if found and found:IsA("TextLabel") then found else nil
end

-- Copies the real template's FontFace rather than reconstructing a Font by
-- name (see the file header comment on HighwayGothic/Balthazar).
local function copyFont(source: TextLabel?, target: TextLabel | TextButton)
	if source then
		(target :: any).FontFace = source.FontFace
	end
end

-- ==================== wiring ====================

function RankController:Init() end

function RankController:Start()
	local titleFontSource = findTemplateLabel("TitleBox")
	local nameFontSource = findTemplateLabel("NameBox")
	local statFontSource = findTemplateLabel("StatBox")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "RankCard"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 100
	screenGui.Enabled = false

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = CARD_SIZE
	card.BackgroundTransparency = 1
	card.Parent = screenGui

	local aspectConstraint = Instance.new("UIAspectRatioConstraint")
	aspectConstraint.AspectRatio = CARD_ASPECT_RATIO
	aspectConstraint.AspectType = Enum.AspectType.FitWithinMaxSize
	aspectConstraint.DominantAxis = Enum.DominantAxis.Width
	aspectConstraint.Parent = card

	local fill = Instance.new("ImageLabel")
	fill.Name = "BackgroundFill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundTransparency = 1
	fill.Image = FILL_IMAGE
	fill.ImageColor3 = FILL_COLOR
	fill.ZIndex = 1
	fill.Parent = card

	local outline = Instance.new("ImageLabel")
	outline.Name = "Outline"
	outline.Size = UDim2.fromScale(1, 1)
	outline.BackgroundTransparency = 1
	outline.Image = OUTLINE_IMAGE
	outline.ZIndex = 2
	outline.Parent = card

	local titleLine = Instance.new("TextLabel")
	titleLine.Name = "TitleLine"
	titleLine.AnchorPoint = Vector2.new(0.5, 0)
	titleLine.Position = UDim2.fromScale(0.5, 0.1)
	titleLine.Size = UDim2.fromScale(0.8, 0.08)
	titleLine.BackgroundTransparency = 1
	titleLine.TextColor3 = Color3.new(0, 0, 0)
	titleLine.TextScaled = true
	titleLine.ZIndex = 3
	titleLine.Parent = card
	copyFont(titleFontSource, titleLine)
	do
		local constraint = Instance.new("UITextSizeConstraint")
		constraint.MaxTextSize = 16
		constraint.Parent = titleLine
	end

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "NameLabel"
	nameLabel.AnchorPoint = Vector2.new(0.5, 0)
	nameLabel.Position = UDim2.fromScale(0.5, 0.2)
	nameLabel.Size = UDim2.fromScale(0.9, 0.14)
	nameLabel.BackgroundTransparency = 1
	nameLabel.TextColor3 = NAME_COLOR
	nameLabel.TextScaled = true
	nameLabel.ZIndex = 3
	nameLabel.Parent = card
	copyFont(nameFontSource, nameLabel)
	do
		local constraint = Instance.new("UITextSizeConstraint")
		constraint.MaxTextSize = 30
		constraint.Parent = nameLabel
	end

	local choicesFrame = Instance.new("Frame")
	choicesFrame.Name = "Choices"
	choicesFrame.AnchorPoint = Vector2.new(0.5, 1)
	choicesFrame.Position = UDim2.fromScale(0.5, 0.94)
	choicesFrame.Size = UDim2.fromScale(0.86, 0.6)
	choicesFrame.BackgroundTransparency = 1
	choicesFrame.ZIndex = 3
	choicesFrame.Parent = card

	local choicesLayout = Instance.new("UIListLayout")
	choicesLayout.FillDirection = Enum.FillDirection.Vertical
	choicesLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	choicesLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	choicesLayout.Padding = UDim.new(0.03, 0)
	choicesLayout.SortOrder = Enum.SortOrder.LayoutOrder
	choicesLayout.Parent = choicesFrame

	local buttons: { TextButton } = {}
	for i = 1, 3 do
		local button = Instance.new("TextButton")
		button.Name = "Choice" .. i
		button.LayoutOrder = i
		button.Size = UDim2.fromScale(1, 0.3)
		button.AutoButtonColor = false
		button.BackgroundColor3 = BUTTON_IDLE
		button.TextColor3 = Color3.new(0, 0, 0)
		button.TextScaled = true
		button.TextWrapped = true
		button.ZIndex = 3
		button.Parent = choicesFrame
		copyFont(statFontSource, button)

		local constraint = Instance.new("UITextSizeConstraint")
		constraint.MaxTextSize = 16
		constraint.Parent = button

		buttons[i] = button
	end

	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- ==================== card state ====================

	local cardShowing = false
	local chosen = false
	local fadeTweens: { Tween } = {}

	local function cancelFade()
		for _, tween in fadeTweens do
			tween:Cancel()
		end
		table.clear(fadeTweens)
	end

	local function setCardTransparency(alpha: number)
		fill.ImageTransparency = alpha
		outline.ImageTransparency = alpha
		titleLine.TextTransparency = alpha
		nameLabel.TextTransparency = alpha
		for _, button in buttons do
			button.BackgroundTransparency = alpha
			button.TextTransparency = alpha
		end
	end

	local function unbindKeys()
		ContextActionService:UnbindAction(CHOOSE_ACTION)
	end

	local function chooseEpithet(index: number)
		if chosen or not cardShowing then
			return
		end
		chosen = true
		unbindKeys()

		for i, button in buttons do
			button.Active = false
			button.BackgroundColor3 = if i == index then BUTTON_CHOSEN else BUTTON_IDLE
		end

		Remotes.Client.Fire("ChooseEpithet", index)
		log:Info("ChooseEpithet: " .. index)
	end

	local function bindKeys()
		ContextActionService:BindAction(CHOOSE_ACTION, function(_actionName, inputState, inputObject)
			if inputState ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			local index = KEY_INDEX[inputObject.KeyCode]
			if not index then
				return Enum.ContextActionResult.Pass
			end
			chooseEpithet(index)
			return Enum.ContextActionResult.Sink
		end, false, Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three)
	end

	local function fadeOutCard()
		if not cardShowing then
			return
		end
		cardShowing = false
		unbindKeys()
		cancelFade()

		local tweenInfo = TweenInfo.new(FADE_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
		table.insert(fadeTweens, TweenService:Create(fill, tweenInfo, { ImageTransparency = 1 }))
		table.insert(fadeTweens, TweenService:Create(outline, tweenInfo, { ImageTransparency = 1 }))
		table.insert(fadeTweens, TweenService:Create(titleLine, tweenInfo, { TextTransparency = 1 }))
		table.insert(fadeTweens, TweenService:Create(nameLabel, tweenInfo, { TextTransparency = 1 }))
		for _, button in buttons do
			table.insert(fadeTweens, TweenService:Create(button, tweenInfo, { BackgroundTransparency = 1, TextTransparency = 1 }))
		end
		for _, tween in fadeTweens do
			tween:Play()
		end

		task.delay(FADE_SECONDS, function()
			if cardShowing then
				return -- a new RankUp re-showed the card mid-fade; leave it alone
			end
			screenGui.Enabled = false
		end)

		log:Info("epithet card: fading (choice confirmed)")
	end

	local function showCard(title: string, choices: { string }, origin: boolean)
		cancelFade()
		setCardTransparency(0)
		chosen = false
		cardShowing = true

		titleLine.Text = if origin then "YOUR ORIGIN" else "A NEW RANK"
		nameLabel.Text = string.upper(title)
		for i, button in buttons do
			button.Text = choices[i] or ""
			button.Active = true
			button.BackgroundColor3 = BUTTON_IDLE
		end

		screenGui.Enabled = true
		bindKeys()
	end

	for i, button in buttons do
		button.Activated:Connect(function()
			chooseEpithet(i)
		end)
		button.MouseEnter:Connect(function()
			if not chosen and button.Active then
				button.BackgroundColor3 = BUTTON_HOVER
			end
		end)
		button.MouseLeave:Connect(function()
			if not chosen and button.Active then
				button.BackgroundColor3 = BUTTON_IDLE
			end
		end)
	end

	-- Registered here (not Init) so this file follows the same convention
	-- as RukhController: only Start() ever touches remotes/GUI. RankUp
	-- always carries the fresh choices needed to render the card, including
	-- on rejoin with a pending choice (the server re-sends it); the
	-- EpithetPending attribute below is what actually decides when to fade.
	Remotes.Client.On("RankUp", function(title: any, rankIndex: any, alignment: any, choices: any, origin: any)
		if
			typeof(title) ~= "string"
			or typeof(rankIndex) ~= "number"
			or typeof(alignment) ~= "string"
			or typeof(choices) ~= "table"
			or typeof(origin) ~= "boolean"
		then
			log:Warn("RankUp: unexpected payload")
			return
		end
		if typeof(choices[1]) ~= "string" or typeof(choices[2]) ~= "string" or typeof(choices[3]) ~= "string" then
			log:Warn("RankUp: expected 3 epithet choices")
			return
		end

		log:Info(string.format("RankUp: %s (rank %d, alignment %s, origin=%s)", title, rankIndex, alignment, tostring(origin)))
		playFlutter(alignment)
		showCard(title, choices :: { string }, origin)
	end)

	Remotes.Client.On("AlignmentChanged", function(alignment: any)
		if typeof(alignment) ~= "string" then
			log:Warn("AlignmentChanged: unexpected payload")
			return
		end
		log:Info("AlignmentChanged: " .. alignment)
		playFlutter(alignment)
	end)

	player:GetAttributeChangedSignal("EpithetPending"):Connect(function()
		if player:GetAttribute("EpithetPending") == false then
			fadeOutCard()
		end
	end)

	player.CharacterRemoving:Connect(function()
		cancelFlutter()
	end)

	log:Info("ready")
end

return RankController

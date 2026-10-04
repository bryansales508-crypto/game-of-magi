--!strict
-- Dev tools: an F8 status overlay and a backquote command panel. Both send
-- text through DevCommand and render what the server sends back
-- (DevReply/DevState); the server alone decides who is a dev (DevService), so
-- a non-dev who opens either one just gets no replies.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared:WaitForChild("Log"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local ChatLines = require(script.Parent.ChatLines)

local log = Log.new("DevController")

local player = Players.LocalPlayer

-- Same order the server streams in DevState.
local STATE_KEYS = {
	"name",
	"userId",
	"joinState",
	"age",
	"magoi",
	"rank",
	"goldRukh",
	"blackRukh",
	"epithet",
	"bounty",
	"copper",
	"silver",
	"gold",
	"walkSpeed",
	"health",
	"maxHealth",
	"livesLeft",
	"position",
	"saveScope",
	"freshSave",
	"timeScale",
	"sessionSeconds",
}

local QUICK_COMMANDS = {
	".state",
	".fresh",
	".age+ 10",
	".magoi+ 100",
	".coins+ 100",
	".tp qarzin",
	".timescale 10",
	".timescale 1",
}

local MAX_REPLY_LINES = 20
local MAX_HISTORY = 50

local BG_COLOR = Color3.fromRGB(18, 18, 22)
local TEXT_COLOR = Color3.fromRGB(225, 225, 225)
local DIM_TEXT_COLOR = Color3.fromRGB(160, 160, 165)
local BUTTON_COLOR = Color3.fromRGB(42, 42, 50)

local DevController = {}

local function formatSnapshotValue(value: any): string
	if value == nil then
		return "n/a"
	end
	if typeof(value) == "table" then
		local x, y, z = value.x, value.y, value.z
		if typeof(x) == "number" and typeof(y) == "number" and typeof(z) == "number" then
			return string.format("%.1f, %.1f, %.1f", x, y, z)
		end
		return "n/a"
	end
	return tostring(value)
end

local function buildOverlayText(snapshot: { [string]: any }): string
	local lines = table.create(#STATE_KEYS + 1)
	lines[1] = "DEV STATUS (F8)"
	for i, key in STATE_KEYS do
		lines[i + 1] = string.format("%s: %s", key, formatSnapshotValue(snapshot[key]))
	end
	return table.concat(lines, "\n")
end

-- Sets Parent last, regardless of table iteration order, so an instance
-- never briefly appears on screen at its default size/position.
local function newInstance<T>(className: string, props: { [string]: any }): T
	local instance = Instance.new(className)
	local parent = props.Parent
	for propertyName, value in props do
		if propertyName ~= "Parent" then
			(instance :: any)[propertyName] = value
		end
	end
	if parent then
		(instance :: any).Parent = parent
	end
	return instance :: any
end

-- Local-only commands: they act on this client's own world, so they are answered
-- here and never sent to the server.
local function handleLocalCommand(text: string, reply: (string) -> ()): boolean
	local matchedCommand, matchedRest = string.match(text, "^%.(%a+)%s*(.-)%s*$")
	if matchedCommand == nil then
		return false
	end
	local command: string = string.lower(matchedCommand)
	local rest: string = matchedRest or ""
	local controllers = script.Parent

	if command == "region" then
		local RegionController = require(controllers.RegionController) :: any
		local keys = RegionController.Current()
		reply(if #keys == 0 then "regions: none" else "regions: " .. table.concat(keys, ", "))
		return true
	elseif command == "music" then
		local MusicController = require(controllers.MusicController) :: any
		local arg = string.lower(rest)
		if arg == "" then
			reply("now playing: " .. tostring(MusicController.Current()))
		elseif arg == "stop" then
			MusicController.Stop()
			reply("music stopped (.music play to resume)")
		elseif arg == "play" then
			MusicController.Play()
			reply("music resumed")
		elseif string.match(arg, "^volume%s+") ~= nil then
			local volume = tonumber(string.match(arg, "^volume%s+(%S+)"))
			if volume == nil then
				reply("usage: .music volume 0-1")
			else
				MusicController.SetVolume(volume)
				reply(string.format("music volume %.2f", MusicController.Volume()))
			end
		elseif arg == "next" then
			MusicController.Next()
			reply("next track")
		elseif MusicController.PlayForced(rest) then
			reply("playing " .. rest)
		else
			reply("no such track: " .. rest)
		end
		return true
	elseif command == "lights" then
		local LightingController = require(controllers.LightingController) :: any
		local arg = string.lower(rest)
		if arg == "on" then
			LightingController.ForceLights(true)
		elseif arg == "off" then
			LightingController.ForceLights(false)
		elseif arg == "auto" then
			LightingController.ForceLights(nil)
		else
			reply("usage: .lights on|off|auto (now " .. (if LightingController.LightsOn() then "on" else "off") .. ")")
			return true
		end
		reply("city lights: " .. arg)
		return true
	end
	return false
end

function DevController:Init() end

function DevController:Start()
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

	local gui = newInstance("ScreenGui", {
		Name = "DevGui",
		ResetOnSpawn = false,
		DisplayOrder = 1000,
		Parent = playerGui,
	}) :: ScreenGui


	local overlayFrame = newInstance("Frame", {
		Name = "Overlay",
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.fromOffset(8, 8),
		Size = UDim2.fromOffset(260, 360),
		BackgroundColor3 = BG_COLOR,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Visible = false,
		Parent = gui,
	}) :: Frame

	newInstance("UIPadding", {
		PaddingLeft = UDim.new(0, 8),
		PaddingRight = UDim.new(0, 8),
		PaddingTop = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 6),
		Parent = overlayFrame,
	})

	local overlayText = newInstance("TextLabel", {
		Name = "StateText",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = Enum.Font.Code,
		TextSize = 14,
		TextColor3 = TEXT_COLOR,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = false,
		Text = "DEV STATUS (F8)\nwaiting for DevState...",
		Parent = overlayFrame,
	}) :: TextLabel

	local overlayVisible = false

	local function setOverlayVisible(visible: boolean)
		overlayVisible = visible
		overlayFrame.Visible = visible
		Remotes.Client.Fire("DevCommand", if visible then ".watch on" else ".watch off")
	end

	Remotes.Client.On("DevState", function(snapshot: any)
		if typeof(snapshot) ~= "table" then
			return
		end
		overlayText.Text = buildOverlayText(snapshot)
	end)

	ContextActionService:BindAction("DevOverlayToggle", function(_actionName, inputState, _inputObject)
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		setOverlayVisible(not overlayVisible)
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.F8)


	local panelFrame = newInstance("Frame", {
		Name = "Panel",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 8),
		Size = UDim2.fromOffset(320, 300),
		BackgroundColor3 = BG_COLOR,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Visible = false,
		Parent = gui,
	}) :: Frame

	newInstance("UIPadding", {
		PaddingLeft = UDim.new(0, 6),
		PaddingRight = UDim.new(0, 6),
		PaddingTop = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 6),
		Parent = panelFrame,
	})

	local replyScroll = newInstance("ScrollingFrame", {
		Name = "ReplyLog",
		Position = UDim2.new(0, 0, 0, 0),
		Size = UDim2.new(1, 0, 0, 156),
		BackgroundColor3 = Color3.fromRGB(10, 10, 12),
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = panelFrame,
	}) :: ScrollingFrame

	newInstance("UIPadding", {
		PaddingLeft = UDim.new(0, 4),
		PaddingRight = UDim.new(0, 4),
		PaddingTop = UDim.new(0, 4),
		Parent = replyScroll,
	})

	local replyText = newInstance("TextLabel", {
		Name = "ReplyText",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = Enum.Font.Code,
		TextSize = 13,
		TextColor3 = DIM_TEXT_COLOR,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		Text = "",
		Parent = replyScroll,
	}) :: TextLabel

	replyText:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		replyScroll.CanvasPosition = Vector2.new(0, replyText.AbsoluteSize.Y)
	end)

	local replyLines: { string } = {}
	local function appendReply(text: string)
		table.insert(replyLines, text)
		while #replyLines > MAX_REPLY_LINES do
			table.remove(replyLines, 1)
		end
		replyText.Text = table.concat(replyLines, "\n")

		-- The panel is hidden unless opened, so every reply (server or local command)
		-- also shows as a local-only chat system message.
		ChatLines.Post(text)
	end

	Remotes.Client.On("DevReply", function(text: any)
		appendReply(tostring(text))
	end)

	-- Chat commands go to the server's DevService, which forwards the ones it
	-- doesn't know (.region, .music, .lights) back here (`text` has no leading dot).
	Remotes.Client.On("DevLocalCommand", function(text: any)
		if typeof(text) ~= "string" or #text == 0 then
			return
		end
		local line = "." .. text
		if not handleLocalCommand(line, appendReply) then
			appendReply("unknown command: " .. line)
		end
	end)

	local commandBox = newInstance("TextBox", {
		Name = "CommandBox",
		Position = UDim2.fromOffset(0, 162),
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundColor3 = Color3.fromRGB(10, 10, 12),
		BorderSizePixel = 0,
		Font = Enum.Font.Code,
		TextSize = 14,
		TextColor3 = TEXT_COLOR,
		PlaceholderText = ".command args",
		PlaceholderColor3 = DIM_TEXT_COLOR,
		Text = "",
		ClearTextOnFocus = false,
		Parent = panelFrame,
	}) :: TextBox

	local history: { string } = {}
	local historyIndex = 1 -- #history + 1 means "blank/live line"

	local function sendCommand(text: string)
		if #text == 0 then
			return
		end
		if not handleLocalCommand(text, appendReply) then
			Remotes.Client.Fire("DevCommand", text)
		end
		table.insert(history, text)
		while #history > MAX_HISTORY do
			table.remove(history, 1)
		end
		historyIndex = #history + 1
	end

	commandBox.FocusLost:Connect(function(enterPressed)
		if not enterPressed then
			return
		end
		local text = commandBox.Text
		commandBox.Text = ""
		sendCommand(text)
		commandBox:CaptureFocus()
	end)

	local function recallHistory(step: number)
		if #history == 0 then
			return
		end
		historyIndex = math.clamp(historyIndex + step, 1, #history + 1)
		commandBox.Text = if historyIndex > #history then "" else history[historyIndex]
		commandBox.CursorPosition = #commandBox.Text + 1
	end

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or not commandBox:IsFocused() then
			return
		end
		if input.KeyCode == Enum.KeyCode.Up then
			recallHistory(-1)
		elseif input.KeyCode == Enum.KeyCode.Down then
			recallHistory(1)
		end
	end)

	local quickRow = newInstance("Frame", {
		Name = "QuickCommands",
		Position = UDim2.fromOffset(0, 196),
		Size = UDim2.new(1, 0, 0, 92),
		BackgroundTransparency = 1,
		Parent = panelFrame,
	}) :: Frame

	newInstance("UIGridLayout", {
		CellSize = UDim2.fromOffset(148, 22),
		CellPadding = UDim2.fromOffset(4, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = quickRow,
	})

	for _, command in QUICK_COMMANDS do
		local button = newInstance("TextButton", {
			Name = "Quick_" .. command,
			BackgroundColor3 = BUTTON_COLOR,
			BorderSizePixel = 0,
			AutoButtonColor = true,
			Font = Enum.Font.Code,
			TextSize = 13,
			TextColor3 = TEXT_COLOR,
			Text = command,
			Parent = quickRow,
		}) :: TextButton
		button.Activated:Connect(function()
			sendCommand(command)
		end)
	end

	local panelVisible = false

	local function setPanelVisible(visible: boolean)
		panelVisible = visible
		panelFrame.Visible = visible
		if visible then
			commandBox:CaptureFocus()
		else
			commandBox:ReleaseFocus()
		end
	end

	ContextActionService:BindAction("DevPanelToggle", function(_actionName, inputState, _inputObject)
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		setPanelVisible(not panelVisible)
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Backquote)

	log:Info("dev overlay (F8) and dev panel (backquote `) ready")
end

return DevController

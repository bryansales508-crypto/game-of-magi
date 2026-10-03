--!strict
-- The delivery mission board, quest tracker and courier beacon.
--
-- Server contract (Shared/Remotes.luau):
--   MissionBoard (server -> client): one table
--     { city, destinations = { {key, name, color = {r,g,b} (0-1), lore, image,
--       pay, modifiers = { {name, chance, text} } } }, intercepted?, offerMultiplier? }
--     or nil to close. `pay` already includes offerMultiplier; when
--     intercepted > 0 one line on the board says offers are at
--     floor(offerMultiplier*100)%.
--   MissionOpenBoard(cityKey), MissionStart(destinationKey), MissionExit()
--     (client -> server intentions only).
--   MissionUpdate (server -> client):
--     { state = "Started"|"Finished"|"Failed"|"Intercepted"|"Cleared"
--              |"ModifierFailed", destination, destinationPosition = {x,y,z},
--       modifiers, returnPosition?, timerEnds?, pay, key?, failed? }
--     ModifierFailed: `key` names the modifier that failed (matched against
--     its own `key`, falling back to its `name`); only that modifier's BONUS
--     button and pop-out grey out, the run itself continues. TimeCrunch's 0:00
--     is a countdown only; the server decides it failed and sends this state.
--     `failed`: the CourierLoop return leg's "Started" carries the modifier
--     keys that already failed on the outbound leg, rebuilt greyed out.
--   Player attributes: OnMission, MissionDestination, MissionStreak, Bounty
--     (consumed elsewhere). Character attribute: CourierBeacon (true while the
--     beacon is on).
--
-- The client never computes pay (board.pay and update.pay are final) and never
-- decides which city is reachable; it only sends intentions.
--
-- The StartButton gets exactly one connection per board (reading a mutable
-- `selectedDestinationKey`, so Start fires for the LAST click only), and every
-- modifier button clone (and its popout) is rebuilt from scratch on each city
-- click, never accumulated.
--
-- ReplicatedFirst.GUI.MissionGUI's children are synced .rbxm assets (art); this
-- file only clones them and sets Text/Image/Parent on the clones. rbxm-sourced
-- children are accessed through `:: any` casts since the Rojo sourcemap can't
-- type an .rbxm's internal structure.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared:WaitForChild("Log"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local log = Log.new("MissionController")
local player = Players.LocalPlayer

local MissionController = {}

-- Connections that live for the whole controller (Start() runs once, so they are never torn down).
-- selene: allow(unused_variable) -- write-only on purpose; nothing ever
-- needs to read this back since the controller itself never tears down.
local controllerConnections: { RBXScriptConnection } = {}


local WAIT_SECONDS = 15
local PROMPT_RANGE = 12
local BOARD_CLOSE_RANGE = 20
local BOARD_WATCH_INTERVAL = 0.5
local RUN_UPDATE_INTERVAL = 0.2 -- distance/timer tick, only while a run is active
local ANNOUNCE_SECONDS = 4

local BEACON_COLOR = Color3.fromRGB(239, 187, 65)

local TIME_CRUNCH_NAME = "Time Crunch"
local COURIER_LOOP_NAME = "Courier Loop"
local COURIER_LOOP_RETURN_TEXT = "Return with the package to complete the Quest."
local MODIFIER_FAILED_TEXT = "Failed."
-- Text colour of a failed modifier's BONUS button (its Constraint label reads "Failed.").
local MODIFIER_FAILED_COLOR = Color3.fromRGB(43, 43, 43)

-- Cosmetic only: ProximityPrompt.ObjectText before the board replies with real destination data.
local CITY_DISPLAY_NAMES: { [string]: string } = {
	Saleh = "SALEH",
	AinJamala = "AIN JAMALA",
	Qarzin = "QARZIN",
	Sahraqin = "SAHRAQIN",
	IllegalPort = "ILLEGAL PORT",
	Rathole = "RATHOLE",
	JaddatysHut = "JADDATY'S HUT",
}


local GUI = ReplicatedFirst:WaitForChild("GUI")
local MISSION_GUI = GUI:WaitForChild("MissionGUI")
local DELIVERY_FRAME_TEMPLATE = MISSION_GUI:WaitForChild("DeliveryFrame") :: ScreenGui
local QUEST_TRACKER_TEMPLATE = MISSION_GUI:WaitForChild("QuestTracker") :: BillboardGui
local QUEST_LINE_BOX_TEMPLATE = MISSION_GUI:WaitForChild("QuestLineBox") :: Frame
local MOD_CONTAINER_TEMPLATE = MISSION_GUI:WaitForChild("MODCONTAINER") :: Frame
local MOD_POP_OUT_TEMPLATE = MISSION_GUI:WaitForChild("ModPopOut") :: Frame
local MOD_CHANCE_TEMPLATE = MISSION_GUI:WaitForChild("ModChance") :: TextLabel

local MSG_TYPES = GUI:WaitForChild("MsgTypes")
local ALERT_TEMPLATES = {
	Good = MSG_TYPES:WaitForChild("MsgHold[BLACKALERT]"),
	Bad = MSG_TYPES:WaitForChild("MsgHold[REDALERT]"),
}

-- Modifier chip / pop-out sizes (pixels, like the rest of the board).
local CHIP_WIDTH = 44
local CHIP_HEIGHT = 26
local POPOUT_WIDTH = 300
local POPOUT_MIN_HEIGHT = 72 -- grows with a 2-3 line description (AutomaticSize Y)
local POPOUT_PADDING = 8
local POPOUT_GAP = 6

local TRACKER_WIDTH = 120
local TRACKER_HEIGHT = 90

local MERRIWEATHER_BOLD = Font.new(Font.fromEnum(Enum.Font.Merriweather).Family, Enum.FontWeight.Bold, Enum.FontStyle.Normal)


type Modifier = { key: string?, name: string, chance: number, text: string }
type Destination = {
	key: string,
	name: string,
	color: { [any]: number }, -- { r, g, b } from the server (also accepts { [1], [2], [3] })
	lore: string,
	image: string,
	pay: number,
	modifiers: { Modifier },
}

-- One entry per modifier in an active run, keyed by its `key` (falling back to `name`),
-- so "ModifierFailed" can find the right BONUS button/pop-out.
type ModifierUiEntry = {
	constraint: TextLabel,
	bonusButton: TextButton?,
	failed: boolean,
}

type RunState = {
	trackerGui: BillboardGui,
	trackerAnchor: BasePart,
	trackerAnchorOwned: boolean,
	questLineBox: Frame,
	trackerDistanceLabel: TextLabel,
	boxDistanceLabel: TextLabel,
	boxOnScreen: boolean,
	modifierInstances: { Instance },
	modifierUiByKey: { [string]: ModifierUiEntry },
	timeCrunchKey: string?,
	timerEnds: number?,
	loopThread: thread?,
}


-- The server sends colours as `{ r, g, b }` (0-1); also accepts `[1..3]`.
local function toColor3(rgb: { [any]: number }?): Color3
	if not rgb then
		return Color3.new(1, 1, 1)
	end
	return Color3.new(rgb.r or rgb[1] or 1, rgb.g or rgb[2] or 1, rgb.b or rgb[3] or 1)
end

-- Positions arrive as `{ x, y, z }` (MissionService vecToTable); also accepts `[1..3]`.
local function toVector3(position: { [any]: number }?): Vector3?
	if not position then
		return nil
	end
	local x = position.x or position[1]
	local y = position.y or position[2]
	local z = position.z or position[3]
	if typeof(x) ~= "number" or typeof(y) ~= "number" or typeof(z) ~= "number" then
		return nil
	end
	return Vector3.new(x, y, z)
end

local function formatDistance(studs: number): string
	return string.format("%dm", math.floor(math.max(0, studs)))
end

local function formatCountdown(remainingSeconds: number): string
	local clamped = math.max(0, math.floor(remainingSeconds))
	return string.format("Complete in %d:%02d", math.floor(clamped / 60), clamped % 60)
end

local function formatChance(chance: number): string
	local percent = if chance <= 1 then chance * 100 else chance
	return string.format("%d%%", math.floor(percent + 0.5))
end

local function getMissionFolder(): Instance?
	local map = Workspace:FindFirstChild("MAP")
	if not map then
		return nil
	end
	return map:FindFirstChild("MISSION")
end

local function findQuestLineGui(): ScreenGui?
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return nil
	end
	local gui = playerGui:FindFirstChild("QuestLine") or playerGui:WaitForChild("QuestLine", WAIT_SECONDS)
	return if gui and gui:IsA("ScreenGui") then gui else nil
end

local function findAnnouncerFrame(): Frame?
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return nil
	end
	local announcer = playerGui:FindFirstChild("Announcer") or playerGui:WaitForChild("Announcer", WAIT_SECONDS)
	local frame = announcer and announcer:FindFirstChild("AnnouncerFrame")
	return if frame and frame:IsA("Frame") then frame else nil
end

local function findMessageLabel(root: Instance): TextLabel?
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("TextLabel") then
			return descendant
		end
	end
	return nil
end

-- Bounces the text in from above; the caller destroys the clone after ANNOUNCE_SECONDS.
local function announce(text: string, tone: "Good" | "Bad")
	local frame = findAnnouncerFrame()
	if not frame then
		log:Warn("PlayerGui.Announcer.AnnouncerFrame missing; announcement dropped: " .. text)
		return
	end

	local template = ALERT_TEMPLATES[tone]
	local clone = template:Clone()
	local label = findMessageLabel(clone)
	if label then
		label.Text = text
		local restPosition = label.Position
		label.Position = restPosition + UDim2.fromOffset(0, -40)
		TweenService:Create(label, TweenInfo.new(0.6, Enum.EasingStyle.Bounce), { Position = restPosition }):Play()
	end
	clone.Parent = frame

	task.delay(ANNOUNCE_SECONDS, function()
		clone:Destroy()
	end)
end


local function setupDeliveryPrompt(part: BasePart, cityKey: string)
	if part:FindFirstChildOfClass("ProximityPrompt") then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Deliver"
	prompt.ObjectText = CITY_DISPLAY_NAMES[cityKey] or cityKey
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = PROMPT_RANGE
	prompt.Parent = part

	prompt.Triggered:Connect(function(triggeringPlayer: Player)
		if triggeringPlayer ~= player then
			return
		end
		Remotes.Client.Fire("MissionOpenBoard", cityKey)
	end)
end

local function watchMissionFolder(folder: Instance)
	local function tryPart(instance: Instance)
		if not instance:IsA("BasePart") then
			return
		end
		local cityKey = instance.Name:match("^(.-)Delivery$")
		if cityKey and cityKey ~= "" then
			setupDeliveryPrompt(instance, cityKey)
		end
	end

	table.insert(controllerConnections, folder.ChildAdded:Connect(tryPart))
	for _, child in folder:GetChildren() do
		tryPart(child)
	end
end


local boardGui: ScreenGui? = nil
local boardConnections: { RBXScriptConnection } = {}
local boardModifierInstances: { Instance } = {}
local boardWatchThread: thread? = nil
local selectedDestinationKey: string? = nil

-- Only one board modifier pop-out is open at a time (clicking another chip replaces it,
-- clicking the same chip closes it).
type OpenBoardPopOut = { popOut: Frame, chip: TextButton, idleTransparency: number, connections: { RBXScriptConnection } }
local openBoardPopOut: OpenBoardPopOut? = nil

local function closeBoardPopOut()
	local open = openBoardPopOut
	openBoardPopOut = nil
	if open then
		for _, connection in open.connections do
			connection:Disconnect()
		end
		open.popOut.Parent = nil
		open.chip.BackgroundTransparency = open.idleTransparency
	end
end

local function closeBoard()
	if boardWatchThread then
		task.cancel(boardWatchThread)
		boardWatchThread = nil
	end
	for _, connection in boardConnections do
		connection:Disconnect()
	end
	table.clear(boardConnections)
	closeBoardPopOut()
	for _, inst in boardModifierInstances do
		inst:Destroy()
	end
	table.clear(boardModifierInstances)
	if boardGui then
		boardGui:Destroy()
		boardGui = nil
	end
	selectedDestinationKey = nil
end

local function clearCityModifiers()
	closeBoardPopOut()
	for _, inst in boardModifierInstances do
		inst:Destroy()
	end
	table.clear(boardModifierInstances)
end

-- Clones MODCONTAINER (the "!!!" BONUS button) + ModPopOut (the name/desc
-- card) + ModChance (the percentage badge, parented into the popout so it
-- shows/hides with it) per modifier. Each BONUS button gets one fresh
-- Activated connection.
--
-- `uiByKey`, when given (an active run only), records each modifier's
-- Constraint label and BONUS button under its own key so a later
-- "ModifierFailed" can find them.
--
-- Placement: the template pop-out is a screen-wide {1,0} frame. On the BOARD
-- (`boardFrame` given) chips sit in their own row and a chip's pop-out is one
-- fixed-size card below the board, left-aligned with the chip, one open at a
-- time. IN A RUN (`boardFrame` nil) the pop-outs are listed in
-- QuestLine.ModFrame, a column (UIListLayout) of cards, one per modifier.
local function buildModifierRow(
	modifiers: { Modifier },
	row: Instance,
	popOutHost: Instance,
	sink: { Instance },
	uiByKey: { [string]: ModifierUiEntry }?,
	boardFrame: GuiObject?
)
	for _, modifier in modifiers do
		local container = MOD_CONTAINER_TEMPLATE:Clone() :: Frame
		container.Size = UDim2.fromOffset(CHIP_WIDTH, CHIP_HEIGHT)
		container.Parent = row
		table.insert(sink, container)

		local popOut = MOD_POP_OUT_TEMPLATE:Clone() :: Frame
		-- The card grows with the description (AutomaticSize Y over a wrapped
		-- Constraint label) so a 2-3 line description never spills out.
		popOut.Size = if boardFrame then UDim2.fromOffset(POPOUT_WIDTH, 0) else UDim2.fromScale(1, 0)
		popOut.AutomaticSize = Enum.AutomaticSize.Y
		local constraint = (popOut :: any).Constraint :: TextLabel
		local modType = (popOut :: any).ModType :: TextLabel
		modType.Text = modifier.name
		modType.AnchorPoint = Vector2.zero
		modType.Position = UDim2.fromOffset(POPOUT_PADDING, POPOUT_PADDING)
		modType.Size = UDim2.new(1, -2 * POPOUT_PADDING, 0, 26)
		modType.TextXAlignment = Enum.TextXAlignment.Left
		constraint.Text = modifier.text
		constraint.TextWrapped = true
		constraint.TextXAlignment = Enum.TextXAlignment.Left
		constraint.TextYAlignment = Enum.TextYAlignment.Top
		constraint.AnchorPoint = Vector2.zero
		constraint.Position = UDim2.fromOffset(POPOUT_PADDING, POPOUT_PADDING + 28)
		constraint.Size = UDim2.new(1, -2 * POPOUT_PADDING, 0, 0)
		constraint.AutomaticSize = Enum.AutomaticSize.Y
		local cardPadding = Instance.new("UIPadding")
		cardPadding.PaddingBottom = UDim.new(0, POPOUT_PADDING)
		cardPadding.Parent = popOut
		table.insert(sink, popOut)

		-- Only the badge's Percentage child is kept, in the card's top-right corner on the
		-- name row; its own "!!!" label would draw over the description.
		local chanceBadge = MOD_CHANCE_TEMPLATE:Clone()
		local percentage = (chanceBadge :: any).Percentage :: TextLabel
		percentage.Text = formatChance(modifier.chance)
		percentage.AnchorPoint = Vector2.new(1, 0)
		percentage.Position = UDim2.new(1, -POPOUT_PADDING, 0, POPOUT_PADDING)
		percentage.Size = UDim2.fromOffset(60, 26)
		percentage.TextXAlignment = Enum.TextXAlignment.Right
		percentage.Parent = popOut
		chanceBadge:Destroy()
		modType.Size = UDim2.new(1, -2 * POPOUT_PADDING - 64, 0, 26)

		local bonusButton = (container :: any).BONUS
		local typedBonusButton: TextButton? = if bonusButton and bonusButton:IsA("TextButton") then bonusButton else nil
		if typedBonusButton then
			local idleTransparency = typedBonusButton.BackgroundTransparency
			local open = false
			typedBonusButton.Activated:Connect(function()
				if boardFrame then
					local wasThis = openBoardPopOut ~= nil and openBoardPopOut.popOut == popOut
					closeBoardPopOut()
					if wasThis then
						return
					end
					typedBonusButton.BackgroundTransparency = 0.75
					popOut.AnchorPoint = Vector2.zero
					popOut.Parent = popOutHost
					local screen = popOutHost :: any
					-- Below the board, lined up with the chip, clamped inside
					-- the ScreenGui; redone when the card, the screen or the
					-- board changes size/position.
					local function place()
						local screenSize: Vector2 = screen.AbsoluteSize
						local cardHeight = math.max(popOut.AbsoluteSize.Y, POPOUT_MIN_HEIGHT)
						local x = math.clamp(container.AbsolutePosition.X, 0, math.max(0, screenSize.X - POPOUT_WIDTH))
						local y = boardFrame.AbsolutePosition.Y + boardFrame.AbsoluteSize.Y + POPOUT_GAP
						y = math.clamp(y, 0, math.max(0, screenSize.Y - cardHeight))
						popOut.Position = UDim2.fromOffset(x, y)
					end
					place()
					local connections = {
						popOut:GetPropertyChangedSignal("AbsoluteSize"):Connect(place),
						boardFrame:GetPropertyChangedSignal("AbsolutePosition"):Connect(place),
						boardFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(place),
						screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(place),
					}
					openBoardPopOut = {
						popOut = popOut,
						chip = typedBonusButton,
						idleTransparency = idleTransparency,
						connections = connections,
					}
					return
				end
				open = not open
				typedBonusButton.BackgroundTransparency = if open then 0.75 else idleTransparency
				popOut.Parent = if open then popOutHost else nil
			end)
		end

		if uiByKey then
			uiByKey[modifier.key or modifier.name] = { constraint = constraint, bonusButton = typedBonusButton, failed = false }
		end
	end
end

local function selectDestination(destination: Destination, textContainer: Instance, modifierRow: Instance, screenGui: ScreenGui, boardFrame: GuiObject)
	selectedDestinationKey = destination.key
	;(textContainer :: any).Visible = true

	local color = toColor3(destination.color)
	;(textContainer :: any).CityPic.Image = destination.image
	;(textContainer :: any).CityPic.BorderColor3 = color
	;(textContainer :: any).CityDesc.Text = destination.lore
	;(textContainer :: any).PayRow.Money.Text = tostring(math.floor(destination.pay))

	clearCityModifiers()
	buildModifierRow(destination.modifiers or {}, modifierRow, screenGui, boardModifierInstances, nil, boardFrame)
end

-- Board buttons: a 56 px slot holding a per-city coloured Frame (0.9 wide,
-- anchored centre) with a TextButton on it (0.9 x 0.7, Merriweather Bold 18,
-- black border; Rathole's border matches its fill). Colours come from the server.
local function buildCityButton(destination: Destination, parent: Instance, layoutOrder: number, onClick: (Destination) -> ())
	local color = toColor3(destination.color)

	local slot = Instance.new("Frame")
	slot.Name = destination.key
	slot.LayoutOrder = layoutOrder
	slot.Size = UDim2.new(1, 0, 0, 56)
	slot.BackgroundTransparency = 1
	slot.BorderSizePixel = 0
	slot.Parent = parent

	local frame = Instance.new("Frame")
	frame.Name = "Plate"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromScale(0.9, 1)
	frame.BackgroundColor3 = color
	frame.BorderSizePixel = 0
	frame.Parent = slot

	local button = Instance.new("TextButton")
	button.Name = "Button"
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.Position = UDim2.fromScale(0.5, 0.5)
	button.Size = UDim2.fromScale(0.9, 0.7)
	button.BackgroundColor3 = color
	button.BorderColor3 = if destination.key == "Rathole" then color else Color3.new(0, 0, 0)
	button.BorderSizePixel = 2
	button.AutoButtonColor = true
	button.Text = string.upper(destination.name)
	button.TextColor3 = Color3.new(1, 1, 1)
	button.TextSize = 18
	button.FontFace = MERRIWEATHER_BOLD
	button.Parent = frame

	button.Activated:Connect(function()
		onClick(destination)
	end)
end

local INTERCEPTED_NOTICE_FORMAT = "Merchants doubt you. Offers at %d%% until you deliver."

-- board.intercepted/offerMultiplier: the pay numbers shown are already
-- multiplied by the server; this line just explains why. `fontSource` is an
-- existing Balthazar Italic 14 label from the same clone (CityDesc), copied
-- rather than guessed.
local function buildInterceptedNotice(board: any, outsideFrame: Instance, fontSource: TextLabel)
	local intercepted = board.intercepted
	local offerMultiplier = board.offerMultiplier
	if typeof(intercepted) ~= "number" or intercepted <= 0 or typeof(offerMultiplier) ~= "number" then
		return
	end

	local notice = Instance.new("TextLabel")
	notice.Name = "InterceptedNotice"
	notice.AnchorPoint = Vector2.new(0.5, 0.5)
	notice.Size = UDim2.fromScale(0.9, 0.06)
	notice.Position = UDim2.fromScale(0.5, 0.97)
	notice.BackgroundTransparency = 1
	notice.TextColor3 = Color3.new(1, 1, 1)
	notice.TextXAlignment = Enum.TextXAlignment.Center
	notice.TextYAlignment = Enum.TextYAlignment.Center
	notice.TextSize = 14
	notice.FontFace = fontSource.FontFace
	notice.Text = string.format(INTERCEPTED_NOTICE_FORMAT, math.floor(offerMultiplier * 100))
	notice.Parent = outsideFrame
end

local function watchBoardDistance(originPart: BasePart)
	boardWatchThread = task.spawn(function()
		while true do
			task.wait(BOARD_WATCH_INTERVAL)
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") and (root.Position - originPart.Position).Magnitude > BOARD_CLOSE_RANGE then
				-- Clear the handle to our OWN thread before calling closeBoard(), which
				-- task.cancel()s it: cancelling the running thread would abort closeBoard()
				-- mid-cleanup.
				boardWatchThread = nil
				closeBoard()
				return
			end
		end
	end)
end

local function openBoard(board: any)
	closeBoard()

	if typeof(board) ~= "table" or typeof(board.destinations) ~= "table" then
		log:Warn("MissionBoard: unexpected payload")
		return
	end

	local clone = DELIVERY_FRAME_TEMPLATE:Clone()
	local outsideFrame = clone:FindFirstChild("OutsideFrame")
	local frame = outsideFrame and outsideFrame:FindFirstChild("Frame")
	local descriptionFrame = frame and frame:FindFirstChild("DescriptionFrame")
	local textContainer = descriptionFrame and descriptionFrame:FindFirstChild("TextContainer")
	-- The ScrollingFrame sits under OutsideFrame.Frame (next to DescriptionFrame),
	-- not directly under OutsideFrame.
	local scrollingFrame = frame and frame:FindFirstChild("ScrollingFrame")
	local xButtonFrame = outsideFrame and outsideFrame:FindFirstChild("XButtonFrame")

	if not (textContainer and scrollingFrame and xButtonFrame) then
		log:Error("DeliveryFrame template layout unexpected; aborting board open")
		clone:Destroy()
		return
	end

	-- The template's X-button LocalScript fires the retired `Delivery` remote;
	-- kill it and wire MissionExit instead.
	for _, descendant in xButtonFrame:GetDescendants() do
		if descendant:IsA("LocalScript") then
			descendant:Destroy()
		end
	end
	local xButton = (xButtonFrame :: Instance):FindFirstChildWhichIsA("TextButton")
	if xButton then
		table.insert(
			boardConnections,
			xButton.Activated:Connect(function()
				Remotes.Client.Fire("MissionExit")
				-- Don't wait on the server's MissionBoard nil reply: the X should feel instant.
				-- Start stays server-driven.
				closeBoard()
			end)
		)
	end

	-- The synced rbxm has no board-side modifier container, so the preview row is
	-- built in code, in its own row under the pay row.
	local modifierRow = Instance.new("Frame")
	modifierRow.Name = "ModifierRow"
	modifierRow.BackgroundTransparency = 1
	-- Its own row under the pay row (PayRow ends at 0.9225), not inside or over it.
	modifierRow.Size = UDim2.fromScale(0.9, 0.07)
	modifierRow.Position = UDim2.fromScale(0.5, 0.96)
	modifierRow.AnchorPoint = Vector2.new(0.5, 0.5)
	modifierRow.Parent = textContainer

	local modifierLayout = Instance.new("UIListLayout")
	modifierLayout.FillDirection = Enum.FillDirection.Horizontal
	modifierLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	modifierLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	modifierLayout.Padding = UDim.new(0, 4)
	modifierLayout.SortOrder = Enum.SortOrder.LayoutOrder
	modifierLayout.Parent = modifierRow

	-- the template's placeholder Slot1..Slot4 are empty art; the real
	-- buttons are built from the board's own destinations instead.
	for _, child in (scrollingFrame :: Instance):GetChildren() do
		if child:IsA("Frame") and child.Name:match("^Slot%d+$") then
			child:Destroy()
		end
	end
	;(scrollingFrame :: any).AutomaticCanvasSize = Enum.AutomaticSize.Y
	;(scrollingFrame :: any).CanvasSize = UDim2.new(0, 0, 0, 0)

	local destinations: { Destination } = board.destinations
	for index, destination in destinations do
		buildCityButton(destination, scrollingFrame :: Instance, index, function(picked: Destination)
			selectDestination(picked, textContainer :: Instance, modifierRow, clone, outsideFrame :: GuiObject)
		end)
	end

	local payRow = (textContainer :: any).PayRow
	local startButton = payRow and payRow.StartButton
	if startButton and startButton:IsA("TextButton") then
		table.insert(
			boardConnections,
			startButton.Activated:Connect(function()
				if selectedDestinationKey then
					Remotes.Client.Fire("MissionStart", selectedDestinationKey)
				end
			end)
		)
	end

	buildInterceptedNotice(board, outsideFrame :: Instance, (textContainer :: any).CityDesc)

	clone.Parent = player:WaitForChild("PlayerGui")
	boardGui = clone

	local missionFolder = getMissionFolder()
	local originPart = missionFolder and missionFolder:FindFirstChild(tostring(board.city) .. "Delivery")
	if originPart and originPart:IsA("BasePart") then
		watchBoardDistance(originPart)
	end

	log:Info("board opened: " .. tostring(board.city))
end


local activeRun: RunState? = nil

local function anyQuestsRemain(set: Instance): boolean
	for _, child in set:GetChildren() do
		if child:IsA("GuiObject") and child.Name ~= "BUFFER" then
			return true
		end
	end
	return false
end

local function teardownRun()
	local run = activeRun
	activeRun = nil
	if not run then
		return
	end

	if run.loopThread then
		task.cancel(run.loopThread)
	end
	for _, inst in run.modifierInstances do
		inst:Destroy()
	end
	run.boxDistanceLabel:Destroy()
	run.questLineBox:Destroy()
	run.trackerGui:Destroy()
	if run.trackerAnchorOwned then
		run.trackerAnchor:Destroy()
	end

	local questLineGui = findQuestLineGui()
	if questLineGui then
		local set = questLineGui:FindFirstChild("Set")
		if set and not anyQuestsRemain(set) then
			questLineGui.Enabled = false
		end
	end
end

local function createTrackerAnchor(position: { [any]: number }?): Part
	local anchor = Instance.new("Part")
	anchor.Name = "MissionTrackerAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	local resolved = toVector3(position)
	if resolved then
		anchor.Position = resolved
	end
	anchor.Parent = Workspace
	return anchor
end

-- MissionUpdate's destinationPosition/returnPosition is authoritative (it can
-- differ from the `<City>Delivery` part): an anchor Part is created there and
-- destroyed with the run. The named MISSION part is only a fallback for when
-- the server sends no position at all.
local function resolveTrackerTarget(cityKey: string?, position: { [any]: number }?): (BasePart, boolean)
	if toVector3(position) then
		return createTrackerAnchor(position), true
	end

	if cityKey then
		local missionFolder = getMissionFolder()
		local part = missionFolder and missionFolder:FindFirstChild(cityKey .. "Delivery")
		if part and part:IsA("BasePart") then
			return part, false
		end
	end

	return createTrackerAnchor(nil), true
end

local function updateRunDistances(run: RunState)
	if not run.trackerAnchor.Parent then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return
	end

	local text = formatDistance((root.Position - run.trackerAnchor.Position).Magnitude)
	run.trackerDistanceLabel.Text = text
	run.boxDistanceLabel.Text = text

	if run.timeCrunchKey and run.timerEnds then
		local entry = run.modifierUiByKey[run.timeCrunchKey]
		-- Once "ModifierFailed" marks this one, stop overwriting its "Failed." text
		-- with the past-zero countdown; the server owns the fail moment.
		if entry and not entry.failed then
			entry.constraint.Text = formatCountdown(run.timerEnds - Workspace:GetServerTimeNow())
		end
	end

	-- The QuestLineBox's own distance label only shows once the tracker billboard
	-- itself has scrolled off screen.
	local camera = Workspace.CurrentCamera
	if camera then
		local _, onScreen = camera:WorldToViewportPoint(run.trackerAnchor.Position)
		if onScreen ~= run.boxOnScreen then
			run.boxOnScreen = onScreen
			run.boxDistanceLabel.Parent = if onScreen then nil else run.questLineBox
		end
	end
end

-- The grey-out "ModifierFailed" applies live, shared with startRun's handling of
-- the return leg's `failed` list.
local function applyModifierFailure(run: RunState, key: string): boolean
	local entry = run.modifierUiByKey[key]
	if not entry then
		return false
	end
	entry.failed = true
	entry.constraint.Text = MODIFIER_FAILED_TEXT
	if entry.bonusButton then
		entry.bonusButton.TextColor3 = MODIFIER_FAILED_COLOR
	end
	return true
end

local function startRun(update: any)
	teardownRun() -- respawn-safe: a resent "Started" (rejoin, the return leg) always rebuilds clean

	local questLineGui = findQuestLineGui()
	if not questLineGui then
		log:Warn("MissionUpdate Started: PlayerGui.QuestLine missing; tracker UI disabled")
		return
	end
	local set = questLineGui:FindFirstChild("Set")
	if not (set and set:IsA("Frame")) then
		log:Warn("QuestLine.Set missing; tracker UI disabled")
		return
	end
	local modFrame = questLineGui:FindFirstChild("ModFrame")
	if not modFrame then
		log:Warn("QuestLine.ModFrame missing; modifier pop-outs disabled")
	elseif modFrame:IsA("Frame") then
		-- The template column is only 0.1 of the screen wide, too narrow for a name +
		-- description. Widen it, right edge just left of the quest list (Set, centred
		-- 0.917, 0.15 wide), growing leftward.
		modFrame.AnchorPoint = Vector2.new(1, 0)
		modFrame.Size = UDim2.fromScale(0.2, 0.4)
		modFrame.Position = UDim2.fromScale(0.835, 0.5)
		local layout = modFrame:FindFirstChildOfClass("UIListLayout")
		if layout then
			layout.Padding = UDim.new(0, 6)
			layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
		end
	end

	local returning = update.returnPosition ~= nil
	local destinationKey = if returning then nil else (update.destination :: string?)
	local targetPosition = if returning then update.returnPosition else update.destinationPosition
	local anchor, anchorOwned = resolveTrackerTarget(destinationKey, targetPosition)

	local questLineBox = QUEST_LINE_BOX_TEMPLATE:Clone()
	;(questLineBox :: any).Quest.Text = "DELIVERY"
	questLineBox.Parent = set
	questLineGui.Enabled = true

	local trackerGui = QUEST_TRACKER_TEMPLATE:Clone()
	-- The template is sized in STUDS ({1000,0}), so the camera's run zoom
	-- (CombatController tweens Camera.FieldOfView) would stretch it. Fixed pixel
	-- size, no world offsets, AlwaysOnTop: a pixel-sized billboard is not scaled
	-- by FOV. The distance text is computed from the character's root to the
	-- anchor (updateRunDistances), never the camera.
	trackerGui.Size = UDim2.fromOffset(TRACKER_WIDTH, TRACKER_HEIGHT)
	trackerGui.StudsOffset = Vector3.zero
	trackerGui.StudsOffsetWorldSpace = Vector3.zero
	trackerGui.ExtentsOffset = Vector3.zero
	trackerGui.SizeOffset = Vector2.zero
	trackerGui.AlwaysOnTop = true
	trackerGui.MaxDistance = math.huge
	trackerGui.Adornee = anchor
	trackerGui.Parent = anchor
	for _, descendant in trackerGui:GetDescendants() do
		if descendant:IsA("ImageLabel") then
			descendant.ScaleType = Enum.ScaleType.Fit
		end
	end

	local run: RunState = {
		trackerGui = trackerGui,
		trackerAnchor = anchor,
		trackerAnchorOwned = anchorOwned,
		questLineBox = questLineBox,
		trackerDistanceLabel = (trackerGui :: any).Frame.Distance,
		boxDistanceLabel = (questLineBox :: any).Distance,
		boxOnScreen = false,
		modifierInstances = {},
		modifierUiByKey = {},
		timeCrunchKey = nil,
		timerEnds = if typeof(update.timerEnds) == "number" then update.timerEnds else nil,
		loopThread = nil,
	}
	activeRun = run

	if typeof(update.modifiers) == "table" then
		local modRow = (questLineBox :: any).MODROW
		for _, modifier in update.modifiers :: { Modifier } do
			local text = modifier.text
			if modifier.name == COURIER_LOOP_NAME and returning then
				text = COURIER_LOOP_RETURN_TEXT
			end
			local key = modifier.key or modifier.name
			buildModifierRow({ { key = key, name = modifier.name, chance = modifier.chance, text = text } }, modRow, modFrame or questLineGui, run.modifierInstances, run.modifierUiByKey)
			if modifier.name == TIME_CRUNCH_NAME then
				run.timeCrunchKey = key
			end
		end
	end

	-- CourierLoop's return leg: `failed` lists modifier keys that already failed on
	-- the outbound leg, so they come back greyed out.
	if typeof(update.failed) == "table" then
		for _, key in update.failed :: { any } do
			if typeof(key) == "string" then
				if not applyModifierFailure(run, key) then
					log:Warn("MissionUpdate Started: unknown failed modifier key " .. key)
				end
			else
				log:Warn("MissionUpdate Started: non-string entry in `failed`")
			end
		end
	end

	run.loopThread = task.spawn(function()
		while true do
			updateRunDistances(run)
			task.wait(RUN_UPDATE_INTERVAL)
		end
	end)

	log:Info(string.format("mission %s: %s", if returning then "returning" else "started", tostring(update.destination)))
end

-- Failing a modifier never ends the run by itself; this only greys out that
-- modifier's BONUS button/pop-out.
local function handleModifierFailed(update: any)
	local run = activeRun
	if not run then
		return
	end
	local key = update.key
	if typeof(key) ~= "string" then
		log:Warn("MissionUpdate ModifierFailed: missing key")
		return
	end
	if not applyModifierFailure(run, key) then
		log:Warn("MissionUpdate ModifierFailed: unknown key " .. key)
	end
end

local function handleMissionUpdate(update: any)
	if typeof(update) ~= "table" or typeof(update.state) ~= "string" then
		log:Warn("MissionUpdate: unexpected payload")
		return
	end

	if update.state == "Started" then
		startRun(update)
		return
	end

	if update.state == "ModifierFailed" then
		handleModifierFailed(update)
		return
	end

	teardownRun()

	local pay = if typeof(update.pay) == "number" then math.floor(update.pay) else nil
	if update.state == "Finished" then
		announce(if pay then string.format("Delivery complete: +%d Copper", pay) else "Delivery complete.", "Good")
	elseif update.state == "Cleared" then
		announce("Delivery cleared.", "Good")
	elseif update.state == "Failed" then
		announce("Delivery failed.", "Bad")
	elseif update.state == "Intercepted" then
		announce("You were intercepted -- the reward is lost.", "Bad")
	else
		log:Warn("MissionUpdate: unknown state " .. tostring(update.state))
	end
end


-- The highlight fades in and out instead of popping. The server toggles the
-- CourierBeacon attribute (Config.Missions.Beacon); the client eases the
-- Highlight in over BEACON_FADE_SECONDS, holds while the attribute stays on,
-- and eases out when it turns off before destroying it.
local BEACON_FADE_SECONDS = 0.6
local BEACON_FADE_INFO = TweenInfo.new(BEACON_FADE_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local BEACON_FILL_TRANSPARENCY = 0.5 -- the Highlight default fill at full strength

local function setBeacon(character: Model, on: boolean)
	local existing = character:FindFirstChild("CourierBeaconHighlight")
	if on then
		local highlight: Highlight
		if existing and existing:IsA("Highlight") then
			highlight = existing
		else
			highlight = Instance.new("Highlight")
			highlight.Name = "CourierBeaconHighlight"
			highlight.FillColor = BEACON_COLOR
			highlight.OutlineColor = BEACON_COLOR
			highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			highlight.FillTransparency = 1
			highlight.OutlineTransparency = 1
			highlight.Parent = character
		end
		TweenService:Create(highlight, BEACON_FADE_INFO, {
			FillTransparency = BEACON_FILL_TRANSPARENCY,
			OutlineTransparency = 0,
		}):Play()
	elseif existing and existing:IsA("Highlight") then
		local tween = TweenService:Create(existing, BEACON_FADE_INFO, { FillTransparency = 1, OutlineTransparency = 1 })
		tween.Completed:Once(function()
			-- only remove it if the beacon didn't come back on mid-fade
			if character:GetAttribute("CourierBeacon") ~= true then
				existing:Destroy()
			end
		end)
		tween:Play()
	elseif existing then
		existing:Destroy()
	end
end

local function wireBeaconForCharacter(character: Model)
	setBeacon(character, character:GetAttribute("CourierBeacon") == true)
	character:GetAttributeChangedSignal("CourierBeacon"):Connect(function()
		setBeacon(character, character:GetAttribute("CourierBeacon") == true)
	end)
end

local function wireOtherPlayer(otherPlayer: Player)
	table.insert(controllerConnections, otherPlayer.CharacterAdded:Connect(wireBeaconForCharacter))
	if otherPlayer.Character then
		wireBeaconForCharacter(otherPlayer.Character)
	end
end


function MissionController:Init() end

function MissionController:Start()
	local missionFolder = getMissionFolder()
	if not missionFolder then
		local map = Workspace:FindFirstChild("MAP") or Workspace:WaitForChild("MAP", WAIT_SECONDS)
		missionFolder = map and (map:FindFirstChild("MISSION") or map:WaitForChild("MISSION", WAIT_SECONDS))
	end
	if missionFolder then
		watchMissionFolder(missionFolder)
	else
		log:Warn("Workspace.MAP.MISSION missing; delivery prompts disabled")
	end

	Remotes.Client.On("MissionBoard", function(board: any)
		if board == nil then
			closeBoard()
		else
			openBoard(board)
		end
	end)

	Remotes.Client.On("MissionUpdate", handleMissionUpdate)

	-- own character included (Players:GetPlayers() lists the local player
	-- too), so a courier sees their own beacon like everyone else does.
	for _, otherPlayer in Players:GetPlayers() do
		wireOtherPlayer(otherPlayer)
	end
	table.insert(controllerConnections, Players.PlayerAdded:Connect(wireOtherPlayer))

	log:Info("ready")
end

return MissionController

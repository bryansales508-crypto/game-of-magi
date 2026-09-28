--!strict
-- The delivery mission board, quest tracker and courier beacon (M5-PLAN
-- Phase 5C, docs/reference/m5c-studio-dump.md). Visuals and flow are ported
-- from the old RS/Modules/MissionDeliniation.luau (city panel, start
-- button, tracker, modifier pop-outs); its LISTENER pattern is not reused --
-- see the FIX M14 notes below.
--
-- Contract with the server (M5C-01, Shared/Remotes.luau):
--   MissionBoard (server -> client): one table
--     { city, destinations = { {key, name, color = {r,g,b} (0-1), lore,
--       image, pay, modifiers = { {name, chance, text} } } } }
--     or nil to close.
--   MissionOpenBoard(cityKey), MissionStart(destinationKey), MissionExit()
--     (client -> server intentions only).
--   MissionUpdate (server -> client):
--     { state = "Started"|"Finished"|"Failed"|"Intercepted"|"Cleared",
--       destination, destinationPosition = {x,y,z}, modifiers,
--       returnPosition?, timerEnds?, pay }
--   Player attributes: OnMission, MissionDestination, MissionStreak, Bounty
--     (consumed elsewhere; nothing here needs them directly). Character
--     attribute: CourierBeacon (true while the beacon is on).
--
-- The client never computes reward/pay math (board.pay and update.pay are
-- already final, modifiers included -- FIX L14) and never decides which
-- city is reachable -- MissionOpenBoard/MissionStart just send intentions,
-- the server decides everything.
--
-- FIX M14 (both halves of it): the old code added a NEW StartButton
-- listener and a NEW modifier-button listener on every single city click,
-- so old listeners from earlier clicks stayed alive and could fire for a
-- stale city. Here the StartButton gets exactly ONE connection per board
-- (reading a mutable `selectedDestinationKey`, updated per click, so
-- Start always fires for the LAST click only), and every modifier
-- button's clone (and its popout) is destroyed and rebuilt from scratch on
-- every city click -- never accumulated.
--
-- ReplicatedFirst.GUI.MissionGUI's children are synced .rbxm assets (art);
-- this file only ever clones them and sets Text/Image/Parent on the
-- clones, it never edits the templates themselves. Known rbxm-sourced
-- children are accessed through `:: any` casts (same pattern as
-- RankController's `copyFont`) since the Rojo sourcemap can't type an
-- .rbxm's internal structure.

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

-- Connections that live for the whole controller (Start() runs once, so
-- these are never torn down -- tracked anyway for consistency with the
-- board/run connections below rather than left dangling off the stack).
-- selene: allow(unused_variable) -- write-only on purpose; nothing ever
-- needs to read this back since the controller itself never tears down.
local controllerConnections: { RBXScriptConnection } = {}

-- ==================== constants ====================

local WAIT_SECONDS = 15
local PROMPT_RANGE = 12 -- studs; the old feel was a click, this is its proximity equivalent
local BOARD_CLOSE_RANGE = 20 -- studs; matches the old board's walk-away distance
local BOARD_WATCH_INTERVAL = 0.5
local RUN_UPDATE_INTERVAL = 0.2 -- distance/timer tick, only while a run is active
local ANNOUNCE_SECONDS = 4

-- MissionHandler.luau:316, the old courier beacon's Highlight colours.
local BEACON_COLOR = Color3.fromRGB(239, 187, 65)

local TIME_CRUNCH_NAME = "Time Crunch"
local COURIER_LOOP_NAME = "Courier Loop"
local COURIER_LOOP_RETURN_TEXT = "Return with the package to complete the Quest."
-- Old code's Time Crunch fail state (MissionDeliniation.luau's
-- conEnd/AncestryChanged branch): the Constraint text and the BONUS
-- button's own text both go this grey once the timer runs out.
local TIME_CRUNCH_FAILED_COLOR = Color3.fromRGB(43, 43, 43)

-- Cosmetic only (ProximityPrompt.ObjectText before the board replies with
-- real destination data) -- exact text from m5c-studio-dump.md section 1,
-- keeping the old city button lettering.
local CITY_DISPLAY_NAMES: { [string]: string } = {
	Saleh = "SALEH",
	AinJamala = "AIN JAMALA",
	Qarzin = "QARZIN",
	Sahraqin = "SAHRAQIN",
	IllegalPort = "ILLEGAL PORT",
	Rathole = "RATHOLE",
	JaddatysHut = "JADDATY'S HUT",
}

-- ==================== templates ====================

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

local MERRIWEATHER_BOLD = Font.new(Font.fromEnum(Enum.Font.Merriweather).Family, Enum.FontWeight.Bold, Enum.FontStyle.Normal)

-- ==================== types ====================

type Modifier = { name: string, chance: number, text: string }
type Destination = {
	key: string,
	name: string,
	color: { number },
	lore: string,
	image: string,
	pay: number,
	modifiers: { Modifier },
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
	timeCrunchConstraint: TextLabel?,
	timeCrunchBonusButton: TextButton?,
	timerEnds: number?,
	loopThread: thread?,
}

-- ==================== small helpers ====================

local function toColor3(rgb: { number }?): Color3
	if not rgb then
		return Color3.new(1, 1, 1)
	end
	return Color3.new(rgb[1] or 1, rgb[2] or 1, rgb[3] or 1)
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

-- Old RegionHandlerPart1.client.luau's TranMsg: bounce the text in from
-- above, then the caller destroys the clone after ANNOUNCE_SECONDS.
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

-- ==================== delivery prompts ====================

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

-- ==================== the board ====================

local boardGui: ScreenGui? = nil
local boardConnections: { RBXScriptConnection } = {}
local boardModifierInstances: { Instance } = {}
local boardWatchThread: thread? = nil
local selectedDestinationKey: string? = nil

local function closeBoard()
	if boardWatchThread then
		task.cancel(boardWatchThread)
		boardWatchThread = nil
	end
	for _, connection in boardConnections do
		connection:Disconnect()
	end
	table.clear(boardConnections)
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
	for _, inst in boardModifierInstances do
		inst:Destroy()
	end
	table.clear(boardModifierInstances)
end

-- Clones MODCONTAINER (the "!!!" BONUS button) + ModPopOut (the name/desc
-- card) + ModChance (the percentage badge, parented into the popout so it
-- shows/hides together with it) per modifier. One Activated connection per
-- BONUS button, created fresh here every time -- FIX M14.
local function buildModifierRow(modifiers: { Modifier }, row: Instance, popOutHost: Instance, sink: { Instance })
	for _, modifier in modifiers do
		local container = MOD_CONTAINER_TEMPLATE:Clone()
		container.Parent = row
		table.insert(sink, container)

		local popOut = MOD_POP_OUT_TEMPLATE:Clone()
		;(popOut :: any).ModType.Text = modifier.name
		;(popOut :: any).Constraint.Text = modifier.text
		table.insert(sink, popOut)

		local chanceBadge = MOD_CHANCE_TEMPLATE:Clone()
		;(chanceBadge :: any).Percentage.Text = formatChance(modifier.chance)
		chanceBadge.Parent = popOut

		local bonusButton = (container :: any).BONUS
		if bonusButton and bonusButton:IsA("TextButton") then
			local idleTransparency = bonusButton.BackgroundTransparency
			local open = false
			bonusButton.Activated:Connect(function()
				open = not open
				bonusButton.BackgroundTransparency = if open then 0.75 else idleTransparency
				popOut.Parent = if open then popOutHost else nil
			end)
		end
	end
end

local function selectDestination(destination: Destination, textContainer: Instance, modifierRow: Instance, screenGui: ScreenGui)
	selectedDestinationKey = destination.key
	;(textContainer :: any).Visible = true

	local color = toColor3(destination.color)
	;(textContainer :: any).CityPic.Image = destination.image
	;(textContainer :: any).CityPic.BorderColor3 = color
	;(textContainer :: any).CityDesc.Text = destination.lore
	;(textContainer :: any).PayRow.Money.Text = tostring(math.floor(destination.pay))

	clearCityModifiers()
	buildModifierRow(destination.modifiers or {}, modifierRow, screenGui, boardModifierInstances)
end

local function buildCityButton(destination: Destination, parent: Instance, layoutOrder: number, onClick: (Destination) -> ())
	local color = toColor3(destination.color)
	local button = Instance.new("TextButton")
	button.Name = destination.key
	button.LayoutOrder = layoutOrder
	button.Size = UDim2.fromOffset(225, 56)
	button.BackgroundColor3 = color
	button.BorderColor3 = if destination.key == "Rathole" then color else Color3.new(0, 0, 0)
	button.BorderSizePixel = 2
	button.AutoButtonColor = true
	button.Text = string.upper(destination.name)
	button.TextColor3 = Color3.new(1, 1, 1)
	button.TextSize = 18
	button.FontFace = MERRIWEATHER_BOLD
	button.Parent = parent

	button.Activated:Connect(function()
		onClick(destination)
	end)
end

local function watchBoardDistance(originPart: BasePart)
	boardWatchThread = task.spawn(function()
		while true do
			task.wait(BOARD_WATCH_INTERVAL)
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") and (root.Position - originPart.Position).Magnitude > BOARD_CLOSE_RANGE then
				-- Clear the handle to our OWN thread before calling closeBoard(),
				-- which task.cancel()s it -- cancelling the thread you're
				-- currently running on aborts the rest of this function, which
				-- would abort closeBoard() itself mid-cleanup (REVIEW-M5C-02 #1).
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
	local scrollingFrame = outsideFrame and outsideFrame:FindFirstChild("ScrollingFrame")
	local xButtonFrame = outsideFrame and outsideFrame:FindFirstChild("XButtonFrame")

	if not (textContainer and scrollingFrame and xButtonFrame) then
		log:Error("DeliveryFrame template layout unexpected; aborting board open")
		clone:Destroy()
		return
	end

	-- the old X-button LocalScript fired the retired `Delivery` remote
	-- (m5c-studio-dump.md section 2); kill it and wire MissionExit instead.
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
				-- Don't wait on the server's MissionBoard nil reply (REVIEW-M5C-02
				-- #2): the X should feel instant even if the reply is slow or
				-- M5C-01 isn't wired up yet. Start stays server-driven.
				closeBoard()
			end)
		)
	end

	-- The board's own modifier preview row has no slot in the synced rbxm
	-- (m5c-studio-dump.md has no board-side modifier container) -- built in
	-- code, between the lore text and the pay row.
	local modifierRow = Instance.new("Frame")
	modifierRow.Name = "ModifierRow"
	modifierRow.BackgroundTransparency = 1
	modifierRow.Size = UDim2.fromScale(0.9, 0.07)
	modifierRow.Position = UDim2.fromScale(0.5, 0.795)
	modifierRow.AnchorPoint = Vector2.new(0.5, 0.5)
	modifierRow.Parent = textContainer

	local modifierLayout = Instance.new("UIListLayout")
	modifierLayout.FillDirection = Enum.FillDirection.Horizontal
	modifierLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	modifierLayout.VerticalAlignment = Enum.VerticalAlignment.Center
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
			selectDestination(picked, textContainer :: Instance, modifierRow, clone)
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

	clone.Parent = player:WaitForChild("PlayerGui")
	boardGui = clone

	local missionFolder = getMissionFolder()
	local originPart = missionFolder and missionFolder:FindFirstChild(tostring(board.city) .. "Delivery")
	if originPart and originPart:IsA("BasePart") then
		watchBoardDistance(originPart)
	end

	log:Info("board opened: " .. tostring(board.city))
end

-- ==================== the active run ====================

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

local function createTrackerAnchor(position: { number }?): Part
	local anchor = Instance.new("Part")
	anchor.Name = "MissionTrackerAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	if position then
		anchor.Position = Vector3.new(position[1] or 0, position[2] or 0, position[3] or 0)
	end
	anchor.Parent = Workspace
	return anchor
end

-- MissionUpdate's own destinationPosition/returnPosition is authoritative
-- (REVIEW-M5C-02 #3: with placeholder routes it can differ from the
-- `<City>Delivery` part) -- an anchor Part is created there and destroyed
-- with the run. The named MISSION part is only a fallback for when the
-- server sends no position at all.
local function resolveTrackerTarget(cityKey: string?, position: { number }?): (BasePart, boolean)
	if position then
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

	if run.timeCrunchConstraint and run.timerEnds then
		local remaining = run.timerEnds - Workspace:GetServerTimeNow()
		if remaining <= 0 then
			-- Old code's fail state (MissionDeliniation.luau's conEnd
			-- branch): grey out the "!!!" button and say so, rather than
			-- sitting on "Complete in 0:00" until the server's own Failed
			-- update tears the tracker down.
			run.timeCrunchConstraint.Text = "Failed."
			if run.timeCrunchBonusButton then
				run.timeCrunchBonusButton.TextColor3 = TIME_CRUNCH_FAILED_COLOR
			end
		else
			run.timeCrunchConstraint.Text = formatCountdown(remaining)
		end
	end

	-- old feel: the QuestLineBox's own distance label only shows once the
	-- tracker billboard itself has scrolled off screen.
	local camera = Workspace.CurrentCamera
	if camera then
		local _, onScreen = camera:WorldToViewportPoint(run.trackerAnchor.Position)
		if onScreen ~= run.boxOnScreen then
			run.boxOnScreen = onScreen
			run.boxDistanceLabel.Parent = if onScreen then nil else run.questLineBox
		end
	end
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
	trackerGui.Adornee = anchor
	trackerGui.Parent = anchor

	local run: RunState = {
		trackerGui = trackerGui,
		trackerAnchor = anchor,
		trackerAnchorOwned = anchorOwned,
		questLineBox = questLineBox,
		trackerDistanceLabel = (trackerGui :: any).Frame.Distance,
		boxDistanceLabel = (questLineBox :: any).Distance,
		boxOnScreen = false,
		modifierInstances = {},
		timeCrunchConstraint = nil,
		timeCrunchBonusButton = nil,
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
			buildModifierRow({ { name = modifier.name, chance = modifier.chance, text = text } }, modRow, modFrame or questLineGui, run.modifierInstances)
			if modifier.name == TIME_CRUNCH_NAME then
				-- buildModifierRow just inserted (container, popOut), in that order.
				local container = run.modifierInstances[#run.modifierInstances - 1]
				local popOut = run.modifierInstances[#run.modifierInstances]
				run.timeCrunchConstraint = (popOut :: any).Constraint
				run.timeCrunchBonusButton = (container :: any).BONUS
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

local function handleMissionUpdate(update: any)
	if typeof(update) ~= "table" or typeof(update.state) ~= "string" then
		log:Warn("MissionUpdate: unexpected payload")
		return
	end

	if update.state == "Started" then
		startRun(update)
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

-- ==================== courier beacon ====================

local function setBeacon(character: Model, on: boolean)
	local existing = character:FindFirstChild("CourierBeaconHighlight")
	if on then
		if existing then
			return
		end
		local highlight = Instance.new("Highlight")
		highlight.Name = "CourierBeaconHighlight"
		highlight.FillColor = BEACON_COLOR
		highlight.OutlineColor = BEACON_COLOR
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.Parent = character
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

-- ==================== wiring ====================

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

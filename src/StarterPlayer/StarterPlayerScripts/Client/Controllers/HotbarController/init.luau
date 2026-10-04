--!nonstrict
-- nonstrict: the slot frames are .rbxm templates whose children and legacy Draggable/DragBegin members have no static types.
-- The hotbar (10 slots, keys 1-9 and 0) and the inventory panel (backquote opens and closes it, drag
-- slots between the two, search box). Frames are cloned from ReplicatedFirst.GUI (SlotFrame, ToolIcon,
-- ToolName, Number); everything else is built here.
-- Display only: equipping goes through Humanoid:EquipTool/UnequipTools, the server owns what is in the Backpack.
-- The ScreenGui survives respawns; the slots are emptied and refilled from each new character's tools.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Log = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Log"))

local log = Log.new("HotbarController")
local player = Players.LocalPlayer

local HotbarController = {}

local HOTBAR_SLOTS = 10
local ICON_BUFFER = 5
local ICON_SIZE = 60

local TOOLTIP_BUFFER = 6
local TOOLTIP_HEIGHT = 16
local TOOLTIP_OFFSET = -25

local SLOT_DRAGGABLE_COLOR = Color3.new(49 / 255, 49 / 255, 49 / 255)
local SLOT_EQUIP_COLOR = Color3.new(1, 0.698039, 0)
local SLOT_EQUIP_THICKNESS = 0.05
local SLOT_FADE_LOCKED = 0.50

local BACKGROUND_FADE = 0.50
local BACKGROUND_COLOR = Color3.new(31 / 255, 31 / 255, 31 / 255)

local INVENTORY_HEADER_SIZE = 40

local SEARCH_BUFFER = 5
local SEARCH_WIDTH = 200
local SEARCH_TEXT = "   Search"
local SEARCH_BACKGROUND_COLOR = Color3.new(0.37, 0.37, 0.37)
local SEARCH_BACKGROUND_FADE = 0.15

local DOUBLE_CLICK_TIME = 0.5

local templates: { [string]: any } = {}

local slots = {} -- hotbar slots 1..HOTBAR_SLOTS, then inventory slots in order
local slotsByTool = {}
local dragging = {}
local hotkeys = {} -- KeyCode.Value -> function(isProcessed)
local lowestEmptySlot = nil
local fullHotbarSlots = 0
local viewingSearchResults = false
local textBoxFocused = false

local character = nil
local humanoid = nil
local backpack = nil
local characterConnections = {}

local hotbarFrame, inventoryFrame, scrollingFrame, gridFrame, openButton

local function disconnectAll(list)
	for _, connection in list do
		connection:Disconnect()
	end
	table.clear(list)
end

local function findLowestEmpty()
	for i = 1, HOTBAR_SLOTS do
		if not slots[i].Tool then
			return slots[i]
		end
	end
	return nil
end

local function isEquipped(tool)
	return tool ~= nil and tool.Parent == character
end

local function isInventoryEmpty()
	for i = HOTBAR_SLOTS + 1, #slots do
		if slots[i].Tool then
			return false
		end
	end
	return true
end

local function adjustHotbarFrames()
	local inventoryOpen = inventoryFrame.Visible
	local visualTotal = inventoryOpen and HOTBAR_SLOTS or fullHotbarSlots
	local visualIndex = 0
	local hotbarIsVisible = visualTotal >= 1

	for i = 1, HOTBAR_SLOTS do
		local slot = slots[i]
		if slot.Tool or inventoryOpen then
			visualIndex += 1
			slot:Readjust(visualIndex, visualTotal)
			slot.Frame.Visible = true
		else
			slot.Frame.Visible = false
		end
	end

	openButton.Visible = not inventoryOpen and (hotbarIsVisible or not isInventoryEmpty())
	openButton.Position = UDim2.new(0.5, -15, 1, hotbarIsVisible and -110 or -50)
end

local function updateCanvasSize()
	local countX = math.max(1, math.floor(scrollingFrame.AbsoluteSize.X / (ICON_SIZE + ICON_BUFFER)))
	local maxRow = math.ceil((#gridFrame:GetChildren() - 1) / countX)
	scrollingFrame.CanvasSize = UDim2.fromOffset(0, maxRow * (ICON_SIZE + ICON_BUFFER) + ICON_BUFFER)
end

local function adjustInventoryFrames()
	for i = HOTBAR_SLOTS + 1, #slots do
		local slot = slots[i]
		slot.Frame.LayoutOrder = slot.Index
		slot.Frame.Visible = slot.Tool ~= nil
	end
	updateCanvasSize()
end

local function updateLayout()
	hotbarFrame.Size = UDim2.fromOffset(ICON_BUFFER + HOTBAR_SLOTS * (ICON_SIZE + ICON_BUFFER), ICON_BUFFER + ICON_SIZE + ICON_BUFFER)
	hotbarFrame.Position = UDim2.new(0.5, -hotbarFrame.Size.X.Offset / 2, 1, -hotbarFrame.Size.Y.Offset)
	inventoryFrame.Size = UDim2.fromOffset(hotbarFrame.Size.X.Offset, hotbarFrame.Size.Y.Offset + INVENTORY_HEADER_SIZE)
	inventoryFrame.Position = UDim2.new(0.5, -inventoryFrame.Size.X.Offset / 2, 1, hotbarFrame.Position.Y.Offset - inventoryFrame.Size.Y.Offset)

	scrollingFrame.Size = UDim2.new(1, scrollingFrame.ScrollBarThickness + 1, 1, -INVENTORY_HEADER_SIZE)
	scrollingFrame.Position = UDim2.fromOffset(0, INVENTORY_HEADER_SIZE)
	adjustHotbarFrames()
	adjustInventoryFrames()
end

local function unequipAllTools()
	if humanoid then
		humanoid:UnequipTools()
	end
end

local function equipTool(tool)
	if not humanoid then
		return
	end
	humanoid:UnequipTools()
	humanoid:EquipTool(tool)
end

local function checkBounds(guiObject, x, y)
	local pos = guiObject.AbsolutePosition
	local size = guiObject.AbsoluteSize
	return x > pos.X and x <= pos.X + size.X and y > pos.Y and y <= pos.Y + size.Y
end

local function getOffset(guiObject, point)
	local center = guiObject.AbsolutePosition + guiObject.AbsoluteSize / 2
	return (center - point).Magnitude
end

local function setZIndex(slotFrame, toolIcon, toolName, slotNumber, highlight, z)
	slotFrame.ZIndex = z
	toolIcon.ZIndex = z
	toolName.ZIndex = z
	if slotNumber then
		slotNumber.ZIndex = z
	end
	if highlight then
		highlight.ZIndex = z
		for _, child in highlight:GetChildren() do
			child.ZIndex = z
		end
	end
end

local makeSlot

local function newInventorySlot()
	return makeSlot(gridFrame)
end

function makeSlot(parent, index)
	index = index or (#slots + 1)

	local slot = { Tool = nil, Index = index, Frame = nil }
	local slotFrame, fakeSlotFrame, toolIcon, toolName, highlightFrame, toolTip, slotNumber
	local toolChangedConnection = nil

	local function updateSlotFading()
		slotFrame.SelectionImageObject = nil
		slotFrame.BackgroundTransparency = slotFrame.Draggable and 0 or SLOT_FADE_LOCKED
		slotFrame.BackgroundColor3 = slotFrame.Draggable and SLOT_DRAGGABLE_COLOR or BACKGROUND_COLOR
	end

	function slot:Readjust(visualIndex, visualTotal)
		local centered = hotbarFrame.Size.X.Offset / 2
		local sizePlus = ICON_BUFFER + ICON_SIZE
		local factor = visualIndex - ((visualTotal / 2) + 0.5)
		slotFrame.Position = UDim2.fromOffset(centered - ICON_SIZE / 2 + sizePlus * factor, ICON_BUFFER)
	end

	function slot:UpdateEquipView(unequippedOverride)
		if not unequippedOverride and isEquipped(self.Tool) then
			if not highlightFrame then
				highlightFrame = Instance.new("Frame")
				highlightFrame.Name = "HighLight"
				highlightFrame.ZIndex = slotFrame.ZIndex
				highlightFrame.Size = UDim2.fromScale(1, 1)
				highlightFrame.Transparency = 1

				local t = SLOT_EQUIP_THICKNESS
				local edges = { -- relative size and position of each border edge
					{ t, 1, 0, 0 },
					{ 1 - 2 * t, t, t, 0 },
					{ t, 1, 1 - t, 0 },
					{ 1 - 2 * t, t, t, 1 - t },
				}
				for _, data in edges do
					local edge = Instance.new("Frame")
					edge.BackgroundTransparency = 0.25
					edge.BackgroundColor3 = SLOT_EQUIP_COLOR
					edge.BorderSizePixel = 0
					edge.Size = UDim2.fromScale(data[1], data[2])
					edge.Position = UDim2.fromScale(data[3], data[4])
					edge.ZIndex = highlightFrame.ZIndex
					edge.Parent = highlightFrame
				end
			end
			highlightFrame.Parent = slotFrame
		elseif highlightFrame then
			highlightFrame.Parent = nil
		end
		updateSlotFading()
	end

	function slot:Fill(tool)
		if not tool then
			self:Clear()
			return
		end
		self.Tool = tool

		local function assignToolData()
			local icon = tool.TextureId
			toolIcon.Image = icon
			if icon ~= "" then
				toolName.Visible = false
			end
			toolName.Text = tool.Name

			if toolTip then
				toolTip.Text = tool.ToolTip
				local width = toolTip.TextBounds.X + TOOLTIP_BUFFER
				toolTip.Size = UDim2.fromOffset(width, TOOLTIP_HEIGHT)
				toolTip.Position = UDim2.new(0.5, -width / 2, 0, TOOLTIP_OFFSET)
			end
		end
		assignToolData()

		if toolChangedConnection then
			toolChangedConnection:Disconnect()
		end
		toolChangedConnection = tool.Changed:Connect(function(property)
			if property == "TextureId" or property == "Name" or property == "ToolTip" then
				assignToolData()
			end
		end)

		if self.Index > HOTBAR_SLOTS or inventoryFrame.Visible then
			slotFrame.Draggable = true
		end
		self:UpdateEquipView()

		if self.Index <= HOTBAR_SLOTS then
			fullHotbarSlots += 1
		end
		slotsByTool[tool] = self
		lowestEmptySlot = findLowestEmpty()
	end

	function slot:Clear()
		if not self.Tool then
			return
		end
		if toolChangedConnection then
			toolChangedConnection:Disconnect()
			toolChangedConnection = nil
		end

		toolIcon.Image = ""
		toolName.Text = ""
		if toolTip then
			toolTip.Text = ""
			toolTip.Visible = false
		end
		slotFrame.Draggable = false
		self:UpdateEquipView(true)

		if self.Index <= HOTBAR_SLOTS then
			fullHotbarSlots -= 1
		end
		slotsByTool[self.Tool] = nil
		self.Tool = nil
		lowestEmptySlot = findLowestEmpty()
	end

	function slot:Delete()
		if toolChangedConnection then
			toolChangedConnection:Disconnect()
			toolChangedConnection = nil
		end
		slotFrame:Destroy()
		table.remove(slots, self.Index)
		for i = self.Index, #slots do
			slots[i]:SlideBack()
		end
		updateCanvasSize()
	end

	-- self must not be empty.
	function slot:Swap(target)
		local myTool, otherTool = self.Tool, target.Tool
		self:Clear()
		if otherTool then
			target:Clear()
			self:Fill(otherTool)
		end
		if myTool then
			target:Fill(myTool)
		else
			target:Clear()
		end
	end

	function slot:SlideBack()
		self.Index -= 1
		slotFrame.Name = self.Index
		slotFrame.LayoutOrder = self.Index
	end

	function slot:SetClickability(on)
		if self.Tool then
			slotFrame.Draggable = not on
			updateSlotFading()
		end
	end

	function slot:TurnNumber(on)
		if slotNumber then
			slotNumber.Visible = on
		end
	end

	function slot:CheckTerms(terms)
		local hits = 0
		if self.Tool then
			local tipText = toolTip and toolTip.Text or ""
			for term in terms do
				local _, n = toolName.Text:lower():gsub(term, "")
				local _, m = tipText:lower():gsub(term, "")
				hits += n + m
			end
		end
		return hits
	end

	function slot:Select()
		local tool = self.Tool
		if not tool then
			return
		end
		if isEquipped(tool) then
			unequipAllTools()
		elseif tool.Parent == backpack then
			equipTool(tool)
		end
	end

	function slot:MoveToInventory()
		if self.Index > HOTBAR_SLOTS then
			return
		end
		local tool = self.Tool
		self:Clear()
		local newSlot = newInventorySlot()
		newSlot:Fill(tool)
		if isEquipped(tool) then
			unequipAllTools()
		end
		if viewingSearchResults then
			newSlot.Frame.Visible = false
			newSlot.Frame.Parent = inventoryFrame
		end
	end

	slotFrame = templates.SlotFrame:Clone()
	slotFrame.Text = ""
	slotFrame.AutoButtonColor = false
	slotFrame.Active = true
	slotFrame.Draggable = false
	slotFrame.LayoutOrder = index
	slotFrame.MouseButton1Click:Connect(function()
		slot:Select()
	end)
	slot.Frame = slotFrame

	toolIcon = templates.ToolIcon:Clone()
	toolIcon.Parent = slotFrame
	toolName = templates.ToolName:Clone()
	toolName.Parent = slotFrame

	if index <= HOTBAR_SLOTS then
		toolTip = Instance.new("TextLabel")
		toolTip.TextWrapped = false
		toolTip.TextYAlignment = Enum.TextYAlignment.Top
		toolTip.BackgroundColor3 = Color3.new(0.4, 0.4, 0.4)
		toolTip.BackgroundTransparency = 0
		toolTip.Visible = false
		toolTip.Parent = slotFrame
		slotFrame.MouseEnter:Connect(function()
			if toolTip.Text ~= "" then
				toolTip.Visible = true
			end
		end)
		slotFrame.MouseLeave:Connect(function()
			toolTip.Visible = false
		end)

		local slotNum = index % 10 -- slot 10 is key 0
		slotNumber = templates.Number:Clone()
		slotNumber.Text = slotNum
		slotNumber.Visible = false
		slotNumber.Parent = slotFrame
		hotkeys[Enum.KeyCode.Zero.Value + slotNum] = function()
			slot:Select()
		end
	end

	do -- dragging
		local startPoint = slotFrame.Position
		local lastUpTime = 0
		local startParent = nil

		slotFrame.DragBegin:Connect(function(dragPoint)
			dragging[slotFrame] = true
			startPoint = dragPoint
			slotFrame.BorderSizePixel = 2
			setZIndex(slotFrame, toolIcon, toolName, slotNumber, highlightFrame, 2)

			startParent = slotFrame.Parent
			if startParent == gridFrame then
				local newPosition = UDim2.new(
					0, slotFrame.AbsolutePosition.X - inventoryFrame.AbsolutePosition.X,
					0, slotFrame.AbsolutePosition.Y - inventoryFrame.AbsolutePosition.Y
				)
				slotFrame.Parent = inventoryFrame
				slotFrame.Position = newPosition

				fakeSlotFrame = Instance.new("Frame")
				fakeSlotFrame.LayoutOrder = slotFrame.LayoutOrder
				fakeSlotFrame.Size = slotFrame.Size
				fakeSlotFrame.BackgroundTransparency = 1
				fakeSlotFrame.Parent = gridFrame
			end
		end)

		slotFrame.DragStopped:Connect(function(x, y)
			if fakeSlotFrame then
				fakeSlotFrame:Destroy()
				fakeSlotFrame = nil
			end

			local now = os.clock()
			slotFrame.Position = startPoint
			slotFrame.Parent = startParent
			slotFrame.BorderSizePixel = 0
			setZIndex(slotFrame, toolIcon, toolName, slotNumber, highlightFrame, 1)
			dragging[slotFrame] = nil

			if not slot.Tool then
				return
			end

			if checkBounds(inventoryFrame, x, y) then
				if slot.Index <= HOTBAR_SLOTS then
					slot:MoveToInventory()
				elseif now - lastUpTime < DOUBLE_CLICK_TIME then
					if lowestEmptySlot then
						local myTool = slot.Tool
						slot:Clear()
						lowestEmptySlot:Fill(myTool)
						slot:Delete()
					end
					now = 0
				end
			elseif checkBounds(hotbarFrame, x, y) then
				local closestOffset, closestSlot = math.huge, nil
				for i = 1, HOTBAR_SLOTS do
					local offset = getOffset(slots[i].Frame, Vector2.new(x, y))
					if offset < closestOffset then
						closestOffset, closestSlot = offset, slots[i]
					end
				end
				if closestSlot ~= slot then
					slot:Swap(closestSlot)
					if slot.Index > HOTBAR_SLOTS then
						local tool = slot.Tool
						if not tool then
							slot:Delete()
						else -- an inventory slot that gained a hotbar slot's tool
							if isEquipped(tool) then
								unequipAllTools()
							end
							if viewingSearchResults then
								slot.Frame.Visible = false
								slot.Frame.Parent = inventoryFrame
							end
						end
					end
				end
			elseif slot.Index <= HOTBAR_SLOTS then
				slot:MoveToInventory()
			end

			lastUpTime = now
		end)
	end

	slotFrame.Parent = parent
	slots[index] = slot

	if index > HOTBAR_SLOTS then
		updateCanvasSize()
		if inventoryFrame.Visible and not viewingSearchResults then
			local offset = scrollingFrame.CanvasSize.Y.Offset - scrollingFrame.AbsoluteSize.Y
			scrollingFrame.CanvasPosition = Vector2.new(0, math.max(0, offset))
		end
	end

	return slot
end

local function onToolAdded(tool)
	local slot = slotsByTool[tool]
	if slot then
		slot:UpdateEquipView()
		return
	end
	slot = lowestEmptySlot or newInventorySlot()
	slot:Fill(tool)
	if slot.Index <= HOTBAR_SLOTS and not inventoryFrame.Visible then
		adjustHotbarFrames()
	end
end

local function onChildAdded(child)
	if child:IsA("Tool") then
		onToolAdded(child)
	end
end

local function onChildRemoved(child)
	if not child:IsA("Tool") then
		return
	end
	-- Moving between Character and Backpack is not a removal.
	local newParent = child.Parent
	if newParent == character or newParent == backpack then
		return
	end

	local slot = slotsByTool[child]
	if slot then
		slot:Clear()
		if slot.Index > HOTBAR_SLOTS then
			slot:Delete()
		elseif not inventoryFrame.Visible then
			adjustHotbarFrames()
		end
	end
end

local function onCharacterAdded(newCharacter)
	for i = #slots, 1, -1 do
		local slot = slots[i]
		slot:Clear()
		if i > HOTBAR_SLOTS then
			slot:Delete()
		end
	end
	disconnectAll(characterConnections)

	character = newCharacter
	humanoid = newCharacter:WaitForChild("Humanoid")
	backpack = player:WaitForChild("Backpack")

	table.insert(characterConnections, character.ChildRemoved:Connect(onChildRemoved))
	table.insert(characterConnections, character.ChildAdded:Connect(onChildAdded))
	for _, child in character:GetChildren() do
		onChildAdded(child)
	end

	table.insert(characterConnections, backpack.ChildRemoved:Connect(onChildRemoved))
	table.insert(characterConnections, backpack.ChildAdded:Connect(onChildAdded))
	for _, child in backpack:GetChildren() do
		onChildAdded(child)
	end

	adjustHotbarFrames()
end

local function toggleInventory()
	if next(dragging) then
		return
	end
	inventoryFrame.Visible = not inventoryFrame.Visible
	local nowOpen = inventoryFrame.Visible
	adjustHotbarFrames()
	hotbarFrame.Active = not hotbarFrame.Active
	for i = 1, HOTBAR_SLOTS do
		slots[i]:SetClickability(not nowOpen)
	end

	if nowOpen then
		ContextActionService:BindAction("RBXRemoveSlot", function(_, state)
			if state ~= Enum.UserInputState.Begin or not GuiService.SelectedCoreObject then
				return
			end
			for i = 1, HOTBAR_SLOTS do
				if slots[i].Frame == GuiService.SelectedCoreObject and slots[i].Tool then
					slots[i]:MoveToInventory()
					return
				end
			end
		end, false, Enum.KeyCode.ButtonX)
	else
		ContextActionService:UnbindAction("RBXRemoveSlot")
	end
end

-- Search box in the inventory header. Returns a function that clears it (called on close and Escape).
local function buildSearch()
	local searchFrame = Instance.new("Frame")
	searchFrame.BackgroundColor3 = SEARCH_BACKGROUND_COLOR
	searchFrame.BackgroundTransparency = SEARCH_BACKGROUND_FADE
	searchFrame.Size = UDim2.fromOffset(SEARCH_WIDTH - SEARCH_BUFFER * 2, INVENTORY_HEADER_SIZE - SEARCH_BUFFER * 2)
	searchFrame.Position = UDim2.new(1, -searchFrame.Size.X.Offset - SEARCH_BUFFER, 0, SEARCH_BUFFER)
	searchFrame.Parent = inventoryFrame

	local searchBox = Instance.new("TextBox")
	searchBox.Text = SEARCH_TEXT
	searchBox.ClearTextOnFocus = false
	searchBox.FontSize = Enum.FontSize.Size24
	searchBox.TextXAlignment = Enum.TextXAlignment.Left
	searchBox.Size = searchFrame.Size
	searchBox.Position = UDim2.new(0, 0, 0, 0)
	searchBox.Parent = searchFrame

	local xButton = Instance.new("TextButton")
	xButton.Text = "x"
	xButton.TextColor3 = SLOT_EQUIP_COLOR
	xButton.FontSize = Enum.FontSize.Size24
	xButton.TextYAlignment = Enum.TextYAlignment.Bottom
	xButton.BackgroundColor3 = SEARCH_BACKGROUND_COLOR
	xButton.BackgroundTransparency = 0
	xButton.Size = UDim2.fromOffset(searchFrame.Size.Y.Offset - SEARCH_BUFFER * 2, searchFrame.Size.Y.Offset - SEARCH_BUFFER * 2)
	xButton.Position = UDim2.new(1, -xButton.Size.X.Offset - SEARCH_BUFFER * 2, 0.5, -xButton.Size.Y.Offset / 2)
	xButton.ZIndex = 0
	xButton.Visible = false
	xButton.BorderSizePixel = 0
	xButton.Parent = searchFrame

	local function search()
		local terms = {}
		for word in searchBox.Text:gmatch("%S+") do
			terms[word:lower()] = true
		end

		local hitTable = {}
		for i = HOTBAR_SLOTS + 1, #slots do
			local slot = slots[i]
			table.insert(hitTable, { slot, slot:CheckTerms(terms) })
			slot.Frame.Visible = false
			slot.Frame.Parent = inventoryFrame
		end
		table.sort(hitTable, function(left, right)
			return left[2] > right[2]
		end)
		viewingSearchResults = true

		local hitCount = 0
		for _, data in hitTable do
			local slot, hits = data[1], data[2]
			if hits > 0 then
				slot.Frame.Visible = true
				slot.Frame.Parent = gridFrame
				slot.Frame.LayoutOrder = HOTBAR_SLOTS + hitCount
				hitCount += 1
			end
		end

		scrollingFrame.CanvasPosition = Vector2.new(0, 0)
		updateCanvasSize()
		xButton.ZIndex = 3
	end

	local function clearResults()
		if xButton.ZIndex > 0 then
			viewingSearchResults = false
			for i = HOTBAR_SLOTS + 1, #slots do
				local slot = slots[i]
				slot.Frame.LayoutOrder = slot.Index
				slot.Frame.Parent = gridFrame
				slot.Frame.Visible = true
			end
			xButton.ZIndex = 0
		end
		updateCanvasSize()
	end

	local function reset()
		clearResults()
		searchBox.Text = SEARCH_TEXT
	end

	searchBox.Focused:Connect(function()
		if searchBox.Text == SEARCH_TEXT then
			searchBox.Text = ""
		end
	end)
	xButton.MouseButton1Click:Connect(reset)
	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		local text = searchBox.Text
		if text == "" then
			clearResults()
		elseif text ~= SEARCH_TEXT then
			search()
		end
		xButton.Visible = text ~= "" and text ~= SEARCH_TEXT
	end)
	searchBox.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			search()
		elseif searchBox.Text == "" then
			searchBox.Text = SEARCH_TEXT
		end
	end)

	-- Gamepad users do not get the keyboard search box.
	UserInputService.LastInputTypeChanged:Connect(function(lastInputType)
		searchFrame.Visible = lastInputType ~= Enum.UserInputType.Gamepad1
	end)

	return function(isNowOpen)
		xButton.Modal = isNowOpen -- free mouse movement in first person
		if not isNowOpen then
			reset()
		end
	end, reset
end

local function buildGui()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Hotbar"
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "BackpackFrame"
	mainFrame.Size = UDim2.fromScale(1, 1)
	mainFrame.Transparency = 1
	mainFrame.Parent = screenGui

	hotbarFrame = Instance.new("Frame")
	hotbarFrame.Name = "HotbarFrame"
	hotbarFrame.Transparency = 1
	hotbarFrame.Parent = mainFrame

	openButton = Instance.new("ImageButton")
	openButton.Size = UDim2.fromOffset(30, 30)
	openButton.Image = "rbxasset://textures/ui/Backpack/ScrollUpArrow.png"
	openButton.MouseButton1Click:Connect(toggleInventory)
	local noSelection = Instance.new("Frame")
	noSelection.Visible = false
	openButton.SelectionImageObject = noSelection

	inventoryFrame = Instance.new("Frame")
	inventoryFrame.BackgroundTransparency = BACKGROUND_FADE
	inventoryFrame.BackgroundColor3 = BACKGROUND_COLOR
	inventoryFrame.Active = true
	inventoryFrame.Visible = false
	inventoryFrame.Parent = mainFrame
	openButton.Parent = mainFrame

	scrollingFrame = Instance.new("ScrollingFrame")
	scrollingFrame.Selectable = false
	scrollingFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollingFrame.Parent = inventoryFrame

	gridFrame = Instance.new("Frame")
	gridFrame.Selectable = false
	gridFrame.Size = UDim2.new(1, -(ICON_BUFFER * 2), 1, 0)
	gridFrame.Position = UDim2.fromOffset(ICON_BUFFER, 0)
	gridFrame.Parent = scrollingFrame

	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.CellSize = UDim2.fromOffset(ICON_SIZE, ICON_SIZE)
	gridLayout.CellPadding = UDim2.fromOffset(ICON_BUFFER, ICON_BUFFER)
	gridLayout.Parent = gridFrame

	for i = 1, HOTBAR_SLOTS do
		local slot = makeSlot(hotbarFrame, i)
		slot.Frame.Visible = false
	end
	lowestEmptySlot = slots[1]

	updateLayout()
end

function HotbarController:Init() end

function HotbarController:Start()
	local guiFolder = ReplicatedFirst:WaitForChild("GUI")
	for _, name in { "SlotFrame", "ToolIcon", "ToolName", "Number" } do
		templates[name] = guiFolder:WaitForChild(name)
	end

	buildGui()
	local onStateChanged, resetSearch = buildSearch()

	hotkeys[Enum.KeyCode.Backquote.Value] = function()
		toggleInventory()
		onStateChanged(inventoryFrame.Visible)
	end
	openButton.MouseButton1Click:Connect(function()
		onStateChanged(inventoryFrame.Visible)
	end)
	hotkeys[Enum.KeyCode.Escape.Value] = function(isProcessed)
		if isProcessed then -- pressed inside a TextBox
			resetSearch()
		elseif inventoryFrame.Visible then
			toggleInventory()
			onStateChanged(false)
		end
	end

	UserInputService.InputBegan:Connect(function(input, isProcessed)
		if input.UserInputType == Enum.UserInputType.Keyboard and not textBoxFocused then
			local hotkey = hotkeys[input.KeyCode.Value]
			if hotkey then
				hotkey(isProcessed)
			end
		end
	end)
	UserInputService.TextBoxFocused:Connect(function()
		textBoxFocused = true
	end)
	UserInputService.TextBoxFocusReleased:Connect(function()
		textBoxFocused = false
	end)

	local function showNumbers()
		for i = 1, HOTBAR_SLOTS do
			slots[i]:TurnNumber(UserInputService.KeyboardEnabled)
		end
	end
	UserInputService:GetPropertyChangedSignal("KeyboardEnabled"):Connect(showNumbers)
	showNumbers()

	player.CharacterAdded:Connect(onCharacterAdded)
	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end

	log:Info("ready")
end

return HotbarController

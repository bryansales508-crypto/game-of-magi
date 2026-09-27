-- setting up guis

local rsGUI = game.ReplicatedFirst.GUI:GetChildren()
local GUIs = {}

for _,r in rsGUI do
	GUIs[r.Name] = r:Clone()
end


-- Services
local PlayersService = game:GetService('Players')
local UserInputService = game:GetService('UserInputService')
local StarterGui = game:GetService('StarterGui')
local GuiService = game:GetService('GuiService')
local ContextActionService = game:GetService('ContextActionService')

-- calls for backpack
local BackpackScript = {}
BackpackScript.OpenClose = nil -- Function to toggle open/close
BackpackScript.IsOpen = false
BackpackScript.StateChanged = Instance.new('BindableEvent') -- Fires after any open/close, passes IsNowOpen

BackpackScript.ModuleName = "Backpack"
BackpackScript.KeepVRTopbarOpen = true
BackpackScript.VRIsExclusive = true
BackpackScript.VRClosesNonExclusive = true

-- variables
local player = game.Players.LocalPlayer
local chara = player.Character or player.CharacterAdded:Wait()
local hum = chara:FindFirstChild("Humanoid")
local backPack = player:WaitForChild("Backpack")

local NumberOfHotbarSlots = 10
local Slots = {} -- List of all Slots by index
local LowestEmptySlot = nil

local SlotsByTool = {} -- Map of Tools to their assigned Slots
local HotkeyFns = {} -- Map of KeyCode values to their assigned behaviors
local Dragging = {} -- Only used to check if anything is being dragged, to disable other input
local FullHotbarSlots = 0 -- Now being used to also determine whether or not LB and RB on the gamepad are enabled.
local ActiveHopper = nil -- NOTE: HopperBin
local StarterToolFound = false -- Special handling is required for the gear currently equipped on the site
local WholeThingEnabled = true
local TextBoxFocused = false -- ANY TextBox, not just the search box
local ViewingSearchResults = false -- If the results of a search are currently being viewed
local HotkeyStrings = {} -- Used for eating/releasing hotkeys
local CharConns = {} -- Holds character connections to be cleared later
local TimeOfLastToolChange = 0

local MainFrame = nil
local HotbarFrame = nil
local OpenInventoryButton = nil
local CloseInventoryButton = nil
local InventoryFrame = nil
local ScrollingFrame = nil
local UIGridFrame = nil
local UIGridLayout = nil
local ModeFrame = nil

local lastEquippedSlot = nil

-- design aspects

local ICON_BUFFER = 5
local ICON_SIZE = 60
local FONT_SIZE = Enum.FontSize.Size14

local ARROW_IMAGE_OPEN = 'rbxasset://textures/ui/Backpack_Open.png'
local ARROW_IMAGE_CLOSE = 'rbxasset://textures/ui/Backpack_Close.png'
local ARROW_SIZE = UDim2.new(0, 14, 0, 9)
local ARROW_HOTKEY = Enum.KeyCode.Backquote.Value --TODO: Hookup '~' too?
local ARROW_HOTKEY_STRING = '`'
local ARROW_HOVER_COLOR = Color3.new(0,162/255,1)

local TOOLTIP_BUFFER = 6
local TOOLTIP_HEIGHT = 16
local TOOLTIP_OFFSET = -25

local SLOT_DRAGGABLE_COLOR = Color3.new(49/255, 49/255, 49/255)
local SLOT_EQUIP_COLOR = Color3.new(1, 0.698039, 0)
local SLOT_EQUIP_THICKNESS = 0.05 -- Relative
local SLOT_FADE_LOCKED = 0.50 -- Locked means undraggable
local SLOT_BORDER_COLOR = Color3.new(1, 1, 1) -- Appears when dragging

local BACKGROUND_FADE = 0.50
local BACKGROUND_COLOR = Color3.new(31/255, 31/255, 31/255)

local INVENTORY_ROWS_FULL = 4
local INVENTORY_ROWS_MINI = 2
local INVENTORY_HEADER_SIZE = 40

local SEARCH_BUFFER = 5
local SEARCH_WIDTH = 200
local SEARCH_TEXT = "   Search"

local SEARCH_TEXT_OFFSET_FROMLEFT = 0
local SEARCH_BACKGROUND_COLOR = Color3.new(0.37, 0.37, 0.37)
local SEARCH_BACKGROUND_FADE = 0.15


-- quick references
local ZERO_KEY_VALUE = Enum.KeyCode.Zero.Value
local DROP_HOTKEY_VALUE = Enum.KeyCode.Backspace.Value
local DOUBLE_CLICK_TIME = 0.5

-- functions

-- easeoflife functions
local function FindLowestEmpty()
	for i = 1, NumberOfHotbarSlots do
		local slot = Slots[i]
		if not slot.Tool then
			return slot
		end
	end
	return nil
end

local function Clamp(low, high, num)
	return math.min(high, math.max(low, num))
end

local function IsEquipped(tool)
	return tool and ((tool:IsA('HopperBin') and tool.Active) or tool.Parent == chara) --NOTE: HopperBin
end

local function isInventoryEmpty()
	for i = NumberOfHotbarSlots + 1, #Slots do
		local slot = Slots[i]
		if slot and slot.Tool then
			return false
		end
	end
	return true
end

local function AdjustHotbarFrames()
	local inventoryOpen = InventoryFrame.Visible -- (Show all)
	local visualTotal = (inventoryOpen) and NumberOfHotbarSlots or FullHotbarSlots
	local visualIndex = 0
	local hotbarIsVisible = (visualTotal >= 1)

	for i = 1, NumberOfHotbarSlots do
		local slot = Slots[i]
		if slot.Tool or inventoryOpen then
			visualIndex = visualIndex + 1
			slot:Readjust(visualIndex, visualTotal)
			slot.Frame.Visible = true
		else
			slot.Frame.Visible = false
		end
	end

	OpenInventoryButton.Visible = not inventoryOpen and (hotbarIsVisible or not isInventoryEmpty())
	OpenInventoryButton.Position = UDim2.new(0.5, -15, 1, hotbarIsVisible and -110 or -50)
end

local function UpdateScrollingFrameCanvasSize()
	local countX = math.floor(ScrollingFrame.AbsoluteSize.X/(ICON_SIZE + ICON_BUFFER))
	local maxRow = math.ceil((#UIGridFrame:GetChildren() - 1)/countX)
	local canvasSizeY = maxRow*(ICON_SIZE + ICON_BUFFER) + ICON_BUFFER
	ScrollingFrame.CanvasSize = UDim2.new(0, 0, 0, canvasSizeY)
end

local function AdjustInventoryFrames()
	for i = NumberOfHotbarSlots + 1, #Slots do
		local slot = Slots[i]
		slot.Frame.LayoutOrder = slot.Index
		slot.Frame.Visible = (slot.Tool ~= nil)
	end
	UpdateScrollingFrameCanvasSize()
end

local function UpdateBackpackLayout()
	HotbarFrame.Size = UDim2.new(0, ICON_BUFFER + (NumberOfHotbarSlots * (ICON_SIZE + ICON_BUFFER)), 0, ICON_BUFFER + ICON_SIZE + ICON_BUFFER)
	HotbarFrame.Position = UDim2.new(0.5, -HotbarFrame.Size.X.Offset / 2, 1, -HotbarFrame.Size.Y.Offset)
	InventoryFrame.Size = UDim2.new(0, HotbarFrame.Size.X.Offset, 0, (HotbarFrame.Size.Y.Offset) + INVENTORY_HEADER_SIZE)
	InventoryFrame.Position = UDim2.new(0.5, -InventoryFrame.Size.X.Offset / 2, 1, HotbarFrame.Position.Y.Offset - InventoryFrame.Size.Y.Offset)

	ScrollingFrame.Size = UDim2.new(1, ScrollingFrame.ScrollBarThickness + 1, 1, -INVENTORY_HEADER_SIZE)
	ScrollingFrame.Position = UDim2.new(0, 0, 0, INVENTORY_HEADER_SIZE)
	AdjustHotbarFrames()
	AdjustInventoryFrames()
end

local function DisableActiveHopper() --NOTE: HopperBin
	ActiveHopper:ToggleSelect()
	SlotsByTool[ActiveHopper]:UpdateEquipView()
	ActiveHopper = nil
end

local function UnequipAllTools() --NOTE: HopperBin
	if hum then
		hum:UnequipTools()
		if ActiveHopper then
			DisableActiveHopper()
		end
	end
end

local function EquipNewTool(tool) --NOTE: HopperBin
	UnequipAllTools()
	if tool:IsA('HopperBin') then
		tool:ToggleSelect()
		SlotsByTool[tool]:UpdateEquipView()
		ActiveHopper = tool
	else
		hum:EquipTool(tool) --NOTE: This would also unequip current Tool
	end
end

function changeSlot(slot)
	slot:Select()
end

local function CheckBounds(guiObject, x, y)
	local pos = guiObject.AbsolutePosition
	local size = guiObject.AbsoluteSize
	return (x > pos.X and x <= pos.X + size.X and y > pos.Y and y <= pos.Y + size.Y)
end

local function GetOffset(guiObject, point)
	local centerPoint = guiObject.AbsolutePosition + (guiObject.AbsoluteSize / 2)
	return (centerPoint - point).magnitude
end


-- main slot function
local function MakeSlot(parent, index)
	index = index or (#Slots + 1)

	-- Slot Definition --

	local slot = {}
	slot.Tool = nil
	slot.Index = index
	slot.Frame = nil

	local SlotFrameParent = nil
	local SlotFrame = nil
	local FakeSlotFrame = nil
	local ToolIcon = nil
	local ToolName = nil
	local ToolChangeConn = nil
	local HighlightFrame = nil
	local SelectionObj = nil

	--NOTE: The following are only defined for Hotbar Slots
	local ToolTip = nil
	local SlotNumber = nil

	-- Slot Functions --

	-- easeoflife slot functions
	local function UpdateSlotFading()
		SlotFrame.SelectionImageObject = nil
		SlotFrame.BackgroundTransparency = (SlotFrame.Draggable) and 0 or SLOT_FADE_LOCKED
		SlotFrame.BackgroundColor3 = (SlotFrame.Draggable) and SLOT_DRAGGABLE_COLOR or BACKGROUND_COLOR
	end

	function slot:Readjust(visualIndex, visualTotal) --NOTE: Only used for Hotbar slots
		local centered = HotbarFrame.Size.X.Offset / 2
		local sizePlus = ICON_BUFFER + ICON_SIZE
		local midpointish = (visualTotal / 2) + 0.5
		local factor = visualIndex - midpointish
		SlotFrame.Position = UDim2.new(0, centered - (ICON_SIZE / 2) + (sizePlus * factor), 0, ICON_BUFFER)
	end
	-- connections
	local con
	
	-- putting in a tool
	function slot:Fill(tool)
		
		if not tool then
			return self:Clear()
		end

		self.Tool = tool

		-- tool info
		local function assignToolData()
			local icon = tool.TextureId
			ToolIcon.Image = icon

			if icon ~= "" then
				ToolName.Visible = false 
			end
			
			-- setting name
			ToolName.Text = tool.Name

			if ToolTip and tool:IsA("Tool") then
				ToolTip.Text = tool.ToolTip
				local width = ToolTip.TextBounds.X + TOOLTIP_BUFFER
				ToolTip.Size = UDim2.new(0, width, 0, TOOLTIP_HEIGHT)
				ToolTip.Position = UDim2.new(0.5, -width / 2, 0, TOOLTIP_OFFSET)
			end
		end

		assignToolData()

		-- updating the tool information
		if ToolChangeConn then
			ToolChangeConn:disconnect()
			ToolChangeConn = nil
		end

		ToolChangeConn = tool.Changed:connect(function(property)
			if property == 'TextureId' or property == 'Name' or property == 'ToolTip' then
				assignToolData()
			end
		end)

		local hotbarSlot = (self.Index <= NumberOfHotbarSlots)
		local inventoryOpen = InventoryFrame.Visible

		if (not hotbarSlot or inventoryOpen) then
			SlotFrame.Draggable = true
		end

		self:UpdateEquipView()

		if hotbarSlot then
			FullHotbarSlots = FullHotbarSlots + 1
		end
		
		-- for mode tools
		if tool:FindFirstChild("Mode") then
			ModeFrame = GUIs["ModeFrame"]:Clone()
			ModeFrame.Parent = SlotFrame
			
			-- setting color just in case mode is already activated
			if tool.Mode.Value == 1 then
				ModeFrame.BackgroundColor3 = Color3.new(0, 0.666667, 0)
			else
				ModeFrame.BackgroundColor3 = Color3.fromRGB(189, 32, 32)
			end
			
			-- listening for it being activated
			con = tool.Mode.Changed:connect(function(v)
				if v == 1 then
					ModeFrame.BackgroundColor3 = Color3.new(0, 0.666667, 0)
				else
					ModeFrame.BackgroundColor3 = Color3.fromRGB(189, 32, 32)
				end
			end)
		end

		SlotsByTool[tool] = self
		LowestEmptySlot = FindLowestEmpty()
	end

	-- removing a tool
	function slot:Clear()
		if not self.Tool then return end

		if ToolChangeConn then
			ToolChangeConn:disconnect()
			ToolChangeConn = nil
		end

		ToolIcon.Image = ''
		ToolName.Text = ''
		if ToolTip then
			ToolTip.Text = ''
			ToolTip.Visible = false
		end
		SlotFrame.Draggable = false

		self:UpdateEquipView(true) -- Show as unequipped

		if self.Index <= NumberOfHotbarSlots then
			FullHotbarSlots = FullHotbarSlots - 1
		end
		
		-- getting rid of any mode
		if ModeFrame then
			ModeFrame:Destroy()
			con:Disconnect()
		end

		SlotsByTool[self.Tool] = nil
		self.Tool = nil
		LowestEmptySlot = FindLowestEmpty()
	end

	-- when tool is equipped
	function slot:UpdateEquipView(unequippedOverride)
		if not unequippedOverride and IsEquipped(self.Tool) then -- Equipped
			lastEquippedSlot = slot
			if not HighlightFrame then

				-- TODO: Make a Highlight Frame
				HighlightFrame = Instance.new("Frame")
				HighlightFrame.Name = "HighLight"
				HighlightFrame.ZIndex = SlotFrame.ZIndex
				HighlightFrame.Size = UDim2.new(1,0,1,0)
				HighlightFrame.Transparency = 1
				
				local t = SLOT_EQUIP_THICKNESS
				local dataTable = { -- Relative sizes and positions
					{t,       1, 0,     0},
					{1 - 2*t, t, t,     0},
					{t,       1, 1 - t, 0},
					{1 - 2*t, t, t,     1 - t},
				}
				for _, data in pairs(dataTable) do
					-- TODO: Make the edge of the equipped frame.
					local edgeFrame = Instance.new("Frame")
					edgeFrame.BackgroundTransparency = 0.25
					edgeFrame.BackgroundColor3 = SLOT_EQUIP_COLOR
					edgeFrame.BorderSizePixel = 0
					edgeFrame.Size = UDim2.new(data[1], 0, data[2], 0)
					edgeFrame.Position = UDim2.new(data[3], 0, data[4], 0)
					edgeFrame.ZIndex = HighlightFrame.ZIndex
					edgeFrame.Parent = HighlightFrame
				end
			end
			HighlightFrame.Parent = SlotFrame
		else -- In the Backpack
			if HighlightFrame then
				HighlightFrame.Parent = nil
			end
		end
		UpdateSlotFading()
	end

	function slot:IsEquipped()
		return IsEquipped(self.Tool)
	end

	-- slot deleted
	function slot:Delete()
		SlotFrame:Destroy() --NOTE: Also clears connections
		table.remove(Slots, self.Index)
		local newSize = #Slots

		-- Now adjust the rest (both visually and representationally)
		for i = self.Index, newSize do
			Slots[i]:SlideBack()
		end

		UpdateScrollingFrameCanvasSize()
	end

	-- one slot is swapped for another
	function slot:Swap(targetSlot) --NOTE: This slot (self) must not be empty!
		local myTool, otherTool = self.Tool, targetSlot.Tool
		self:Clear()
		if otherTool then -- (Target slot might be empty)
			targetSlot:Clear()
			self:Fill(otherTool)
		end
		if myTool then
			targetSlot:Fill(myTool)
		else
			targetSlot:Clear()
		end
	end

	-- moves the slots around
	function slot:SlideBack() -- For inventory slot shifting
		self.Index = self.Index - 1
		SlotFrame.Name = self.Index
		SlotFrame.LayoutOrder = self.Index
	end

	function slot:SetClickability(on) -- (Happens on open/close arrow)
		if self.Tool then
			if UserInputService.VREnabled then
				SlotFrame.Draggable = false
			else
				SlotFrame.Draggable = not on
			end
			UpdateSlotFading()
		end
	end

	function slot:TurnNumber(on)
		if SlotNumber then
			SlotNumber.Visible = on
		end
	end

	-- item search
	function slot:CheckTerms(terms)
		local hits = 0
		local function checkEm(str, term)
			local _, n = str:lower():gsub(term, '')
			hits = hits + n
		end
		local tool = self.Tool
		if tool then
			for term in pairs(terms) do
				checkEm(ToolName.Text, term)
				if tool:IsA('Tool') then --NOTE: HopperBin
					local toolTipText = ToolTip and ToolTip.Text or ""
					checkEm(toolTipText, term)
				end
			end
		end
		return hits
	end

	-- slot select: click or hotkey press
	function slot:Select()
		local tool = slot.Tool
		if tool then
			-- TODO: Where you play around with multiple select.
			if IsEquipped(tool) then --NOTE: HopperBin
				UnequipAllTools()
			elseif tool.Parent == backPack then
				EquipNewTool(tool)
			end
		end
	end

	-- Slot Init Logic --

	-- TODO: Make a frame for the actual slots
	SlotFrame = GUIs["SlotFrame"]:Clone()
	SlotFrame.Text = ""
	SlotFrame.AutoButtonColor = false
	SlotFrame.Active = true
	SlotFrame.Draggable = false
	SlotFrame.MouseButton1Click:connect(function() changeSlot(slot) end)
	slot.Frame = SlotFrame

	-- BRYAN isolates variables, never knew about this so.
	do
		--TODO: I don't know what this is yet, figure out later. But you need to make it.
		local selectionObjectClipper = Instance.new("Frame")
		selectionObjectClipper.Name = "UnknownGUI"
		selectionObjectClipper.Visible = false
		selectionObjectClipper.Parent = SlotFrame

		-- TODO: Same here.
		SelectionObj = Instance.new("ImageLabel")
		SelectionObj.Size = UDim2.new(1, 0, 1, 0)
		SelectionObj.Image = "rbxasset://textures/ui/Keyboard/key_selection_9slice.png"
		SelectionObj.ScaleType = Enum.ScaleType.Slice
		SelectionObj.SliceCenter = Rect.new(12,12,52,52)
		SelectionObj.Parent = selectionObjectClipper
	end

	ToolIcon = GUIs["ToolIcon"]:Clone()
	ToolIcon.Parent = SlotFrame

	ToolName = GUIs["ToolName"]:Clone()
	ToolName.Parent = SlotFrame

	slot.Frame.LayoutOrder = slot.Index

	if index <= NumberOfHotbarSlots then -- Hotbar-Specific Slot Stuff
		-- ToolTip stuff
		-- TODO: Tooltip frame. Make one.
		ToolTip = Instance.new("TextLabel")
		ToolTip.TextWrapped = false
		ToolTip.TextYAlignment = Enum.TextYAlignment.Top
		ToolTip.BackgroundColor3 = Color3.new(0.4, 0.4, 0.4)
		ToolTip.BackgroundTransparency = 0
		ToolTip.Visible = false
		ToolTip.Parent = SlotFrame
		SlotFrame.MouseEnter:connect(function()
			if ToolTip.Text ~= '' then
				ToolTip.Visible = true
			end
		end)
		SlotFrame.MouseLeave:connect(function() ToolTip.Visible = false end)

		-- Removed from the Hotbar to Inventory
		function slot:MoveToInventory()
			if slot.Index <= NumberOfHotbarSlots then -- From a Hotbar slot
				local tool = slot.Tool
				self:Clear() --NOTE: Order matters here
				local newSlot = MakeSlot(UIGridFrame)
				newSlot:Fill(tool)
				if IsEquipped(tool) then -- Also unequip it --NOTE: HopperBin
					UnequipAllTools()
				end
				-- Also hide the inventory slot if we're showing results right now
				if ViewingSearchResults then
					newSlot.Frame.Visible = false
					newSlot.Parent = InventoryFrame
				end
			end
		end

		-- Show label and assign hotkeys for 1-9 and 0 (zero is always last slot when > 10 total)
		if index < 10 or index == NumberOfHotbarSlots then -- NOTE: Hardcoded on purpose!
			local slotNum = (index < 10) and index or 0

			SlotNumber = GUIs["Number"]:Clone()
			SlotNumber.Text = slotNum
			SlotNumber.Visible = false
			SlotNumber.Parent = SlotFrame
			HotkeyFns[ZERO_KEY_VALUE + slotNum] = slot.Select
		end
	end

	do -- Dragging Logic
		local startPoint = SlotFrame.Position
		local lastUpTime = 0
		local startParent = nil

		SlotFrame.DragBegin:connect(function(dragPoint)
			Dragging[SlotFrame] = true
			startPoint = dragPoint

			SlotFrame.BorderSizePixel = 2

			-- Raise above other slots
			SlotFrame.ZIndex = 2
			ToolIcon.ZIndex = 2
			ToolName.ZIndex = 2
			if SlotNumber then
				SlotNumber.ZIndex = 2
			end
			if HighlightFrame then
				HighlightFrame.ZIndex = 2
				for _, child in pairs(HighlightFrame:GetChildren()) do
					child.ZIndex = 2
				end
			end

			-- Circumvent the ScrollingFrame's ClipsDescendants property
			startParent = SlotFrame.Parent
			if startParent == UIGridFrame then
				local oldAbsolutPos = SlotFrame.AbsolutePosition
				local newPosition = UDim2.new(0, SlotFrame.AbsolutePosition.X - InventoryFrame.AbsolutePosition.X, 0, SlotFrame.AbsolutePosition.Y - InventoryFrame.AbsolutePosition.Y)
				SlotFrame.Parent = InventoryFrame
				SlotFrame.Position = newPosition

				-- TODO: The empty slot GUI
				FakeSlotFrame = Instance.new("Frame")
				FakeSlotFrame.LayoutOrder = SlotFrame.LayoutOrder
				FakeSlotFrame.Size = SlotFrame.Size
				FakeSlotFrame.BackgroundTransparency = 1
				FakeSlotFrame.Parent = UIGridFrame
			end
		end)

		SlotFrame.DragStopped:connect(function(x, y)
			if FakeSlotFrame then
				FakeSlotFrame:Destroy()
			end

			local now = tick()
			SlotFrame.Position = startPoint
			SlotFrame.Parent = startParent

			SlotFrame.BorderSizePixel = 0

			-- Restore height
			SlotFrame.ZIndex = 1
			ToolIcon.ZIndex = 1
			ToolName.ZIndex = 1
			if SlotNumber then
				SlotNumber.ZIndex = 1
			end
			if HighlightFrame then
				HighlightFrame.ZIndex = 1
				for _, child in pairs(HighlightFrame:GetChildren()) do
					child.ZIndex = 1
				end
			end

			Dragging[SlotFrame] = nil

			-- Make sure the tool wasn't dropped
			if not slot.Tool then
				return
			end

			-- Check where we were dropped
			if CheckBounds(InventoryFrame, x, y) then
				if slot.Index <= NumberOfHotbarSlots then
					slot:MoveToInventory()
				end
				-- Check for double clicking on an inventory slot, to move into empty hotbar slot
				if slot.Index > NumberOfHotbarSlots and now - lastUpTime < DOUBLE_CLICK_TIME then
					if LowestEmptySlot then
						local myTool = slot.Tool
						slot:Clear()
						LowestEmptySlot:Fill(myTool)
						slot:Delete()
					end
					now = 0 -- Resets the timer
				end
			elseif CheckBounds(HotbarFrame, x, y) then
				local closest = {math.huge, nil}
				for i = 1, NumberOfHotbarSlots do
					local otherSlot = Slots[i]
					local offset = GetOffset(otherSlot.Frame, Vector2.new(x, y))
					if offset < closest[1] then
						closest = {offset, otherSlot}
					end
				end
				local closestSlot = closest[2]
				if closestSlot ~= slot then
					slot:Swap(closestSlot)
					if slot.Index > NumberOfHotbarSlots then
						local tool = slot.Tool
						if not tool then -- Clean up after ourselves if we're an inventory slot that's now empty
							slot:Delete()
						else -- Moved inventory slot to hotbar slot, and gained a tool that needs to be unequipped
							if IsEquipped(tool) then --NOTE: HopperBin
								UnequipAllTools()
							end
							-- Also hide the inventory slot if we're showing results right now
							if ViewingSearchResults then
								slot.Frame.Visible = false
								slot.Frame.Parent = InventoryFrame
							end
						end
					end
				end
			else
				-- local tool = slot.Tool
				-- if tool.CanBeDropped then --TODO: HopperBins
				-- tool.Parent = workspace
				-- --TODO: Move away from character
				-- end
				if slot.Index <= NumberOfHotbarSlots then
					slot:MoveToInventory() --NOTE: Temporary
				end
			end

			lastUpTime = now
		end)
	end

	-- All ready!
	SlotFrame.Parent = parent
	Slots[index] = slot

	if index > NumberOfHotbarSlots then
		UpdateScrollingFrameCanvasSize()
		-- Scroll to new inventory slot, if we're open and not viewing search results
		if InventoryFrame.Visible and not ViewingSearchResults then
			local offset = ScrollingFrame.CanvasSize.Y.Offset - ScrollingFrame.AbsoluteSize.Y
			ScrollingFrame.CanvasPosition = Vector2.new(0, math.max(0, offset))
		end
	end

	return slot
end

-- NOTE: We should probably migrate to a 2 collection system:
-- One collection for the hotbar and another collection for the inventory
local function SetNumberOfHotbarSlots(numSlots)
	if NumberOfHotbarSlots ~= numSlots then
		local prevNumberOfSlots = NumberOfHotbarSlots
		local newNumberOfSlots = numSlots
		-- If we are shrinking the number of slots we need
		-- to move around our tools to the right locations
		if prevNumberOfSlots > newNumberOfSlots then
			-- Delete the slots that are now no longer in the Hotbar
			-- Iterate backwards as to not corrupt our iterator
			for i = prevNumberOfSlots, newNumberOfSlots + 1, -1 do
				local slot = Slots[i]
				if slot then
					slot:MoveToInventory()
					slot:Delete()
				end
			end
			-- Also need to slide-back the inventory slots now that they are indexed earlier
			for i = prevNumberOfSlots, newNumberOfSlots + 1, -1 do
				local slot = Slots[i]
				if not slot.Tool then
					slot:Delete()
				end
			end
		else -- If we added more slots
			for i = prevNumberOfSlots, newNumberOfSlots do
				-- Incrementally add hotbar slots
				NumberOfHotbarSlots = i
				if Slots[i] then
					-- Move old
					local oldSlot = Slots[i]
					local oldTool = Slots[i].Tool

					local newSlot = MakeSlot(HotbarFrame, i)

					if oldTool then
						newSlot:Fill(oldTool)
					elseif not LowestEmptySlot then
						LowestEmptySlot = newSlot
					end
				else
					local slot = MakeSlot(HotbarFrame, i)

					slot.Frame.Visible = false

					if not LowestEmptySlot then
						LowestEmptySlot = slot
					end
				end
			end
		end
		NumberOfHotbarSlots = numSlots
		FullHotbarSlots = 0
		for i = 1, NumberOfHotbarSlots do
			if Slots[i] and Slots[i].Tool then
				FullHotbarSlots = FullHotbarSlots + 1
			end
		end

		UpdateBackpackLayout()
	end
end

local function OnChildAdded(child) -- To Character or Backpack
	if not child:IsA('Tool') and not child:IsA('HopperBin') then --NOTE: HopperBin
		if child:IsA('Humanoid') and child.Parent == Character then
			hum = child
		end
		return
	end
	local tool = child

	if tool.Parent == Character then
		TimeOfLastToolChange = tick()
	end

	if ActiveHopper and tool.Parent == Character then --NOTE: HopperBin
		DisableActiveHopper()
	end

	--TODO: Optimize / refactor / do something else
	if not StarterToolFound and tool.Parent == Character and not SlotsByTool[tool] then
		local starterGear = player:FindFirstChild('StarterGear')
		if starterGear then
			if starterGear:FindFirstChild(tool.Name) then
				StarterToolFound = true
				local slot = LowestEmptySlot or MakeSlot(UIGridFrame)
				for i = slot.Index, 1, -1 do
					local curr = Slots[i] -- An empty slot, because above
					local pIndex = i - 1
					if pIndex > 0 then
						local prev = Slots[pIndex] -- Guaranteed to be full, because above
						prev:Swap(curr)
					else
						curr:Fill(tool)
					end
				end
				-- Have to manually unequip a possibly equipped tool
				for _, child in pairs(Character:GetChildren()) do
					if child:IsA('Tool') and child ~= tool then
						child.Parent = Backpack
					end
				end
				AdjustHotbarFrames()
				return -- We're done here
			end
		end
	end

	-- The tool is either moving or new
	local slot = SlotsByTool[tool]
	if slot then
		slot:UpdateEquipView()
	else -- New! Put into lowest hotbar slot or new inventory slot
		slot = LowestEmptySlot or MakeSlot(UIGridFrame)
		slot:Fill(tool)
		if slot.Index <= NumberOfHotbarSlots and not InventoryFrame.Visible then
			AdjustHotbarFrames()
		end
		if tool:IsA('HopperBin') then --NOTE: HopperBin
			if tool.Active then
				UnequipAllTools()
				ActiveHopper = tool
			end
		end
	end
end

local function OnChildRemoved(child) -- From Character or Backpack
	if not child:IsA('Tool') and not child:IsA('HopperBin') then --NOTE: HopperBin
		return
	end
	local tool = child

	TimeOfLastToolChange = tick()

	-- Ignore this event if we're just moving between the two
	local newParent = tool.Parent
	if newParent == Character or newParent == Backpack then
		return
	end

	local slot = SlotsByTool[tool]
	if slot then
		slot:Clear()
		if slot.Index > NumberOfHotbarSlots then -- Inventory slot
			slot:Delete()
		elseif not InventoryFrame.Visible then
			AdjustHotbarFrames()
		end
	end

	if tool == ActiveHopper then --NOTE: HopperBin
		ActiveHopper = nil
	end
end

local function OnCharacterAdded(character)
	-- First, clean up any old slots
	for i = #Slots, 1, -1 do
		local slot = Slots[i]
		if slot.Tool then
			slot:Clear()
		end
		if i > NumberOfHotbarSlots then
			slot:Delete()
		end
	end
	ActiveHopper = nil --NOTE: HopperBin

	-- And any old connections
	for _, conn in pairs(CharConns) do
		conn:disconnect()
	end
	CharConns = {}

	-- Hook up the new character
	Character = character
	table.insert(CharConns, character.ChildRemoved:connect(OnChildRemoved))
	table.insert(CharConns, character.ChildAdded:connect(OnChildAdded))
	for _, child in pairs(character:GetChildren()) do
		OnChildAdded(child)
	end
	--NOTE: Humanoid is set inside OnChildAdded

	-- And the new backpack, when it gets here
	Backpack = player:WaitForChild('Backpack')
	table.insert(CharConns, Backpack.ChildRemoved:connect(OnChildRemoved))
	table.insert(CharConns, Backpack.ChildAdded:connect(OnChildAdded))
	for _, child in pairs(Backpack:GetChildren()) do
		OnChildAdded(child)
	end

	AdjustHotbarFrames()
end

local function OnInputBegan(input, isProcessed)
	-- Pass through keyboard hotkeys when not typing into a TextBox and not disabled (except for the Drop key)
	if input.UserInputType == Enum.UserInputType.Keyboard and not TextBoxFocused and (WholeThingEnabled or input.KeyCode.Value == DROP_HOTKEY_VALUE) then
		local hotkeyBehavior = HotkeyFns[input.KeyCode.Value]
		if hotkeyBehavior then
			hotkeyBehavior(isProcessed)
		end
	end
end

local function OnUISChanged(property)
	if property == 'KeyboardEnabled' or property == "VREnabled" then
		local on = UserInputService.KeyboardEnabled and not UserInputService.VREnabled
		for i = 1, NumberOfHotbarSlots do
			Slots[i]:TurnNumber(on)
		end
	end
end

-- main frame
local sgooey = Instance.new("ScreenGui")
sgooey.Parent = player.PlayerGui
sgooey.IgnoreGuiInset = true

MainFrame = Instance.new("Frame")
MainFrame.Name = "BackpackFrame"
MainFrame.Size = UDim2.new(1,0,1,0)
MainFrame.Transparency = 1
MainFrame.Visible = true
MainFrame.Parent = sgooey

-- hotbar frame
HotbarFrame = Instance.new("Frame")
HotbarFrame.Name = "HotbarFrame"
HotbarFrame.Transparency = 1
HotbarFrame.Parent = MainFrame


-- hotbar slots
for i=1, NumberOfHotbarSlots do
	local slot = MakeSlot(HotbarFrame, i)
	slot.Frame.Visible = false

	if not LowestEmptySlot then
		LowestEmptySlot = slot
	end
end

-- Up arrow to open the inventory

-- i am drunk so recheck this coding when sober
-- TODO: Create a open inventory image button

OpenInventoryButton = Instance.new("ImageButton")
do
	OpenInventoryButton.Size = UDim2.new(0, 30, 0, 30)
	OpenInventoryButton.Image = "rbxasset://textures/ui/Backpack/ScrollUpArrow.png"
	OpenInventoryButton.MouseButton1Click:connect(function()
		BackpackScript.OpenClose()
	end)

	-- TODO: Create a frame for selection, once again I have no clue what this is.
	local openInventoryButtonSelectionObject = Instance.new("Frame")
	openInventoryButtonSelectionObject.Visible = false
	OpenInventoryButton.SelectionImageObject = openInventoryButtonSelectionObject
end

--TODO: Make a clove inventory button.
CloseInventoryButton = Instance.new("ImageButton")
CloseInventoryButton.Position = UDim2.new(0, 0, 0, -50)
CloseInventoryButton.MouseButton1Click:connect(function()
	if InventoryFrame.Visible then
		BackpackScript.OpenClose()
		spawn(function() GuiService:SetMenuIsOpen(false) end)
	end
end)

-- Make the Inventory, which holds the ScrollingFrame, the header, and the search box
-- TODO: Make a inventory frame.
InventoryFrame = Instance.new("Frame")
InventoryFrame.BackgroundTransparency = BACKGROUND_FADE
InventoryFrame.BackgroundColor3 = BACKGROUND_COLOR
InventoryFrame.Active = true
InventoryFrame.Visible = false
InventoryFrame.Parent = MainFrame

-- TODO: Image label for selector image.
local selectorImage = Instance.new("ImageLabel")
selectorImage.Size = UDim2.new(1, 0, 1, 0)
selectorImage.Image = "rbxasset://textures/ui/Keyboard/key_selection_9slice.png"
selectorImage.ScaleType = Enum.ScaleType.Slice
selectorImage.SliceCenter = Rect.new(12,12,52,52)
selectorImage.Visible = false

-- Make the ScrollingFrame, which holds the rest of the Slots (however many)
--TODO: Scrolling Frame for the GUI
ScrollingFrame = Instance.new("ScrollingFrame")
ScrollingFrame.Selectable = false
ScrollingFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
ScrollingFrame.Parent = InventoryFrame

-- TODO: Frame for UIGrid
UIGridFrame = Instance.new("Frame")
UIGridFrame.Selectable = false
UIGridFrame.Size = UDim2.new(1, -(ICON_BUFFER*2), 1, 0)
UIGridFrame.Position = UDim2.new(0, ICON_BUFFER, 0, 0)
UIGridFrame.Parent = ScrollingFrame

UIGridLayout = Instance.new("UIGridLayout")
UIGridLayout.SortOrder = Enum.SortOrder.LayoutOrder
UIGridLayout.CellSize = UDim2.new(0, ICON_SIZE, 0, ICON_SIZE)
UIGridLayout.CellPadding = UDim2.new(0, ICON_BUFFER, 0, ICON_BUFFER)
UIGridLayout.Parent = UIGridFrame

ScrollingFrame.Changed:connect(function(prop)
	if prop == 'AbsoluteWindowSize' or prop == 'CanvasPosition' or prop == 'CanvasSize' then
		local canScrollUp = ScrollingFrame.CanvasPosition.Y ~= 0
		local canScrollDown = ScrollingFrame.CanvasPosition.Y < ScrollingFrame.CanvasSize.Y.Offset - ScrollingFrame.AbsoluteWindowSize.Y
	end
end)

-- Position the frames and sizes for the Backpack GUI elements
UpdateBackpackLayout()

do -- Search stuff

	--TODO: Frame for Search
	local searchFrame = Instance.new("Frame")
	searchFrame.BackgroundColor3 = SEARCH_BACKGROUND_COLOR
	searchFrame.BackgroundTransparency = SEARCH_BACKGROUND_FADE
	searchFrame.Size = UDim2.new(0, SEARCH_WIDTH - (SEARCH_BUFFER * 2), 0, INVENTORY_HEADER_SIZE - (SEARCH_BUFFER * 2))
	searchFrame.Position = UDim2.new(1, -searchFrame.Size.X.Offset - SEARCH_BUFFER, 0, SEARCH_BUFFER)
	searchFrame.Parent = InventoryFrame

	--TODO: TextBox for SearchBox
	local searchBox = Instance.new("TextBox")
	searchBox.Text = SEARCH_TEXT
	searchBox.ClearTextOnFocus = false
	searchBox.FontSize = Enum.FontSize.Size24
	searchBox.TextXAlignment = Enum.TextXAlignment.Left
	searchBox.Size = searchFrame.Size - UDim2.new(0, SEARCH_TEXT_OFFSET_FROMLEFT, 0, 0)
	searchBox.Position = UDim2.new(0, SEARCH_TEXT_OFFSET_FROMLEFT, 0, 0)
	searchBox.Parent = searchFrame

	--TODO: Textbutton for X
	local xButton = Instance.new("TextButton")
	xButton.Text = 'x'
	xButton.TextColor3 = SLOT_EQUIP_COLOR
	xButton.FontSize = Enum.FontSize.Size24
	xButton.TextYAlignment = Enum.TextYAlignment.Bottom
	xButton.BackgroundColor3 = SEARCH_BACKGROUND_COLOR
	xButton.BackgroundTransparency = 0
	xButton.Size = UDim2.new(0, searchFrame.Size.Y.Offset - (SEARCH_BUFFER * 2), 0, searchFrame.Size.Y.Offset - (SEARCH_BUFFER * 2))
	xButton.Position = UDim2.new(1, -xButton.Size.X.Offset - (SEARCH_BUFFER * 2), 0.5, -xButton.Size.Y.Offset / 2)
	xButton.ZIndex = 0
	xButton.Visible = false
	xButton.BorderSizePixel = 0
	xButton.Parent = searchFrame

	local function search()
		local terms = {}
		for word in searchBox.Text:gmatch('%S+') do
			terms[word:lower()] = true
		end

		local hitTable = {}
		for i = NumberOfHotbarSlots + 1, #Slots do -- Only search inventory slots
			local slot = Slots[i]
			local hits = slot:CheckTerms(terms)
			table.insert(hitTable, {slot, hits})
			slot.Frame.Visible = false
			slot.Frame.Parent = InventoryFrame
		end

		table.sort(hitTable, function(left, right)
			return left[2] > right[2]
		end)
		ViewingSearchResults = true

		local hitCount = 0
		for i, data in ipairs(hitTable) do
			local slot, hits = data[1], data[2]
			if hits > 0 then
				slot.Frame.Visible = true
				slot.Frame.Parent = UIGridFrame
				slot.Frame.LayoutOrder = NumberOfHotbarSlots + hitCount
				hitCount = hitCount + 1
			end
		end

		ScrollingFrame.CanvasPosition = Vector2.new(0, 0)
		UpdateScrollingFrameCanvasSize()

		xButton.ZIndex = 3
	end

	local function clearResults()
		if xButton.ZIndex > 0 then
			ViewingSearchResults = false
			for i = NumberOfHotbarSlots + 1, #Slots do
				local slot = Slots[i]
				slot.Frame.LayoutOrder = slot.Index
				slot.Frame.Parent = UIGridFrame
				slot.Frame.Visible = true
			end
			xButton.ZIndex = 0
		end
		UpdateScrollingFrameCanvasSize()
	end

	local function reset()
		clearResults()
		searchBox.Text = SEARCH_TEXT
	end

	local function onChanged(property)
		if property == 'Text' then
			local text = searchBox.Text
			if text == '' then
				clearResults()
			elseif text ~= SEARCH_TEXT then
				search()
			end
			xButton.Visible = (text ~= '' and text ~= SEARCH_TEXT)
		end
	end

	local function onFocused()
		if searchBox.Text == SEARCH_TEXT then
			searchBox.Text = ''
		end
	end

	local function focusLost(enterPressed)
		if enterPressed then
			--TODO: Could optimize
			search()
		elseif searchBox.Text == '' then
			searchBox.Text = SEARCH_TEXT
		end
	end

	searchBox.Focused:connect(onFocused)
	xButton.MouseButton1Click:connect(reset)
	searchBox.Changed:connect(onChanged)
	searchBox.FocusLost:connect(focusLost)

	BackpackScript.StateChanged.Event:connect(function(isNowOpen)
		xButton.Modal = isNowOpen -- Allows free mouse movement even in first person
		if not isNowOpen then
			reset()
		end
	end)

	HotkeyFns[Enum.KeyCode.Escape.Value] = function(isProcessed)
		if isProcessed then -- Pressed from within a TextBox
			reset()
		elseif InventoryFrame.Visible then
			BackpackScript.OpenClose()
		end
	end

	local function detectGamepad(lastInputType)
		if lastInputType == Enum.UserInputType.Gamepad1 and not UserInputService.VREnabled then
			searchFrame.Visible = false
		else
			searchFrame.Visible = true
		end
	end
	UserInputService.LastInputTypeChanged:connect(detectGamepad)
end

do -- Make the Inventory expand/collapse arrow (unless TopBar)
	local removeHotBarSlot = function(name, state, input)
		if state ~= Enum.UserInputState.Begin then return end
		if not GuiService.SelectedCoreObject then return end

		for i = 1, NumberOfHotbarSlots do
			if Slots[i].Frame == GuiService.SelectedCoreObject and Slots[i].Tool then
				Slots[i]:MoveToInventory()
				return
			end
		end
	end

	local function openClose()
		if not next(Dragging) then -- Only continue if nothing is being dragged
			InventoryFrame.Visible = not InventoryFrame.Visible
			local nowOpen = InventoryFrame.Visible
			AdjustHotbarFrames()
			HotbarFrame.Active = not HotbarFrame.Active
			for i = 1, NumberOfHotbarSlots do
				Slots[i]:SetClickability(not nowOpen)
			end
		end

		if InventoryFrame.Visible then
			ContextActionService:BindAction("RBXRemoveSlot", removeHotBarSlot, false, Enum.KeyCode.ButtonX)
		else
			ContextActionService:UnbindAction("RBXRemoveSlot")
		end

		BackpackScript.IsOpen = InventoryFrame.Visible
		BackpackScript.StateChanged:Fire(InventoryFrame.Visible)
	end
	HotkeyFns[ARROW_HOTKEY] = openClose
	BackpackScript.OpenClose = openClose -- Exposed
end

-- Listen to current and all future characters of our player
player.CharacterAdded:connect(OnCharacterAdded)
if player.Character then
	OnCharacterAdded(player.Character)
end

do -- Hotkey stuff
	-- Init HotkeyStrings, used for eating hotkeys
	for i = 0, 9 do
		table.insert(HotkeyStrings, tostring(i))
	end
	table.insert(HotkeyStrings, ARROW_HOTKEY_STRING)

	-- Listen to key down
	UserInputService.InputBegan:connect(OnInputBegan)

	-- Listen to ANY TextBox gaining or losing focus, for disabling all hotkeys
	UserInputService.TextBoxFocused:connect(function() TextBoxFocused = true end)
	UserInputService.TextBoxFocusReleased:connect(function() TextBoxFocused = false end)

	-- Manual unequip for HopperBins on drop button pressed
	HotkeyFns[DROP_HOTKEY_VALUE] = function() --NOTE: HopperBin
		if ActiveHopper then
			UnequipAllTools()
		end
	end

	-- Listen to keyboard status, for showing/hiding hotkey labels
	UserInputService.Changed:connect(OnUISChanged)
	OnUISChanged('KeyboardEnabled')
end

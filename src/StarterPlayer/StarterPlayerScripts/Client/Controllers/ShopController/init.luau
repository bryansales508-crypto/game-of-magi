--!strict
-- Client-only hover highlight for the Qarzin clothes shop.
--
-- Contract with the server (ShopService): it stocks Workspace.Qarzin.ClothesStand
-- and creates the ProximityPrompts (always Enabled, RequiresLineOfSight =
-- false, ActionText = the price); purchases are entirely server-side and the
-- server never touches each rack's Highlight child. This controller only sets
-- Highlight.Enabled / the part's Transparency LOCALLY, so only the hovering
-- player sees the outline. No prices are computed and nothing is sent.
--
-- Hover mechanism: a ClickDetector (MaxActivationDistance 10) on the
-- ShirtHL/PantsHL part, whose MouseHoverEnter/Leave set Transparency 0.999 / 1
-- and toggle the Highlight child. The server only promises the
-- ProximityPrompts, so a ClickDetector is used when one shows up on the part
-- and otherwise Mouse.Target is polled on RenderStepped, gated behind a cheap
-- distance check so there is no real per-frame work away from the stand.
--
-- One central per-frame pass measures each rack part on its own, outlines only
-- the truly hovered one, and enables exactly one prompt: the hovered rack's,
-- or, with no mouse (gamepad/touch) or nothing hovered, the single rack the
-- player is within reach of.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared:WaitForChild("Log"))

local log = Log.new("ShopController")
local player = Players.LocalPlayer

local ShopController = {}

local STAND_WAIT_SECONDS = 15
local HOVER_TRANSPARENCY = 0.999
local IDLE_TRANSPARENCY = 1
local DEFAULT_RANGE = 10 -- ClickDetector / prompt MaxActivationDistance
local HOVERABLE_NAMES = { ShirtHL = true, PantsHL = true }

type HoverTarget = {
	part: BasePart,
	highlight: Highlight,
	connections: { RBXScriptConnection },
	prompt: ProximityPrompt?, -- cached; kept current by ChildAdded/ChildRemoved
	hovering: boolean, -- outline + hover transparency shown
	promptOn: boolean,
	detectorHover: boolean, -- set by a ClickDetector's hover events
	usingClickDetector: boolean,
	stocked: boolean, -- an empty (undressed, invisible) rack never highlights or shows a prompt
}

local targets: { [BasePart]: HoverTarget } = {}
local frameConnection: RBXScriptConnection? = nil
-- The stand's centre and reach, recomputed from the racks whenever one is
-- added or removed; the per-frame pass does nothing beyond it (plus a margin).
local STAND_MARGIN = 10 -- studs beyond the farthest rack part
local standCenter = Vector3.zero
local standRadius = 0
local boundsDirty = false
local allHidden = true
local mouse = player:GetMouse()

-- A rack is stocked while its rig's Shirt or Pants has a template; ShopService
-- blanks both when it undresses the rack. A part with no rack Model above it
-- counts as stocked.
local function isRackStocked(part: BasePart): boolean
	local rack = part:FindFirstAncestorOfClass("Model")
	if not rack then
		return true
	end
	local shirt = rack:FindFirstChildOfClass("Shirt")
	local pants = rack:FindFirstChildOfClass("Pants")
	if not (shirt or pants) then
		return true
	end
	return (shirt ~= nil and shirt.ShirtTemplate ~= "") or (pants ~= nil and pants.PantsTemplate ~= "")
end

local function rangeOf(target: HoverTarget): number
	local prompt = target.prompt
	return if prompt then prompt.MaxActivationDistance else DEFAULT_RANGE
end

local function recomputeBounds()
	boundsDirty = false
	local sum = Vector3.zero
	local count = 0
	for part in targets do
		sum += part.Position
		count += 1
	end
	if count == 0 then
		standRadius = 0
		return
	end
	standCenter = sum / count
	local farthest = 0
	for part, target in targets do
		farthest = math.max(farthest, (part.Position - standCenter).Magnitude + rangeOf(target))
	end
	standRadius = farthest + STAND_MARGIN
end

-- The server leaves every rack prompt Enabled with the default Exclusivity
-- (OnePerButton), so with many prompts on E in range the engine would show
-- only one arbitrary prompt. Only one prompt is enabled at a time, locally;
-- Triggered still fires server-side.
local function setState(target: HoverTarget, hovering: boolean, promptOn: boolean)
	if target.hovering ~= hovering then
		target.hovering = hovering
		target.part.Transparency = if hovering then HOVER_TRANSPARENCY else IDLE_TRANSPARENCY
		target.highlight.Enabled = hovering
	end
	local prompt = target.prompt
	target.promptOn = promptOn
	if prompt and prompt.Enabled ~= promptOn then
		prompt.Enabled = promptOn
	end
end

local function teardownTarget(part: BasePart)
	local target = targets[part]
	if not target then
		return
	end
	targets[part] = nil
	boundsDirty = true
	for _, connection in target.connections do
		connection:Disconnect()
	end
	if next(targets) == nil and frameConnection then
		frameConnection:Disconnect()
		frameConnection = nil
	end
end

local function hideAll()
	if allHidden then
		return
	end
	allHidden = true
	for _, target in targets do
		setState(target, false, false)
	end
end

local function refresh()
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (rootPart and rootPart:IsA("BasePart") and humanoid) or humanoid.Health <= 0 then
		hideAll()
		return
	end

	if boundsDirty then
		recomputeBounds()
	end
	local origin = rootPart.Position
	if (origin - standCenter).Magnitude > standRadius then
		hideAll() -- away from the stand: one hide on leaving, then nothing per frame
		return
	end
	allHidden = false
	local mouseTarget = mouse.Target
	local hoveredTarget: HoverTarget? = nil
	local hoveredDistance = math.huge
	local nearTarget: HoverTarget? = nil
	local nearCount = 0
	local nearDistance = math.huge

	for part, target in targets do
		local distance = (origin - part.Position).Magnitude
		if target.stocked and distance <= rangeOf(target) then
			nearCount += 1
			if distance < nearDistance then
				nearDistance = distance
				nearTarget = target
			end
			local pointed = if target.usingClickDetector then target.detectorHover else mouseTarget == part
			if pointed and distance < hoveredDistance then
				hoveredDistance = distance
				hoveredTarget = target
			end
		end
	end

	-- Nothing hovered: a single rack in reach keeps its prompt on (no mouse
	-- on gamepad/touch); with several in reach and no hover, none shows.
	local promptTarget = hoveredTarget
	if not promptTarget and nearCount == 1 then
		promptTarget = nearTarget
	end

	for _, target in targets do
		setState(target, target == hoveredTarget, target == promptTarget)
	end
end

local function ensureFrameLoop()
	if frameConnection then
		return
	end
	frameConnection = RunService.RenderStepped:Connect(refresh)
end

local function bindClickDetector(target: HoverTarget, clickDetector: ClickDetector)
	target.usingClickDetector = true
	target.detectorHover = false
	table.insert(
		target.connections,
		clickDetector.MouseHoverEnter:Connect(function(hoveringPlayer: Player)
			if hoveringPlayer == player then
				target.detectorHover = true
			end
		end)
	)
	table.insert(
		target.connections,
		clickDetector.MouseHoverLeave:Connect(function(hoveringPlayer: Player)
			if hoveringPlayer == player then
				target.detectorHover = false
			end
		end)
	)
end

local function registerTarget(part: BasePart)
	if targets[part] then
		return
	end

	local highlight = part:FindFirstChildOfClass("Highlight")
	if not highlight then
		-- The rig's own Highlight isn't parented yet; pick this part back up
		-- once it is, then stop watching.
		local waitConnection: RBXScriptConnection
		waitConnection = part.ChildAdded:Connect(function(child)
			if child:IsA("Highlight") then
				waitConnection:Disconnect()
				registerTarget(part)
			end
		end)
		return
	end

	local target: HoverTarget = {
		part = part,
		highlight = highlight,
		connections = {},
		prompt = part:FindFirstChildOfClass("ProximityPrompt"),
		hovering = false,
		promptOn = false,
		detectorHover = false,
		usingClickDetector = false,
		stocked = isRackStocked(part),
	}
	targets[part] = target
	setState(target, false, false)

	local function updateStocked()
		target.stocked = isRackStocked(part)
		if not target.stocked then
			setState(target, false, false)
		end
	end
	local rack = part:FindFirstAncestorOfClass("Model")
	if rack then
		local function watchClothing(child: Instance)
			if child:IsA("Shirt") then
				table.insert(target.connections, child:GetPropertyChangedSignal("ShirtTemplate"):Connect(updateStocked))
			elseif child:IsA("Pants") then
				table.insert(target.connections, child:GetPropertyChangedSignal("PantsTemplate"):Connect(updateStocked))
			else
				return
			end
			updateStocked()
		end
		for _, child in rack:GetChildren() do
			watchClothing(child)
		end
		table.insert(target.connections, rack.ChildAdded:Connect(watchClothing))
		table.insert(target.connections, rack.ChildRemoved:Connect(updateStocked))
	end

	-- A prompt the server adds (or re-adds on restock) after we registered
	-- starts hidden; the next frame's refresh decides if it shows.
	table.insert(
		target.connections,
		part.ChildAdded:Connect(function(child)
			if child:IsA("ProximityPrompt") then
				target.prompt = child
				child.Enabled = target.promptOn
			elseif child:IsA("ClickDetector") and not target.usingClickDetector then
				bindClickDetector(target, child)
			end
		end)
	)
	table.insert(
		target.connections,
		part.ChildRemoved:Connect(function(child)
			if child == target.prompt then
				target.prompt = part:FindFirstChildOfClass("ProximityPrompt")
			end
		end)
	)
	table.insert(
		target.connections,
		part.Destroying:Connect(function()
			teardownTarget(part)
		end)
	)

	boundsDirty = true
	allHidden = false
	local existingDetector = part:FindFirstChildOfClass("ClickDetector")
	if existingDetector then
		bindClickDetector(target, existingDetector)
	end
	ensureFrameLoop()
end

local function tryRegisterDescendant(instance: Instance)
	if HOVERABLE_NAMES[instance.Name] and instance:IsA("BasePart") then
		registerTarget(instance)
	end
end

local function watchStand(stand: Instance)
	stand.DescendantAdded:Connect(tryRegisterDescendant) -- the stand lives for the whole session
	for _, descendant in stand:GetDescendants() do
		tryRegisterDescendant(descendant)
	end
end

function ShopController:Init() end

function ShopController:Start()
	local qarzin = Workspace:FindFirstChild("Qarzin") or Workspace:WaitForChild("Qarzin", STAND_WAIT_SECONDS)
	if not qarzin then
		log:Warn("Workspace.Qarzin missing; clothes shop hover disabled")
		return
	end

	local stand = qarzin:FindFirstChild("ClothesStand") or qarzin:WaitForChild("ClothesStand", STAND_WAIT_SECONDS)
	if not stand then
		log:Warn("Workspace.Qarzin.ClothesStand missing; clothes shop hover disabled")
		return
	end

	watchStand(stand)
	log:Info("ready")
end

return ShopController

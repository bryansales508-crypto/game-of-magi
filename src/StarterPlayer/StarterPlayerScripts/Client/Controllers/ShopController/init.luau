--!strict
-- Client-only hover highlight for the Qarzin clothes shop (docs/M5-PLAN.md
-- Phase 5B, docs/reference/m5b-studio-dump.md sections 1-2).
--
-- Contract with the server (M5B-01, ShopService): it stocks
-- Workspace.Qarzin.ClothesStand and creates the ProximityPrompts (always
-- Enabled, RequiresLineOfSight = false, ActionText = the price); purchases
-- are entirely server-side (the prompt's Triggered is handled there) and
-- the server never touches each rack's Highlight child. This controller
-- only ever sets Highlight.Enabled / the part's Transparency LOCALLY, so
-- unlike the old script (which did this server-side and so was visible to
-- everyone) only the hovering player ever sees the outline. No prices are
-- computed here and no purchase is sent -- the client sends nothing new.
--
-- Hover mechanism (old script, m5b-studio-dump.md section 2): a
-- ClickDetector (MaxActivationDistance 10) on the ShirtHL/PantsHL part,
-- whose MouseHoverEnter/Leave set Transparency 0.999 / 1 and toggle the
-- Highlight child. The M5B-01 contract only promises the ProximityPrompts,
-- so this controller uses a ClickDetector when one shows up on the part
-- (from the server, or the rig itself) and otherwise falls back to
-- Mouse.Target polling on RenderStepped -- gated behind a cheap distance
-- check so it never does real per-frame work while the player is away
-- from the stand.
--
-- BUG-49 (M7-06): after M7-04 the racks showed neither prompt nor outline.
-- The poll was gated on distance to ONE anchor (the first rack registered),
-- so every other rack never polled and (prompts being disabled until hovered)
-- never showed anything. One central per-frame pass now measures each rack
-- part on its own, outlines only the truly hovered one, and enables exactly
-- one prompt: the hovered rack's, or -- with no mouse (gamepad/touch) or
-- nothing hovered -- the single rack the player is within reach of.

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
local DEFAULT_RANGE = 10 -- old ClickDetector's / prompt's MaxActivationDistance
local HOVERABLE_NAMES = { ShirtHL = true, PantsHL = true }

type HoverTarget = {
	part: BasePart,
	highlight: Highlight,
	connections: { RBXScriptConnection },
	hovering: boolean, -- outline + hover transparency shown
	promptOn: boolean,
	detectorHover: boolean, -- set by a ClickDetector's hover events
	usingClickDetector: boolean,
}

local targets: { [BasePart]: HoverTarget } = {}
local standConnections: { RBXScriptConnection } = {}
local frameConnection: RBXScriptConnection? = nil
local mouse = player:GetMouse()

local function findPrompt(part: BasePart): ProximityPrompt?
	return part:FindFirstChildOfClass("ProximityPrompt")
end

local function rangeOf(target: HoverTarget): number
	local prompt = findPrompt(target.part)
	return if prompt then prompt.MaxActivationDistance else DEFAULT_RANGE
end

-- BUG-39: the server leaves every rack prompt Enabled with the default
-- Exclusivity (OnePerButton), so with 18 prompts on E in range the engine
-- showed only ONE. Only one prompt is enabled at a time, locally; Triggered
-- still fires server-side.
local function setState(target: HoverTarget, hovering: boolean, promptOn: boolean)
	if target.hovering ~= hovering then
		target.hovering = hovering
		target.part.Transparency = if hovering then HOVER_TRANSPARENCY else IDLE_TRANSPARENCY
		target.highlight.Enabled = hovering
	end
	local prompt = findPrompt(target.part)
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
	for _, connection in target.connections do
		connection:Disconnect()
	end
end

local function hideAll()
	for _, target in targets do
		setState(target, false, false)
	end
end

local function refresh()
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not (rootPart and rootPart:IsA("BasePart")) then
		hideAll()
		return
	end

	local origin = rootPart.Position
	local mouseTarget = mouse.Target
	local hoveredTarget: HoverTarget? = nil
	local hoveredDistance = math.huge
	local nearTarget: HoverTarget? = nil
	local nearCount = 0
	local nearDistance = math.huge

	for part, target in targets do
		local distance = (origin - part.Position).Magnitude
		if distance <= rangeOf(target) then
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
		-- The rig's own Highlight (m5b-studio-dump.md section 1) not
		-- parented yet; pick this part back up once it is, then stop
		-- watching.
		local waitConnection: RBXScriptConnection
		waitConnection = part.ChildAdded:Connect(function(child)
			if child:IsA("Highlight") then
				waitConnection:Disconnect()
				registerTarget(part)
			end
		end)
		table.insert(standConnections, waitConnection)
		return
	end

	local target: HoverTarget = {
		part = part,
		highlight = highlight,
		connections = {},
		hovering = false,
		promptOn = false,
		detectorHover = false,
		usingClickDetector = false,
	}
	targets[part] = target
	setState(target, false, false)

	-- A prompt the server adds (or re-adds on restock) after we registered
	-- starts hidden; the next frame's refresh decides if it shows.
	table.insert(
		target.connections,
		part.ChildAdded:Connect(function(child)
			if child:IsA("ProximityPrompt") then
				child.Enabled = target.promptOn
			elseif child:IsA("ClickDetector") and not target.usingClickDetector then
				bindClickDetector(target, child)
			end
		end)
	)
	table.insert(
		target.connections,
		part.Destroying:Connect(function()
			teardownTarget(part)
		end)
	)

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
	table.insert(standConnections, stand.DescendantAdded:Connect(tryRegisterDescendant))
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

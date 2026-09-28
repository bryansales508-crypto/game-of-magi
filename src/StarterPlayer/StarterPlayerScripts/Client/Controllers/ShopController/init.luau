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
local HOVER_RANGE = 10 -- old ClickDetector's MaxActivationDistance
local POLL_GATE_RANGE = 12 -- only poll Mouse.Target within this of the stand
local HOVERABLE_NAMES = { ShirtHL = true, PantsHL = true }

type HoverTarget = {
	part: BasePart,
	highlight: Highlight,
	connections: { RBXScriptConnection },
	hovering: boolean,
	usingClickDetector: boolean,
}

local targets: { [BasePart]: HoverTarget } = {}
local pollCandidates: { [BasePart]: HoverTarget } = {}
local standAnchor: Vector3? = nil
local fallbackConnection: RBXScriptConnection? = nil
local mouse = player:GetMouse()

local function setHover(target: HoverTarget, hovering: boolean)
	if target.hovering == hovering then
		return
	end
	target.hovering = hovering
	target.part.Transparency = if hovering then HOVER_TRANSPARENCY else IDLE_TRANSPARENCY
	target.highlight.Enabled = hovering
end

local function teardownTarget(part: BasePart)
	local target = targets[part]
	if not target then
		return
	end
	targets[part] = nil
	pollCandidates[part] = nil
	for _, connection in target.connections do
		connection:Disconnect()
	end
end

local function pollHover()
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not (rootPart and rootPart:IsA("BasePart") and standAnchor) then
		return
	end

	if (rootPart.Position - standAnchor).Magnitude > POLL_GATE_RANGE then
		for _, target in pollCandidates do
			setHover(target, false)
		end
		return
	end

	local mouseTarget = mouse.Target
	for part, target in pollCandidates do
		local hovering = mouseTarget == part and (rootPart.Position - part.Position).Magnitude <= HOVER_RANGE
		setHover(target, hovering)
	end
end

local function ensureFallbackLoop()
	if fallbackConnection then
		return
	end
	fallbackConnection = RunService.RenderStepped:Connect(pollHover)
end

local function bindClickDetector(target: HoverTarget, clickDetector: ClickDetector)
	target.usingClickDetector = true
	pollCandidates[target.part] = nil
	setHover(target, false)

	table.insert(
		target.connections,
		clickDetector.MouseHoverEnter:Connect(function(hoveringPlayer: Player)
			if hoveringPlayer == player then
				setHover(target, true)
			end
		end)
	)
	table.insert(
		target.connections,
		clickDetector.MouseHoverLeave:Connect(function(hoveringPlayer: Player)
			if hoveringPlayer == player then
				setHover(target, false)
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
		return
	end

	local target: HoverTarget = {
		part = part,
		highlight = highlight,
		connections = {},
		hovering = false,
		usingClickDetector = false,
	}
	targets[part] = target

	if not standAnchor then
		standAnchor = part.Position
	end

	table.insert(
		target.connections,
		part.Destroying:Connect(function()
			teardownTarget(part)
		end)
	)

	local existingDetector = part:FindFirstChildOfClass("ClickDetector")
	if existingDetector then
		bindClickDetector(target, existingDetector)
	else
		pollCandidates[part] = target
		ensureFallbackLoop()
		table.insert(
			target.connections,
			part.ChildAdded:Connect(function(child)
				if child:IsA("ClickDetector") and not target.usingClickDetector then
					bindClickDetector(target, child :: ClickDetector)
				end
			end)
		)
	end
end

local function tryRegisterDescendant(instance: Instance)
	if HOVERABLE_NAMES[instance.Name] and instance:IsA("BasePart") then
		registerTarget(instance)
	end
end

local function watchStand(stand: Instance)
	stand.DescendantAdded:Connect(tryRegisterDescendant)
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

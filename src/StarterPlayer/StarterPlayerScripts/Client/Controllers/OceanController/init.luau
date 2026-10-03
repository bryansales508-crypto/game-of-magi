--!strict
-- The ocean, driven from one place. Off until Config.World.Ocean.Enabled (the
-- old per-part ocean scripts must be deleted first).
--
-- Every BasePart named MovingPart or OceanWaves under Workspace.MAP.OCEAN
-- is a tile: it rises Amplitude studs over RiseSeconds, holds HoldSeconds,
-- and falls over RiseSeconds. Every Decal under an OceanWaves fades to
-- DecalVisibleTransparency over DecalFadeSeconds, back, then pauses at 1 for
-- DecalPauseSeconds. Time is the shared server clock so everyone sees the
-- same swell. One Heartbeat; only tiles within CullDistance of the camera are
-- moved, in one BulkMoveTo call; nothing is allocated per frame.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Log = require(Shared:WaitForChild("Log"))

local log = Log.new("OceanController")
local ocean = Config.World.Ocean

local TILE_NAMES = { MovingPart = true, OceanWaves = true }
-- Decal writes below this change are skipped (the fade is slow).
local DECAL_EPSILON = 0.002

local OceanController = {}

local tiles: { BasePart } = {}
local bases: { CFrame } = {}
local tileIndex: { [BasePart]: number } = {}
local decals: { Decal } = {}
local decalIndex: { [Decal]: number } = {}

-- Reused every frame; BulkMoveTo needs arrays of exactly the moved size.
local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}
local movedLast = 0
local lastDecalTransparency = -1

local function addTile(part: BasePart)
	if tileIndex[part] ~= nil then
		return
	end
	table.insert(tiles, part)
	table.insert(bases, part.CFrame)
	tileIndex[part] = #tiles
end

local function removeTile(part: BasePart)
	local index = tileIndex[part]
	if index == nil then
		return
	end
	local last = #tiles
	if index ~= last then
		local moved = tiles[last]
		tiles[index] = moved
		bases[index] = bases[last]
		tileIndex[moved] = index
	end
	tiles[last] = nil :: any
	bases[last] = nil :: any
	tileIndex[part] = nil
end

local function addDecal(decal: Decal)
	if decalIndex[decal] ~= nil then
		return
	end
	table.insert(decals, decal)
	decalIndex[decal] = #decals
	if lastDecalTransparency >= 0 then
		decal.Transparency = lastDecalTransparency
	end
end

local function removeDecal(decal: Decal)
	local index = decalIndex[decal]
	if index == nil then
		return
	end
	local last = #decals
	if index ~= last then
		local moved = decals[last]
		decals[index] = moved
		decalIndex[moved] = index
	end
	decals[last] = nil :: any
	decalIndex[decal] = nil
end

local function consider(instance: Instance)
	if instance:IsA("BasePart") and TILE_NAMES[instance.Name] then
		addTile(instance)
	elseif instance:IsA("Decal") then
		local parent = instance.Parent
		if parent ~= nil and parent.Name == "OceanWaves" then
			addDecal(instance)
		end
	end
end

local function forget(instance: Instance)
	if instance:IsA("BasePart") then
		removeTile(instance)
	elseif instance:IsA("Decal") then
		removeDecal(instance)
	end
end

-- 0 -> 1 -> hold -> 1 -> 0, smoothed at both ends.
local function swell(now: number): number
	local rise = ocean.RiseSeconds
	local period = 2 * rise + ocean.HoldSeconds
	local u = now % period
	local s: number
	if u < rise then
		s = u / rise
	elseif u < rise + ocean.HoldSeconds then
		s = 1
	else
		s = 1 - (u - rise - ocean.HoldSeconds) / rise
	end
	return s * s * (3 - 2 * s)
end

-- Transparency over one decal cycle: pause at 1, fade in, fade out.
local function decalTransparency(now: number): number
	local fade = ocean.DecalFadeSeconds
	local u = now % (2 * fade + ocean.DecalPauseSeconds)
	local amount: number
	if u < ocean.DecalPauseSeconds then
		amount = 0
	elseif u < ocean.DecalPauseSeconds + fade then
		amount = (u - ocean.DecalPauseSeconds) / fade
	else
		amount = 1 - (u - ocean.DecalPauseSeconds - fade) / fade
	end
	return 1 - (1 - ocean.DecalVisibleTransparency) * amount
end

local function step()
	local now = Workspace:GetServerTimeNow()

	local camera = Workspace.CurrentCamera
	if camera ~= nil and #tiles > 0 then
		local offset = Vector3.new(0, ocean.Amplitude * swell(now), 0)
		local cameraPosition = camera.CFrame.Position
		local cullSquared = ocean.CullDistance * ocean.CullDistance
		local count = 0
		for i = 1, #tiles do
			local base = bases[i]
			local delta = base.Position - cameraPosition
			if delta:Dot(delta) <= cullSquared then
				count += 1
				moveParts[count] = tiles[i]
				moveCFrames[count] = base + offset
			end
		end
		for i = count + 1, movedLast do
			moveParts[i] = nil :: any
			moveCFrames[i] = nil :: any
		end
		movedLast = count
		if count > 0 then
			Workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
		end
	end

	local transparency = decalTransparency(now)
	if math.abs(transparency - lastDecalTransparency) >= DECAL_EPSILON then
		lastDecalTransparency = transparency
		for i = 1, #decals do
			decals[i].Transparency = transparency
		end
	end
end

function OceanController:Init() end

function OceanController:Start()
	if not ocean.Enabled then
		return
	end
	local map = Workspace:WaitForChild("MAP", 30)
	local root = if map ~= nil then map:WaitForChild("OCEAN", 30) else nil
	if root == nil then
		log:Warn("Workspace.MAP.OCEAN not found; ocean stays still")
		return
	end

	for _, descendant in root:GetDescendants() do
		consider(descendant)
	end
	-- The controller lives as long as the client, so these are never dropped.
	root.DescendantAdded:Connect(consider)
	root.DescendantRemoving:Connect(forget)
	RunService.Heartbeat:Connect(step)
	log:Info("ocean driving", #tiles, "tiles and", #decals, "decals")
end

return OceanController

--!strict
-- Collision groups for the map. Every BasePart under Workspace.MAP (Unions included) joins
-- MapCollisionGroup unless it sits under a folder named "Areas"; every BasePart inside a model
-- named "ClothingRack" anywhere under Workspace joins ClothingRackGroup (players walk through
-- racks; CharacterService registers PlayerLimbs and makes it ignore the rack group). Runs at
-- Init with no game.Loaded wait and keeps listening to MAP.DescendantAdded. ShopService changes
-- a rack's group itself when it is dressed or undressed.

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.new("CollisionService")

local MAP_GROUP = "MapCollisionGroup"
local RACK_GROUP = "ClothingRackGroup"
local AREAS_FOLDER = "Areas"
local RACK_MODEL = "ClothingRack"

local CollisionService = {}

local function registerGroup(name: string)
	if not PhysicsService:IsCollisionGroupRegistered(name) then
		PhysicsService:RegisterCollisionGroup(name)
	end
end

local function inRack(part: Instance): boolean
	local ancestor = part.Parent
	while ancestor ~= nil and ancestor ~= Workspace do
		if ancestor.Name == RACK_MODEL and ancestor:IsA("Model") then
			return true
		end
		ancestor = ancestor.Parent
	end
	return false
end

-- Puts one part in the right group. Rack parts win over map parts. Returns
-- "Map", "Rack" or nil (not a BasePart, or excluded under Areas).
function CollisionService.AssignMapPart(part: Instance): string?
	if not part:IsA("BasePart") then
		return nil
	end
	if inRack(part) then
		part.CollisionGroup = RACK_GROUP
		return "Rack"
	end
	if part:FindFirstAncestor(AREAS_FOLDER) ~= nil then
		return nil
	end
	part.CollisionGroup = MAP_GROUP
	return "Map"
end

-- Assigns every descendant of `root`; returns (mapCount, rackCount).
function CollisionService.AssignTree(root: Instance): (number, number)
	local mapCount, rackCount = 0, 0
	for _, descendant in root:GetDescendants() do
		local kind = CollisionService.AssignMapPart(descendant)
		if kind == "Map" then
			mapCount += 1
		elseif kind == "Rack" then
			rackCount += 1
		end
	end
	return mapCount, rackCount
end

function CollisionService:Init()
	registerGroup(MAP_GROUP)
	registerGroup(RACK_GROUP)

	local mapCount, rackCount = 0, 0
	local map = Workspace:FindFirstChild("MAP")
	if map then
		mapCount, rackCount = CollisionService.AssignTree(map)
		map.DescendantAdded:Connect(function(descendant: Instance)
			CollisionService.AssignMapPart(descendant)
		end)
	else
		log:Warn("Workspace.MAP not found; no map parts assigned")
	end

	-- Racks outside MAP.
	for _, descendant in Workspace:GetDescendants() do
		if descendant:IsA("BasePart") and (map == nil or not descendant:IsDescendantOf(map)) and inRack(descendant) then
			descendant.CollisionGroup = RACK_GROUP
			rackCount += 1
		end
	end

	log:Info(string.format("assigned %d map parts, %d clothing-rack parts", mapCount, rackCount))
end

function CollisionService:Start() end

return CollisionService

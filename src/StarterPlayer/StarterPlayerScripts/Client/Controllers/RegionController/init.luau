--!strict
-- Which regions is my character standing in? (M6 Phase 6A, docs/M6-PLAN.md)
--
-- Every BasePart named "<Key>REGION" under Workspace.Regions (a folder may
-- group several parts into one region) is a box. Every
-- Config.World.Music.RegionPollSeconds the local root part's position is
-- tested against each box with pure math: no Touched, no physics queries, so
-- teleporting or walking through walls can never leave you in the wrong
-- region. Entered/Left fire locally for the music and the banner.
--
-- Respawn-safe: the set is re-evaluated when a character appears and
-- everything is left when it is removed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Log = require(Shared:WaitForChild("Log"))
local Regions = require(Shared:WaitForChild("Data"):WaitForChild("Regions"))

local log = Log.new("RegionController")

local player = Players.LocalPlayer

local SUFFIX = "REGION"

local RegionController = {}

local partKeys: { [BasePart]: string } = {}
local inside: { [string]: boolean } = {}
local scratch: { [string]: boolean } = {}
local listenersEntered: { [number]: (key: string) -> () } = {}
local listenersLeft: { [number]: (key: string) -> () } = {}
local nextListenerId = 0
local warnedUnknown: { [string]: boolean } = {}
local character: Model? = nil

local function keyOf(part: Instance): string?
	if not part:IsA("BasePart") then
		return nil
	end
	local name = part.Name
	if #name <= #SUFFIX or string.sub(name, -#SUFFIX) ~= SUFFIX then
		return nil
	end
	return string.sub(name, 1, #name - #SUFFIX)
end

local function fire(listeners: { [number]: (key: string) -> () }, key: string)
	for _, listener in listeners do
		task.spawn(listener, key)
	end
end

local function rootPosition(): Vector3?
	local model = character
	if model == nil or model.Parent == nil then
		return nil
	end
	local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	if root ~= nil and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

local function contains(part: BasePart, point: Vector3): boolean
	local local_ = part.CFrame:PointToObjectSpace(point)
	local half = part.Size * 0.5
	return math.abs(local_.X) <= half.X and math.abs(local_.Y) <= half.Y and math.abs(local_.Z) <= half.Z
end

local function evaluate()
	table.clear(scratch)
	local position = rootPosition()
	if position ~= nil then
		for part, key in partKeys do
			if not scratch[key] and contains(part, position) then
				scratch[key] = true
			end
		end
	end

	-- Entered first, then Left, so a hand-over between two regions never
	-- passes through "nowhere" for the music.
	for key in scratch do
		if not inside[key] then
			inside[key] = true
			fire(listenersEntered, key)
		end
	end
	for key in inside do
		if not scratch[key] then
			inside[key] = nil
			fire(listenersLeft, key)
		end
	end
end

local function addPart(part: Instance)
	local key = keyOf(part)
	if key == nil or partKeys[part :: BasePart] ~= nil then
		return
	end
	local basePart = part :: BasePart
	if Regions[key] == nil and not warnedUnknown[key] then
		warnedUnknown[key] = true
		log:Warn("region part", part:GetFullName(), "has no entry in Shared/Data/Regions for", key)
	end
	partKeys[basePart] = key
end

local function removePart(part: Instance)
	if partKeys[part :: BasePart] == nil then
		return
	end
	partKeys[part :: BasePart] = nil
end

local function watchFolder(folder: Instance)
	for _, descendant in folder:GetDescendants() do
		addPart(descendant)
	end
	folder.DescendantAdded:Connect(addPart)
	folder.DescendantRemoving:Connect(removePart)
end

local function setCharacter(model: Model?)
	character = model
	evaluate()
end

-- Sorted by priority, highest first (ties by name, so it is stable).
function RegionController.Current(): { string }
	local list: { string } = {}
	for key in inside do
		table.insert(list, key)
	end
	table.sort(list, function(a, b)
		local pa = if Regions[a] then Regions[a].priority else 0
		local pb = if Regions[b] then Regions[b].priority else 0
		if pa ~= pb then
			return pa > pb
		end
		return a < b
	end)
	return list
end

function RegionController.IsInside(key: string): boolean
	return inside[key] == true
end

-- Returns a function that removes the listener.
function RegionController.OnEntered(listener: (key: string) -> ()): () -> ()
	nextListenerId += 1
	local id = nextListenerId
	listenersEntered[id] = listener
	return function()
		listenersEntered[id] = nil
	end
end

function RegionController.OnLeft(listener: (key: string) -> ()): () -> ()
	nextListenerId += 1
	local id = nextListenerId
	listenersLeft[id] = listener
	return function()
		listenersLeft[id] = nil
	end
end

function RegionController:Init() end

function RegionController:Start()
	task.spawn(function()
		local folder = Workspace:WaitForChild("Regions", 30)
		if folder == nil then
			log:Warn("Workspace.Regions not found; no regions this session")
			return
		end
		watchFolder(folder)
		evaluate()
	end)

	player.CharacterAdded:Connect(setCharacter)
	player.CharacterRemoving:Connect(function()
		setCharacter(nil)
	end)
	if player.Character ~= nil then
		setCharacter(player.Character)
	end

	-- The only recurring work: one small loop, once per poll interval.
	task.spawn(function()
		while true do
			task.wait(Config.World.Music.RegionPollSeconds)
			if character ~= nil then
				evaluate()
			end
		end
	end)
end

return RegionController

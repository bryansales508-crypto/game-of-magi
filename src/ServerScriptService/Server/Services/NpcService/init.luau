--!strict
-- Behavior-tree NPCs (M3-04, TRIAGE #20, fixes AUDIT M19). "Man was bad.
-- Use behavior trees if at all possible. NPCs should be treated like
-- normal players but with obvious AI controllers." (Bryan, 2026-09-27)
--
-- Every NPC registers with StatusService, MovementService and
-- CombatService exactly the way a player's character does on
-- PlayerService.Ready (M3-01/02/03's own design rule) - it takes hits,
-- blocks, staggers, gets knocked and recovers through the identical code
-- path, keyed by its character Model, never a Player. One shared loop
-- ticks every NPC's tree (not a thread per NPC), same reasoning as
-- StatusService's shared expiry loop: nothing to leak on respawn.
--
-- Dummy models stay in Workspace as art, untouched; this service only
-- finds and drives them. AUDIT M19's actual bugs (comp() using
-- connections before they exist, failureProtection never resetting,
-- wayp[2] indexed unchecked) don't carry over: the old NPCFetch/
-- NPController design isn't ported, just its numbers (chase/give-up/
-- attack range, TRIAGE #20's own instruction).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")

local Log = require(ReplicatedStorage.Shared.Log)
local Config = require(ReplicatedStorage.Shared.Config)
local StatusService = require(script.Parent.StatusService)
local MovementService = require(script.Parent.MovementService)
local CombatService = require(script.Parent.CombatService)
local DevService = require(script.Parent.DevService)
local AiController = require(script.AiController)
local Trees = require(script.Trees)

local log = Log.new("NpcService")

local NPC_TAG = "NPC"
local TEMPLATES_FOLDER_NAME = "NpcTemplates"

local controllers: { [Model]: AiController.AiController } = {}
local templatesFolder: Folder? = nil

local NpcService = {}

-- ==================== helpers ====================

local function getTemplatesFolder(): Folder
	if templatesFolder then
		return templatesFolder
	end

	local existing = ServerStorage:FindFirstChild(TEMPLATES_FOLDER_NAME)
	if existing and not existing:IsA("Folder") then
		existing:Destroy()
		existing = nil
	end

	local folder: Folder
	if existing and existing:IsA("Folder") then
		folder = existing
	else
		local created = Instance.new("Folder")
		created.Name = TEMPLATES_FOLDER_NAME
		created.Parent = ServerStorage
		folder = created
	end

	templatesFolder = folder
	return folder
end

function NpcService.ResolveNpcType(model: Instance): string
	local attr = model:GetAttribute("NpcType")
	if attr == "Dummy" or attr == "Target" then
		return attr :: string
	end
	local child = model:FindFirstChild("NpcType")
	if child and child:IsA("StringValue") and (child.Value == "Dummy" or child.Value == "Target") then
		return child.Value
	end
	return "Dummy"
end

local function buildTree(npcType: string)
	if npcType == "Target" then
		return Trees.BuildTarget()
	end
	return Trees.BuildDummy()
end

local function unregisterNpc(model: Model)
	controllers[model] = nil
	StatusService.Unregister(model)
	MovementService.Unregister(model)
	CombatService.Unregister(model)
end

-- Forward-declared: setupNpc's own AncestryChanged handler re-clones from
-- the template and calls back into setupNpc for the fresh copy.
local setupNpc: (model: Model) -> ()

setupNpc = function(model: Model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local rootPart = model:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or rootPart == nil or not rootPart:IsA("BasePart") then
		log:Warn(string.format("%s has no Humanoid/HumanoidRootPart; not registering as an NPC", model.Name))
		return
	end

	local npcType = NpcService.ResolveNpcType(model)
	local maxHealth = Config.Npc.MaxHealth[npcType] or Config.Npc.MaxHealth.Dummy
	humanoid.MaxHealth = maxHealth
	humanoid.Health = maxHealth
	pcall(function()
		model:SetAttribute("NpcType", npcType)
	end)

	local templates = getTemplatesFolder()
	if templates:FindFirstChild(model.Name) == nil then
		local ok, clone = pcall(function()
			return model:Clone()
		end)
		if ok then
			(clone :: Model).Parent = templates
		else
			log:Warn(string.format("couldn't template %s: %s", model.Name, tostring(clone)))
		end
	end

	StatusService.Register(model, nil)
	MovementService.Register(model, nil)
	CombatService.Register(model, nil, "Fist")

	local controller = AiController.new(model, npcType, buildTree(npcType))
	if controller then
		controllers[model] = controller
	end

	-- AUDIT M19's actual bug was giving up forever after one bad chase;
	-- here, losing the model entirely just respawns a fresh one from its
	-- template at the same spot, with a brand-new AiController (Wander
	-- re-acquires on its own - no permanent "gave up" flag to get stuck in).
	local spawnCFrame = (rootPart :: BasePart).CFrame
	local spawnParent = model.Parent

	local ancestryConn: RBXScriptConnection
	ancestryConn = model.AncestryChanged:Connect(function(_child, parent)
		if parent ~= nil then
			return
		end
		ancestryConn:Disconnect()
		unregisterNpc(model)

		task.spawn(function()
			local template = getTemplatesFolder():FindFirstChild(model.Name)
			if template == nil or not template:IsA("Model") or spawnParent == nil then
				return
			end
			local ok, fresh = pcall(function()
				local f = (template :: Model):Clone()
				f:PivotTo(spawnCFrame)
				f.Parent = spawnParent
				return f
			end)
			if ok then
				setupNpc(fresh :: Model)
			else
				log:Warn(string.format("couldn't respawn %s: %s", model.Name, tostring(fresh)))
			end
		end)
	end)
end

local function isNpcModel(instance: Instance): Model?
	if not instance:IsA("Model") then
		return nil
	end
	if instance:FindFirstChildOfClass("Humanoid") == nil then
		return nil
	end
	return instance
end

local function discoverExisting()
	local npcFolder = Workspace:FindFirstChild("NPC")
	if npcFolder then
		for _, child in npcFolder:GetChildren() do
			local model = isNpcModel(child)
			if model and controllers[model] == nil then
				setupNpc(model)
			end
		end
	end

	for _, tagged in CollectionService:GetTagged(NPC_TAG) do
		local model = isNpcModel(tagged)
		if model and controllers[model] == nil then
			setupNpc(model)
		end
	end
end

local function watchForNew()
	local npcFolder = Workspace:FindFirstChild("NPC")
	if npcFolder then
		npcFolder.ChildAdded:Connect(function(child: Instance)
			local model = isNpcModel(child)
			if model and controllers[model] == nil then
				setupNpc(model)
			end
		end)
	end

	CollectionService:GetInstanceAddedSignal(NPC_TAG):Connect(function(instance: Instance)
		local model = isNpcModel(instance)
		if model and controllers[model] == nil then
			setupNpc(model)
		end
	end)
end

-- ==================== dev commands ====================

local function registerDevCommands()
	DevService.Register("npc", "list|reset|type <name> Dummy|Target", function(_caller, args)
		local sub = args[1]
		if sub == "list" then
			if next(controllers) == nil then
				return "No NPCs registered"
			end
			local lines: { string } = {}
			for model, controller in controllers do
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				table.insert(
					lines,
					string.format(
						"%s (%s): %.0f/%.0f hp%s",
						model.Name,
						controller.npcType,
						if humanoid then humanoid.Health else 0,
						if humanoid then humanoid.MaxHealth else 0,
						if StatusService.Has(model, "Knocked") then " [knocked]" else ""
					)
				)
			end
			return table.concat(lines, "\n")
		elseif sub == "reset" then
			local names: { string } = {}
			for model in controllers do
				table.insert(names, model.Name)
				model:Destroy()
			end
			return string.format("Reset %d NPC(s): %s", #names, table.concat(names, ", "))
		elseif sub == "type" then
			local name = args[2]
			local npcType = args[3]
			if name == nil or (npcType ~= "Dummy" and npcType ~= "Target") then
				return "usage: .npc type <name> Dummy|Target"
			end
			for model in controllers do
				if model.Name == name then
					unregisterNpc(model)
					pcall(function()
						model:SetAttribute("NpcType", npcType)
					end)
					setupNpc(model)
					return string.format("%s is now %s", name, npcType)
				end
			end
			return string.format("no NPC named %q", name)
		end
		return "usage: .npc list|reset|type <name> Dummy|Target"
	end)
end

-- ==================== service ====================

function NpcService:Init()
	registerDevCommands()
end

function NpcService:Start()
	discoverExisting()
	watchForNew()

	task.spawn(function()
		while true do
			task.wait(Config.Npc.TickSeconds)
			for _, controller in controllers do
				local ok, err = pcall(function()
					controller:Tick()
				end)
				if not ok then
					log:Error(string.format("%s AI tick errored: %s", controller.character.Name, tostring(err)))
				end
			end
		end
	end)
end

return NpcService

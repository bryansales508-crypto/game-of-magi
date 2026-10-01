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
local HealthService = require(script.Parent.HealthService)
local StatusService = require(script.Parent.StatusService)
local MovementService = require(script.Parent.MovementService)
local CombatService = require(script.Parent.CombatService)
local DevService = require(script.Parent.DevService)
local AiController = require(script.AiController)
local Trees = require(script.Trees)

local log = Log.new("NpcService")

local NPC_TAG = "NPC"
local TEMPLATES_FOLDER_NAME = "NpcTemplates"
local TRAINERS_FOLDER_NAME = "Trainers"

local controllers: { [Model]: AiController.AiController } = {}
local templatesFolder: Folder? = nil
local trainersFolder: Folder? = nil

-- M3B-02: every currently-spawned training dummy, keyed by its own
-- character Model (so `.dummy clear`/list and the knockout-reset
-- subscriber below can tell a trainer apart from a Dummy/Target NPC without
-- another attribute round-trip). Never auto-discovered/respawned the way
-- Workspace.NPC's own children are - `.dummy spawn`/`clear` own their
-- lifetime outright.
local trainers: { [Model]: { key: string } } = {}

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

-- M3B-02: trainers live in their own Workspace folder, never Workspace.NPC -
-- that folder's own ChildAdded (watchForNew below) would otherwise
-- auto-register a spawned trainer a second time, as a plain Dummy, clobbering
-- the trainer controller/tree this module just built for it.
local function getTrainersFolder(): Folder
	if trainersFolder then
		return trainersFolder
	end

	local existing = Workspace:FindFirstChild(TRAINERS_FOLDER_NAME)
	if existing and not existing:IsA("Folder") then
		existing:Destroy()
		existing = nil
	end

	local folder: Folder
	if existing and existing:IsA("Folder") then
		folder = existing
	else
		local created = Instance.new("Folder")
		created.Name = TRAINERS_FOLDER_NAME
		created.Parent = Workspace
		folder = created
	end

	trainersFolder = folder
	return folder
end

-- "the one under ServerStorage.NpcTemplates from M3-04; if two templates
-- exist use the Dummy one" - templates are keyed by the source model's own
-- Name (setupNpc below), so this prefers one literally named "Dummy" and
-- falls back to whatever else got templated first.
local function findDummyTemplate(): Model?
	local templates = getTemplatesFolder()
	local named = templates:FindFirstChild("Dummy")
	if named and named:IsA("Model") then
		return named
	end
	for _, child in templates:GetChildren() do
		if child:IsA("Model") then
			return child
		end
	end
	return nil
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
	HealthService.Unregister(model)
	StatusService.Unregister(model)
	MovementService.Unregister(model)
	CombatService.Unregister(model)
end

-- ==================== training dummies (M3B-02) ====================

-- Bryan's menu style (docs/TINKER.md: name (255,224,152), Merriweather) on
-- a dark card, over the head - same read as any other name tag.
local function addTrainerNameTag(model: Model, displayName: string)
	local head = model:FindFirstChild("Head")
	local attachTo = if head and head:IsA("BasePart") then head else model:FindFirstChild("HumanoidRootPart")
	if attachTo == nil or not attachTo:IsA("BasePart") then
		return
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "TrainerNameTag"
	gui.Size = UDim2.fromScale(4, 1.2)
	gui.StudsOffset = Vector3.new(0, 1.5, 0)
	gui.AlwaysOnTop = true

	local card = Instance.new("Frame")
	card.Size = UDim2.fromScale(1, 1)
	card.BackgroundColor3 = Color3.fromRGB(20, 16, 10)
	card.BackgroundTransparency = 0.2
	card.BorderSizePixel = 0
	card.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = card

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = displayName
	label.TextColor3 = Color3.fromRGB(255, 224, 152)
	label.FontFace = Font.new(Font.fromEnum(Enum.Font.Merriweather).Family, Enum.FontWeight.Regular, Enum.FontStyle.Normal)
	label.TextScaled = true
	label.Parent = card

	gui.Parent = attachTo :: BasePart
end

-- Clones the Dummy template 6 studs in front of `targetPlayer`, facing
-- them, registers it through the exact same HealthService/StatusService/
-- MovementService/CombatService.Register calls setupNpc uses for any other
-- NPC (so it takes hits, blocks and gets knocked identically), but with
-- Trees.BuildTrainer(key)'s own tree instead of buildTree's Dummy/Target
-- pick, and never auto-respawns.
local function spawnTrainer(caller: Player, key: string, targetPlayer: Player): (Model?, string?)
	local cfg = Config.Npc.Trainers[key]
	if cfg == nil then
		return nil, string.format("no trainer named %q", key)
	end

	local template = findDummyTemplate()
	if template == nil then
		return nil, "no dummy template found yet (a Dummy NPC has to exist in the place at least once first)"
	end

	local playerCharacter = targetPlayer.Character
	local playerRoot = playerCharacter and playerCharacter:FindFirstChild("HumanoidRootPart")
	if playerCharacter == nil or playerRoot == nil or not playerRoot:IsA("BasePart") then
		return nil, string.format("%s has no character to spawn against", targetPlayer.Name)
	end

	local playerCFrame = (playerRoot :: BasePart).CFrame
	local spawnPosition = playerCFrame.Position + playerCFrame.LookVector * 6
	local spawnCFrame = CFrame.lookAt(spawnPosition, playerCFrame.Position)

	local ok, cloneOrErr = pcall(function()
		return template:Clone()
	end)
	if not ok then
		return nil, string.format("couldn't clone the dummy template: %s", tostring(cloneOrErr))
	end
	local model = cloneOrErr :: Model
	model.Name = string.format("Trainer_%s", key)

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local rootPart = model:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or rootPart == nil or not rootPart:IsA("BasePart") then
		model:Destroy()
		return nil, "the dummy template has no Humanoid/HumanoidRootPart"
	end

	pcall(function()
		model:SetAttribute("NpcType", "Dummy")
	end)
	model:PivotTo(spawnCFrame)
	model.Parent = getTrainersFolder()

	HealthService.Register(model, { maxHealth = Config.Npc.MaxHealth.Dummy })
	StatusService.Register(model, nil)
	MovementService.Register(model, nil)
	CombatService.Register(model, nil, "Fist")
	pcall(function()
		model:SetAttribute("InCombat", true)
	end)

	local controller = AiController.new(model, "Dummy", Trees.BuildTrainer(key))
	if controller == nil then
		unregisterNpc(model)
		model:Destroy()
		return nil, "couldn't build the trainer's AI controller"
	end
	controller.blackboard.trainerKey = key
	controller.blackboard.spawner = targetPlayer
	controller.blackboard.engageRadius = cfg.engageRadius or 12
	controllers[model] = controller
	trainers[model] = { key = key }
	-- Tagged AFTER controllers[model] is set, so watchForNew's own tag
	-- listener sees it as already registered. The client's
	-- NpcAnimController animates every tagged NPC.
	CollectionService:AddTag(model, NPC_TAG)

	addTrainerNameTag(model, cfg.displayName or key)

	local ancestryConn: RBXScriptConnection
	ancestryConn = model.AncestryChanged:Connect(function(_child, parent)
		if parent ~= nil then
			return
		end
		ancestryConn:Disconnect()
		trainers[model] = nil
		unregisterNpc(model)
	end)

	log:Info(string.format("%s spawned trainer %s (%s) for %s", caller.Name, key, cfg.displayName or key, targetPlayer.Name))
	return model, nil
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

	-- REVIEW-M3-04 H1: an NPC takes the identical health path as a player
	-- now - HealthService.Register sets MaxHealth/Health itself (from
	-- Config.Npc.MaxHealth, not the rank ladder a player's own
	-- HealthService.Ready path uses).
	HealthService.Register(model, { maxHealth = maxHealth })
	StatusService.Register(model, nil)
	MovementService.Register(model, nil)
	CombatService.Register(model, nil, "Fist")
	-- M3B-01: NPCs don't earn or toggle the combat stance - they're always
	-- in it, so CombatService.Attack/SetBlocking work for them exactly as
	-- before the stance existed.
	pcall(function()
		model:SetAttribute("InCombat", true)
	end)

	local controller = AiController.new(model, npcType, buildTree(npcType))
	if controller then
		controllers[model] = controller
	end
	-- Every registered NPC carries the tag (the template clone above was
	-- taken before this, so a re-clone starts untagged and gets it here
	-- again). Set after controllers[model], so watchForNew's own tag
	-- listener sees it as already registered. The client's
	-- NpcAnimController animates every tagged NPC.
	CollectionService:AddTag(model, NPC_TAG)

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

	-- M3B-02.
	DevService.Register("dummy", "spawn <name> [player] | clear | list", function(caller, args)
		local sub = args[1]
		if sub == "spawn" then
			local key = args[2]
			if key == nil then
				return "usage: .dummy spawn <name> [player]"
			end
			local targetPlayer, err = DevService.ResolvePlayer(caller, args[3])
			if targetPlayer == nil then
				return err or "player not found"
			end
			local model, spawnErr = spawnTrainer(caller, key, targetPlayer)
			if model == nil then
				return spawnErr or "couldn't spawn the trainer"
			end
			return string.format("Spawned %s for %s", key, targetPlayer.Name)
		elseif sub == "clear" then
			local names: { string } = {}
			for model in trainers do
				table.insert(names, model.Name)
				trainers[model] = nil
				unregisterNpc(model)
				model:Destroy()
			end
			return string.format("Cleared %d trainer(s): %s", #names, table.concat(names, ", "))
		elseif sub == "list" then
			local lines: { string } = { "Trainers (spawn order):" }
			for _, key in Config.Npc.TrainerOrder do
				local cfg = Config.Npc.Trainers[key]
				local liveCount = 0
				for _, info in trainers do
					if info.key == key then
						liveCount += 1
					end
				end
				table.insert(
					lines,
					string.format(
						"  %s (%s)%s",
						cfg and cfg.displayName or key,
						key,
						if liveCount > 0 then string.format(" - %d live", liveCount) else ""
					)
				)
			end
			return table.concat(lines, "\n")
		end
		return "usage: .dummy spawn <name> [player] | clear | list"
	end)
end

-- ==================== service ====================

function NpcService:Init()
	registerDevCommands()
end

function NpcService:Start()
	discoverExisting()
	watchForNew()

	-- M3B-02: trainers reset after a knockout - full health, Bleed cleared,
	-- HitCount back to 0 - instead of the general Combat.Knockout.
	-- healthOnGetUp partial heal every other combatant gets, so a lesson
	-- doesn't stay half-broken for the next player to try it. One shared
	-- subscriber, same reasoning as CombatService's own single onStatusChanged
	-- owner: it fires for every combatant, `trainers` is just the filter.
	StatusService.Changed:Connect(function(character: Model, status: string, active: boolean)
		if status ~= "Knocked" or active or trainers[character] == nil then
			return
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Health = humanoid.MaxHealth
		end
		StatusService.Remove(character, "Bleed")
		pcall(function()
			character:SetAttribute("HitCount", 0)
		end)
	end)

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

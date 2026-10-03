--!strict
-- Builds a character's look from the save: strips the default Roblox avatar, then
-- rebuilds skin, FalseHead face, hair colour, combat hitbox, the shared collision
-- group, sounds/particles, the saved (or a fresh starter) outfit, hats, and the
-- custom run/walk/jump/idle/fall animations. Waits for CreateCharacter on a
-- brand-new life; the gender/skin picker is a client screen shown while Player
-- attribute Gender == 0.

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local SaveSchema = require(ReplicatedStorage.Shared.SaveSchema)
local Assets = require(ReplicatedFirst.Assets) :: any
local ItemService = require(script.Parent.ItemService)
local DataService = require(script.Parent.DataService)
local PlayerService = require(script.Parent.PlayerService)
local AgeService = require(script.Parent.AgeService)
local AgeHandler = require(script.Parent.AgeService.AgeHandler)
local FaceControl = require(script.FaceControl)

local log = Log.new("CharacterService")

type Data = SaveSchema.Data

-- One collision group for every player, registered once (Roblox allows only 32 groups).
local COLLISION_GROUP = "PlayerLimbs"
local CLOTHING_RACK_GROUP = "ClothingRackGroup"

-- Display-only: HeightStuds = Height (HeightHandler's body-scale ratio, ~0.75-1.25)
-- times a nominal default rig height, so menus can show a stud figure.
local BASE_HUMAN_HEIGHT_STUDS = 5

local WAIT_TIMEOUT = 10

local CharacterService = {}


-- Skin templates are chosen by name: 1 Black, 2 Brown, 3 White, with kingdom
-- overrides (Kingdom 1 swaps White for LightTan; Kingdom 2 swaps Black for Tan
-- and Brown for LightTan).
function CharacterService.SkinTemplateName(skinTone: number, kingdom: number): string
	local base: string
	if skinTone == 1 then
		base = "Black"
	elseif skinTone == 2 then
		base = "Brown"
	else
		base = "White"
	end

	if kingdom == 1 and base == "White" then
		return "LightTan"
	elseif kingdom == 2 and base == "Black" then
		return "Tan"
	elseif kingdom == 2 and base == "Brown" then
		return "LightTan"
	end
	return base
end

-- Gender-matched first name; SaveSchema.NewLife's roll is only a placeholder that
-- CreateCharacter overwrites.
local warnedNoFemaleNames = false
local function rollFirstName(gender: number): string
	local names = Assets.FirstNames.sindria
	local list = if gender == 2 then names.female else names.male
	if gender == 2 and (list == nil or #list == 0) then
		if not warnedNoFemaleNames then
			warnedNoFemaleNames = true
			log:Warn("Assets.FirstNames.sindria.female is empty; using the male list instead")
		end
		list = names.male
	end
	return list[math.random(1, #list)]
end

-- Applies one CreateCharacter call against `data` directly (no DataService/Remotes),
-- so SelfTestService can test validation with a fake save. The remote handler
-- calls this, then refreshes the legacy bridge and the player's attributes.
function CharacterService.ApplyCreateCharacter(data: Data, gender: number, skin: number): boolean
	if data.Character.Gender ~= 0 then
		return false
	end
	if gender ~= 1 and gender ~= 2 then
		return false
	end
	if skin ~= 1 and skin ~= 2 and skin ~= 3 then
		return false
	end

	data.Character.Gender = gender
	data.Character.SkinTone = skin
	data.Character.FirstName = rollFirstName(gender)
	return true
end


-- Stand-in for a Stats Value folder: RF.Assets' facebase/mouthshape/eyecolor/eyebrow
-- functions read `stat["Field"].Value`. It must cover every key they read (Gender,
-- FaceBase, Race, EyeColor, MouthShape, HairColor; eyebrow reads HairColor as a
-- Color3): a missing key throws and aborts the build. SelfTestService checks this
-- list stays complete.
function CharacterService.StatShim(data: Data): any
	return {
		Gender = { Value = data.Character.Gender },
		FaceBase = { Value = data.Character.FaceBase },
		MouthShape = { Value = data.Character.MouthShape },
		EyeColor = { Value = data.Character.EyeColor },
		Race = { Value = data.Character.Race },
		HairColor = { Value = Color3.new(data.Character.HairColor.R, data.Character.HairColor.G, data.Character.HairColor.B) },
	}
end
local statShim = CharacterService.StatShim

local function stripDefaultAvatar(character: Model)
	for _, child in character:GetChildren() do
		if child:IsA("Accessory") then
			if child.AccessoryType == Enum.AccessoryType.Hair then
				for _, part in child:GetDescendants() do
					if part.Name == "Handle" then
						local specialMesh = part:FindFirstChildOfClass("SpecialMesh")
						if specialMesh then
							specialMesh.TextureId = ""
						end
						-- Also clears a child named "Mesh" (not the SpecialMesh class): some hair
						-- accessories keep their texture on a second mesh by that name.
						local namedMesh = part:FindFirstChild("Mesh")
						if namedMesh and namedMesh:IsA("SpecialMesh") then
							namedMesh.TextureId = ""
						end
					end
				end
			else
				child:Destroy()
			end
		elseif child:IsA("Shirt") or child:IsA("Pants") then
			child:Destroy()
		end
	end
end

local function applySkin(character: Model, data: Data)
	local existing = character:FindFirstChildOfClass("BodyColors")
	if existing then
		existing:Destroy()
	end

	local templateName = CharacterService.SkinTemplateName(data.Character.SkinTone, data.Character.Kingdom)
	local template = script:FindFirstChild(templateName)
	if template == nil then
		log:Error(string.format("no skin template named %s", templateName))
		return
	end
	local skin = template:Clone()
	skin.Parent = character
end

-- Returns the FalseHead so buildFace can use it, or nil if the template
-- (or the character's Head) is missing.
local function buildFalseHead(character: Model, data: Data): BasePart?
	local head = character:FindFirstChild("Head")
	if not (head and head:IsA("BasePart")) then
		log:Error("character has no Head; can't attach FalseHead")
		return nil
	end

	local template = script:FindFirstChild("FalseHead")
	if not (template and template:IsA("BasePart")) then
		log:Error("FalseHead template missing")
		return nil
	end

	local falseHead = template:Clone() :: BasePart
	falseHead.Transparency = 1
	falseHead.CFrame = head.CFrame + (head.CFrame.LookVector / 20)

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = falseHead
	weld.Part1 = head
	weld.Parent = falseHead

	falseHead.Parent = character

	for _, child in character:GetChildren() do
		if child:IsA("CharacterMesh") then
			child:Destroy()
		end
	end

	local headMesh = head:FindFirstChild("Mesh")
	if headMesh then
		headMesh:Destroy()
	end
	local face = head:FindFirstChild("face")
	if face then
		face:Destroy()
	end

	local normMeshieTemplate = script:FindFirstChild("NormMeshie")
	if normMeshieTemplate then
		local normMeshie = normMeshieTemplate:Clone()
		normMeshie.Parent = head
	end

	-- Each face decal call is its own pcall so one bad Assets read drops only that
	-- decal (logged) instead of aborting the build before AppearenceLoaded is set.
	local stat = statShim(data)
	local function safeDecal(label: string, build: () -> Decal): Decal?
		local ok, result = pcall(build)
		if not ok then
			log:Error(string.format("Assets.%s(stat) errored, skipping that decal: %s", label, tostring(result)))
			return nil
		end
		(result :: Decal).Parent = falseHead
		return result :: Decal
	end

	safeDecal("facebase", function()
		return Assets.facebase(stat)
	end)
	safeDecal("mouthshape", function()
		return Assets.mouthshape(stat)
	end)
	safeDecal("eyecolor", function()
		return Assets.eyecolor(stat)
	end)
	safeDecal("eyebrow", function()
		return Assets.eyebrow(stat)
	end)

	return falseHead
end

local function buildHitbox(character: Model)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		log:Error("character has no HumanoidRootPart; can't attach the combat hitbox")
		return
	end

	local misc = ReplicatedFirst:WaitForChild("MISC", WAIT_TIMEOUT)
	local template = misc and misc:FindFirstChild("HitBox")
	if not (template and template:IsA("BasePart")) then
		log:Error("ReplicatedFirst.MISC.HitBox template missing; no combat hitbox")
		return
	end

	local hitbox = template:Clone() :: BasePart
	hitbox.CFrame = hrp.CFrame:ToWorldSpace(CFrame.new(0, 0, -1))
	hitbox.Color = Color3.new(0.133333, 0.458824, 0.976471)

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hrp
	weld.Part1 = hitbox
	weld.Parent = hitbox

	hitbox.Parent = character
end

-- Shared implementation lives in AgeService.ApplyHairColor (also called on birthday).
-- The applied colour lerps toward grey from Config.Aging.GreyStart to GreyEnd; the
-- SAVED HairColor never changes.
local applyHairColor = AgeService.ApplyHairColor

-- Visible aging is hair-only: RF.Assets has no wrinkle decal yet.

local function setCollisionGroup(character: Model)
	for _, part in character:GetChildren() do
		if part:IsA("BasePart") then
			part.CollisionGroup = COLLISION_GROUP
		end
	end
end

-- Sounds/particles are resolved once at Init, recursively by name (assets live in
-- various subfolders, so a flat FindFirstChild would miss them); a missing asset
-- warns once at boot.
local SFX_NAMES = {
	"CoinReward",
	"BlockBroken",
	"Parry",
	"QuickDash",
	"LightHitSound1",
	"LightHitSound2",
	"LightHitSound3",
	"MissSound1",
	"MissSound2",
	"MissSound3",
	"LightHitSoundFin",
	"BlockSound1",
	"BlockSound2",
}
-- Cancel is a Highlight (RF/VFX/MiscEffects), not a ParticleEmitter, but it
-- clones and parents the same way.
local VFX_NAMES = { "HitParticle", "Cancel", "BlockParticle", "BlockBreakParticle", "Confusion", "Sparks1", "Sparks2" }

local resolvedAssets: { [string]: Instance } = {}
local assetsResolved = false

local function resolveSoundsAndParticles()
	if assetsResolved then
		return
	end
	assetsResolved = true

	local sfx = ReplicatedFirst:WaitForChild("SFX", WAIT_TIMEOUT)
	local vfx = ReplicatedFirst:WaitForChild("VFX", WAIT_TIMEOUT)
	if sfx == nil or vfx == nil then
		log:Error("ReplicatedFirst.SFX/VFX missing; every spawn will be missing sounds/particles")
		return
	end

	for _, name in SFX_NAMES do
		local found = sfx:FindFirstChild(name, true)
		if found then
			resolvedAssets[name] = found
		else
			log:Warn(string.format("missing SFX asset %s (searched recursively under ReplicatedFirst.SFX)", name))
		end
	end
	for _, name in VFX_NAMES do
		local found = vfx:FindFirstChild(name, true)
		if found then
			resolvedAssets[name] = found
		else
			log:Warn(string.format("missing VFX asset %s (searched recursively under ReplicatedFirst.VFX)", name))
		end
	end
end

local function cloneNamed(name: string, parent: Instance)
	local template = resolvedAssets[name]
	if template then
		local clone = template:Clone()
		clone.Parent = parent
	end
	-- A missing name already warned once, at boot, in resolveSoundsAndParticles.
end

local function attachSoundsAndParticles(character: Model)
	local torso = character:FindFirstChild("Torso")
	if not (torso and torso:IsA("BasePart")) then
		log:Error("character has no Torso; skipping sounds/particles")
		return
	end

	for _, name in { "CoinReward", "BlockBroken", "Parry", "QuickDash" } do
		cloneNamed(name, torso)
	end
	for i = 1, 3 do
		cloneNamed("LightHitSound" .. i, torso)
		cloneNamed("MissSound" .. i, torso)
	end
	cloneNamed("LightHitSoundFin", torso)
	cloneNamed("BlockSound1", torso)
	cloneNamed("BlockSound2", torso)

	local centerAttachment = Instance.new("Attachment")
	centerAttachment.Name = "CenterHook"
	centerAttachment.Parent = torso

	local head = character:FindFirstChild("Head")
	if head then
		local headAttachment = Instance.new("Attachment")
		headAttachment.Name = "HeadHook"
		headAttachment.Parent = head
	end

	cloneNamed("HitParticle", torso)
	cloneNamed("Cancel", character)
	cloneNamed("BlockParticle", torso)
	cloneNamed("BlockBreakParticle", torso)
	local hairAttachment = head and head:FindFirstChild("HairAttachment")
	if hairAttachment then
		cloneNamed("Confusion", hairAttachment)
	end
	cloneNamed("Sparks1", centerAttachment)
	cloneNamed("Sparks2", centerAttachment)
	-- Step sounds and the OST playlist are played by the client from ReplicatedFirst.SFX.
end

-- Rolls a random starter rag outfit into `data.Gear` if the player has never had one (Shirt == "").
local function ensureStarterOutfit(data: Data)
	if data.Gear.Shirt ~= "" then
		return
	end
	local color = if math.random(1, 2) == 1 then Color3.fromRGB(35, 35, 35) else Color3.fromRGB(144, 90, 42)
	local pantsName = if math.random(1, 2) == 1 then "Shoes and Rags" else "Barefooted and Rags"
	data.Gear.Shirt = ItemService.Encode("S", "Short Sleeve Rags", ItemService.ColorToCode(color))
	data.Gear.Pants = ItemService.Encode("P", pantsName, ItemService.ColorToCode(color))
end

local function equipGear(character: Model, data: Data)
	ensureStarterOutfit(data)

	if data.Gear.Shirt ~= "" then
		ItemService.Equip(data.Gear.Shirt, character)
	end
	if data.Gear.Pants ~= "" then
		ItemService.Equip(data.Gear.Pants, character)
	end
	for _, code in data.Gear.Hats do
		if code ~= "" then
			ItemService.Equip(code, character)
		end
	end
end

-- ToolGrip's Part0 is the Torso (its own parent); client tool code reaches for Torso.ToolGrip.Part1.
local function wireToolGrip(character: Model)
	local torso = character:FindFirstChild("Torso")
	if not (torso and torso:IsA("BasePart")) then
		return
	end

	local motor = Instance.new("Motor6D")
	motor.Name = "ToolGrip"
	motor.Part0 = torso
	motor.Parent = torso

	character.ChildAdded:Connect(function(child: Instance)
		if child:IsA("Tool") and child:FindFirstChild("BodyAttach") then
			motor.Part1 = child:FindFirstChild("BodyAttach") :: BasePart
		end
	end)
end

-- Runs the custom animations as part of the build; ids come from Config.Character.Animations.
local function applyAnimations(character: Model)
	local animate = character:WaitForChild("Animate", WAIT_TIMEOUT)
	if animate == nil then
		log:Error("character has no Animate script; custom animations not applied")
		return
	end

	local function setAnimId(path: string, propertyOwner: string, id: string)
		local container = animate:FindFirstChild(path)
		local animation = container and container:FindFirstChild(propertyOwner)
		if animation and animation:IsA("Animation") then
			animation.AnimationId = id
		end
	end

	local ids = Config.Character.Animations
	setAnimId("run", "RunAnim", ids.Run)
	setAnimId("walk", "WalkAnim", ids.Walk)
	setAnimId("jump", "JumpAnim", ids.Jump)
	setAnimId("idle", "Animation1", ids.Idle)
	setAnimId("fall", "FallAnim", ids.Fall)

	-- Stops every playing track after the ids are swapped so a stale track can't keep playing.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if animator then
		for _, track in animator:GetPlayingAnimationTracks() do
			track:Stop(0)
		end
	end
end

local function setAttributes(player: Player, data: Data)
	player:SetAttribute("Gender", data.Character.Gender)
	player:SetAttribute("SkinTone", data.Character.SkinTone)
	player:SetAttribute("Kingdom", data.Character.Kingdom)
	player:SetAttribute("FirstName", data.Character.FirstName)
	player:SetAttribute("HeightStuds", data.Character.Height * BASE_HUMAN_HEIGHT_STUDS)
	player:SetAttribute("Lives", data.Meta.Lives)
	player:SetAttribute("Age", data.Age.Years)
end

-- Waits until CreateCharacter has been handled (data.Character.Gender ~= 0), the
-- player leaves, or this character is replaced by a respawn. The client shows the
-- Gender screen on its own when it sees the Gender attribute at 0.
local function waitForCharacterCreated(player: Player, character: Model, data: Data): boolean
	while data.Character.Gender == 0 do
		if player.Parent ~= Players or player.Character ~= character then
			return false
		end
		task.wait()
	end
	return true
end

-- Players never show Roblox's default overhead name or health bar: DisplayDistanceType
-- None hides both. NPC trainers keep their own billboards.
local PLAYER_DISPLAY_DISTANCE_TYPE = Enum.HumanoidDisplayDistanceType.None

function CharacterService.HideOverheadDisplay(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end
	humanoid.DisplayDistanceType = PLAYER_DISPLAY_DISTANCE_TYPE
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.NameDisplayDistance = 0
	humanoid.HealthDisplayDistance = 0
end

local function buildCharacter(player: Player, character: Model, data: Data)
	CharacterService.HideOverheadDisplay(character)

	local appearenceLoaded = Instance.new("BoolValue")
	appearenceLoaded.Name = "AppearenceLoaded"
	appearenceLoaded.Value = false
	appearenceLoaded.Parent = character

	-- Set every attribute now: a brand-new player's Gender is still 0, and the
	-- creation screen waits on that attribute.
	setAttributes(player, data)

	if data.Character.Gender == 0 then
		if not waitForCharacterCreated(player, character, data) then
			return
		end
	end
	if player.Parent ~= Players or player.Character ~= character then
		return
	end

	-- First-time height roll; needs gender, so it happens once gender is known.
	-- AgeService's resizeCharacter re-rolls defensively if this is skipped.
	if data.Character.Height == 10 then
		local profileStr, height = AgeHandler.start(data.Age.Years, data.Character.Race, data.Character.Gender)
		data.Character.GrowthProfile = profileStr
		data.Character.Height = height
	end

	stripDefaultAvatar(character)
	applySkin(character, data)
	local falseHead = buildFalseHead(character, data)
	buildHitbox(character)
	applyHairColor(character, data)
	setCollisionGroup(character)
	attachSoundsAndParticles(character)
	equipGear(character, data)
	wireToolGrip(character)
	applyAnimations(character)

	setAttributes(player, data)

	appearenceLoaded.Value = true

	-- FaceControl waits on `Effects`, which EffectsService creates once AppearenceLoaded
	-- is true; start it after that flip and off this thread so spawns don't stall.
	if falseHead then
		task.spawn(FaceControl.Start, player, character, falseHead)
	end

	local charactersFolder = Workspace:FindFirstChild("Characters")
	if charactersFolder then
		character.Parent = charactersFolder
	end
end


-- A second CreateCharacter after Gender is set is ignored, warning once per cooldown.
local lastDuplicateCreateWarn: { [Player]: number } = {}
local DUPLICATE_CREATE_WARN_COOLDOWN = 30

function CharacterService:Init()
	-- Register both groups if missing (CollisionService also registers them; both sides
	-- check first) so SetCollidable always has real groups. No pcall: a failure should be loud.
	if not PhysicsService:IsCollisionGroupRegistered(COLLISION_GROUP) then
		PhysicsService:RegisterCollisionGroup(COLLISION_GROUP)
	end
	if not PhysicsService:IsCollisionGroupRegistered(CLOTHING_RACK_GROUP) then
		PhysicsService:RegisterCollisionGroup(CLOTHING_RACK_GROUP)
	end
	PhysicsService:CollisionGroupSetCollidable(COLLISION_GROUP, CLOTHING_RACK_GROUP, false)

	Remotes.Server.On("CreateCharacter", function(player: Player, gender: number, skin: number)
		local data = DataService.Get(player)
		if data == nil then
			return
		end
		if not CharacterService.ApplyCreateCharacter(data, gender, skin) then
			if data.Character.Gender ~= 0 then
				local now = os.clock()
				local last = lastDuplicateCreateWarn[player]
				if not last or now - last >= DUPLICATE_CREATE_WARN_COOLDOWN then
					lastDuplicateCreateWarn[player] = now
					log:Warn(string.format("%s sent CreateCharacter again after Gender was already set", player.Name))
				end
			end
			return
		end
		-- HeightStuds is transiently the Height==10 sentinel until buildCharacter rolls the
		-- growth profile and calls setAttributes again.
		setAttributes(player, data)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		lastDuplicateCreateWarn[player] = nil
	end)
end

-- Hide the default overhead name/health the moment the Humanoid exists, not after PlayerService.Ready.
local function hideWhenHumanoidExists(character: Model)
	if character:FindFirstChildOfClass("Humanoid") == nil then
		character:WaitForChild("Humanoid", 10)
	end
	CharacterService.HideOverheadDisplay(character)
end

local function watchPlayer(player: Player)
	player.CharacterAdded:Connect(function(character: Model)
		task.spawn(hideWhenHumanoidExists, character)
	end)
	if player.Character then
		task.spawn(hideWhenHumanoidExists, player.Character)
	end
end

function CharacterService:Start()
	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	-- Resolved here, not Init() (Init must not yield; WaitForChild can).
	resolveSoundsAndParticles()

	PlayerService.Ready:Connect(function(player: Player, character: Model)
		local data = DataService.Get(player)
		if data == nil then
			log:Error(string.format("%s is Ready but has no loaded save; can't build appearance", player.Name))
			return
		end
		task.spawn(buildCharacter, player, character, data)
	end)
end

return CharacterService

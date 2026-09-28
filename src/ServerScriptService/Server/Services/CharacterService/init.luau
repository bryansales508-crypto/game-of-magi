--!strict
-- Builds a character's look from the save, replacing the old
-- Character/AppearanceController/init.server.luau (TRIAGE #3). Strips the
-- default Roblox avatar, then rebuilds skin, FalseHead face, hair colour,
-- combat hitbox, one shared collision group, sounds/particles, the saved
-- (or a fresh starter) outfit, hats, and the custom run/walk/jump/idle/fall
-- animations (old Animations.server.luau). Waits for CreateCharacter on a
-- brand-new life; the gender/skin picker itself is now a client screen
-- (M2-04) that shows while Player attribute Gender == 0.
--
-- Fixes carried in from AUDIT: H4 (server-side gender picker replaced by a
-- checked remote), L2 (magician eye colours reachable, in RF/Assets),
-- L3 (first name matches the chosen gender), L6 (ToolGrip.Part0 wired),
-- M8 (one shared collision group instead of one per player, ever).

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
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

-- M8: one collision group for every player, registered once here instead of
-- once per spawn (the old per-player-name group was never removed, and
-- Roblox only allows 32 total).
local COLLISION_GROUP = "PlayerLimbs"
local CLOTHING_RACK_GROUP = "ClothingRackGroup"

-- Display-only: HeightStuds = Height (HeightHandler's own body-scale ratio,
-- ~0.75-1.25) times a nominal default rig height, so the menu (M2-04) can
-- show a stud figure without knowing HeightHandler's internal scale.
local BASE_HUMAN_HEIGHT_STUDS = 5

local WAIT_TIMEOUT = 10

local CharacterService = {}

-- ==================== pure helpers (self-tested directly) ====================

-- P4: by NAME, not by old positional guesses. 1 Black, 2 Brown, 3 White,
-- then the same kingdom overrides the old script used (Kingdom 1 swaps
-- White for the more tan LightTan; Kingdom 2 swaps Black for Tan and Brown
-- for LightTan). REVIEW-M2-01 confirmed each .rbxm template's own colours
-- match its name (darkest to lightest: Black, Tan, Brown, LightTan, White).
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

-- L3: gender-matched, not the male list rolled before gender is even known
-- (SaveSchema.NewLife's roll at save creation is just a placeholder;
-- CreateCharacter overwrites it here once the player has actually chosen).
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

-- Applies one CreateCharacter call against `data` directly (no DataService/
-- Remotes involved), so SelfTestService can exercise the validation with a
-- fake save. The real remote handler below calls this, then refreshes the
-- legacy bridge and the player's attributes.
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

-- ==================== build steps ====================

-- A stand-in for the old Stats Value folder: RF.Assets' facebase/mouthshape/
-- eyecolor/eyebrow functions all read `stat["Field"].Value`. The folder itself
-- is gone (M6), so this shim is all they see.
-- BUG-10: must cover every key RF/Assets reads via `stat["X"].Value`
-- (grepped: Gender, FaceBase, Race, EyeColor, MouthShape, HairColor -
-- Assets.eyebrow reads HairColor as a Color3 to tint the eyebrow decal).
-- Missing HairColor crashed buildFalseHead, which aborted the whole build
-- before AppearenceLoaded was ever set, hanging every old script waiting
-- on it. SelfTestService.testCharacterService checks this list stays
-- complete against Assets' real reads.
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
						-- Old code also cleared a child literally named "Mesh"
						-- (not the SpecialMesh class above): some hair
						-- accessories keep their texture on a second mesh
						-- instance under that name.
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

	-- BUG-10/BUG-13: one broken Assets call (missing HairColor) used to
	-- throw here, unprotected, aborting the rest of buildCharacter -
	-- AppearenceLoaded never got set, so AgeService's own spawn-triggered
	-- resize (gated on it) never ran either, leaving every respawn at
	-- Roblox's unscaled default size until the next birthday (whose
	-- resize isn't gated on AppearenceLoaded) fixed it again. Each face
	-- decal call is now its own pcall, so a future bad Assets read drops
	-- just that one decal (logged) instead of the whole build.
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

-- M2-02 visible aging, REVIEW-M2-02 R3: the shared implementation lives in
-- AgeService.ApplyHairColor (also called from onBirthday, so hair greys
-- in on the birthday it's due, not only on the next respawn). The applied
-- colour lerps toward grey from Config.Aging.GreyStart to GreyEnd; the
-- SAVED HairColor never changes (it's the natural colour).
local applyHairColor = AgeService.ApplyHairColor

-- ART TASK (Bryan): wrinkle decal. RF.Assets has no wrinkle/aged-face
-- decal yet, so visible aging is hair-only for now; add one to the face
-- decal tables when it exists and blend it in here by AgeService.GreyFactor.

local function setCollisionGroup(character: Model)
	for _, part in character:GetChildren() do
		if part:IsA("BasePart") then
			part.CollisionGroup = COLLISION_GROUP
		end
	end
end

-- BUG-19: the old AppearanceController built its SoundsTable/ParticleTable
-- from `:GetDescendants()`, so it found these regardless of which subfolder
-- they actually live in (RF/reference/m2-studio-dump.md section 3: VFX's
-- children are split across HitEffects/RukhEffects/StatusEffects/
-- MiscEffects; SFX has its own subfolders like UISounds). A flat
-- `container:FindFirstChild(name)` (immediate children only) found none of
-- them. Resolved once at Init (recursively, by name) instead of per spawn:
-- cheaper, and lets a missing asset warn once at boot instead of once per
-- player who ever spawns.
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
	-- Step sounds and the OST playlist are no longer cloned into the Torso: the
	-- client plays them straight from ReplicatedFirst.SFX (M6).
end

-- Rolls a random starter rag outfit into `data.Gear` if the player has
-- never had one (Shirt == ""); same items/colours the old script used.
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

-- L6: the old block created this Motor6D but never gave it a Part0, so it
-- never actually moved anything; wired here (Part0 = Torso, its own
-- parent) instead of deleted, since the not-yet-rebuilt client tool code
-- (PhysicalHandler.client.luau) still reaches for Torso.ToolGrip.Part1.
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

-- Ported from the old Animations.server.luau: same animation ids, now run
-- as part of the same build instead of its own PlayerAdded listener keyed
-- off Roblox's CharacterAppearanceLoaded (a different signal from our own
-- AppearenceLoaded).
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

	setAnimId("run", "RunAnim", "rbxassetid://15421855688")
	setAnimId("walk", "WalkAnim", "rbxassetid://15421859266")
	setAnimId("jump", "JumpAnim", "rbxassetid://15428492106")
	setAnimId("idle", "Animation1", "rbxassetid://15422107398")
	setAnimId("fall", "FallAnim", "rbxassetid://15428818320")

	-- F9: the old script stopped every playing track around the id swap so
	-- a stale (old-id) track can't keep playing; stopped here, after the
	-- ids are set, so the next state change starts fresh with the new id.
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

-- Waits until CreateCharacter has been handled (data.Character.Gender ~= 0),
-- the player leaves, or (F8) this character is replaced by a respawn while
-- still waiting. The client shows the Gender screen itself whenever it sees
-- the Gender attribute at 0; the server just waits here, same polling shape
-- as PlayerService.WaitForReady.
local function waitForCharacterCreated(player: Player, character: Model, data: Data): boolean
	while data.Character.Gender == 0 do
		if player.Parent ~= Players or player.Character ~= character then
			return false
		end
		task.wait()
	end
	return true
end

local function buildCharacter(player: Player, character: Model, data: Data)
	local appearenceLoaded = Instance.new("BoolValue")
	appearenceLoaded.Name = "AppearenceLoaded"
	appearenceLoaded.Value = false
	appearenceLoaded.Parent = character

	-- F1: set every attribute now, not only at the end. A brand-new
	-- player's Gender is still 0 here, but that IS the signal M2-04's
	-- CreationController waits for to show the creation screen; without
	-- this, the attribute stays nil forever and the screen never appears.
	setAttributes(player, data)

	if data.Character.Gender == 0 then
		if not waitForCharacterCreated(player, character, data) then
			return
		end
	end
	if player.Parent ~= Players or player.Character ~= character then
		return
	end

	-- F2: the old AppearanceController's "first time height" roll (moved
	-- out when AppearanceController was removed, not into AgeController).
	-- Needs gender, so it happens here, once gender is known, rather than
	-- eagerly on load (AgeService no longer rolls it that early either -
	-- see AgeService's DataService.Loaded handler). AgeService's own
	-- resizeCharacter still re-rolls defensively if this is ever skipped.
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

	-- F3: FaceControl waits (unbounded) on `Effects`, which EffectsService
	-- only creates once AppearenceLoaded is true; starting it only after
	-- that flip (and off this thread) means it no longer stalls every
	-- spawn for FaceControl's old fixed 10s timeout.
	if falseHead then
		task.spawn(FaceControl.Start, player, character, falseHead)
	end

	local charactersFolder = Workspace:FindFirstChild("Characters")
	if charactersFolder then
		character.Parent = charactersFolder
	end
end

-- ==================== service ====================

-- F7: a second CreateCharacter after Gender is already set is silently
-- ignored (as before), but now warns once per cooldown instead of never,
-- so a client stuck retrying doesn't go unnoticed.
local lastDuplicateCreateWarn: { [Player]: number } = {}
local DUPLICATE_CREATE_WARN_COOLDOWN = 30

function CharacterService:Init()
	-- F6: register both groups if missing (ClothingRackGroup is normally
	-- registered later by CollisionsHandler, only after the map loads) so
	-- SetCollidable below always has two real groups to work with, and
	-- runs with no pcall: a real failure here should be loud, not silent.
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
		-- N2: HeightStuds here is transiently the Height==10 sentinel until
		-- buildCharacter's own thread rolls the growth profile (F2) and
		-- calls setAttributes again; harmless today since nothing reads it
		-- this early, but worth knowing if that ever changes.
		setAttributes(player, data)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		lastDuplicateCreateWarn[player] = nil
	end)
end

function CharacterService:Start()
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

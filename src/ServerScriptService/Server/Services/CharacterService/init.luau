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
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local SaveSchema = require(ReplicatedStorage.Shared.SaveSchema)
local Assets = require(ReplicatedFirst.Assets) :: any
local ItemHandler = require(ServerScriptService.Character.ItemHandler) :: any
local DataService = require(script.Parent.DataService)
local PlayerService = require(script.Parent.PlayerService)
local LegacyBridge = require(script.Parent.LegacyBridge)
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
-- then the same kingdom overrides the old script used (Qarzin lightens
-- White to LightTan; a second kingdom lightens Black to Tan and Brown to
-- LightTan). Whether each .rbxm template's own colours actually match its
-- name still needs a Studio look (AUDIT P4); this only fixes the mapping.
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
-- eyecolor/eyebrow functions all read `stat["Field"].Value`. Cheaper than
-- waiting on LegacyBridge's real Values, and works before Build() has run.
local function statShim(data: Data): any
	return {
		Gender = { Value = data.Character.Gender },
		FaceBase = { Value = data.Character.FaceBase },
		MouthShape = { Value = data.Character.MouthShape },
		EyeColor = { Value = data.Character.EyeColor },
		Race = { Value = data.Character.Race },
	}
end

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

	local stat = statShim(data)
	local faceBase = Assets.facebase(stat)
	faceBase.Parent = falseHead
	local mouthShape = Assets.mouthshape(stat)
	mouthShape.Parent = falseHead
	local eyeColor = Assets.eyecolor(stat)
	eyeColor.Parent = falseHead
	local eyebrow = Assets.eyebrow(stat)
	eyebrow.Parent = falseHead

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

local function applyHairColor(character: Model, data: Data)
	local color = Color3.new(data.Character.HairColor.R, data.Character.HairColor.G, data.Character.HairColor.B)
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") and part.Name:find("Handle") then
			part.Color = color
		end
	end
end

local function setCollisionGroup(character: Model)
	for _, part in character:GetChildren() do
		if part:IsA("BasePart") then
			part.CollisionGroup = COLLISION_GROUP
		end
	end
end

local function attachSoundsAndParticles(character: Model)
	local torso = character:FindFirstChild("Torso")
	if not (torso and torso:IsA("BasePart")) then
		log:Error("character has no Torso; skipping sounds/particles")
		return
	end

	local sfx = ReplicatedFirst:WaitForChild("SFX", WAIT_TIMEOUT)
	local vfx = ReplicatedFirst:WaitForChild("VFX", WAIT_TIMEOUT)
	if sfx == nil or vfx == nil then
		log:Error("ReplicatedFirst.SFX/VFX missing; skipping sounds/particles")
		return
	end

	local function cloneNamed(container: Instance, name: string, parent: Instance)
		local template = container:FindFirstChild(name)
		if template then
			local clone = template:Clone()
			clone.Parent = parent
		else
			log:Warn(string.format("missing SFX/VFX asset %s", name))
		end
	end

	for _, name in { "CoinReward", "BlockBroken", "Parry", "QuickDash" } do
		cloneNamed(sfx, name, torso)
	end
	for i = 1, 3 do
		cloneNamed(sfx, "LightHitSound" .. i, torso)
		cloneNamed(sfx, "MissSound" .. i, torso)
	end
	cloneNamed(sfx, "LightHitSoundFin", torso)
	cloneNamed(sfx, "BlockSound1", torso)
	cloneNamed(sfx, "BlockSound2", torso)

	local centerAttachment = Instance.new("Attachment")
	centerAttachment.Name = "CenterHook"
	centerAttachment.Parent = torso

	local head = character:FindFirstChild("Head")
	if head then
		local headAttachment = Instance.new("Attachment")
		headAttachment.Name = "HeadHook"
		headAttachment.Parent = head
	end

	cloneNamed(vfx, "HitParticle", torso)
	cloneNamed(vfx, "Cancel", character)
	cloneNamed(vfx, "BlockParticle", torso)
	cloneNamed(vfx, "BlockBreakParticle", torso)
	local hairAttachment = head and head:FindFirstChild("HairAttachment")
	if hairAttachment then
		cloneNamed(vfx, "Confusion", hairAttachment)
	end
	cloneNamed(vfx, "Sparks1", centerAttachment)
	cloneNamed(vfx, "Sparks2", centerAttachment)

	local steps = sfx:FindFirstChild("Steps")
	if steps then
		for _, sound in steps:GetChildren() do
			local clone = sound:Clone()
			clone.Parent = torso
		end
	end

	local soundsFolder = Instance.new("Folder")
	soundsFolder.Name = "SoundsFolder"
	soundsFolder.Parent = torso
	local osts = sfx:FindFirstChild("OSTs")
	if osts then
		for _, track in osts:GetChildren() do
			local clone = track:Clone()
			clone.Parent = soundsFolder
		end
	end
end

-- Rolls a random starter rag outfit into `data.Gear` if the player has
-- never had one (Shirt == ""); same items/colours the old script used.
local function ensureStarterOutfit(data: Data)
	if data.Gear.Shirt ~= "" then
		return
	end
	local color = if math.random(1, 2) == 1 then Color3.fromRGB(35, 35, 35) else Color3.fromRGB(144, 90, 42)
	local pantsName = if math.random(1, 2) == 1 then "Shoes and Rags" else "Barefooted and Rags"
	data.Gear.Shirt = ItemHandler.encode("S", "Short Sleeve Rags", ItemHandler.colorToCode(color))
	data.Gear.Pants = ItemHandler.encode("P", pantsName, ItemHandler.colorToCode(color))
end

local function equipGear(character: Model, data: Data)
	ensureStarterOutfit(data)

	if data.Gear.Shirt ~= "" then
		ItemHandler.equip(data.Gear.Shirt, character)
	end
	if data.Gear.Pants ~= "" then
		ItemHandler.equip(data.Gear.Pants, character)
	end
	for _, code in data.Gear.Hats do
		if code ~= "" then
			ItemHandler.equip(code, character)
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
end

local function setAttributes(player: Player, data: Data)
	player:SetAttribute("Gender", data.Character.Gender)
	player:SetAttribute("SkinTone", data.Character.SkinTone)
	player:SetAttribute("Kingdom", data.Character.Kingdom)
	player:SetAttribute("FirstName", data.Character.FirstName)
	player:SetAttribute("HeightStuds", data.Character.Height * BASE_HUMAN_HEIGHT_STUDS)
	player:SetAttribute("Lives", data.Meta.Lives)
end

-- Waits until CreateCharacter has been handled (data.Character.Gender ~= 0),
-- or the player leaves. The client shows the Gender screen itself whenever
-- it sees the Gender attribute at 0; the server just waits here, same
-- polling shape as PlayerService.WaitForReady.
local function waitForCharacterCreated(player: Player, data: Data): boolean
	while data.Character.Gender == 0 do
		if player.Parent ~= Players then
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

	if data.Character.Gender == 0 then
		if not waitForCharacterCreated(player, data) then
			return
		end
	end
	if player.Parent ~= Players or player.Character ~= character then
		return
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

	if falseHead then
		FaceControl.Start(player, character, falseHead)
	end

	LegacyBridge.Refresh(player, data)
	setAttributes(player, data)

	appearenceLoaded.Value = true

	local charactersFolder = Workspace:FindFirstChild("Characters")
	if charactersFolder then
		character.Parent = charactersFolder
	end
end

-- ==================== service ====================

function CharacterService:Init()
	local ok = pcall(function()
		PhysicsService:RegisterCollisionGroup(COLLISION_GROUP)
	end)
	if not ok then
		log:Debug(string.format("collision group %s already registered", COLLISION_GROUP))
	end
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(COLLISION_GROUP, CLOTHING_RACK_GROUP, false)
	end)

	Remotes.Server.On("CreateCharacter", function(player: Player, gender: number, skin: number)
		local data = DataService.Get(player)
		if data == nil then
			return
		end
		if not CharacterService.ApplyCreateCharacter(data, gender, skin) then
			return
		end
		LegacyBridge.Refresh(player, data)
		setAttributes(player, data)
	end)
end

function CharacterService:Start()
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

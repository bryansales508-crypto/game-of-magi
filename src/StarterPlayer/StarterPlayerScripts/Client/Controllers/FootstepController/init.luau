--!strict
-- Footstep sounds and sand/mud prints (M6 Phase 6C, docs/M6-PLAN.md).
-- Everything is local to this player: no remote, no server work per step.
--
-- Roblox's Animate script keeps its step timing. On each marker it fires a
-- BindableEvent named "FootstepEvent", created by Animate as a child of the
-- character (client-side only, never replicated), with "Left", "Right" or
-- "Jump". This controller does the rest:
--   * sound: by Humanoid.FloorMaterial (same material -> sound mapping as the
--     old server FootstepService), volume by the character's `Running`
--     attribute, skipped while character.Effects.MutedStep exists;
--   * print: one local raycast down; on Sand or Mud a block under the foot
--     that fades out, then is destroyed.
-- The step sounds are cloned once from ReplicatedFirst.SFX.Steps into one
-- client folder in SoundService (not per character, not per life).

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Log = require(Shared:WaitForChild("Log"))
local ColorMath = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("ColorMath"))

local log = Log.new("FootstepController")
local settings = Config.World.Footsteps

local player = Players.LocalPlayer

type Step = "Left" | "Right" | "Jump"

-- Same mapping as the old FootstepService.
local HARD_SURFACES: { [string]: boolean } =
	{ Rock = true, Sandstone = true, RoofShingles = true, Pavement = true, Slate = true }
local DIRT_SURFACES: { [string]: boolean } = { Sand = true, Dirt = true, Mud = true }
local THUD_SURFACES: { [string]: boolean } = { Wood = true, Carpet = true }
local PRINT_SURFACES: { [string]: boolean } = { Sand = true, Mud = true }

local FootstepController = {}

local sounds: { [string]: Sound } = {}
local printFolder: Folder? = nil
local stepConnections: { RBXScriptConnection } = {}
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function suffixFor(material: Enum.Material): string?
	local name = material.Name
	if HARD_SURFACES[name] then
		return "Block"
	elseif DIRT_SURFACES[name] then
		return "Dirt"
	elseif THUD_SURFACES[name] then
		return "Carpet"
	end
	return nil
end

local function playSound(step: Step, suffix: string, running: boolean)
	-- "Left" and "Jump" both use the left-foot sound, as before.
	local sound: Sound? = sounds[(if step == "Right" then "Right" else "Left") .. suffix]
	if sound == nil or sound.IsPlaying then
		return
	end
	sound.Volume = if running then settings.RunVolume else settings.WalkVolume
	sound:Play()
end

local function makePrint(character: Model, legName: string, running: boolean, result: RaycastResult)
	local folder = printFolder
	local leg = character:FindFirstChild(legName)
	if folder == nil or leg == nil or not leg:IsA("BasePart") then
		return
	end
	local predict = if running then 8 else 2

	local block = Instance.new("Part")
	block.CanCollide = false
	block.CanQuery = false
	block.CanTouch = false
	block.Anchored = true
	block.Size = Vector3.new(1.5, 0.25, 1.5)
	block.Material = result.Material
	local ground = result.Instance
	local groundColor = if ground:IsA("BasePart") then ground.Color else Color3.new(1, 1, 1)
	block.Color = ColorMath.mul(groundColor, Color3.new(0.8, 0.8, 0.8))

	block.CFrame = leg.CFrame + leg.CFrame.LookVector * predict
	block.Orientation = Vector3.new(0, block.Orientation.Y, block.Orientation.Z)
	block.Position = Vector3.new(block.Position.X, result.Position.Y, block.Position.Z)
	block.Parent = folder

	local tween = TweenService:Create(
		block,
		TweenInfo.new(settings.PrintSeconds, Enum.EasingStyle.Linear),
		{ Transparency = 1 }
	)
	tween.Completed:Once(function()
		block:Destroy()
	end)
	tween:Play()
	Debris:AddItem(block, settings.PrintSeconds + 2)
end

local function onStep(character: Model, step: Step)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local torso = character:FindFirstChild("Torso") or character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or torso == nil or not torso:IsA("BasePart") then
		return
	end
	local floorMaterial = humanoid.FloorMaterial
	if floorMaterial == Enum.Material.Air and step ~= "Jump" then
		return
	end

	rayParams.FilterDescendantsInstances = { character }
	local result =
		Workspace:Raycast(torso.Position, Vector3.new(0, -settings.PrintRayStuds, 0), rayParams)

	local muted = false
	local effects = character:FindFirstChild("Effects")
	if effects ~= nil and effects:FindFirstChild("MutedStep") ~= nil then
		muted = true
	end
	local running = character:GetAttribute("Running") == true

	if not muted then
		-- A jump starts in the air, so it takes the material from the ray.
		local soundMaterial = floorMaterial
		if soundMaterial == Enum.Material.Air and result ~= nil then
			soundMaterial = result.Material
		end
		local suffix = suffixFor(soundMaterial)
		if suffix ~= nil then
			playSound(step, suffix, running)
		end
	end

	if result ~= nil and PRINT_SURFACES[result.Material.Name] then
		if step == "Jump" then
			makePrint(character, "Right Leg", running, result)
			makePrint(character, "Left Leg", running, result)
		else
			makePrint(character, step .. " Leg", running, result)
		end
	end
end

local function clearStepConnections()
	for _, connection in stepConnections do
		connection:Disconnect()
	end
	table.clear(stepConnections)
end

local function hookEvent(character: Model, event: Instance)
	if not event:IsA("BindableEvent") then
		return
	end
	table.insert(
		stepConnections,
		event.Event:Connect(function(step: any)
			if step == "Left" or step == "Right" or step == "Jump" then
				onStep(character, step :: Step)
			end
		end)
	)
end

local function onCharacter(character: Model)
	clearStepConnections()
	local existing = character:FindFirstChild("FootstepEvent")
	if existing ~= nil then
		hookEvent(character, existing)
	end
	-- Animate creates the event when it starts; also covers it being
	-- recreated.
	table.insert(
		stepConnections,
		character.ChildAdded:Connect(function(child)
			if child.Name == "FootstepEvent" then
				hookEvent(character, child)
			end
		end)
	)
end

function FootstepController:Init() end

function FootstepController:Start()
	local sfx = ReplicatedFirst:WaitForChild("SFX", 30)
	local steps = if sfx ~= nil then sfx:WaitForChild("Steps", 30) else nil
	if steps == nil then
		log:Warn("ReplicatedFirst.SFX.Steps not found; no step sounds this session")
	else
		local folder = Instance.new("Folder")
		folder.Name = "FootstepSounds"
		folder.Parent = SoundService
		for _, source in steps:GetChildren() do
			if source:IsA("Sound") then
				local sound = source:Clone()
				sound.Parent = folder
				sounds[source.Name] = sound
			end
		end
	end

	local prints = Instance.new("Folder")
	prints.Name = "ClientFootprints"
	prints.Parent = Workspace
	printFolder = prints

	player.CharacterAdded:Connect(onCharacter)
	player.CharacterRemoving:Connect(clearStepConnections)
	if player.Character ~= nil then
		onCharacter(player.Character)
	end
end

return FootstepController

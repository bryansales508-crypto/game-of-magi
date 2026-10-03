--!strict
-- Footstep sounds and sand/mud prints.
-- Everything is local to this player: no remote, no server work per step.
--
-- Roblox's Animate script keeps its step timing. On each marker it fires a
-- BindableEvent named "FootstepEvent", created by Animate as a child of the
-- character (client-side only, never replicated), with "Left", "Right" or
-- "Jump". This controller does the rest:
--   * sound: by Humanoid.FloorMaterial (same material -> sound mapping as the
--     material -> sound mapping below), volume by the character's `Running`
--     attribute, skipped while character.Effects.MutedStep exists;
--   * print: one local raycast down; on Sand or Mud a block under the foot
--     that fades out, then is destroyed.
-- The step sounds are cloned once from ReplicatedFirst.SFX.Steps into one
-- client folder in SoundService (not per character, not per life).

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
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

local HARD_SURFACES: { [string]: boolean } =
	{ Rock = true, Sandstone = true, RoofShingles = true, Pavement = true, Slate = true }
local DIRT_SURFACES: { [string]: boolean } = { Sand = true, Dirt = true, Mud = true }
local THUD_SURFACES: { [string]: boolean } = { Wood = true, Carpet = true }
local PRINT_SURFACES: { [string]: boolean } = { Sand = true, Mud = true }

local FootstepController = {}

local sounds: { [string]: Sound } = {}
local printFolder: Folder? = nil
local stepConnections: { RBXScriptConnection } = {}
local runDriving = false -- the run animation is driving steps; Animate's are ignored
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
	-- "Left" and "Jump" both use the left-foot sound.
	local soundName = (if step == "Right" then "Right" else "Left") .. suffix
	local sound: Sound? = sounds[soundName]
	if sound == nil then
		if settings.Debug then
			log:Info("step sound missing: " .. soundName)
		end
		return
	elseif sound.IsPlaying then
		return
	end
	if settings.Debug then
		log:Info(string.format("play %s (%s volume)", soundName, if running then "run" else "walk"))
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

local function onStep(character: Model, step: Step, source: string)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local torso = character:FindFirstChild("Torso") or character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or torso == nil or not torso:IsA("BasePart") then
		return
	end
	local floorMaterial = humanoid.FloorMaterial
	if settings.Debug then
		log:Info(string.format("step %s from %s, floor %s", step, source, floorMaterial.Name))
	end
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

	if settings.Debug and muted then
		log:Info("step sound muted (Effects.MutedStep)")
	end

	if not muted then
		-- A jump starts in the air, so it takes the material from the ray.
		local soundMaterial = floorMaterial
		if soundMaterial == Enum.Material.Air and result ~= nil then
			soundMaterial = result.Material
		end
		local suffix = suffixFor(soundMaterial)
		if suffix ~= nil then
			playSound(step, suffix, running)
		elseif settings.Debug then
			log:Info("no step sound for material " .. soundMaterial.Name)
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
	runDriving = false
	for _, connection in stepConnections do
		connection:Disconnect()
	end
	table.clear(stepConnections)
end

-- Fallback: Animate only fires "Left"/"Right" when the WALK track hits its
-- RightFoot/LeftFoot markers (and never while the run animation, played by
-- CombatController, is on screen). When no Animate step arrived for
-- MARKER_GRACE seconds, steps are generated by distance walked instead
-- (Config.World.Footsteps.FallbackStrideStuds; 0 turns this off).
--
-- Running is driven by the run AnimationTrack itself, not by distance. The
-- track CombatController plays (Config.Combat.MoveAnimations.Run)
-- has no named foot keyframes we can rely on, so a step lands every half
-- cycle: each time the track's TimePosition crosses a multiple of Length / 2
-- (or, if Config.World.Footsteps.RunStepSeconds > 0, every that many seconds),
-- alternating Left / Right. TimePosition moves at the track's speed, so steps
-- follow the animation however fast it plays. While that driver is active,
-- Animate's own events and the distance fallback are ignored so feet never
-- double up.
local MARKER_GRACE = 0.75
local lastMarkerStepAt = 0

local function findRunTrack(character: Model): AnimationTrack?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if animator == nil then
		return nil
	end
	for _, track in animator:GetPlayingAnimationTracks() do
		local animation: Animation? = track.Animation
		if animation ~= nil and animation.AnimationId == Config.Combat.MoveAnimations.Run then
			return track
		end
	end
	return nil
end

local function startFallback(character: Model)
	local stride = settings.FallbackStrideStuds
	local travelled = 0
	local nextFoot: Step = "Left"
	local runTrackedLast: AnimationTrack? = nil
	local lastHalfCycle = 0
	local runClock = 0

	local function stepRun(source: string)
		local step: Step = nextFoot
		nextFoot = if step == "Left" then "Right" else "Left"
		onStep(character, step, source)
	end

	table.insert(
		stepConnections,
		RunService.Heartbeat:Connect(function(dt: number)
			local root = character:FindFirstChild("HumanoidRootPart")
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if
				not (root and root:IsA("BasePart") and humanoid)
				or humanoid.Health <= 0
				or humanoid:GetState() == Enum.HumanoidStateType.Dead
				or humanoid.FloorMaterial == Enum.Material.Air
			then
				travelled = 0
				runDriving = false
				runTrackedLast = nil
				return
			end

			-- Running: step on the run animation's own cycle.
			local runTrack = if character:GetAttribute("Running") == true then findRunTrack(character) else nil
			if runTrack ~= nil and runTrack.Length > 0 then
				runDriving = true
				travelled = 0
				if runTrack ~= runTrackedLast then
					runTrackedLast = runTrack
					runClock = 0
					lastHalfCycle = math.floor(runTrack.TimePosition / (runTrack.Length / 2))
					if settings.Debug then
						log:Info(string.format("run track hooked, length %.3f s, speed %.2f", runTrack.Length, runTrack.Speed))
					end
				end
				if settings.RunStepSeconds > 0 then
					runClock += dt
					if runClock >= settings.RunStepSeconds then
						runClock -= settings.RunStepSeconds
						stepRun("run timer")
					end
				else
					local halfCycle = math.floor(runTrack.TimePosition / (runTrack.Length / 2))
					if halfCycle ~= lastHalfCycle then
						lastHalfCycle = halfCycle
						stepRun("run animation")
					end
				end
				return
			end
			runDriving = false
			runTrackedLast = nil

			if stride <= 0 then
				return
			end
			if os.clock() - lastMarkerStepAt < MARKER_GRACE then
				travelled = 0
				return
			end
			local velocity = root.AssemblyLinearVelocity
			travelled += Vector3.new(velocity.X, 0, velocity.Z).Magnitude * dt
			if travelled >= stride then
				travelled -= stride
				stepRun("fallback")
			end
		end)
	)
end

local function hookEvent(character: Model, event: Instance)
	if not event:IsA("BindableEvent") then
		return
	end
	if settings.Debug then
		log:Info("FootstepEvent hooked")
	end
	table.insert(
		stepConnections,
		event.Event:Connect(function(step: any)
			if step == "Jump" or ((step == "Left" or step == "Right") and not runDriving) then
				lastMarkerStepAt = os.clock()
				onStep(character, step :: Step, "Animate")
			end
		end)
	)
end

local function onCharacter(character: Model)
	clearStepConnections()
	startFallback(character)
	if settings.Debug then
		log:Info("character attached: " .. character.Name)
	end
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
	-- Hook the character first: the sound wait below can take a while.
	local prints = Instance.new("Folder")
	prints.Name = "ClientFootprints"
	prints.Parent = Workspace
	printFolder = prints

	player.CharacterAdded:Connect(onCharacter)
	player.CharacterRemoving:Connect(clearStepConnections)
	if player.Character ~= nil then
		onCharacter(player.Character)
	end

	local sfx = ReplicatedFirst:WaitForChild("SFX", 30)
	local steps = if sfx ~= nil then sfx:WaitForChild("Steps", 30) else nil
	if steps == nil then
		log:Warn("ReplicatedFirst.SFX.Steps not found; no step sounds this session")
	else
		local folder = Instance.new("Folder")
		folder.Name = "FootstepSounds"
		folder.Parent = SoundService
		local names: { string } = {}
		for _, source in steps:GetChildren() do
			if source:IsA("Sound") then
				local sound = source:Clone()
				sound.Parent = folder
				sounds[source.Name] = sound
				table.insert(names, source.Name)
			end
		end
		log:Info(string.format("ready: %d step sounds (%s)", #names, table.concat(names, ", ")))
	end

end

return FootstepController

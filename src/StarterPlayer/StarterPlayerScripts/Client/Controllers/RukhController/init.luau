--!strict
-- Old-age heart attacks and the return-to-the-Rukh death scene, ported
-- from the old OldGameScripts/WipeHandlerPart2 (docs/reference/
-- old-game-scripts.txt line 6503) and DeathHandlerPart1 (line 6064).
--
-- Contract with the server (M2-02):
--   HeartAttack(age: number, fatal: boolean) -- server -> client. Every
--   online birthday from 60 fires a short non-fatal moment; a fatal one
--   leads into the scene below.
--   RukhSceneDone() -- client -> server, no args, fired once the scene
--   finishes; the server starts the fresh life then, or after a 30s
--   timeout regardless.
--   Player:GetAttribute("Dying") is true for the duration of the fatal
--   sequence -- informational on the server's side; this controller
--   drives entirely off the HeartAttack remote's own `fatal` argument.
--
-- Bryan tunes the scene himself (M2-FIX-C, BUG-16): every timing here
-- comes from Config.Scene, and the return-to-the-Rukh scene's own LOOK
-- lives in his ReplicatedFirst.AfterLife model, not in this file. This
-- controller only ever reads three children of that model -- documented
-- in docs/SYSTEMS.md section 4 -- and otherwise leaves it alone:
--   AfterlifeCamera (BasePart)     -- the scene's camera CFrame/subject.
--   AfterlifeSpawnBlock (BasePart) -- where the character is moved to.
--   AfterlifeCore (BasePart, optional) -- what the character walks
--     toward; a plain stand-in marker is built instead when it's absent
--     (or when the model itself is absent).
--
-- Only one heart-attack pulse or death scene is ever active at a time
-- (REVIEW-M2-05 #1/#2): a fresh HeartAttack, and a respawn mid-sequence,
-- both cancel whatever's currently running -- gui, sound, camera, frozen
-- input, clones -- through the shared generation/cleanup pair below.

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared:WaitForChild("Log"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Config = require(Shared:WaitForChild("Config"))

local log = Log.new("RukhController")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera :: Camera

local FREEZE_ACTION = "RukhSceneFreeze"
local GOLD = Color3.fromRGB(223, 193, 112)

local RukhController = {}

-- ==================== shared generation/cleanup ====================

local activeGeneration = 0
local activeCleanup: (() -> ())? = nil

local function runActiveCleanup()
	local cleanup = activeCleanup
	activeCleanup = nil
	if cleanup then
		local results = table.pack(pcall(cleanup))
		if not results[1] then
			log:Warn("cleanup failed: " .. tostring(results[2]))
		end
	end
end

-- Cancels whatever's running (pulse or scene) and returns a fresh
-- generation number for the caller's own run.
local function startGeneration(): number
	activeGeneration += 1
	runActiveCleanup()
	return activeGeneration
end

local function isCurrent(myGeneration: number): boolean
	return activeGeneration == myGeneration
end

-- ==================== heartbeat sound ====================

-- FIX (REVIEW-M2-05 #3): a fallback destroy in case the placeholder
-- asset never loads and Sound.Ended never fires.
local HEARTBEAT_FALLBACK_DESTROY = 5

local function playHeartbeatSound(): Sound
	local sound = Instance.new("Sound")
	sound.Name = "Heartbeat"
	sound.SoundId = Config.Sfx.Heartbeat
	sound.Parent = SoundService
	sound:Play()
	sound.Ended:Connect(function()
		sound:Destroy()
	end)
	task.delay(HEARTBEAT_FALLBACK_DESTROY, function()
		sound:Destroy()
	end)
	return sound
end

-- ==================== full-screen pulse frame ====================

local function newPulseGui(displayOrder: number, color: Color3, transparency: number): (ScreenGui, Frame)
	local gui = Instance.new("ScreenGui")
	gui.Name = "HeartAttackGui"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = displayOrder

	local frame = Instance.new("Frame")
	frame.Name = "Pulse"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency
	frame.BorderSizePixel = 0
	frame.ZIndex = 1
	frame.Parent = gui

	return gui, frame
end

local function tweenFrame(frame: Frame, goal: { [string]: any }, duration: number)
	local tween = TweenService:Create(frame, TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), goal)
	tween:Play()
	tween.Completed:Wait()
end

-- FIX BUG-16 (Bryan, design): a heartbeat is "lub-dub" -- two quick
-- beats BeatGap apart -- not one long pulse. Plays both beats (each
-- dipping to `dip`), then eases to `rest` over PairGap: either the pause
-- before the next cycle, or the final hold after the last one. Returns
-- false the moment this generation goes stale, so callers can bail
-- immediately instead of scheduling more tweens/sounds.
local function playBeatCycle(
	myGeneration: number,
	frame: Frame,
	dip: number,
	rest: number,
	color: Color3,
	beatGap: number,
	pairGap: number,
	sounds: { Sound }
): boolean
	local mid = (dip + rest) / 2

	table.insert(sounds, playHeartbeatSound())
	tweenFrame(frame, { BackgroundTransparency = dip, BackgroundColor3 = color }, beatGap * 0.4)
	if not isCurrent(myGeneration) then
		return false
	end

	tweenFrame(frame, { BackgroundTransparency = mid }, beatGap * 0.2)
	if not isCurrent(myGeneration) then
		return false
	end

	table.insert(sounds, playHeartbeatSound())
	tweenFrame(frame, { BackgroundTransparency = dip }, beatGap * 0.4)
	if not isCurrent(myGeneration) then
		return false
	end

	tweenFrame(frame, { BackgroundTransparency = rest }, pairGap)
	if not isCurrent(myGeneration) then
		return false
	end

	return true
end

-- "a full-screen red Frame ... Then it passes: everything removed, no
-- message. Keep it short and not flashy." -- Config.Scene.NonFatalCycles
-- lub-dubs, fully clearing between and after each.
local NON_FATAL_COLOR = Color3.fromRGB(170, 0, 0)
local NON_FATAL_DIP = 0.55
local NON_FATAL_REST = 1

local function playNonFatalPulse(myGeneration: number)
	if not isCurrent(myGeneration) then
		return
	end

	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	if not isCurrent(myGeneration) then
		return
	end

	local gui, frame = newPulseGui(900, NON_FATAL_COLOR, 1)
	gui.Parent = playerGui

	-- FIX (REVIEW-M2-05 #1/#2): whoever cancels this generation (a new
	-- HeartAttack, or a respawn) tears down this gui and any sound this
	-- pulse has started that hasn't self-destroyed yet.
	local sounds: { Sound } = {}
	activeCleanup = function()
		gui:Destroy()
		for _, sound in sounds do
			sound:Destroy()
		end
	end

	for _ = 1, Config.Scene.NonFatalCycles do
		local ok =
			playBeatCycle(myGeneration, frame, NON_FATAL_DIP, NON_FATAL_REST, NON_FATAL_COLOR, Config.Scene.BeatGap, Config.Scene.PairGap, sounds)
		if not ok then
			return
		end
	end

	gui:Destroy()
	activeCleanup = nil
end

-- "three slower, heavier beats while the red deepens ... and does not
-- fade; on the last beat the screen goes to near-black ... and a
-- centred TextLabel ... appears ... Then the scene." -- each of
-- Config.Scene.FatalCycles cycles deepens the colour/dip further and
-- only partially recovers between cycles (never back to clear); the
-- last holds near-black. Each cycle's BeatGap/PairGap is stretched by
-- FatalSlowFactor again, compounding, so the beats visibly slow down.
local FATAL_START_COLOR = Color3.fromRGB(170, 0, 0)
local FATAL_END_COLOR = Color3.fromRGB(90, 0, 0)
local FATAL_DIP_START = 0.5
local FATAL_DIP_END = 0.05
local FATAL_REST_STEP = 0.2

local function playFatalPulse(myGeneration: number)
	if not isCurrent(myGeneration) then
		return
	end

	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	if not isCurrent(myGeneration) then
		return
	end

	local gui, frame = newPulseGui(950, FATAL_START_COLOR, 1)
	gui.Parent = playerGui

	-- Same cancellation contract as the non-fatal pulse above.
	local sounds: { Sound } = {}
	activeCleanup = function()
		gui:Destroy()
		for _, sound in sounds do
			sound:Destroy()
		end
	end

	local cycles = Config.Scene.FatalCycles
	for cycle = 1, cycles do
		local slow = Config.Scene.FatalSlowFactor ^ (cycle - 1)
		local progress = cycle / cycles
		local color = FATAL_START_COLOR:Lerp(FATAL_END_COLOR, progress)
		local dip = FATAL_DIP_START + (FATAL_DIP_END - FATAL_DIP_START) * progress
		local isLast = cycle == cycles
		local rest = if isLast then FATAL_DIP_END else math.clamp(dip + FATAL_REST_STEP, 0, 1)

		local ok = playBeatCycle(myGeneration, frame, dip, rest, color, Config.Scene.BeatGap * slow, Config.Scene.PairGap * slow, sounds)
		if not ok then
			return
		end
	end

	local message = Instance.new("TextLabel")
	message.Name = "Message"
	message.AnchorPoint = Vector2.new(0.5, 0.5)
	message.Position = UDim2.fromScale(0.5, 0.5)
	message.Size = UDim2.fromScale(0.8, 0.15)
	message.BackgroundTransparency = 1
	message.FontFace = Font.new(Font.fromEnum(Enum.Font.Merriweather).Family, Enum.FontWeight.Regular, Enum.FontStyle.Italic)
	message.TextColor3 = Color3.fromRGB(255, 224, 152)
	message.TextScaled = true
	message.Text = "Your heart gave out."
	message.ZIndex = 2
	message.Parent = gui

	task.wait(Config.Scene.MessageSeconds)
	if not isCurrent(myGeneration) then
		return
	end

	gui:Destroy()
	activeCleanup = nil
end

-- ==================== return-to-the-Rukh scene ====================

-- WipeHandlerPart2's character-golden-neon setup, unchanged.
local function applyRukhAppearance(chara: Model)
	for _, child in chara:GetChildren() do
		if child:IsA("BodyColors") then
			child.HeadColor3 = GOLD
			child.LeftArmColor3 = GOLD
			child.RightArmColor3 = GOLD
			child.LeftLegColor3 = GOLD
			child.RightLegColor3 = GOLD
			child.TorsoColor3 = GOLD
		elseif child:IsA("Clothing") then
			child:Destroy()
		elseif child:IsA("BasePart") then
			if child.Name == "Head" then
				child.Transparency = 1
			elseif child.Name == "FalseHead" or child.Name == "Falsehead" then
				child.Material = Enum.Material.Neon
				child.Transparency = 0
				child.Color = GOLD
			else
				child.Material = Enum.Material.Neon
			end
		elseif child:IsA("Accessory") then
			if child.AccessoryType == Enum.AccessoryType.Hair then
				for _, part in child:GetChildren() do
					if part.Name == "Handle" and part:IsA("BasePart") then
						part.Color = GOLD
						part.Transparency = 0.7
					end
				end
			end
		end
	end
end

-- The walk target: Bryan's own AfterlifeCore if his AfterLife model has
-- one, else a plain stand-in marker positioned ahead of the spawn point
-- (or the character, if there's no AfterLife model at all). Nothing
-- else is built here -- no particles, no extra geometry -- so the scene
-- stays Bryan's to art-direct in his own model.
local function resolveCoreTarget(rootPart: BasePart, afterlifeClone: Instance?, spawnBlock: BasePart?): (Vector3, Part?)
	if afterlifeClone then
		local afterlifeCore = afterlifeClone:FindFirstChild("AfterlifeCore") :: BasePart?
		if afterlifeCore then
			return afterlifeCore.Position, nil
		end
	end

	local origin = if spawnBlock
		then spawnBlock.Position + spawnBlock.CFrame.LookVector * Config.Scene.CoreDistance
		else rootPart.Position + rootPart.CFrame.LookVector * Config.Scene.CoreDistance

	local core = Instance.new("Part")
	core.Name = "RukhCoreStandIn"
	core.Shape = Enum.PartType.Ball
	core.Size = Vector3.new(2, 2, 2)
	core.Anchored = true
	core.CanCollide = false
	core.Material = Enum.Material.Neon
	core.Color = GOLD
	core.Position = origin
	core.Parent = Workspace

	return origin, core
end

local function playRukhScene(myGeneration: number)
	if not isCurrent(myGeneration) then
		return
	end

	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not rootPart then
		log:Warn("no Humanoid/HumanoidRootPart; skipping the Rukh scene")
		return
	end

	local cleanupFns: { () -> () } = {}
	local function addCleanup(fn: () -> ())
		table.insert(cleanupFns, fn)
	end
	activeCleanup = function()
		for i = #cleanupFns, 1, -1 do
			cleanupFns[i]()
		end
	end

	-- 1. Freeze every player action (the same ContextActionService sink
	-- trick WipeHandlerPart2 used).
	ContextActionService:BindAction(FREEZE_ACTION, function()
		return Enum.ContextActionResult.Sink
	end, false, table.unpack(Enum.PlayerActions:GetEnumItems() :: any))
	addCleanup(function()
		ContextActionService:UnbindAction(FREEZE_ACTION)
	end)

	-- 2. Camera to AfterlifeCamera + character to AfterlifeSpawnBlock,
	-- from Bryan's AfterLife model if present, or the simple stand-in
	-- (keep the world, camera 12 studs in front looking back) if not.
	camera.CameraType = Enum.CameraType.Scriptable
	addCleanup(function()
		camera.CameraType = Enum.CameraType.Custom
		local currentCharacter = player.Character
		local currentHumanoid = currentCharacter and currentCharacter:FindFirstChildOfClass("Humanoid")
		if currentHumanoid then
			camera.CameraSubject = currentHumanoid
		end
	end)

	local afterlifeTemplate = ReplicatedFirst:FindFirstChild("AfterLife")
	local afterlifeClone: Instance? = nil
	local spawnBlock: BasePart? = nil

	if afterlifeTemplate then
		local clone = afterlifeTemplate:Clone()
		clone.Parent = Workspace
		afterlifeClone = clone
		addCleanup(function()
			clone:Destroy()
		end)

		local afterlifeCameraPart = clone:FindFirstChild("AfterlifeCamera") :: BasePart?
		spawnBlock = clone:FindFirstChild("AfterlifeSpawnBlock") :: BasePart?
		if afterlifeCameraPart then
			camera.CFrame = afterlifeCameraPart.CFrame
			-- WipeHandlerPart2 also pointed CameraSubject at
			-- AfterlifeCamera; harmless under Scriptable, kept for parity.
			camera.CameraSubject = afterlifeCameraPart
		end
		if spawnBlock then
			rootPart.CFrame = spawnBlock.CFrame
		else
			log:Warn("ReplicatedFirst.AfterLife has no AfterlifeSpawnBlock")
		end
	else
		local lookVector = rootPart.CFrame.LookVector
		local cameraPosition = rootPart.Position + lookVector * 12 + Vector3.new(0, 2, 0)
		camera.CFrame = CFrame.lookAt(cameraPosition, rootPart.Position + Vector3.new(0, 2, 0))
	end

	if not isCurrent(myGeneration) then
		return
	end

	-- 3. The golden body.
	applyRukhAppearance(character)

	local corePosition, standInCore = resolveCoreTarget(rootPart, afterlifeClone, spawnBlock)
	if standInCore then
		addCleanup(function()
			standInCore:Destroy()
		end)
	end

	-- 4. The walk toward the core over Config.Scene.WalkSeconds; fade to
	-- white over the last Config.Scene.FadeSeconds of it.
	humanoid.WalkSpeed = 7
	humanoid:MoveTo(corePosition)

	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	local fadeGui = Instance.new("ScreenGui")
	fadeGui.Name = "RukhFade"
	fadeGui.IgnoreGuiInset = true
	fadeGui.ResetOnSpawn = false
	fadeGui.DisplayOrder = 1000
	local fade = Instance.new("Frame")
	fade.Size = UDim2.fromScale(1, 1)
	fade.BackgroundColor3 = Color3.new(1, 1, 1)
	fade.BackgroundTransparency = 1
	fade.BorderSizePixel = 0
	fade.Parent = fadeGui
	fadeGui.Parent = playerGui
	addCleanup(function()
		fadeGui:Destroy()
	end)

	local holdSeconds = math.max(Config.Scene.WalkSeconds - Config.Scene.FadeSeconds, 0)
	task.wait(holdSeconds)
	if not isCurrent(myGeneration) then
		return
	end

	local fadeTween =
		TweenService:Create(fade, TweenInfo.new(Config.Scene.FadeSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.In), { BackgroundTransparency = 0 })
	fadeTween:Play()
	fadeTween.Completed:Wait()
	if not isCurrent(myGeneration) then
		return
	end

	-- 5. Done. Cleanup (camera, frozen input, clones) happens on the next
	-- CharacterAdded, below, not here -- the white screen is meant to
	-- keep hiding the transition until the fresh life actually spawns.
	Remotes.Client.Fire("RukhSceneDone")
end

-- ==================== wiring ====================

function RukhController:Init() end

function RukhController:Start()
	player.CharacterAdded:Connect(function()
		activeGeneration += 1
		runActiveCleanup()
	end)

	Remotes.Client.On("HeartAttack", function(age: any, fatal: any)
		if typeof(age) ~= "number" or typeof(fatal) ~= "boolean" then
			log:Warn("HeartAttack: unexpected payload")
			return
		end

		-- FIX (REVIEW-M2-05 #1): starting a new generation cancels
		-- whatever pulse/scene is currently running, so a second
		-- HeartAttack can never stack overlays/sounds/labels.
		local myGeneration = startGeneration()

		if fatal then
			task.spawn(function()
				playFatalPulse(myGeneration)
				if isCurrent(myGeneration) then
					playRukhScene(myGeneration)
				end
			end)
		else
			task.spawn(function()
				playNonFatalPulse(myGeneration)
			end)
		end
	end)

	log:Info("ready")
end

return RukhController

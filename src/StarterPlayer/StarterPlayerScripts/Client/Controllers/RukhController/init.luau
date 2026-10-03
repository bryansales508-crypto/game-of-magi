--!strict
-- Old-age heart attacks and the return-to-the-Rukh death scene.
--
-- Server contract:
--   HeartAttack(age: number, fatal: boolean) -- server -> client. Every online
--   birthday from 60 fires a short non-fatal pulse; a fatal one (old age, always
--   wipes) leads into the scene.
--   Died({cause: "lastLife"}) -- server -> client, fired instead of HeartAttack
--   when a death takes a character's last life; goes straight into the scene.
--   Ordinary deaths never reach the client.
--   RukhSceneDone() -- client -> server, fired when the scene finishes; the
--   server starts the fresh life then, or after 30s regardless.
--
-- Timings come from Config.Scene. The scene's look lives in
-- ReplicatedFirst.AfterLife; this file reads only AfterlifeCamera (BasePart),
-- AfterlifeSpawnBlock (BasePart) and AfterlifeCore (BasePart, optional; a
-- stand-in marker is built when absent).
--
-- Only one pulse or scene runs at a time: a new HeartAttack or a respawn cancels
-- the current one through the shared generation/cleanup list. A fatal sequence
-- freezes input (action sink, PlayerModule controls, humanoid movement, camera)
-- for the whole pulse-then-scene run and restores it all on cleanup.

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
local activeCleanupFns: { () -> () } = {}

-- Registers a teardown step for whatever's running under the current
-- generation. Returns the function itself so a phase that finishes
-- normally (not cancelled) can retire just its own step early with
-- removeActiveCleanup, instead of leaving it to run redundantly later.
local function addActiveCleanup(fn: () -> ()): () -> ()
	table.insert(activeCleanupFns, fn)
	return fn
end

local function removeActiveCleanup(fn: () -> ())
	local index = table.find(activeCleanupFns, fn)
	if index then
		table.remove(activeCleanupFns, index)
	end
end

local function runActiveCleanup()
	local fns = activeCleanupFns
	activeCleanupFns = {}
	for i = #fns, 1, -1 do
		local results = table.pack(pcall(fns[i]))
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

-- Fallback destroy in case the asset never loads and Sound.Ended never fires.
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

-- ==================== input freeze ====================

-- The default PlayerModule's Controls object (WASD/gamepad/touch
-- movement input); GetControls()/Disable()/Enable() is its public API.
-- Returns nil (and warns once) if anything about it is missing or
-- errors, so a freeze/unfreeze never itself throws.
local function getControls(): any
	local playerScripts = player:FindFirstChild("PlayerScripts") :: PlayerScripts?
	local playerModule = playerScripts and playerScripts:FindFirstChild("PlayerModule")
	if not playerModule then
		log:Warn("PlayerScripts.PlayerModule missing; Controls won't be disabled")
		return nil
	end

	local ok, moduleOrErr = pcall(require, playerModule)
	if not ok then
		log:Warn("require(PlayerModule) failed: " .. tostring(moduleOrErr))
		return nil
	end

	local okControls, controlsOrErr = pcall(function()
		return moduleOrErr:GetControls()
	end)
	if not okControls then
		log:Warn("PlayerModule:GetControls() failed: " .. tostring(controlsOrErr))
		return nil
	end

	return controlsOrErr
end

-- Locks down every input path at once (the action sink, PlayerModule controls,
-- humanoid movement, camera) and registers the matching restores, so whichever
-- cleanup runs next puts it all back together. Called once, before the fatal
-- pulse starts.
local function freezeInput(myGeneration: number)
	if not isCurrent(myGeneration) then
		return
	end

	ContextActionService:BindAction(FREEZE_ACTION, function()
		return Enum.ContextActionResult.Sink
	end, false, table.unpack(Enum.PlayerActions:GetEnumItems() :: any))
	addActiveCleanup(function()
		ContextActionService:UnbindAction(FREEZE_ACTION)
	end)

	local controls = getControls()
	if controls then
		local ok, err = pcall(function()
			controls:Disable()
		end)
		if not ok then
			log:Warn("Controls:Disable() failed: " .. tostring(err))
		end
		addActiveCleanup(function()
			local okEnable, enableErr = pcall(function()
				controls:Enable()
			end)
			if not okEnable then
				log:Warn("Controls:Enable() failed: " .. tostring(enableErr))
			end
		end)
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local originalWalkSpeed = humanoid.WalkSpeed
		local originalJumpPower = humanoid.JumpPower
		local originalAutoRotate = humanoid.AutoRotate
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.AutoRotate = false
		addActiveCleanup(function()
			humanoid.WalkSpeed = originalWalkSpeed
			humanoid.JumpPower = originalJumpPower
			humanoid.AutoRotate = originalAutoRotate
		end)
	end

	camera.CameraType = Enum.CameraType.Scriptable
	addActiveCleanup(function()
		camera.CameraType = Enum.CameraType.Custom
		local currentCharacter = player.Character
		local currentHumanoid = currentCharacter and currentCharacter:FindFirstChildOfClass("Humanoid")
		if currentHumanoid then
			camera.CameraSubject = currentHumanoid
		end
	end)
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

-- A heartbeat is "lub-dub": two quick beats BeatGap apart. Plays both beats
-- (each dipping to `dip`), then eases to `rest` over PairGap: the pause before
-- the next cycle, or the final hold after the last one. Returns false the
-- moment this generation goes stale so callers can bail immediately.
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

-- Short, not flashy: Config.Scene.NonFatalCycles lub-dubs, fully clearing
-- between and after each. Never freezes input.
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

-- Cancelling this generation tears down this gui and any sound not yet self-destroyed.
	local sounds: { Sound } = {}
	local cleanup = addActiveCleanup(function()
		gui:Destroy()
		for _, sound in sounds do
			sound:Destroy()
		end
	end)

	for _ = 1, Config.Scene.NonFatalCycles do
		local ok =
			playBeatCycle(myGeneration, frame, NON_FATAL_DIP, NON_FATAL_REST, NON_FATAL_COLOR, Config.Scene.BeatGap, Config.Scene.PairGap, sounds)
		if not ok then
			return
		end
	end

	gui:Destroy()
	removeActiveCleanup(cleanup)
end

-- Each of Config.Scene.FatalCycles cycles deepens the colour/dip and only
-- partially recovers between cycles; the last holds near-black and shows a
-- message. Each cycle's BeatGap/PairGap is stretched by FatalSlowFactor again,
-- compounding, so the beats visibly slow down.
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
	local cleanup = addActiveCleanup(function()
		gui:Destroy()
		for _, sound in sounds do
			sound:Destroy()
		end
	end)

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
	removeActiveCleanup(cleanup)
end

-- ==================== return-to-the-Rukh scene ====================

-- Turns the character golden and neon.
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

-- The walk target: AfterlifeCore if the AfterLife model has one, else a
-- stand-in marker ahead of the spawn point (or the character, if there is no
-- AfterLife model).
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

	-- 1. Camera and character go to AfterlifeCamera / AfterlifeSpawnBlock, or to a
	-- stand-in (camera 12 studs in front looking back) if the model is absent.
	-- freezeInput has already made the camera Scriptable.
	local afterlifeTemplate = ReplicatedFirst:FindFirstChild("AfterLife")
	local afterlifeClone: Instance? = nil
	local spawnBlock: BasePart? = nil

	if afterlifeTemplate then
		local clone = afterlifeTemplate:Clone()
		clone.Parent = Workspace
		afterlifeClone = clone
		addActiveCleanup(function()
			clone:Destroy()
		end)

		local afterlifeCameraPart = clone:FindFirstChild("AfterlifeCamera") :: BasePart?
		spawnBlock = clone:FindFirstChild("AfterlifeSpawnBlock") :: BasePart?
		if afterlifeCameraPart then
			camera.CFrame = afterlifeCameraPart.CFrame
			-- Harmless under Scriptable.
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

	applyRukhAppearance(character)

	local corePosition, standInCore = resolveCoreTarget(rootPart, afterlifeClone, spawnBlock)
	if standInCore then
		addActiveCleanup(function()
			standInCore:Destroy()
		end)
	end

	-- 3. Walk toward the core over Config.Scene.WalkSeconds, fading to white over
	-- the last Config.Scene.FadeSeconds. AutoRotate is re-enabled so the character
	-- faces the core; Controls stays disabled, so this is never player-driven.
	humanoid.AutoRotate = true
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
	addActiveCleanup(function()
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

	-- 4. Cleanup (camera, input, clones) runs on the next CharacterAdded, not here:
	-- the white screen keeps hiding the transition until the fresh life spawns.
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

		-- A new generation cancels any running pulse/scene so overlays never stack.
		local myGeneration = startGeneration()

		if fatal then
			task.spawn(function()
				freezeInput(myGeneration)
				if not isCurrent(myGeneration) then
					return
				end
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

	-- The death that takes a character's last life. Shares the generation/cleanup
	-- machinery above, so it cancels a running pulse and is cancelled in turn.
	-- Goes straight to the scene: no pulses, no message.
	Remotes.Client.On("Died", function(data: any)
		if typeof(data) ~= "table" or data.cause ~= "lastLife" then
			log:Warn("Died: unexpected payload")
			return
		end

		local myGeneration = startGeneration()
		task.spawn(function()
			freezeInput(myGeneration)
			if not isCurrent(myGeneration) then
				return
			end
			playRukhScene(myGeneration)
		end)
	end)

	log:Info("ready")
end

return RukhController

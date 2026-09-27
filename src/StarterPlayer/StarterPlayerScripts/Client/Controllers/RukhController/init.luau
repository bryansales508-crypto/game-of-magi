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

-- "a full-screen red Frame ... that pulses twice with a heartbeat:
-- transparency 1 -> 0.55 -> 0.9 -> 0.5 -> 1 over about 1.2 s, in time with
-- a heartbeat Sound played twice. Then it passes: everything removed, no
-- message."
local function playNonFatalPulse(myGeneration: number)
	if not isCurrent(myGeneration) then
		return
	end

	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	if not isCurrent(myGeneration) then
		return
	end

	local gui, frame = newPulseGui(900, Color3.fromRGB(170, 0, 0), 1)
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

	local segment = 1.2 / 4

	table.insert(sounds, playHeartbeatSound())
	tweenFrame(frame, { BackgroundTransparency = 0.55 }, segment)
	if not isCurrent(myGeneration) then
		return
	end
	tweenFrame(frame, { BackgroundTransparency = 0.9 }, segment)
	if not isCurrent(myGeneration) then
		return
	end
	table.insert(sounds, playHeartbeatSound())
	tweenFrame(frame, { BackgroundTransparency = 0.5 }, segment)
	if not isCurrent(myGeneration) then
		return
	end
	tweenFrame(frame, { BackgroundTransparency = 1 }, segment)
	if not isCurrent(myGeneration) then
		return
	end

	gui:Destroy()
	activeCleanup = nil
end

-- "three slower, heavier beats (about 2.5 s) while the red deepens to
-- (90,0,0) and does not fade; on the last beat the screen goes to
-- near-black (transparency 0.05) and a centred TextLabel ... appears ...
-- for 2 s. Then the scene."
local FATAL_START_COLOR = Color3.fromRGB(170, 0, 0)
local FATAL_END_COLOR = Color3.fromRGB(90, 0, 0)
local FATAL_BEATS = {
	{ dip = 0.5, hold = 0.75 },
	{ dip = 0.35, hold = 0.55 },
	{ dip = 0.15, hold = 0.05 },
}

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

	local segment = (2.5 / #FATAL_BEATS) / 2

	for beatIndex, beat in FATAL_BEATS do
		local color = FATAL_START_COLOR:Lerp(FATAL_END_COLOR, beatIndex / #FATAL_BEATS)
		table.insert(sounds, playHeartbeatSound())
		tweenFrame(frame, { BackgroundTransparency = beat.dip, BackgroundColor3 = color }, segment)
		if not isCurrent(myGeneration) then
			return
		end
		tweenFrame(frame, { BackgroundTransparency = beat.hold }, segment)
		if not isCurrent(myGeneration) then
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

	task.wait(2)
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

-- docs/reference/m2-studio-dump.md §3: RF.VFX.RukhEffects holds the
-- emitters. Cloned fresh onto the torso and a code-built glowing core,
-- rather than relying on any pre-existing attachment on the rig.
local function attachRukhEffects(chara: Model, corePosition: Vector3): { Instance }
	local created: { Instance } = {}

	local vfx = ReplicatedFirst:FindFirstChild("VFX")
	local rukhEffects = vfx and vfx:FindFirstChild("RukhEffects")
	local torso = chara:FindFirstChild("Torso") or chara:FindFirstChild("UpperTorso") or chara:FindFirstChild("HumanoidRootPart")

	if not rukhEffects then
		log:Warn("ReplicatedFirst.VFX.RukhEffects missing; death scene will have no particles")
	elseif torso then
		for _, name in { "Rukh1", "Rukh2", "Rukh3", "Piece1", "Piece2", "Piece3", "Piece4" } do
			local template = rukhEffects:FindFirstChild(name)
			if not template then
				continue
			end
			local clone = template:Clone()
			if clone:IsA("ParticleEmitter") then
				clone.Enabled = true
			end
			clone.Parent = torso
			table.insert(created, clone)
		end
	end

	local core = Instance.new("Part")
	core.Name = "RukhCore"
	core.Shape = Enum.PartType.Ball
	core.Size = Vector3.new(2, 2, 2)
	core.Anchored = true
	core.CanCollide = false
	core.Material = Enum.Material.Neon
	core.Color = GOLD
	core.Position = corePosition
	core.Parent = Workspace
	table.insert(created, core)

	if rukhEffects then
		for _, name in { "RukhInnerLightning", "RukhOuterLightning" } do
			local template = rukhEffects:FindFirstChild(name)
			if template then
				local clone = template:Clone()
				if clone:IsA("ParticleEmitter") then
					clone.Enabled = true
				end
				clone.Parent = core
			end
		end
	end

	return created
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

	-- 2. Camera + AfterLife model (Bryan's, if present in Studio) or the
	-- simple stand-in.
	camera.CameraType = Enum.CameraType.Scriptable
	addCleanup(function()
		camera.CameraType = Enum.CameraType.Custom
		local currentCharacter = player.Character
		local currentHumanoid = currentCharacter and currentCharacter:FindFirstChildOfClass("Humanoid")
		if currentHumanoid then
			camera.CameraSubject = currentHumanoid
		end
	end)

	local corePosition: Vector3
	local afterlifeTemplate = ReplicatedFirst:FindFirstChild("AfterLife")

	if afterlifeTemplate then
		local clone = afterlifeTemplate:Clone()
		clone.Parent = Workspace
		addCleanup(function()
			clone:Destroy()
		end)

		local afterlifeCameraPart = clone:FindFirstChild("AfterlifeCamera") :: BasePart?
		local spawnBlock = clone:FindFirstChild("AfterlifeSpawnBlock") :: BasePart?
		if afterlifeCameraPart then
			camera.CFrame = afterlifeCameraPart.CFrame
			-- FIX (REVIEW-M2-05 #4): WipeHandlerPart2 also pointed the
			-- CameraSubject at AfterlifeCamera; harmless under
			-- Scriptable, kept for parity.
			camera.CameraSubject = afterlifeCameraPart
		end
		if spawnBlock then
			rootPart.CFrame = spawnBlock.CFrame
			corePosition = spawnBlock.Position + spawnBlock.CFrame.LookVector * 15
		else
			log:Warn("ReplicatedFirst.AfterLife has no AfterlifeSpawnBlock")
			corePosition = rootPart.Position + rootPart.CFrame.LookVector * 15
		end
	else
		-- Stand-in: keep the world, camera 12 studs in front of the
		-- character looking back at them.
		local lookVector = rootPart.CFrame.LookVector
		local cameraPosition = rootPart.Position + lookVector * 12 + Vector3.new(0, 2, 0)
		camera.CFrame = CFrame.lookAt(cameraPosition, rootPart.Position + Vector3.new(0, 2, 0))
		corePosition = rootPart.Position + lookVector * 15
	end

	if not isCurrent(myGeneration) then
		return
	end

	-- 3. Character setup + VFX.
	applyRukhAppearance(character)
	local effectInstances = attachRukhEffects(character, corePosition)
	addCleanup(function()
		for _, instance in effectInstances do
			instance:Destroy()
		end
	end)

	-- 4. Walk toward the core over ~6s; fade to white over the last 2s.
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

	task.wait(4)
	if not isCurrent(myGeneration) then
		return
	end

	local fadeTween = TweenService:Create(fade, TweenInfo.new(2, Enum.EasingStyle.Sine, Enum.EasingDirection.In), { BackgroundTransparency = 0 })
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

--!nocheck
-- Replaces Roblox's default character sound script.
--
-- A LocalScript named "RbxCharacterSounds" in StarterPlayerScripts overrides
-- the engine's built-in one of the same name. This copy plays every default
-- sound (jump, land, climb, splash, free-fall, get-up, swim) but NEVER the
-- default "Running" footstep: the game's own footsteps (FootstepController,
-- ReplicatedFirst.SFX.Steps) are the only step sounds, so there is no second
-- Roblox step underneath them.
--
-- It creates the sounds itself on each character's HumanoidRootPart, driven
-- by Humanoid state changes, and leaves out "Running" entirely.

local Players = game:GetService("Players")

local SOUND_DATA = {
	Died = { SoundId = "rbxasset://sounds/uuhhh.mp3" },
	Climbing = { SoundId = "rbxasset://sounds/action_footsteps_plastic.mp3", Looped = true },
	GettingUp = { SoundId = "rbxasset://sounds/action_get_up.mp3" },
	Jumping = { SoundId = "rbxasset://sounds/action_jump.mp3" },
	Landing = { SoundId = "rbxasset://sounds/action_jump_land.mp3" },
	Splash = { SoundId = "rbxasset://sounds/impact_water.mp3" },
	Swimming = { SoundId = "rbxasset://sounds/action_swim.mp3", Looped = true, Pitch = 1.6 },
	FreeFalling = { SoundId = "rbxasset://sounds/action_falling.mp3", Looped = true },
}

local function setup(character)
	local humanoid = character:WaitForChild("Humanoid")
	local root = character:WaitForChild("HumanoidRootPart")

	-- The engine may have made its own sounds before this script ran.
	local running = root:FindFirstChild("Running")
	if running then
		running.Volume = 0
	end

	local sounds = {}
	for name, data in SOUND_DATA do
		local sound = Instance.new("Sound")
		sound.Name = name
		sound.SoundId = data.SoundId
		sound.Looped = data.Looped or false
		sound.PlaybackSpeed = data.Pitch or 1
		sound.Volume = 0.65
		sound.RollOffMaxDistance = 75
		sound.Parent = root
		sounds[name] = sound
	end

	local function play(name)
		local sound = sounds[name]
		if sound then
			sound:Play()
		end
	end
	local function stopLoops()
		for _, name in { "Climbing", "Swimming", "FreeFalling" } do
			sounds[name]:Stop()
		end
	end

	local connections = {}
	local function track(connection)
		table.insert(connections, connection)
	end
	track(humanoid.Died:Connect(function()
		stopLoops()
		play("Died")
	end))
	track(humanoid.StateChanged:Connect(function(_old, new)
		stopLoops()
		if new == Enum.HumanoidStateType.Jumping then
			play("Jumping")
		elseif new == Enum.HumanoidStateType.Landed then
			play("Landing")
		elseif new == Enum.HumanoidStateType.GettingUp then
			play("GettingUp")
		elseif new == Enum.HumanoidStateType.Climbing then
			play("Climbing")
		elseif new == Enum.HumanoidStateType.Swimming then
			play("Splash")
			play("Swimming")
		elseif new == Enum.HumanoidStateType.Freefall then
			play("FreeFalling")
		end
	end))
	-- A climbing loop only sounds while actually moving on the ladder.
	track(humanoid.Climbing:Connect(function(speed)
		sounds.Climbing.PlaybackSpeed = 1
		if math.abs(speed) < 0.1 then
			sounds.Climbing:Pause()
		elseif humanoid:GetState() == Enum.HumanoidStateType.Climbing then
			sounds.Climbing:Resume()
		end
	end))

	character.AncestryChanged:Once(function()
		for _, connection in connections do
			connection:Disconnect()
		end
	end)
end

local player = Players.LocalPlayer
player.CharacterAdded:Connect(setup)
if player.Character then
	task.spawn(setup, player.Character)
end

local Players = game:GetService("Players")

local function onCharacterAdded(character)
	-- Get animator on humanoid
	local humanoid = character:WaitForChild("Humanoid")	local animator = humanoid:WaitForChild("Animator")

	-- Stop all animation tracks
	for _, playingTrack in pairs(animator:GetPlayingAnimationTracks()) do
		playingTrack:Stop(0)
	end

	local animateScript = character:WaitForChild("Animate")
	animateScript.run.RunAnim.AnimationId = "rbxassetid://15421855688"
	animateScript.walk.WalkAnim.AnimationId = "rbxassetid://15421859266"
	animateScript.jump.JumpAnim.AnimationId = "rbxassetid://15428492106"
	animateScript.idle.Animation1.AnimationId = "rbxassetid://15422107398"
	--animateScript.idle.Animation2.AnimationId = "rbxassetid://"
	animateScript.fall.FallAnim.AnimationId = "rbxassetid://15428818320"
	--animateScript.swim.Swim.AnimationId = "rbxassetid://"
	--animateScript.swimidle.SwimIdle.AnimationId = "rbxassetid://"
	--animateScript.climb.ClimbAnim.AnimationId = "rbxassetid://"
end

local function onPlayerAdded(player)
	player.CharacterAppearanceLoaded:Connect(onCharacterAdded)
end

Players.PlayerAdded:Connect(onPlayerAdded)
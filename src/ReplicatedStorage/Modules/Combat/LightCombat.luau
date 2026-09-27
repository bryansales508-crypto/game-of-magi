local DamageService = require(game.ServerScriptService.Services.DamageService)
local db = game:GetService("Debris")

function light(character, air)
	local humanoid = character.Humanoid
	local animator = humanoid:WaitForChild("Animator")
	local intFold = character:WaitForChild("IntFold")

	--Fetching Player and Defining Variables
	local player = game.Players:GetPlayerFromCharacter(character)
	local StatsFold = player:WaitForChild("Stats")
	local Height = StatsFold:WaitForChild("Height")
	local Effects = character:WaitForChild("Effects")
	local hit = intFold:WaitForChild("HitInt") 
	local combatstring = intFold:WaitForChild("CombatString")

	-- RayCast Set Up
	local rcPar = RaycastParams.new()
	rcPar.FilterType = Enum.RaycastFilterType.Exclude
	rcPar.FilterDescendantsInstances = {character}

	local enemy
	local finalHit = false

	-- CombatString
	if combatstring.Value ~= "Engaged" then
		combatstring.Value = "Engaged"
	end
	
	hit.Changed:Connect(function(e)
		if e == 0 then
			combatstring:FindFirstChild("Adversary").Value = ""
		end
	end)

	if hit.Value >= 0 and hit.value < 3 then
		local currenthit = hit.Value + 1
		hit.Value = hit.Value + 1

		if currenthit > 0 and currenthit < 4 then
			local m = math.random(1,3)
			local Missed = character.Torso:WaitForChild("SoundEffects"):FindFirstChild("MissSound"..tostring(m)):Clone()
			Missed.Parent = character.Torso
			Missed:Play()
			db:AddItem(Missed, 1)

			local anim = animator:LoadAnimation(game.ReplicatedStorage.Animations:FindFirstChild("BasicLightHit"..currenthit))
			anim:Play()
			anim:AdjustSpeed(1.2)
		end
	elseif hit.Value == 3 then
		hit.Value = hit.Value + 1
		local anim
		if Effects:FindFirstChild("InAirSender") then
			anim = animator:LoadAnimation(game.ReplicatedStorage.Animations:FindFirstChild("BasicLightHit5"))
		else
			anim = animator:LoadAnimation(game.ReplicatedStorage.Animations:FindFirstChild("BasicLightHit4"))
		end
		anim:Play()
		anim:AdjustSpeed(0.75)

		if intFold:FindFirstChild("CombatString"):WaitForChild("Adversary").Value == "" then
			local m = math.random(1,3)
			local Missed = character.Torso:WaitForChild("SoundEffects"):FindFirstChild("MissSound"..tostring(m)):Clone()
			Missed.Parent = character.Torso
			Missed:Play()
			Missed.PlaybackSpeed = 0.8
			db:AddItem(Missed, 1)
		end

		finalHit = true
	else
		hit.Value = 0
	end

	local lasthit = hit.Value

	delay(1.8, function()
		if lasthit == hit.Value then
			hit.Value = 0
			combatstring.Value = ""
			combatstring:FindFirstChild("Adversary").Value = ""
		end
	end)

	local attacking
	local locked = false
	spawn(function()
		task.wait(0.1)
		attacking:Disconnect()
	end)

	local function packetsender(targChara)
		if not locked and targChara ~= character then
			locked = true
			
			-- Checking if Behind
			local detect = targChara.HumanoidRootPart.CFrame:Inverse() * character.HumanoidRootPart.CFrame
			local behind = false if detect.Z > 1 then behind = true end
			
			local packet = {
				Damage = 3,
				Knockback = true,
				KnockForce = 5,
				Finisher = finalHit,
				Slow = true,
				SlowDuration = 1,
				Hit = true,
				HitType = "LightSword",
				CombatTagged = true,
				EnemyCombatTagged = true,
				RaceModifier = true,
				KnockOnNorms = "falseFinisher",
				ExtenderDuration = 5,
				BlockPunisher = behind
			}
			if hit.Value == 0 or hit.Value > 4 then return end

			DamageService.damage(character, targChara, packet)

			-- CombatString
			combatstring:FindFirstChild("Adversary").Value = targChara.Name
		end
	end

	-- HitBox Crap
	local function failhit()
		for _,n in game.Workspace.Characters:GetChildren() do
			if n:FindFirstChild("Humanoid") and n:FindFirstChild("HumanoidRootPart") and not n:FindFirstChild("CurrentAction") then
				if n ~= character and n.HitiBox then
					local mag = ((character.HumanoidRootPart.Position + (character.HumanoidRootPart.CFrame.LookVector * 3 )) - n.HumanoidRootPart.Position).magnitude
					if mag <= 4 then
						packetsender(n)
					else
						local t = workspace:GetPartsInPart(n.HitBox)
						if table.find(t, character.HitBox) then
							packetsender(n)
						end
					end
				end
			end
		end
	end

	attacking = game["Run Service"].Heartbeat:Connect(function()
		local rcRes = workspace:Raycast(character.HumanoidRootPart.CFrame.Position,character.HumanoidRootPart.CFrame.LookVector * 3, rcPar)
		if rcRes then
			if rcRes.Instance.Name == "HitBox" then
				local targChara = rcRes.Instance.Parent
				packetsender(targChara)
			else
				failhit()
			end
		else
			failhit()
		end
	end)
end

return light
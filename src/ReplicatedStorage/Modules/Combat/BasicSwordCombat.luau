local DamageService = require(game.ServerScriptService.Services.DamageService)
local db = game:GetService("Debris")

function swordcombat(character)
	local humanoid = character.Humanoid
	local animator = humanoid:WaitForChild("Animator")
	local intFold = character:WaitForChild("IntFold")

	--Fetching Player and Defining Variables
	local player = game.Players:GetPlayerFromCharacter(character)
	local StatsFold = player:WaitForChild("Stats")
	local Effects = character:WaitForChild("Effects")
	local hit = intFold:WaitForChild("HitInt") 
	local combatstring = intFold:WaitForChild("CombatString")

	-- Pulling up Sword
	local SwordType = intFold:FindFirstChild("Sword")
	local SwordModel

	if SwordType.Value == "Cutlass" then
		SwordModel = character:FindFirstChild("DisplayCutlass")
	elseif SwordType.Value == "Royal Dagger" then
		SwordModel = character:FindFirstChild("Royal Dagger")
	end
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
		-- Sound
		local m = math.random(1,3)
		local Missed = character.Torso:WaitForChild("SoundEffects"):FindFirstChild("SwordMissSound"..tostring(m)):Clone()
		Missed.Parent = character.Torso
		Missed.Ended:Connect(function()
			Missed:Destroy()
		end)
		Missed:Play()

		local anim = nil

		if SwordType:FindFirstChild("MagicItemIdentifer") then
			-- Type 1
			if SwordType:WaitForChild("MagicItemIdentifer").Value == "Type1" then
				anim = animator:LoadAnimation(game.ReplicatedFirst.Animations.Combat["(S)MagicItemType"]:WaitForChild("MIType1Hit"..tostring(hit.Value)))
				anim:Play()
				anim:AdjustSpeed(0.9) 
			end
		else
			anim = animator:LoadAnimation(game.ReplicatedFirst.Animations.Combat["(B)Sword"]:FindFirstChild("BasicSwordHit"..tostring(hit.Value)))
			anim:Play()
			anim:AdjustSpeed(0.9)
		end

		local mbCopy

		anim:GetMarkerReachedSignal("SlashStart"):Connect(function()
			
			if SwordType:FindFirstChild("MagicItemIdentifer") then
				-- Type 1
				if SwordType:WaitForChild("MagicItemIdentifer").Value == "Type1" then
					SwordModel:FindFirstChild("Blade").Transparency = 1

					-- Animating Sword Movement
					mbCopy = game.ReplicatedFirst.Objects.MovingBlade:Clone()
					mbCopy.Color = Color3.new(0.105882, 0.105882, 0.105882)
					mbCopy.Size = Vector3.new(mbCopy.Size.X, SwordModel.Blade.Size.Y, mbCopy.Size.Z)
					mbCopy.CFrame = SwordModel.Blade.CFrame

					local TempWeld = Instance.new("WeldConstraint")
					TempWeld.Part0 = mbCopy
					TempWeld.Part1 = SwordModel.Blade
					TempWeld.Parent = mbCopy
					mbCopy.Parent = character
				end
			else
				SwordModel:FindFirstChild("default").Transparency = 1

				-- Animating Sword Movement
				mbCopy = game.ReplicatedFirst.Objects.MovingBlade:Clone()
				mbCopy.Size = Vector3.new(mbCopy.Size.X, SwordModel.default.Size.Y, mbCopy.Size.Z)
				mbCopy.CFrame = SwordModel.default.CFrame

				local TempWeld = Instance.new("WeldConstraint")
				TempWeld.Part0 = mbCopy
				TempWeld.Part1 = SwordModel.default
				TempWeld.Parent = mbCopy
				mbCopy.Parent = character
			end
		end)

		anim:GetMarkerReachedSignal("SlashEnd"):Connect(function()

			if SwordType:FindFirstChild("MagicItemIdentifer") then
				-- Type 1
				if SwordType:WaitForChild("MagicItemIdentifer").Value == "Type1" then
					SwordModel:FindFirstChild("Blade").Transparency = 0
					mbCopy:Destroy()
				end
			else
				SwordModel:FindFirstChild("default").Transparency = 0
				mbCopy:Destroy()
			end
		end)

		-- Adding Hit
		hit.Value += 1
	elseif hit.Value == 3 then
		-- Sound
		local m = math.random(2,3)
		local Missed = character.Torso:WaitForChild("SoundEffects"):FindFirstChild("SwordMissSound"..tostring(m)):Clone()
		Missed.Parent = character.Torso
		Missed.Ended:Connect(function()
			Missed:Destroy()
		end)

		local m = math.random(2,3)
		local Missed2 = character.Torso:WaitForChild("SoundEffects"):FindFirstChild("SwordMissSound"..tostring(m)):Clone()
		Missed2.Parent = character.Torso
		Missed2.Ended:Connect(function()
			Missed2:Destroy()
		end)

		Missed:Play()
		Missed.PlaybackSpeed = 0.8
		delay(0.25,function()
			Missed2:Play()
			Missed2.PlaybackSpeed = 0.8
		end)

		local anim = animator:LoadAnimation(game.ReplicatedFirst.Animations.Combat["(B)Sword"].BasicSwordHitFinal)
		anim:Play()

		local mbCopy
		anim:AdjustSpeed(0.9)

		anim:GetMarkerReachedSignal("SlashStart"):Connect(function()
			if SwordType:FindFirstChild("MagicItemIdentifer") then
				-- Type 1
				if SwordType:WaitForChild("MagicItemIdentifer").Value == "Type1" then
					SwordModel:FindFirstChild("Blade").Transparency = 1

					-- Animating Sword Movement
					mbCopy = game.ReplicatedFirst.Objects.MovingBlade:Clone()
					mbCopy.Color = Color3.new(0.105882, 0.105882, 0.105882)
					mbCopy.Size = Vector3.new(mbCopy.Size.X, SwordModel.Blade.Size.Y, mbCopy.Size.Z)
					mbCopy.CFrame = SwordModel.Blade.CFrame

					local TempWeld = Instance.new("WeldConstraint")
					TempWeld.Part0 = mbCopy
					TempWeld.Part1 = SwordModel.Blade
					TempWeld.Parent = mbCopy
					mbCopy.Parent = character
				end
			else
				SwordModel:FindFirstChild("default").Transparency = 1

				-- Animating Sword Movement
				mbCopy = game.ReplicatedFirst.Objects.MovingBlade:Clone()
				mbCopy.Size = Vector3.new(mbCopy.Size.X, SwordModel.default.Size.Y, mbCopy.Size.Z)
				mbCopy.CFrame = SwordModel.default.CFrame

				local TempWeld = Instance.new("WeldConstraint")
				TempWeld.Part0 = mbCopy
				TempWeld.Part1 = SwordModel.default
				TempWeld.Parent = mbCopy
				mbCopy.Parent = character
			end
		end)

		anim:GetMarkerReachedSignal("SlashEnd"):Connect(function()
			if SwordType:FindFirstChild("MagicItemIdentifer") then
				-- Type 1
				if SwordType:WaitForChild("MagicItemIdentifer").Value == "Type1" then
					SwordModel:FindFirstChild("Blade").Transparency = 0
					mbCopy:Destroy()
				end
			else
				SwordModel:FindFirstChild("default").Transparency = 0
				mbCopy:Destroy()
			end
		end)

		finalHit = true

		-- Adding Hit
		hit.Value += 1
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
				Damage = 1,
				Knockback = true,
				KnockForce = 3,
				Finisher = finalHit,
				SpecialFinisher = "DoubleLick",
				Hit = true,
				HitType = "[s]Light",
				CombatTagged = true,
				EnemyCombatTagged = true,
				BlockPunisher = behind,
				Bleed = true,
				StatusEffectDuration = 7,
				Slow = true,
				SlowDuration = 0.75,
				KnockOnNorms = "falseFinisher"
			}
			
			-- Adding for MagicItem
			if SwordType:FindFirstChild("MagicItemIdentifer") then
				-- Type 1
				if SwordType:WaitForChild("MagicItemIdentifer").Value == "Type1" then
					packet["Damage"] = 3
					packet["StatusEffectDuration"] = 9
				end
			end
			
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
				if n ~= character and n.HitBox then
					local mag = ((character.HumanoidRootPart.Position + (character.HumanoidRootPart.CFrame.LookVector * 3 )) - n.HumanoidRootPart.Position).magnitude
					if mag <= 4 then
						packetsender(n)
					else
						local t = workspace:GetPartsInPart(n.HitBox)
						if table.find(t, character:FindFirstChild("SwordHitBox")) then
							packetsender(n)
						end
					end
				end
			end
		end
	end

	attacking = game["Run Service"].Heartbeat:Connect(function()
		if not locked then
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
		end
	end)
end


return swordcombat
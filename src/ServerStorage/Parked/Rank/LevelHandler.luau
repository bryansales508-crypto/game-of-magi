local module = {}

GoodVibe = 25
BadVibe = -25

local tweenserv = game:GetService("TweenService")


module.RankUp = function(player, method, slain)
	local StatsFold = player:FindFirstChild("Stats")
	local Race = StatsFold.Race
	local MaxMagoi = StatsFold.MaxMagoi
	local Depr = StatsFold.Depravity
	local LBR = StatsFold.LovedByRukh

	local chara = player.Character or player.CharacterAdded:Wait()

	local RaceMod

	if Race.Value == 5 then
		RaceMod = 5
	elseif Race.Value == 4 then
		RaceMod = 3
	else
		RaceMod = 1
	end

	local PlayerAlign
	if LBR.Value - Depr.Value > GoodVibe then
		PlayerAlign = "Hero"
	elseif LBR.Value - Depr.Value <= GoodVibe and LBR.Value - Depr.Value > BadVibe then
		PlayerAlign = "Neutral"
	else 
		PlayerAlign = "Villain"
	end

	if slain then
		local SlainStatsFold = game.Players:FindFirstChild(slain):FindFirstChild("Stats")
		local SlainRace = SlainStatsFold.Race
		local SlainMaxMagoi = SlainStatsFold.MaxMagoi
		local SlainDepr = SlainStatsFold.Depravity
		local SlainLBR = SlainStatsFold.LovedByRukh

		local SlainAlign
		if SlainLBR.Value - SlainDepr.Value > GoodVibe then
			SlainAlign = "Hero"
		elseif SlainLBR.Value - SlainDepr.Value <= GoodVibe and SlainLBR.Value - SlainDepr.Value > BadVibe then
			SlainAlign = "Neutral"
		else 
			SlainAlign = "Villain"
		end

		if method == "Gripped" then

		elseif method == "TurnIn" then

		elseif method == "PackageDelivery" then

			-- How much Max Magoi (EXP) this gives. Decent mission for beginners. Overall better for Villain types. 
			if PlayerAlign == "Hero" and SlainAlign == "Villain" then
				MaxMagoi.Value += 3*RaceMod
				LBR.Value += 1
				
			elseif PlayerAlign == "Hero" and SlainAlign == "Neutral" then
				MaxMagoi.Value += 1*RaceMod
				if LBR.Value > 0 then LBR.Value += -1 end
				
			elseif PlayerAlign == "Hero" and SlainAlign == "Hero" then
				if LBR.Value > 0 then LBR.Value += -1 end
				Depr.Value += 1
				
				
			elseif PlayerAlign == "Villain" and SlainAlign == "Villain" then
				MaxMagoi.Value += 1*RaceMod
				
			elseif PlayerAlign == "Villain" and SlainAlign == "Neutral" then
				MaxMagoi.Value += 3*RaceMod
				Depr.Value += 1
				
			elseif PlayerAlign == "Villain" and SlainAlign == "Hero" then
				MaxMagoi.Value += 5*RaceMod
				Depr.Value += 2
				
				
			elseif PlayerAlign == "Neutral" and SlainAlign == "Villain" then
				MaxMagoi.Value += 3*RaceMod
				LBR.Value += 1
				
			elseif PlayerAlign == "Neutral" and SlainAlign == "Neutral" then
				MaxMagoi.Value += 5*RaceMod
				
			elseif PlayerAlign == "Neutral" and SlainAlign == "Hero" then
				MaxMagoi.Value += 3*RaceMod
				Depr.Value += 1
			end
		end
		
		local Dep1 = chara.Torso.RukhAttach1.DepravityRukh1
		local Dep2 = chara.Torso.RukhAttach2.DepravityRukh2
		local Dep3 = chara.Torso.RukhAttach3.DepravityRukh3
		local RS = chara.Torso.RukhSound
		
		local sound = chara.Torso:FindFirstChild("RukhSound")
		sound.Looped = true
		sound.RollOffMaxDistance = 50
		sound.Volume = 0
		local Tween = tweenserv:Create(sound, TweenInfo.new(1, Enum.EasingStyle.Linear), {Volume = 0.1})

		sound:Play()
		Tween:Play()

		Dep1.Enabled = true
		Dep2.Enabled = true
		Dep3.Enabled = true

		delay(3, function()
			local Tween = tweenserv:Create(sound, TweenInfo.new(1, Enum.EasingStyle.Linear), {Volume = 0})
			Tween:Play()
			Tween.Completed:Connect(function()
				sound:Stop()
				sound.Looped = false
			end)

			Dep1.Enabled = false
			Dep2.Enabled = false
			Dep3.Enabled = false
		end)
	else
		if method == "PackageDelivery" then

			-- How much Max Magoi (EXP) this gives. Decent mission for beginners. Overall better for Hero types.
			if PlayerAlign == "Hero" then
				MaxMagoi.Value += 3*RaceMod
			elseif PlayerAlign == "Neutral" then
				MaxMagoi.Value += 5*RaceMod

				LBR.Value += 1

				if Depr.Value > 0 then
					Depr.Value += -1
				end
			elseif PlayerAlign == "Villain" then
				MaxMagoi.Value += 1*RaceMod

				LBR.Value += 1
			end
		end

		local Dep1 = chara.Torso.RukhAttach1.Rukh1
		local Dep2 = chara.Torso.RukhAttach2.Rukh2
		local Dep3 = chara.Torso.RukhAttach3.Rukh3
		local RS = chara.Torso.RukhSound

		local sound = chara.Torso:FindFirstChild("RukhSound")
		sound.Looped = true
		sound.RollOffMaxDistance = 50
		sound.Volume = 0
		local Tween = tweenserv:Create(sound, TweenInfo.new(1, Enum.EasingStyle.Linear), {Volume = 0.1})

		sound:Play()
		Tween:Play()

		Dep1.Enabled = true
		Dep2.Enabled = true
		Dep3.Enabled = true

		delay(3, function()
			local Tween = tweenserv:Create(sound, TweenInfo.new(1, Enum.EasingStyle.Linear), {Volume = 0})
			Tween:Play()
			Tween.Completed:Connect(function()
				sound:Stop()
				sound.Looped = false
			end)

			Dep1.Enabled = false
			Dep2.Enabled = false
			Dep3.Enabled = false
		end)
	end
end

return module

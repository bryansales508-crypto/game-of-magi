local chara = script.Parent
local Humanoid = chara:WaitForChild'Humanoid'
local player = game.Players:GetPlayerFromCharacter(chara)

while player:WaitForChild("Loaded").Value == false do task.wait() end
while chara:WaitForChild("AppearenceLoaded").Value == false do task.wait()end

local Race = player.Stats:WaitForChild("Race") 
local MaxMagoi = player.Stats:WaitForChild("MaxMagoi")
local Height = player.Stats:WaitForChild("Height")

local Effects = chara:WaitForChild("Effects")

-- Setting Max Health

local StarterHealth = 50

local function HealthDetermine(dt, inc)
	local MaxHealth
	if dt == "Starter" then
		if Race.Value == 1 then
			MaxHealth = StarterHealth + 100 + (10 * Height.Value)
		elseif Race.Value == 2 then
			MaxHealth = StarterHealth + (MaxMagoi.Value/2) + (3 * Height.Value)
		elseif Race.Value == 3 then
			MaxHealth = StarterHealth + (MaxMagoi.Value/2) + 20 + (3 * Height.Value)
		elseif Race.Value == 4 or Race.Value == 5 then
			MaxHealth = StarterHealth + (MaxMagoi.Value/100) + (10 * Height.Value)
		end

		Humanoid.MaxHealth = 0
	elseif dt == "Strength" then
		--[[if Race.Value == (1 or 4 or 5) then
			MaxHealth = inc/2
		end]]
	elseif dt == "Depravity" then
		--MaxHealth = inc/2
	elseif dt == "MaxMagoi" then
		if Race.Value ~= 1 then
			if Race.Value == 4 or Race.Value == 5 then
				MaxHealth = inc/100
			else 
				MaxHealth = inc/2
			end
		end
	elseif dt == "Height" then
		if Race.Value == 1 or Race.Value == 4 or Race.Value == 5 then
			MaxHealth = inc * 10
		else
			MaxHealth = inc * 3
		end
	end

	if MaxHealth then
		Humanoid.MaxHealth += MaxHealth
	end
end

HealthDetermine("Starter")
Humanoid.Health = Humanoid.MaxHealth

--Defining Regen Rates
local Regen = 1
local Rate = 1/250

Effects.ChildAdded:Connect(function(child)
	if child.Name == "CombatTagged" then
		Regen = 10
	end
	if child.Name == "Knocked" then
		Regen = 5
	end
end)


Effects.ChildRemoved:Connect(function(child)
	if child.Name == "CombatTagged" and not Effects:FindFirstChild("Knocked") then
		Regen = 1
	end
	if child.Name == "Knocked" then
		Regen = 1
	end
end)

--Refiguring MaxHealth

-- Height Add
local OldHeight = Height.Value
Height.Changed:Connect(function()
	local NewHeight = Height.Value
	local Increase = NewHeight - OldHeight

	HealthDetermine("MaxHealth", Increase)
	OldHeight = NewHeight
end)

-- Strength Add
--[[local OldStr = Strength.Value
Strength.Changed:Connect(function()
	local NewStr = Strength.Value
	local Increase = NewStr - OldStr

	HealthDetermine("Strength", Increase)
	OldStr = NewStr
end)]]

-- Depravity Add/Subtract
--[[local OldDep = Depravity.Value
Depravity.Changed:Connect(function()
	local NewDep = Depravity.Value
	local Increase = NewDep - OldDep

	HealthDetermine("Depravity", Increase)
	OldDep = NewDep
end)]]

-- Max Magoi Add
local OldMM = MaxMagoi.Value
MaxMagoi.Changed:Connect(function()
	local NewMM = MaxMagoi.Value
	local Increase = NewMM - OldMM

	HealthDetermine("MaxMagoi", Increase)
	OldMM = NewMM
end)


--Reducing Blindness
Humanoid.HealthChanged:Connect(function(h)
	-- Low Health Music
	--[[if h < Humanoid.MaxHealth/3 and h >= 1 then
		if not (chara:WaitForChild("RegionInfo"):FindFirstChild("LowHealth") or chara:WaitForChild("Effects"):FindFirstChild("Knocked")) then
			local LH = Instance.new("IntValue")
			LH.Name = "LowHealth"
			LH.Parent = chara:FindFirstChild("RegionInfo")
		end
	elseif h >= Humanoid.MaxHealth/3 then
		if chara:FindFirstChild("RegionInfo"):FindFirstChild("LowHealth") then
			chara.RegionInfo.LowHealth:Destroy()
		end
	end]]
end)

--Regenerating Health

spawn(function()
	while true do
		while Humanoid.Health < Humanoid.MaxHealth do

			-- Burn / Bleed Regeneration Prevention
			local dt = wait(Regen)
			local dh = dt*Rate*Humanoid.MaxHealth

			if not Effects:FindFirstChild("FireBurn") and not Effects:FindFirstChild("Bleed") then 
				Humanoid.Health = math.min(Humanoid.Health + dh, Humanoid.MaxHealth)
			end 
		end
		--Wait
		Humanoid.HealthChanged:Wait()
	end
end)

Effects.ChildAdded:Connect(function(v) -- beginning the knock out revival
	if v.Name == "Knocked" then
		spawn(function()
			while v.Parent ~= nil do
				if Humanoid.Health > Humanoid.MaxHealth/10 then -- if they are above 10% of their health
					local blindGUI = player.PlayerGui:FindFirstChild("Blind")

					if blindGUI then -- lighting blind
						if blindGUI.Blind2.Blind1.ImageTransparency ~= 0.5 then
							blindGUI.Blind2.Blind1.ImageTransparency = 1
						end
					end

					Effects.Knocked.Value -= 1

					if Effects.Knocked.Value <= 0 then -- removing knock
						Effects.Knocked:Destroy()
					end
				end
				
				task.wait(1)
			end
		end)
	end
end)
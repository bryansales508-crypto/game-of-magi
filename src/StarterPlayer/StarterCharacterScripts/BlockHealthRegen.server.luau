local chara = script.Parent
local Humanoid = chara:WaitForChild'Humanoid'
local player = game.Players:GetPlayerFromCharacter(chara)

while player:WaitForChild("Loaded").Value == false do task.wait() end
while chara:WaitForChild("AppearenceLoaded").Value == false do task.wait()end

local Race = player.Stats:WaitForChild("Race") 
local MaxMagoi = player.Stats:WaitForChild("MaxMagoi")

local Effects = chara:WaitForChild("Effects")

local IntFold = chara:WaitForChild("IntFold")
local Block = IntFold:WaitForChild("BlockInt")
local MaxBlock = IntFold:WaitForChild("MaxBlockHpInt")

--Defining Regen Rates
local Regen = 6
local Rate = 1/750

Effects.ChildAdded:Connect(function(child)
	if child.Name == "CombatTagged" then
		Regen = 12
	end
	if child.Name == "Knocked" then
		Regen = 8
	end
end)


Effects.ChildRemoved:Connect(function(child)
	if child.Name == "CombatTagged" and not Effects:FindFirstChild("Knocked") then
		Regen = 6
	end
	if child.Name == "Knocked" then
		Regen = 6
	end
end)

--Regenerating Block

while true do
	while Block.Value < MaxBlock.Value do
		local dt = wait(Regen)
		local dh = dt*Rate*MaxBlock.Value
		
		Block.Value = math.min(Block.Value + dh, MaxBlock.Value)
	end
	Block.Changed:Wait()
end
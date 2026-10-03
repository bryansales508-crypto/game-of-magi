repeat task.wait() until game.Loaded

local player = game.Players.LocalPlayer
local chara = player.Character or player.CharacterAdded:Wait()

while chara:WaitForChild("AppearenceLoaded").Value == false do task.wait() end
while player:WaitForChild("Loaded").Value == false do task.wait() end
while player:WaitForChild("Stats").Height.Value == 10 do task.wait() end

local statFold = player.Stats

local hunStat = statFold:WaitForChild("Hunger")

local GUI = game.ReplicatedFirst.GUI

local FullBar = game.ReplicatedFirst.GUI.MiscGUI.Full
local EmptyBar = game.ReplicatedFirst.GUI.MiscGUI.Empty

local barHolder = script.Parent.HudFrame.HungerBar

local function hungerUpd()
	for _, child in ipairs(barHolder:GetChildren()) do
		if child:IsA("ImageLabel") and child.Name ~= "Padding" then
			child:Destroy()
		end
	end

	local setNum = math.floor(hunStat.Value)
	local setEmpty = 5 - setNum

	for i = 1, setNum do
		local bar = FullBar:Clone()
		bar.Parent = barHolder
	end

	for i = 1, setEmpty do
		local bar = EmptyBar:Clone()
		bar.Parent = barHolder
	end
end

hunStat.Changed:Connect(hungerUpd)

hungerUpd()
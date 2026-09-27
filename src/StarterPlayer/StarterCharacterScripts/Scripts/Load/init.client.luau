-- Variables
print("Test")
local contentP = game:GetService("ContentProvider")
local gooey = script:WaitForChild("LoadScreen"):Clone()
local loadEvent = game.ReplicatedStorage.Remotes.MiscRemotes.MainScreen

-- services

local ts = game:GetService("TweenService")

repeat wait() until game:IsLoaded() -- loading game

-- Assests
local assets = game:GetDescendants()
local max = #assets

-- PlayerVariables
local player = game.Players.LocalPlayer
local playerGooey = player:WaitForChild("PlayerGui")
gooey.Parent = playerGooey

local tween = ts:Create(gooey.Frame:WaitForChild("ImageLabel"), TweenInfo.new(5,Enum.EasingStyle.Linear),{ImageTransparency = 1})
local tween2 = ts:Create(gooey.Frame:WaitForChild("ImageLabel"), TweenInfo.new(5,Enum.EasingStyle.Linear),{ImageTransparency = 0.5})

tween:Play()
tween.Completed:Connect(function()
	tween2:Play()
	local con
	con = tween2.Completed:Connect(function()
		tween:Play()
		con:Disconnect()
	end)
end)

for i, load in assets do
	--contentP:PreloadAsync({load})
	--gooey:WaitForChild("Frame"):WaitForChild("TextLabel").Text = i.."/"..max
end

tween:Cancel()
tween2:Cancel()

local tween3 = ts:Create(gooey.Frame:WaitForChild("ImageLabel"), TweenInfo.new(1,Enum.EasingStyle.Linear),{ImageTransparency = 0})
tween3:Play()
tween3.Completed:Connect(function()
	task.wait(2)
	gooey:Destroy()
	loadEvent:FireServer()
end)


repeat task.wait() until game.Loaded

local player = game.Players.LocalPlayer

local character = player.Character or player.CharacterAdded:Wait()
while character:WaitForChild("AppearenceLoaded").Value == false do task.wait() end

local Tween = game:GetService("TweenService")

HUD = player.PlayerGui.HUD.HudFrame

local blockDebounce = false

local orangebar = HUD.BlockBarImageFrame.BlockHP.BlockOrangeBar

local intFold = character:WaitForChild("IntFold")
local BlockInt = intFold.BlockInt
local MaxBlockHpInt = intFold.MaxBlockHpInt

BlockInt:GetPropertyChangedSignal("Value"):Connect(function()
	local orangeInfo = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	local percent = BlockInt.Value / MaxBlockHpInt.Value

	local orangeProperties = {
		Size = UDim2.new((percent - 0.062),0,1,0)
	}

	local orangeTwen = Tween:Create(orangebar, orangeInfo, orangeProperties)
	
	orangeTwen:Play()
end)

--if not working add debounce (TJJ3442 suggests)
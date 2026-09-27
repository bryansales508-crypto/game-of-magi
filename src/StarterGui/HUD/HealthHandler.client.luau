repeat task.wait() until game.Loaded

local player = game.Players.LocalPlayer

local character = player.Character or player.CharacterAdded:Wait()
while character:WaitForChild("AppearenceLoaded").Value == false do task.wait() end

local humanoid = character:WaitForChild("Humanoid")

local Tween = game:GetService("TweenService")

HUD = player.PlayerGui.HUD.HudFrame

local healthDebounce = false


local emptyBar = HUD.HPBarImageFrame.HP

local redBar = HUD.HPBarImageFrame.HP.HPRedBar
local redDarkBar = HUD.HPBarImageFrame.HP.HPDarkRedBar
local whiteDmgBar = HUD.HPBarImageFrame.HP.HPWhiteDmgTakenBar

local healthInd = HUD.HPBarImageFrame.HP.HealthIndicator

local prevHealth = humanoid.MaxHealth

healthInd.Text = string.format("%d / %d", humanoid.Health, humanoid.MaxHealth)

humanoid.HealthChanged:Connect(function(currHealth)
	healthInd.Text = string.format("%d / %d", currHealth, humanoid.MaxHealth)

	local redDelay
	local redDarkDelay
	local whiteDelay

	local redSpeed

	if prevHealth <= currHealth then
		redSpeed = 1
		redDelay = 0.5
		whiteDelay = 0
		redDarkDelay = 0
	else
		redSpeed = 0.3
		redDelay = 0
		whiteDelay = 0.5
		redDarkDelay = 0.5
	end

	prevHealth = currHealth

	local redInfo = TweenInfo.new(redSpeed, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, redDelay)
	local redProperties = {
		Size = UDim2.new((currHealth / humanoid.MaxHealth),0,1,0)
	}

	local whiteInfo = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, whiteDelay)
	local whiteProperties = {
		Size = UDim2.new((currHealth / humanoid.MaxHealth),0,1,0)
	}

	local darkRedInfo = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, redDarkDelay)
	local darkRedProperties = {
		Size = UDim2.new((currHealth / humanoid.MaxHealth),0,0.357,0)
	}

	local redTwen = Tween:Create(redBar, redInfo, redProperties)
	local whiteTwen = Tween:Create(whiteDmgBar, whiteInfo, whiteProperties)
	local darkRedTwen = Tween:Create(redDarkBar, darkRedInfo, darkRedProperties)

	redTwen:Play()
	darkRedTwen:Play()
	whiteTwen:Play()

	healthDebounce = false
end)

emptyBar.MouseEnter:Connect(function()
	healthInd.TextTransparency = 0
end)

emptyBar.MouseLeave:Connect(function()
	healthInd.TextTransparency = 1
end)
--if not working add debounce (TJJ3442 suggests)
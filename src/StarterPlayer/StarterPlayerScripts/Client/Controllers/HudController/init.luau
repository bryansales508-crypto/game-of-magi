--!strict
-- The health and block bars. Same look and tween animation as the old
-- src/StarterGui/HUD/HealthHandler.client.luau and BlockHandler.client.luau
-- (now removed), driven by the Health/MaxHealth/Block/MaxBlock player
-- attributes instead of Humanoid.Health / the old IntFold Values.
--
-- The HUD ScreenGui itself stays StarterGui-sourced (ResetOnSpawn is the
-- class default, true), so PlayerGui.HUD is destroyed and recloned on
-- every respawn; this controller re-finds the bars and reconnects on every
-- CharacterAdded, disconnecting its previous set first so nothing leaks.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared:WaitForChild("Log"))

local log = Log.new("HudController")

local player = Players.LocalPlayer

local HudController = {}

local function bindHealthBar(hud: Instance): { RBXScriptConnection }
	local hpBarImageFrame = hud:FindFirstChild("HPBarImageFrame")
	local hp = (hpBarImageFrame and hpBarImageFrame:FindFirstChild("HP")) :: Frame?
	if not hp then
		log:Warn("HUD.HPBarImageFrame.HP missing; health bar disabled")
		return {}
	end

	local redBar = hp:FindFirstChild("HPRedBar") :: Frame?
	local redDarkBar = hp:FindFirstChild("HPDarkRedBar") :: Frame?
	local whiteDmgBar = hp:FindFirstChild("HPWhiteDmgTakenBar") :: Frame?
	local healthInd = hp:FindFirstChild("HealthIndicator") :: TextLabel?
	if not (redBar and redDarkBar and whiteDmgBar and healthInd) then
		log:Warn("HUD health bar children missing; health bar disabled")
		return {}
	end

	local prevHealth: number? = nil

	local function update()
		local health = player:GetAttribute("Health")
		local maxHealth = player:GetAttribute("MaxHealth")
		if typeof(health) ~= "number" or typeof(maxHealth) ~= "number" or maxHealth <= 0 then
			return
		end

		healthInd.Text = string.format("%d / %d", health, maxHealth)

		local healing = prevHealth == nil or prevHealth <= health
		prevHealth = health

		local redSpeed = if healing then 1 else 0.3
		local redDelay = if healing then 0.5 else 0
		local whiteDelay = if healing then 0 else 0.5
		local redDarkDelay = if healing then 0 else 0.5

		local frac = health / maxHealth

		local redInfo = TweenInfo.new(redSpeed, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, redDelay)
		local whiteInfo = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, whiteDelay)
		local darkRedInfo = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, redDarkDelay)

		TweenService:Create(redBar, redInfo, { Size = UDim2.fromScale(frac, 1) }):Play()
		TweenService:Create(whiteDmgBar, whiteInfo, { Size = UDim2.fromScale(frac, 1) }):Play()
		TweenService:Create(redDarkBar, darkRedInfo, { Size = UDim2.fromScale(frac, 0.357) }):Play()
	end

	local connections: { RBXScriptConnection } = {}
	table.insert(connections, player:GetAttributeChangedSignal("Health"):Connect(update))
	table.insert(connections, player:GetAttributeChangedSignal("MaxHealth"):Connect(update))
	table.insert(
		connections,
		hp.MouseEnter:Connect(function()
			healthInd.TextTransparency = 0
		end)
	)
	table.insert(
		connections,
		hp.MouseLeave:Connect(function()
			healthInd.TextTransparency = 1
		end)
	)
	update()

	return connections
end

local function bindBlockBar(hud: Instance): { RBXScriptConnection }
	local blockBarImageFrame = hud:FindFirstChild("BlockBarImageFrame")
	local blockHp = blockBarImageFrame and blockBarImageFrame:FindFirstChild("BlockHP")
	local orangeBar = (blockHp and blockHp:FindFirstChild("BlockOrangeBar")) :: Frame?
	if not orangeBar then
		log:Warn("HUD.BlockBarImageFrame.BlockHP.BlockOrangeBar missing; block bar disabled")
		return {}
	end

	local function update()
		local block = player:GetAttribute("Block")
		local maxBlock = player:GetAttribute("MaxBlock")
		if typeof(block) ~= "number" or typeof(maxBlock) ~= "number" or maxBlock <= 0 then
			return
		end
		local percent = block / maxBlock
		local info = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(orangeBar, info, { Size = UDim2.fromScale(percent - 0.062, 1) }):Play()
	end

	local connections: { RBXScriptConnection } = {}
	table.insert(connections, player:GetAttributeChangedSignal("Block"):Connect(update))
	table.insert(connections, player:GetAttributeChangedSignal("MaxBlock"):Connect(update))
	update()

	return connections
end

local activeConnections: { RBXScriptConnection } = {}

local function disconnectAll()
	for _, connection in activeConnections do
		connection:Disconnect()
	end
	table.clear(activeConnections)
end

local function bindForCurrentGui()
	disconnectAll()

	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	local hudGui = playerGui:WaitForChild("HUD")
	local hud = hudGui:WaitForChild("HudFrame")

	for _, connection in bindHealthBar(hud) do
		table.insert(activeConnections, connection)
	end
	for _, connection in bindBlockBar(hud) do
		table.insert(activeConnections, connection)
	end
end

function HudController:Init() end

function HudController:Start()
	player.CharacterAdded:Connect(bindForCurrentGui)
	if player.Character then
		bindForCurrentGui()
	end
	log:Info("ready")
end

return HudController

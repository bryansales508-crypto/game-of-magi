local player = game.Players.LocalPlayer
local chara = player.Character or player.CharacterAdded:Wait()
while chara:WaitForChild("AppearenceLoaded").Value == false do task.wait() end

-- Services
local TS = game:GetService("TweenService")

-- Functions
local function TranMsg(xt)
	local olPos = xt.Position
	xt.Position = olPos + UDim2.new(0,0,0,-100)
	local tw = TS:Create(xt, TweenInfo.new(1, Enum.EasingStyle.Bounce), {Position = olPos})
	tw:Play()

	task.delay(5, function()
		local tw = TS:Create(xt, TweenInfo.new(0.5, Enum.EasingStyle.Linear), {Position = olPos + UDim2.new(0,0,0,-250)})
		tw:Play()
		tw.Completed:Connect(function()
			xt:Destroy()
		end)
	end)
end

-- Variables
local RegionInfo = chara:WaitForChild("RegionInfo")

--[[ Light Store
local color1 = game.Lighting.Atmosphere.Color
local color2 = game.Lighting.Atmosphere.Decay
local val1 = game.Lighting.Atmosphere.Glare
local val2 = game.Lighting.Atmosphere.Haze
local val3 = game.Lighting.Atmosphere.Density

local color3 = game.Lighting.Ambient
local color4 = game.Lighting.ColorShift_Top
local color5 = game.Lighting.ColorShift_Bottom
local val4 = game.Lighting.EnvironmentDiffuseScale
local val5 = game.Lighting.EnvironmentSpecularScale
local color6 = game.Lighting.OutdoorAmbient]]

-- Module
local sfx = require(game.ReplicatedStorage.Modules.SoundController)
local msgTypes = game.ReplicatedFirst.GUI.MsgTypes

-- Regions
RegionInfo.ChildAdded:Connect(function(c)
	--[[if chara:WaitForChild("IntFold"):FindFirstChild("CharacterInScreen") then
		local check = chara:WaitForChild("IntFold"):FindFirstChild("CharacterInScreen")
		
		sfx.MainControl(chara, "Die")
		
		while check.Parent ~= nil do task.wait() end
		sfx.CutOff(chara, "All")
	end]]
	
	if c.Name == "Badlands" then
		sfx.MainControl(chara, "L'imminence")
		sfx.MainControl(chara, "Notre Empire Dévastation")
	--	sfx.MainControl(chara, "Sentiment Actuel 01")

		sfx.Playlist(chara)
	elseif c.Name == "EndlessDesert" then
		
	elseif c.Name == "SakuraIsland" then
		sfx.MainControl(chara, "Resort Island")
		sfx.MainControl(chara, "We Did It")
		--sfx.MainControl(chara, "Lullaby")
		
		sfx.Playlist(chara)
	elseif c.Name == "BanditCamp" then
	
	elseif c.Name == "Qarzin" then
		-- Music
		sfx.MainControl(chara, "Danse Bizzare")
		sfx.MainControl(chara, "Tostarena Ruins")
		sfx.MainControl(chara, "Paix D'espirit")
		sfx.Playlist(chara)
		
		-- Announcer 
		local cc = msgTypes["MsgHold[CITY]"]:Clone()
		cc.CityTitle.Text = "Q A R Z I N"
		cc.Description.Text = "The Merchant's Playground"
		cc.Parent = player.PlayerGui.Announcer.AnnouncerFrame
		
		TranMsg(cc.CityTitle)
		TranMsg(cc.Description)
		
		task.delay(5.25, function()
			cc:Destroy()
		end)
	elseif c.Name == "Gourge" then
		
	elseif c.Name == "QishanCity" then
		sfx.MainControl(chara, "Danse Bizzare")
		sfx.MainControl(chara, "Tostarena Ruins")
		sfx.MainControl(chara, "Paix D'espirit")
		--sfx.MainControl(chara, "Gerudo Town Night")
		sfx.MainControl(chara, "Gerudo Town Day")

		sfx.Playlist(chara)
	elseif c.Name == "QishanEntrance" then
		
	elseif c.Name == "SultanChest" then
		
	elseif c.Name == "DesertLairTunnel" then
		
		-- Lighting
		game.Lighting.Atmosphere.Color = Color3.fromRGB(0, 0, 0)
		game.Lighting.Atmosphere.Decay = Color3.fromRGB(0, 0, 0)
		game.Lighting.Atmosphere.Glare = 0
		game.Lighting.Atmosphere.Haze = 0
		game.Lighting.Atmosphere.Density = 0.65

		game.Lighting.Ambient = Color3.fromRGB(0,0,0)
		game.Lighting.ColorShift_Top = Color3.fromRGB(0,0,0)
		game.Lighting.ColorShift_Bottom = Color3.fromRGB(0,0,0)
		game.Lighting.EnvironmentDiffuseScale = 0
		game.Lighting.EnvironmentSpecularScale = 0
		game.Lighting.OutdoorAmbient = Color3.fromRGB(0,0,0)
		
		
	elseif c.Name == "LowHealth" then
		--sfx.MainControl(chara, "LowHealthAmbi", 0.1)
		--TODO: Interweave with the rest of the music. Like it needs to cut off the current music, then resume when it ends.
	elseif c.Name == "Slept" then
		
	elseif c.Name == "Rain" then
		sfx.MainControl(chara, "RainAmbi", 0.2)
	elseif c.Name == "Ocean" then
		sfx.MainControl(chara, "OceanAmbi", 0.6)
	end
end)

RegionInfo.ChildRemoved:Connect(function(c)
	if c.Name == "Badlands" then
		sfx.CutOff(chara, "All")
	elseif c.Name == "EndlessDesert" then

	elseif c.Name == "BanditCamp" then
		
	elseif c.Name == "Qarzin" then
		sfx.CutOff(chara, "All")
	elseif c.Name == "Gourge" then

	elseif c.Name == "QishanCity" then
		sfx.CutOff(chara, "All")
	elseif c.Name == "QishanEntrance" then

	elseif c.Name == "SultanChest" then
		
	elseif c.Name == "SakuraIsland" then
		sfx.CutOff(chara, "All")
	elseif c.Name == "DesertLairTunnel" then
		--[[Lighting
		game.Lighting.Atmosphere.Color = color1
		game.Lighting.Atmosphere.Decay = color2
		game.Lighting.Atmosphere.Glare = val1
		game.Lighting.Atmosphere.Haze = val2
		game.Lighting.Atmosphere.Density = val3

		game.Lighting.Ambient = color3
		game.Lighting.ColorShift_Top = color4
		game.Lighting.ColorShift_Bottom = color5
		game.Lighting.EnvironmentDiffuseScale = val4
		game.Lighting.EnvironmentSpecularScale = val5
		game.Lighting.OutdoorAmbient = color6]]
		
	elseif c.Name == "LowHealth" then
		
	elseif c.Name == "Slept" then
		
	elseif c.Name == "Rain" then
		sfx.CutOff(chara, "RainAmbi")
	elseif c.Name == "Ocean" then
		sfx.CutOff(chara, "OceanAmbi")
	end
end)

-- Random Local Sounds

-- Coin Reward
--[[
local RewardS = MSounds.CoinReward:Clone()
RewardS.Parent = chara.Torso

player.OnCharacter.Currency.Gold.Changed:Connect(function()
	RewardS:Play()
end)

player.OnCharacter.Currency.Silver.Changed:Connect(function()
	RewardS:Play()
end)

player.OnCharacter.Currency.Copper.Changed:Connect(function()
	RewardS:Play()
end)]]



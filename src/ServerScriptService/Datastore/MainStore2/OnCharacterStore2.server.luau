local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local SSS = game:GetService("ServerScriptService")

local ds = game:GetService("DataStoreService")
local assets = require(game.ReplicatedFirst.Assets)

CharaStats = {
	"Clothing_Shirt",
	"Clothing_Pants",
	--"Bounty",
	"Position",
	--"JailTime",
	--"Lives",
	--"Spells",
	"Copper",
	"Silver",
	"Gold",
	--"Huang",
	--"SkillSet1", -- Race Traits
	--"NPContinuation",
	--"MagicItemTable",
	"HatSpot1",
	"HatSpot2",
	"HatSpot3",
	"Row1",
	"Row2", 
}

-- MISC
local Locker = require(game.ReplicatedFirst.Assets)

-- functions

local function createVal(i)
	if i:find("Cloth") then
		return Instance.new("StringValue"), "Clothes"
	elseif i:find("Position") then
		return nil
	elseif i == "Copper" or i == "Silver" or i == "Gold" then
		return Instance.new("IntValue"), "Currency"
	elseif i:find("HatSpot") then
		return Instance.new("StringValue"), "Hats"
	elseif i:find("Row") then
		return Instance.new("StringValue"), "Inventory"
	else 
		return Instance.new("IntValue")
	end
end

local function setNewPlayerData(i, ply)
	if i:find("Clothing") then
		return ""
	elseif i == "Copper" or i == "Silver" or i == "Gold" then
		local starterNum = 0
		if i == "Copper" then -- starting amount
			starterNum = 20
		end

		local gui = ply.PlayerGui:WaitForChild("Currency").Bank.CoinPurse:FindFirstChild(i) -- updating GUI
		if gui then
			gui.Text = tostring(starterNum)
		end
		
		return starterNum
	elseif i:find("HatSpot") or i:find("Row") then
		return ""
	else -- Position
		return 0
	end
end

local function updateReturnPlayer(i, val, ply, check)
	if i == "Copper" or i == "Gold" or i == "Silver" then
		local gui = ply.PlayerGui:WaitForChild("Currency").Bank.CoinPurse:FindFirstChild(i) -- updating GUI
		if gui then
			gui.Text = tostring(val)
		end

		if check ~= "return" then
			ply.Character.Torso:WaitForChild("CoinReward"):Play() -- playing Sound
		end
	elseif i == "Position" or i:find("Row") or i:find("Cloth") then
		--DO NOTHING
	elseif i:find("HatSpot") then
		-- Thinking it has to root out this and maybe like remove the hat ? idk.
	end
end

-- Load/save utilities
local statStore = ds:GetDataStore(script.Parent.Parent.CurrentStore.Value)

local function loadData(player)
	local success, data = pcall(function()
		return statStore:GetAsync(player.UserId)
	end)
	if not success then
		warn("Data didn't load.")
	end
	return (success and data) or {}
end

local function saveData(player, statsToSave)
	local success, errorMsg = pcall(function()
		statStore:UpdateAsync(player.UserId, function(statsFromPast)
			statsFromPast = statsToSave
			
			return statsFromPast
		end)
	end)

	if not success then
		warn(errorMsg)
	end
end

local ingameData = {}
local dirtyData = {}

Players.PlayerAdded:Connect(function(player)
	local savingAlready = false --db
	
	-- Loaded Value
	local Loaded = Instance.new("BoolValue")
	Loaded.Name = "LoadedOC"
	Loaded.Parent = player
	Loaded.Value = false

	-- Needed Values
	local Stats = player:WaitForChild("Stats")

	-- Folder
	local OnCharacterFolder = Instance.new("Folder")
	OnCharacterFolder.Name = "OnCharacter"
	OnCharacterFolder.Parent = player

	local Clothes = Instance.new("Folder")
	Clothes.Name = "Clothes"
	Clothes.Parent = OnCharacterFolder

	local Currency = Instance.new("Folder")
	Currency.Name = "Currency"
	Currency.Parent = OnCharacterFolder
	
	local Hats = Instance.new("Folder")
	Hats.Name = "Hats"
	Hats.Parent = OnCharacterFolder
	
	local Inventory = Instance.new("Folder")
	Inventory.Name = "Inventory"
	Inventory.Parent = OnCharacterFolder

	local posVal = Instance.new("Vector3Value")
	posVal.Name = "Position"
	posVal.Parent = OnCharacterFolder

	local savedtheData = loadData(player)
	ingameData[player] = savedtheData

	-- IntVal Creation
	for _,i in CharaStats do
		if i == "Position" then -- position work
			--[[local valData = savedtheData[i] -- calling data

			if valData == nil then -- newPlayer
				local x,y,z = setNewPlayerData(i, player)
				posVal.Value = Vector3.new(x,y,z)
				savedtheData[i] = {X=x,Y=y,Z=z}
			else -- returnPlayer
				posVal.Value = Vector3.new(valData.X, valData.Y, valData.Z)
			end

			posVal.Changed:Connect(function(v)
				savedtheData[i] = {X=v.X, Y=v.Y, Z=v.Z}
				updateReturnPlayer(i, v, player)
				saveData(player, savedtheData)
			end)]]
		else 
			local val,toParent = createVal(i) -- value for folder
			val.Name = i
			val.Parent = OnCharacterFolder:FindFirstChild(toParent)

			local valData = savedtheData[i] -- setting data
			
			if i == "Copper" or i == "Silver" or i == "Gold" then -- need to update the gui on load
				local gui = player.PlayerGui:WaitForChild("Currency").Bank.CoinPurse:FindFirstChild(i)
				if gui then gui.Text = tostring(valData) end
			end

			if valData == nil then --newPlayer
				valData = setNewPlayerData(i, player) -- setting new value
				savedtheData[i] = valData --updating values
			end
			val.Value = valData -- setting the value to our local stores

			val.Changed:Connect(function(v) -- updating if the value is changed in game
				ingameData[player][i] = v -- data stored in the server
				updateReturnPlayer(i, v, player) -- updating player to reflect
				dirtyData[player] = true -- marking player as data that needs to be saved eventually
			end)
		end
	end

	Loaded.Value = true
end)

-- saving for server
task.spawn(function()
	while true do
		task.wait(60)
		
		for player, data in ingameData do
			if dirtyData[player] then
				dirtyData[player] = false
				print(data)
				
				saveData(player, data)
			end
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	saveData(player, ingameData[player])
end)

game:BindToClose(function() -- save when the game closes
	for player, data in ingameData do
		saveData(player, data)
	end
end)
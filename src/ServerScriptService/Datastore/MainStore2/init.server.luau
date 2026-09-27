local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local SSS = game:GetService("ServerScriptService")

local ds = game:GetService("DataStoreService")
local assets = require(game.ReplicatedFirst.Assets)

PlyStats = {
	"Race",
	"HairColor",
	"FirstName",
	--"Family",
	--"MagicType",
	--"MagicType2",
	"Kingdom",
	--"DjinnCapturer",
	--"DjinnEquip",
	"MaxMagoi",
	"EyeColor",
	"FaceBase",
	--"Mark",
	"Gender",
	"Age",
	"Height",
	"GrowthProfile",
	--"Depravity",
	--"Strength",
	"MouthShape",
	--"LovedByRukh",
	"SkinTone",
	"TimePassed",
	"ProgToAge",
	"Hunger"
}

-- functions

local function createVal(i)
	if i == "Height" or i == "Hunger" then
		return Instance.new("NumberValue")
	elseif i:find("HairColor") then
		return nil
	elseif i:find("Name") or i == "GrowthProfile" then -- firstname, growthprofile
		return Instance.new("StringValue")
	else -- race, gender, skintone, age, kingdom, eyecolor, facebase, mouthshape, maxmagoi, timepassed, progtoage
		return Instance.new("IntValue")
	end
end

local ItemHandler = require(game.ServerScriptService.Character.ItemHandler)

local function setNewPlayerData(i, player)
	if i == "Race" then
		local raceDecision = math.random(1,100)

		if raceDecision <= 50 then
			raceDecision = 2 -- Human
		elseif raceDecision > 50 and raceDecision <= 70 then
			local MagiChance = math.random(1, 1000)
			if MagiChance == 1000 then
				raceDecision = 5 -- Magi
			else
				raceDecision = 4 -- Magician
			end
		elseif raceDecision > 70 and raceDecision <= 85 then
			raceDecision = 3 -- Imuchakk
		else
			raceDecision = 1 -- Fanalis
		end

		raceDecision = 2 -- TODO: Setting everyone to human till more races are added.
		return raceDecision
	elseif i == "Age" then
		return 13
	elseif i == "Height" then
		return 10
	elseif i == "GrowthProfile" then
		return ""
	elseif i == "Kingdom" then
		return math.random(1,1) --TODO: For now, setting Kingdom to Middle Eastern
	elseif i == "EyeColor" then
		return math.random(1,5)
	elseif i == "FaceBase" then
		return math.random(1,2)
	elseif i == "MouthShape" then
		return math.random(1,6)
	elseif i:find("HairColor") then
		return math.random(1,1000) / 1000, math.random(1,1000) / 1000, math.random(1,1000) / 1000
	elseif i == "MaxMagoi" then
		local MMNum = 0
		if player.Stats:WaitForChild("Race").Value == 1 then -- fanalis
			MMNum = 1
		elseif player.Stats:WaitForChild("Race").Value == 2 or player.Stats:WaitForChild("Race").Value == 3 then -- human, immuchakk
			MMNum = 10
		elseif player.Stats:WaitForChild("Race").Value == 4 then -- magician
			MMNum = 100
		elseif player.Stats:WaitForChild("Race").Value == 5 then -- magi
			MMNum = 1000
		end

		return MMNum
	elseif i == "FirstName" then
		local random = math.random(1,50)

		return assets.FirstNames.sindria.male[random]
	elseif i == "TimePassed" then
		return os.time()
	elseif i == "Hunger" then
		return 5
	else -- gender, skintone, progtoage
		return 0
	end
end


local function updateReturnPlayer(i, val, ply, check)
	if check ~= "return" then
		if i == "MaxMagoi" or i == "FirstName" or i == "TimePassed" or i == "ProgToAge" or i == "Age" or i == "Hunger" or i == "GrowthProfile" or i == "Height" then
			-- nothing
		elseif i == "Gender" or i == "SkinTone" then
			-- nothing? I need it to update, but this gets changed when ur in appearence at initial start		
		else --race, kingdom, eyecolor, facebase, mouthshape, haircolor
			ply:LoadCharacter()
		end
	end
end

-- Load/save utilities
local statStore = ds:GetDataStore(script.Parent.CurrentStore.Value)

local function loadData(player)
	local success, data = pcall(function()
		return statStore:GetAsync(player.UserId)
	end)
	if not success then
		warn("Data didn't load.")
		local BadDataWarning = Instance.new("IntValue") -- warning game not to save the bad data.
		BadDataWarning.Name = "BadData"
		BadDataWarning.Parent = player

		player:Kick("Data didn't load, rejoin in a couple minutes.") -- removing player
	end
	return (success and data) or {}
end

local function saveData(player, statsToSave)
	local success, errorMsg = pcall(function()
		statStore:SetAsync(player.UserId, statsToSave)
	end)

	if not success then
		warn(errorMsg)
	end
end

-- NEW: ingameData + dirtyData tables, mirroring OnCharacter2's pattern.
-- These let the dev command handler (and anything else) mutate a player's
-- live stats table and flag it for the periodic sweep to pick up, instead
-- of relying on the old per-Stat 6-second cooldown gate.
local ingameData = {}
local dirtyData = {}

Players.PlayerAdded:Connect(function(player)
	-- Loaded Value
	local Loaded = Instance.new("BoolValue")
	Loaded.Name = "Loaded"
	Loaded.Parent = player
	Loaded.Value = false

	-- Folder
	local StatsFolder = Instance.new("Folder")
	StatsFolder.Name = "Stats"
	StatsFolder.Parent = player

	local hcVal = Instance.new("Color3Value")
	hcVal.Name = "HairColor"
	hcVal.Parent = StatsFolder

	local savedData = loadData(player)
	ingameData[player] = savedData --register this player's live table

	for _,i in PlyStats do
		if i == "HairColor" then -- handling specifically for haircolor
			local valData = savedData[i] -- get data
			if not valData then -- if none, new player
				local r,g,b = setNewPlayerData(i, player)
				hcVal.Value = Color3.new(r, g, b)
				savedData[i] = {R=r, G=g, B=b}
			else -- if return, update our stores
				hcVal.Value = Color3.new(valData.R, valData.G, valData.B)
			end

			hcVal.Changed:Connect(function(v)
				savedData[i] = {R=v.R, G=v.G, B=v.B}
				updateReturnPlayer(i, v, player)
				dirtyData[player] = true -- flag instead of immediate save
			end)
		else
			local val = createVal(i) -- value for folder
			val.Name = i
			val.Parent = StatsFolder

			local valData = savedData[i]

			if valData == nil then --newPlayer
				valData = setNewPlayerData(i, player)
				savedData[i] = valData -- setting new value
			end

			val.Value = valData -- setting the value to our local stores

			val.Changed:Connect(function(v) -- updating if the value is changed in game
				savedData[i] = v
				updateReturnPlayer(i, val, player)
				dirtyData[player] = true -- flag instead of immediate save
			end)
		end
	end
	
	repeat task.wait() until player:FindFirstChild("LoadedOC") and player.LoadedOC.Value
	Loaded.Value = true
end)

--periodic sweep, mirroring OnCharacter2
task.spawn(function()
	while true do
		task.wait(60)

		for player, data in ingameData do
			if dirtyData[player] then
				dirtyData[player] = false
				saveData(player, data)
			end
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	if not player:FindFirstChild("BadData") and ingameData[player] then
		saveData(player, ingameData[player])
	end
	ingameData[player] = nil
	dirtyData[player] = nil
end)

game:BindToClose(function() -- save when the game closes
	for player, data in ingameData do
		if not player:FindFirstChild("BadData") then
			saveData(player, data)
		end
	end
end)
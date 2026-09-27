-- services
local ageHandle = require(game.ServerScriptService.Character.AgeHandler)
local heightHandle = require(game.ServerScriptService.Character.HeightHandler)
local itemHandle = require(game.ServerScriptService.Character.ItemHandler)


-- tuning
local SECONDS_PER_YEAR = 30 --debug    -- 5 min
local TICK             = 10 -- how often we check, in seconds
local GROW_START_AGE   = 13
local GROW_END_AGE     = 18

-- Advance a player's age based on accumulated real time, then resync height.

local function rebuildAccessories(ply, char)
	-- destroy current cloaks (anything whose name is a known cloak)
	for _, acc in char:GetChildren() do
		if acc:IsA("Accessory") and heightHandle.isGameHat(acc.Name) then
			acc:Destroy()
		end
	end

	-- re-equip everything from saved codes
	local items = ply.OnCharacter:FindFirstChild("Hats")
	if not items then return end
	for _, p in items:GetChildren() do
		if p.Value ~= "" then
			itemHandle.equip(p.Value, char)
		end
	end
end

local function sizeCharacter(ply, jump)
	local char = ply.Character
	local statFold = ply:FindFirstChild("Stats")
	if not char or not statFold then return end

	local profile = ageHandle.unpack(statFold.GrowthProfile.Value)
	if not profile then
		local profileStr, height = ageHandle.start(statFold.Age.Value, statFold.Race.Value, statFold.Gender.Value)
		statFold.GrowthProfile.Value = profileStr
		statFold.Height.Value = height
		return
	end

	local height = ageHandle.heightAt(profile, statFold.Age.Value)
	local fat = ageHandle.fatAt(profile, statFold.Age.Value) 

	local ratio = heightHandle.heightToRatio(height, fat)
	heightHandle.resize(char:GetDescendants(), ratio, char)
	rebuildAccessories(ply, char)

	statFold.Height.Value = height
end

local function processAging(statFold, player)
	local profileStr = statFold.GrowthProfile.Value
	if ageHandle.unpack(profileStr) == nil then return end -- no valid profile yet; skip

	-- bank the real time elapsed since we last looked
	local now = os.time()
	statFold.ProgToAge.Value += now - statFold.TimePassed.Value
	statFold.TimePassed.Value = now

	-- convert banked time into whole years
	local yearsToAdd = math.floor(statFold.ProgToAge.Value / SECONDS_PER_YEAR)
	if yearsToAdd > 0 then
		statFold.Age.Value += yearsToAdd
		statFold.ProgToAge.Value -= yearsToAdd * SECONDS_PER_YEAR -- keep the remainder
		sizeCharacter(player) -- size the character and make sure first time is destroyed
		if player.Character:FindFirstChild("CheckSizing") then
			player.Character:FindFirstChild("CheckSizing"):Destroy()
		end
	elseif player.Character:FindFirstChild("CheckSizing") then
		sizeCharacter(player) -- in case of a new spawn, still size
		player.Character:FindFirstChild("CheckSizing"):Destroy()
	end
end


game.Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(chara)
		-- wait until stats are loaded and if first-time height roll has happened
		while not player:WaitForChild("Loaded").Value do task.wait() end
		while player:WaitForChild("Stats").Height.Value == 10 do task.wait() end
		-- until character has fully loaded
		while not chara:WaitForChild("AppearenceLoaded").Value do task.wait() end

		-- first time size
		local checkVal = Instance.new("IntValue")
		checkVal.Name = "CheckSizing"
		checkVal.Parent = chara

		local statFold = player.Stats
		processAging(statFold, player) -- age character

		task.spawn(function() -- loop
			while player.Parent and chara.Parent do
				task.wait(TICK)
				if not (player.Parent and chara.Parent) then break end
				processAging(statFold, player)
			end
		end)
	end)
end)

--[[game.Players.PlayerAdded:Connect(function(player) -- has to be seperate because latency between player add and character add
	--age wait until stats are loaded and if first-time height roll has happened
	while not player:WaitForChild("Loaded").Value do task.wait() end
	while player:WaitForChild("Stats").Height.Value == 10 do task.wait() end

	--age sudden changes
	local ageVerify = player.Stats.Age.Value -- stored age that will get updated
	local ageChange = nil -- in case age gets reverted by admin or game
	local ageChange = player.Stats.Age.Changed:Connect(function(n)
		if player.Parent and player.Character then
			if ageVerify > n then
				print(ageVerify, n)
				ageVerify = player.Stats.Age.Value -- update the stored age so we are always accurate
				if not player.Character:FindFirstChild("CheckSizing") then -- make sure this isn't getting captured by new spawn
					sizeCharacter(player, true)
				end
			elseif ageVerify < n and ageVerify ~= n+1 then
				print(ageVerify, n)
				ageVerify = player.Stats.Age.Value -- update the stored age so we are always accurate
				if not player.Character:FindFirstChild("CheckSizing") then -- make sure this isn't getting captured by new spawn
					sizeCharacter(player, true)
				end
			else
				ageVerify = player.Stats.Age.Value -- update the stored age so we are always accurate
			end
		else
			ageChange:Disconnect()
		end
	end)
end)

--  TODO: Stil working on this.]]

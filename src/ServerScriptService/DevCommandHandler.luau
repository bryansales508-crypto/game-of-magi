local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

local DevCommandHandler = {}

local MAINSTORE_NAME = "Mainstore2"
local ONCHARACTER_STORE_NAME = "OnCharacterStore2"

local mainStore = DataStoreService:GetDataStore(MAINSTORE_NAME)
local onCharacterStore = DataStoreService:GetDataStore(ONCHARACTER_STORE_NAME)

-- Single-dev whitelist. Add more UserIds later as a comma-separated list.
local AUTHORIZED_USERIDS = {
	[27938432] = true,
}

-- ====================================================================
-- FIELD REGISTRY
-- Maps a command keyword -> where that field lives and how to reach it.
--
--   store        = "Mainstore" | "OnCharacter"   (which DataStore/table)
--   folder       = player instance path under the player, as a function
--                  returning the Instance (or nil if not found)
--   dataKey      = the exact key name inside the saved data table
--   instanceName = the exact Instance name under that folder
--   isNumber     = true if Add (+) mode is meaningful for this field
-- ====================================================================

local FieldRegistry = {
	-- Currency (OnCharacter store, nested under OnCharacter.Currency)
	silvercoin = {
		store = "OnCharacter",
		dataKey = "Silver",
		instanceName = "Silver",
		getFolder = function(player) return player:FindFirstChild("OnCharacter") and player.OnCharacter:FindFirstChild("Currency") end,
		isNumber = true,
	},
	coppercoin = {
		store = "OnCharacter",
		dataKey = "Copper",
		instanceName = "Copper",
		getFolder = function(player) return player:FindFirstChild("OnCharacter") and player.OnCharacter:FindFirstChild("Currency") end,
		isNumber = true,
	},
	goldcoin = {
		store = "OnCharacter",
		dataKey = "Gold",
		instanceName = "Gold",
		getFolder = function(player) return player:FindFirstChild("OnCharacter") and player.OnCharacter:FindFirstChild("Currency") end,
		isNumber = true,
	},

	-- Simple Stats fields (Mainstore, directly under player.Stats)
	age = {
		store = "Mainstore",
		dataKey = "Age",
		instanceName = "Age",
		getFolder = function(player) return player:FindFirstChild("Stats") end,
		isNumber = true,
	},
	height = {
		store = "Mainstore",
		dataKey = "Height",
		instanceName = "Height",
		getFolder = function(player) return player:FindFirstChild("Stats") end,
		isNumber = true,
	},
	hunger = {
		store = "Mainstore",
		dataKey = "Hunger",
		instanceName = "Hunger",
		getFolder = function(player) return player:FindFirstChild("Stats") end,
		isNumber = true,
	},
	maxmagoi = {
		store = "Mainstore",
		dataKey = "MaxMagoi",
		instanceName = "MaxMagoi",
		getFolder = function(player) return player:FindFirstChild("Stats") end,
		isNumber = true,
	},
	exp = {
		-- NOTE: "Exp" doesn't currently exist in either script's stat list.
		-- Wired here as a placeholder pointing at Mainstore/Stats so it's a
		-- one-line addition once you add a real Exp value to PlyStats.
		store = "Mainstore",
		dataKey = "Exp",
		instanceName = "Exp",
		getFolder = function(player) return player:FindFirstChild("Stats") end,
		isNumber = true,
	},
}

-- ====================================================================
-- INTERNAL HELPERS
-- ====================================================================

local function findPlayerByName(targetName)
	targetName = string.lower(targetName)
	for _, p in Players:GetPlayers() do
		if string.lower(p.Name) == targetName then
			return p
		end
	end
	return nil
end

local function resolveOfflineUserId(targetName)
	local success, userId = pcall(function()
		return Players:GetUserIdFromNameAsync(targetName)
	end)
	if success then
		return userId
	end
	return nil
end

-- Applies set/add math given the existing value, requested value, and mode.
local function computeNewValue(currentValue, requestedValue, mode)
	if mode == "add" then
		return (currentValue or 0) + requestedValue
	else -- "set"
		return requestedValue
	end
end

-- ====================================================================
-- ONLINE PATH
-- Edits the live Instance directly so existing .Changed listeners
-- (GUI updates, sounds, dirty-flagging) keep working untouched.
-- ====================================================================

local function executeOnline(player, field, requestedValue, mode)
	local folder = field.getFolder(player)
	if not folder then
		return false, "Could not find data folder for " .. player.Name .. " (not loaded yet?)"
	end

	local valueInstance = folder:FindFirstChild(field.instanceName)
	if not valueInstance then
		return false, "Could not find " .. field.instanceName .. " instance for " .. player.Name
	end

	local newValue = computeNewValue(valueInstance.Value, requestedValue, mode)
	valueInstance.Value = newValue -- triggers existing .Changed listeners, dirty flag, save, etc.

	return true, player.Name .. "'s " .. field.dataKey .. " is now " .. tostring(newValue)
end

-- ====================================================================
-- OFFLINE PATH
-- Uses UpdateAsync (atomic, merge-safe) against the correct store.
-- ====================================================================

local function executeOffline(userId, targetNameForMessage, field, requestedValue, mode)
	local store = (field.store == "Mainstore") and mainStore or onCharacterStore

	local finalValue
	local success, errorMsg = pcall(function()
		store:UpdateAsync(userId, function(data)
			data = data or {}
			local current = data[field.dataKey]
			finalValue = computeNewValue(current, requestedValue, mode)
			data[field.dataKey] = finalValue
			return data
		end)
	end)

	if not success then
		return false, "Offline update failed for " .. targetNameForMessage .. ": " .. tostring(errorMsg)
	end

	return true, targetNameForMessage .. "'s " .. field.dataKey .. " is now " .. tostring(finalValue) .. " (offline write)"
end

-- ====================================================================
-- PUBLIC API
-- ====================================================================

-- issuer       : the Player running the command (for the auth check)
-- commandName  : string, e.g. "silvercoin" (lowercase, no leading dot, no +)
-- targetName   : string, the username to target
-- value        : number, the value to set/add
-- mode         : "set" or "add"
function DevCommandHandler.Execute(issuer, commandName, targetName, value, mode)
	if not AUTHORIZED_USERIDS[issuer.UserId] then
		return false, "You are not authorized to use dev commands."
	end

	local field = FieldRegistry[string.lower(commandName)]
	if not field then
		return false, "Unknown command: " .. tostring(commandName)
	end

	if type(value) ~= "number" then
		return false, "Value must be a number."
	end

	mode = mode or "set"

	-- Try online first.
	local onlinePlayer = findPlayerByName(targetName)
	if onlinePlayer then
		return executeOnline(onlinePlayer, field, value, mode)
	end

	-- Fall back to offline.
	local userId = resolveOfflineUserId(targetName)
	if not userId then
		return false, "Could not find player (online or offline) named: " .. targetName
	end

	return executeOffline(userId, targetName, field, value, mode)
end

-- Add inside DevCommandHandler as well.
function DevCommandHandler.IsAuthorized(player)
	return AUTHORIZED_USERIDS[player.UserId] == true
end

-- Returns a formatted list of all available commands, grouped by store.
function DevCommandHandler.ListCommands()
	local mainstoreCmds = {}
	local oncharacterCmds = {}

	for cmdName, field in FieldRegistry do
		if field.store == "Mainstore" then
			table.insert(mainstoreCmds, cmdName)
		else
			table.insert(oncharacterCmds, cmdName)
		end
	end

	table.sort(mainstoreCmds)
	table.sort(oncharacterCmds)

	local lines = { "Available commands (use .cmd+ for ADD mode):" }

	if #oncharacterCmds > 0 then
		table.insert(lines, "  [Currency/OnCharacter] ." .. table.concat(oncharacterCmds, "  ."))
	end
	if #mainstoreCmds > 0 then
		table.insert(lines, "  [Stats/Mainstore] ." .. table.concat(mainstoreCmds, "  ."))
	end

	return table.concat(lines, "\n")
end

return DevCommandHandler

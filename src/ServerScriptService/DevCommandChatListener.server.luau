--[[
	DevCommandChatListener

	Listens for chat messages of the form:
		.silvercoin iiBry 2000      -> SET iiBry's silver to 2000
		.silvercoin+ iiBry 2000     -> ADD 2000 to iiBry's silver
		.age Bryan 16

	Parses and forwards to DevCommandHandler.Execute. Confirmation messages
	are sent only to the issuer via a private system message (StarterGui's
	TextChatService SystemMessage, falling back to a console print).

	Place this under ServerScriptService (e.g. ServerScriptService.DevCommandChatListener).
	Requires DevCommandHandler to be a sibling/accessible module.
]]

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")

local DevCommandHandler = require(script.Parent.DevCommandHandler) -- adjust path as needed

-- Sends a message visible only to the issuing player.
local function notifyIssuer(player, message)
	-- TextChatService system message channel (modern chat)
	local ok = pcall(function()
		local channel = TextChatService.TextChannels:FindFirstChild("RBXSystem")
		if channel then
			channel:DisplaySystemMessage(message)
		end
	end)

	if not ok then
		-- Fallback: just print to server console tagged with the player's name,
		-- visible to you in Studio/server logs even if the channel lookup fails.
		print("[DevCommand -> " .. player.Name .. "]: " .. message)
	end
end

-- Parses ".command target value" or ".command+ target value"
-- Returns commandName, mode ("set"/"add"), targetName, value (number) — or nil on failure.
local function parseCommand(message)
	if message:sub(1, 1) ~= "." then
		return nil
	end

	local parts = {}
	for word in message:gmatch("%S+") do
		table.insert(parts, word)
	end

	if #parts ~= 3 then
		return nil
	end

	local rawCommand = parts[1]:sub(2) -- strip leading "."
	local targetName = parts[2]
	local rawValue = parts[3]

	local mode = "set"
	local commandName = rawCommand
	if rawCommand:sub(-1) == "+" then
		mode = "add"
		commandName = rawCommand:sub(1, -2)
	end

	local value = tonumber(rawValue)
	if not value then
		return nil
	end

	return commandName, mode, targetName, value
end

Players.PlayerAdded:Connect(function(player)
	player.Chatted:Connect(function(message)
		-- Intercept .cmd (list commands) before the normal parser.
		if message:lower() == ".cmd" then
			-- Still gate behind the auth check so non-devs don't see it.
			local ok = DevCommandHandler.IsAuthorized(player)
			if ok then
				notifyIssuer(player, DevCommandHandler.ListCommands())
			end
			return
		end

		local commandName, mode, targetName, value = parseCommand(message)
		
		local commandName, mode, targetName, value = parseCommand(message)
		if not commandName then
			return -- not a recognized command format, ignore silently
		end

		local success, resultMessage = DevCommandHandler.Execute(player, commandName, targetName, value, mode)

		if success then
			notifyIssuer(player, "[DevCommand] " .. resultMessage)
		else
			notifyIssuer(player, "[DevCommand ERROR] " .. resultMessage)
		end
	end)
end)

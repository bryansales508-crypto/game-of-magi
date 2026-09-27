local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local SSS = game:GetService("ServerScriptService")

local StatStore = require(SSS.Datastore.DataStore2)
local CurrentStore = script.Parent.CurrentStore.Value

--[[game.Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(chara)
		task.delay(3, function() -- slight delay
			player:WaitForChild("Loaded") -- waiting on loads
			player:WaitForChild("LoadedOC")
			
			task.spawn(function()
				while chara:WaitForChild("AppearenceLoaded").Value ~= true do task.wait() end -- waiting for appearence to be set

				if player:FindFirstChild("FreshSpawn") then -- setting up a backup for new player spawn

					StatStore.SaveAll(player)

					local current = StatStore(CurrentStore, player)
					local backup = StatStore(CurrentStore.."_SpawnBackUp", player)
					print(backup)
					print(current)
				end
			end)
		end)
	end)

	-- chat commands
	local cmds = {
		"Race",
		"Gender",
	}

	local function cmdGiven(t,p,c)
		print(t..p..c)
		
	end
	
	local allowedUsers = {
		["iiBry"] = true,
		["notCapaIot"] = true
	}

	local function onPlayerChatted(player, msg)
		if string.sub(msg, 1, 1) ~= "." then return end -- only respond to commands starting with '.'

		local split = msg:split(" ")
		local commandName = string.sub(split[1], 2) -- remove the '.' from the command
		if not table.find(cmds, commandName) then
			warn("[OWNER] " .. player.Name .. ": Did not find command.")
			return
		end

		local targetName = split[2]
		if not targetName or string.lower(targetName) == "me" then return end

		local targetPlayer = nil
		for _, p in ipairs(game.Players:GetPlayers()) do
			if string.lower(p.Name) == string.lower(targetName) then
				targetPlayer = p
				break
			end
		end

		if targetPlayer then
			local value = msg:sub(#commandName + #targetPlayer.Name + 4) -- trims ".cmd target "
			cmdGiven(targetPlayer.Name, commandName, value)
		else
			warn("[OWNER] " .. player.Name .. ": Did not find player. Check spelling.")
		end
	end

	game.Players.PlayerAdded:Connect(function(player)
		if allowedUsers[player.Name] then
			player.Chatted:Connect(function(msg)
				onPlayerChatted(player, msg)
			end)
		end
	end)
end)]]
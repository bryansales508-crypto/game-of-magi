
-- spawn locations --TODO: Once you add back kingdoms, they shoudl get their own specific set of spawns.
spawnfold = game.Workspace.MAP.Spawns
spawnlocations = {
	spawnfold.QarzinSpawn.Position
}

-- Services
local RS = game:GetService("RunService")

-- Events
local loadEvent = game.ReplicatedStorage.Remotes.MiscRemotes.MainScreen


game.Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(chara)
		local hrt = chara.HumanoidRootPart

		-- Defining Location
		local Pos = player:WaitForChild("OnCharacter"):WaitForChild("Position")
		local lastPos = hrt.CFrame

		if Pos.Value == Vector3.new(0,0,0) then
			Pos = spawnlocations[1]	
		end
		
		local loading = true -- loading
		local loadCon
		loadCon = loadEvent.OnServerEvent:Connect(function(LoadPly)
			if LoadPly == player then
				loading = false
				loadCon:Disconnect()
			end
		end)
		repeat task.wait() until loading == false
		
		--TODO: Death stuff.
		while chara:WaitForChild("AppearenceLoaded").Value == false do task.wait() end -- Waiting for Appearence
		hrt.CFrame = CFrame.new(Pos) -- teleporting character --TODO: Once you add back rukh blocks this will need to be in game.
		
		
		-- Updating Player Location
		--[[RS.Stepped:Connect(function()
			if player.OnCharacter:WaitForChild("Lives").Value > 0 and not player:FindFirstChild("WipedRecent") and not player:FindFirstChild("RecentDeath") then
				if hrt.Position ~= lastPos then
					lastPos = hrt.Position
					Pos.Value = hrt.Position
				end
			end
		end)]]
	end)
end)
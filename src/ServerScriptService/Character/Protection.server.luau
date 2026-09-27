game.Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(chara)
		
		spawn(function()
			task.wait(30)
			if not chara:FindFirstChild("AppearenceLoaded") or chara:FindFirstChild("AppearenceLoaded").Value ~= true then
				player:Kick("Appearence isn't loading, try rejoining.")
			end
		end)
	end)
end)
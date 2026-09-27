game.Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(chara)
		-- Wait for Values
		while player:WaitForChild("Loaded").Value == false do task.wait() end
		while player:WaitForChild("Stats").Height.Value == 10 do task.wait() end

		-- Variables
		local statFold = player.Stats
		
		-- HUNGER
		local HungerBar = statFold.Hunger
		
		spawn(function() -- main Hunger tick
			while chara do 
				task.wait(10)

				if HungerBar.Value > 0 then -- above 0 hunger
					HungerBar.Value -= .5
				elseif HungerBar.Value <= 0 then -- below 0
					if not chara:FindFirstChild("Effects"):FindFirstChild("Hungry") then
						local Hungry = Instance.new("IntValue") do
							Hungry.Name = "Hungry"
							Hungry.Parent = chara:FindFirstChild("Effects")
							
							local check
							check = HungerBar.Changed:Connect(function(v)
								if v > 0 then
									Hungry:Destroy()
									check:Disconnect()
									check = nil
								end
							end)
						end
					end
				end
			end
		end)
	end)
end)
game.Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(chara)
		while chara:WaitForChild("AppearenceLoaded").Value == false do task.wait() end

		local RegionInfo = Instance.new("Folder")
		RegionInfo.Name = "RegionInfo"
		RegionInfo.Parent = chara

		local hrt = chara.HumanoidRootPart

		hrt.Touched:Connect(function(region)
			if string.find(region.Name, "REGION") then
				local RegionName = string.gsub(region.Name, "REGION", "")

				if not RegionInfo:FindFirstChild(RegionName) then
					local NewReg = Instance.new("StringValue")
					NewReg.Name = RegionName
					NewReg.Parent = RegionInfo
				end
			end
		end)

		hrt.TouchEnded:Connect(function(region)
			if string.find(region.Name, "REGION") then
				local RegionName = string.gsub(region.Name, "REGION", "")
				task.wait(0.3)

				local Missing
				local Saved
				local Found

				for _,n in workspace.Regions:GetChildren() do
					if string.find(n.Name, RegionName) then
						if n:IsA("Folder") then
							for _,v in n:GetChildren() do
								local t = workspace:GetPartBoundsInBox(v.CFrame, v.Size)
								if not table.find(t, hrt) then
									if RegionInfo:FindFirstChild(RegionName) then
										Saved = RegionName
										Missing = "False"
									end
								else
									Found = true
								end
							end
						else
							local t = workspace:GetPartBoundsInBox(region.CFrame, region.Size)
							if not table.find(t, hrt) then
								if RegionInfo:FindFirstChild(RegionName) then
									RegionInfo:FindFirstChild(RegionName):Destroy()
								end
							end
						end
					end
				end

				if Found == true then
					Missing = nil
				end

				if Missing == "False" then
					RegionInfo:FindFirstChild(Saved):Destroy()
				end
			end
		end)
	end)
end)
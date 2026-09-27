-- variables
local misFold = game.Workspace.MAP.MISSION
local MissionGUI = game.ReplicatedFirst.GUI.MissionGUI
local reward = require(game.ReplicatedStorage.Modules.RewardHandler)
local heighthandler = require(game.ServerScriptService.Server.Services.AgeService.HeightHandler)
local speedHandler = require(game.ReplicatedStorage.Modules.SpeedHandler)
local modGUIEvent = game.ReplicatedStorage.Remotes.MiscRemotes.QuestGUI
local submodGUIEvent = game.ReplicatedStorage.Remotes.MiscRemotes.Quest2GUI
local ts = game:GetService("TweenService")

-- mission related objects
local packagetypes = {
	game.ReplicatedFirst.Objects.Package1,
	game.ReplicatedFirst.Objects.Package2
}

-- cities 
local cities = {}

-- insert variables
for _,v in script:GetChildren() do
	local c = script:WaitForChild(v.Name)
	cities[v.Name] = c
end

local tradeRoutes = { -- trade routes
	Qarzin = {
		cities["AIN JAMALA"],
		cities["ILLEGAL PORT"],
		cities["SAHRAQIN"],
		cities["SALEH"]
	},
	Sahraqin = {
		cities["AIN JAMALA"],
		cities["QARZIN"]
	},
	IllegalPort = {
		cities["QARZIN"],
		cities["SALEH"]
	},
	AinJamala = {
		cities["SAHRAQIN"],
		cities["QARZIN"]
	},
	Saleh = {
		cities["QARZIN"],
		cities["ILLEGAL PORT"],
		cities["RATHOLE"],
		cities["JADDATYSHUT"]
	},
	Rathole = {
		cities["SALEH"],
		cities["JADDATYS HUT"],
		cities["CITYF"]
	},
	JaddatysHut = {
		cities["SALEH"],
		cities["RATHOLE"],
		cities["CITYF"]
	}
}

-- setting up Route Logic
for i,v in tradeRoutes do
	local cityVal = Instance.new("IntValue")
	cityVal.Name = string.lower(i)
	cityVal.Parent =  script

	local timesRun = Instance.new("IntValue")
	timesRun.Name = "timesRun"
	timesRun.Parent = cityVal

	local successRate = Instance.new("NumberValue")
	successRate.Name = "successRate"
	successRate.Parent = cityVal
	successRate.Value = 1
end

-- setting up Modifiers Info
local Modifiers = {
	["TimeCrunch"] = {
		chance = 20,
		rewardMultiplier = 1.2,
		reqs = nil
	},
	["CourierLoop"] = {
		chance = 10,
		rewardMultiplier = 1,
		reqs = nil
	},
	["HighlyValuable"] = {
		chance = 10,
		rewardMultiplier = 1.5,
		reqs = {
			SafeRoute = 1
		}
	},
	["HeavyCargo"] = {
		chance = 3,
		rewardMultiplier = 1.3,
		reqs = nil
	},
	["VIP"] = {
		chance = 1,
		rewardMultiplier = 2,
		reqs = {
			PlayerActive = 0,
			SafeRoute = 0
		}
	},
	["FragilePackage"] = {
		chance = 20,
		rewardMultiplier = 1.3,
		reqs = nil
	},
	["CleartheRoute"] = {
		chance = 3,
		rewardMultiplier = 1.5,
		reqs = {
			SafeRoute = 0
		}
	},
	["Nothing"] = {
		chance = 40
	}
}

-- TODO: Figure out my probablity, as three vals are spawning too often.
local function modDeterminant(city)
	local factorTable = {}
	local cityRoute = script:FindFirstChild(city)

	factorTable["PlayerActive"] = cityRoute.timesRun.Value > 10 and 1 or 0
	factorTable["SafeRoute"] = cityRoute.successRate.Value > 0.75 and 1 or 0

	local possMods = {}
	for name, data in Modifiers do
		local meetReqs = true

		if data.reqs then
			for reqKey, reqValue in data.reqs do
				if factorTable[reqKey] ~= reqValue then
					meetReqs = false
				end
			end
		end

		if meetReqs then
			table.insert(possMods, {
				Name = name,
				Data = data
			})
		end
	end

	local selected = {}

	local totalWeight = 0
	for _,mod in possMods do 
		totalWeight += mod["Data"]["chance"]
	end

	local roll = math.random(1, totalWeight)
	local cumulative = 0

	for i,mod in possMods do -- roll is 5, cum 0
		cumulative += mod["Data"]["chance"] -- 3\
		if roll <= cumulative then -- 5 <= 3
			table.insert(selected, mod)
			table.remove(possMods, i)
			break
		end
	end

	if #possMods > 0 and math.random(10) <= 5 then
		totalWeight = 0
		for _, mod in possMods do
			totalWeight = totalWeight + mod["Data"]["chance"]
		end
		roll = math.random(1, totalWeight)
		cumulative = 0
		for i, mod in possMods do
			cumulative = cumulative + mod["Data"]["chance"]
			if roll <= cumulative then
				table.insert(selected, mod)
				table.remove(possMods, i)
				break
			end
		end

		if #possMods > 0 and math.random(10) <= 3 then
			totalWeight = 0
			for _, mod in possMods do
				totalWeight = totalWeight + mod["Data"]["chance"]
			end
			roll = math.random(1, totalWeight)
			cumulative = 0
			for i, mod in possMods do
				cumulative = cumulative + mod["Data"]["chance"]
				if roll <= cumulative then
					table.insert(selected, mod)
					table.remove(possMods, i)
					break
				end
			end
		end
	end

	return selected
end

-- setting up ModVals
local function modVals(player, city)
	if not player:FindFirstChild("CityMods") then
		local fold = Instance.new("Folder")
		fold.Name = "CityMods"
		fold.Parent = player
	end
	local modFold = player:FindFirstChild("CityMods")

	if not modFold:FindFirstChild(city) then
		local Fold = Instance.new("Folder")
		Fold.Name = city
		Fold.Parent = modFold
	end
	local cityFold = modFold:FindFirstChild(city)

	if #cityFold:GetChildren() <= 0 then
		local mods = modDeterminant(city)

		for _,mod in mods do
			if mod.Name ~= "Nothing" then
				local ModInt = Instance.new("IntValue")
				ModInt.Name = mod.Name
				ModInt.Value = 0
				ModInt.Parent = cityFold
			else
				local ModInt = Instance.new("IntValue")
				ModInt.Name = mod.Name
				ModInt.Parent = cityFold
			end
		end
	else
		local mods = cityFold:GetChildren()
	end
end

-- main work of Mods
local function modCall(mod, player, city)
	modGUIEvent:FireClient(player, mod)

	if mod == "TimeCrunch" then -- TimeCrunch
		local timeInt = Instance.new("IntValue")
		timeInt.Name = "TimerQuestMod"
		timeInt.Parent = player
		timeInt.Value = 180

		player.Character:FindFirstChild("Pack").AncestryChanged:Connect(function(o,p) --destroying once pack is gone
			if p == nil then
				timeInt:Destroy()
			end
		end)

		spawn(function() -- time dwindle
			while timeInt do
				task.wait(1)
				timeInt.Value -= 1

				if timeInt.Value <= 0 then
					timeInt:Destroy()
				end
			end
		end)
	elseif mod == "FragilePackage" then --FragilePackage
		local pack = player.Character:WaitForChild("Pack")
		if pack:FindFirstChild("Pack1") then -- making it glass
			for _,v in pack:GetDescendants() do
				if v:IsA("MeshPart") then
					v.Material = Enum.Material.Glass
					v.Color = Color3.fromRGB(168, 187, 208)
				end
			end
		else
			pack.Main.Material = Enum.Material.Glass
			pack.Main.Color = Color3.fromRGB(168, 187, 208)
		end

		local conGlass
		conGlass = player.Character.Effects.ChildAdded:Connect(function(c)
			if c.Name == "Hit" then
				-- TODO: Add glass break and particle bits to this eventually.
				city:FindFirstChild("FragilePackage").Value = 1
				conGlass:Disconnect()
			end
		end)
	elseif mod == "HeavyCargo" then -- HeavyCargo
		local pack = player.Character:WaitForChild("Pack")
		local hVal = player.Stats.Height.Value
		--heighthandler.resize(pack:GetChildren(), Vector3.new(hVal*1.25,hVal,hVal*1.25)) -- resizing the package

		speedHandler.SpeedHandle(player.Character, 0.75, "HeavyCargo") -- slowing player
	elseif mod == "HighlyValuable" then -- HighlyValuable
		local pack = player.Character:WaitForChild("Pack")
		local s1 = game.ReplicatedFirst.VFX.MiscEffects.trueSparkle:Clone() -- particle work
		local s2 = game.ReplicatedFirst.VFX.MiscEffects.sparkle1:Clone()
		local s3 = game.ReplicatedFirst.VFX.MiscEffects.sparkle2:Clone()
		s3.Parent = pack.Main:FindFirstChild("BodyBackAttachment")
		s2.Parent = pack.Main:FindFirstChild("BodyBackAttachment")
		s1.Parent = pack.Main

		local hl = game.ReplicatedFirst.VFX.MiscEffects.Cancel:Clone() -- highlight
		hl.FillTransparency = 1
		hl.OutlineTransparency = 1
		hl.FillColor = Color3.fromRGB(239, 187, 65)
		hl.OutlineColor = Color3.fromRGB(239, 187, 65)
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.Adornee = pack
		hl.Parent = pack
		local tween1 = ts:Create(hl, TweenInfo.new(1), {FillTransparency = 0.75, OutlineTransparency = 0})  -- glowing every 20 seconds or so.
		local tween2 = ts:Create(hl, TweenInfo.new(1), {FillTransparency = 1, OutlineTransparency = 1})
		spawn(function()
			while pack do
				tween1:Play()
				task.wait(6)
				tween2:Play()
				task.wait(20)
			end
		end)

		player.Character.Effects.OnMission.RewardAmount.Value *= 2 -- doubling the reward
	elseif mod == "CleartheRoute" then
		local conGrip
		conGrip = player.Character.IntFold.GripInt.ChildAdded:connect(function(c)
			city:FindFirstChild("CleartheRoute").Value = 1
			conGrip:Disconnect()
		end)
	end
end


for _,v in misFold:GetChildren() do
	if v.Name:find("Delivery") then -- package delivery
		local click = Instance.new("ClickDetector")
		click.Parent = v

		click.MaxActivationDistance = 10
		click.MouseClick:Connect(function(player)
			if not player.Character.Effects:FindFirstChild("Reading") and not player.Character.Effects:FindFirstChild("OnMission") then
				-- connections
				local con

				local gooey = MissionGUI.DeliveryFrame:Clone()
				gooey.Parent = player.PlayerGui

				local reading = Instance.new("IntValue") -- setting up effect val
				reading.Name = "Reading"
				reading.Parent = player.Character.Effects

				spawn(function() -- checking for distance to delete
					while gooey ~= nil and player.Character ~= nil do
						local mag = (player.Character.HumanoidRootPart.Position - v.Position).Magnitude

						if mag > 20 then
							gooey:Destroy()
							reading:Destroy()
							con:Disconnect()
						end
						task.wait()
					end
				end)

				--[[gooey.AncestryChanged:Connect(function(n,p) -- check if deleted via X.
					if p == nil then
						
					end
				end)]]

				for i,v in tradeRoutes[string.gsub(click.Parent.Name, "Delivery", "")] do
					local p = v:Clone() 
					p.Parent = gooey.OutsideFrame.Frame.ScrollingFrame["Slot"..tonumber(i)] -- putting in cities
					modVals(player, string.gsub(string.lower(v.Name), " ", "")) -- modifier work

					-- TODO: Come up with how percentages will work and just finalize my thoughts around that.
				end

				local event = game.ReplicatedStorage.Remotes.ImportantRemotes.Delivery -- mission functionality
				con = event.OnServerEvent:Connect(function(eventPlayer, state, city)
					if eventPlayer == player then -- making sure it is the right player
						if state == "MissionStart" then -- starting mission
							reading:Destroy()
							con:Disconnect()

							city = string.gsub(city, " ", "") -- setting up city for later usage

							-- variables
							local chara = player.Character
							local effFold = chara.Effects

							-- setting up eff vals 
							local MissionVal = Instance.new("StringValue")
							MissionVal.Name = "OnMission"
							MissionVal.Value = "Delivery"

							local CarriedReward = Instance.new("IntValue")
							CarriedReward.Name = "RewardAmount"
							CarriedReward.Value = reward.rewardcaculation(player)
							CarriedReward.Parent = MissionVal

							MissionVal.Parent = effFold

							-- putting on backpack
							local pack = packagetypes[math.random(1, #packagetypes)]:Clone() -- TODO: Fix the height adjustments for bag weapons, make the sword longer
							--heighthandler.resize(pack:GetChildren(), Vector3.new(player.Stats.Height.Value, player.Stats.Height.Value, player.Stats.Height.Value))
							pack.PrimaryPart.CFrame = chara.Torso.CFrame
							pack.Name = "Pack"

							if pack:FindFirstChild("Pack1") then
								pack.Main.CFrame = chara.Torso.CFrame:ToWorldSpace(CFrame.new(0,0,.3) * CFrame.Angles(0, math.rad(180), 0))
							elseif pack:FindFirstChild("Pack2") then
								pack.Main.CFrame = chara.Torso.CFrame:ToWorldSpace(CFrame.new(0,0,1.25) * CFrame.Angles(math.rad(270), math.rad(90), math.rad(90)))
							end

							local weld = Instance.new("WeldConstraint")
							weld.Parent = pack
							weld.Part0 = pack.PrimaryPart
							weld.Part1 = chara.Torso

							pack.Parent = chara

							-- modifier work
							local Mods = player:FindFirstChild("CityMods"):FindFirstChild(string.lower(city))
							for _,v in Mods:GetChildren() do 
								if v.Name ~= "Nothing" then
									local check = string.gsub(v.Name, " ", "")
									modCall(check, player, player:FindFirstChild("CityMods"):FindFirstChild(string.lower(city)), v)
								end
							end

							local function success() -- completed mission successfully
								local CompletedModWork = {}
								local ModWork = player:FindFirstChild("CityMods"):FindFirstChild(string.lower(city))

								-- Mod Specific Completions
								for _,completedMod in ModWork:GetChildren() do
									if completedMod.Name == "TimeCrunch" then -- Time Crunch
										if player:FindFirstChild("TimerQuestMod") then
											table.insert(CompletedModWork, completedMod)
										end
									elseif completedMod.Name == "FragilePackage" and completedMod.Value == 0 then -- Fragile Package
										table.insert(CompletedModWork, completedMod)
									elseif completedMod.Name == "CleartheRoute" and completedMod.Value == 1 then -- Clear the Route
										table.insert(CompletedModWork, completedMod)
									elseif completedMod.Name == "HeavyCargo" or completedMod.Name == "HighlyValuable" or completedMod.Name == "CourierLoop" then -- Heavy Cargo, Valuable Package, Courier Loop
										table.insert(CompletedModWork, completedMod)
										if completedMod.Name == "HeavyCargo" then speedHandler.SpeedHandleRemove(chara, "HeavyCargo") end -- removing slow
									end
								end
								
								reward.missionsuccess(player, false, nil, CompletedModWork)

								-- Ridding, for reset
								ModWork:Destroy()
								pack:Destroy()
								MissionVal:Destroy()
							end

							-- checking range
							local CourierLoopCheck = false
							local mag
							spawn(function()
								while pack.Parent ~= nil do
									if not CourierLoopCheck then
										mag = (chara.HumanoidRootPart.Position - workspace.MAP.MISSION:FindFirstChild(city.."Delivery").Position).Magnitude
									else
										mag = (chara.HumanoidRootPart.Position - v.Position).Magnitude -- setting mag back to the original deliverySpot
									end

									if mag <= 10 then
										if not Mods:FindFirstChild("CourierLoop") then
											success()
										elseif not CourierLoopCheck then
											CourierLoopCheck = true
											submodGUIEvent:FireClient(player, v) -- firing to gui work to handle everything client side
										elseif CourierLoopCheck then
											success()
										end
									end

									task.wait()
								end
							end)

							-- mission interruption
							local con2
							con2 = chara.Effects.ChildAdded:Connect(function(v)
								if v.Name == "Knocked" then
									local personKnocker = v:FindFirstChildOfClass("StringValue")

									if personKnocker then
										reward.missionsuccess(game.Players:FindFirstChild(personKnocker.Name), true, CarriedReward.Value)
										if Mods:FindFirstChild("HighlyValuable") then CarriedReward /= 2 end -- making sure to get the natural reward amount to deduct
										player.OnCharacter.Currency.Copper.Value -= CarriedReward.Value
										for _,v in player.SuccessRate:GetChildren() do -- clearing out success if ganked
											if v.Name == "Delivery" then
												v:Destroy()
											end
										end
									end

									pack:Destroy()
									MissionVal:Destroy()
									con2:Disconnect()
								end
							end)
							con:Disconnect()
						elseif state == "Exit" then
							gooey:Destroy()
							reading:Destroy()
							con:Disconnect()
						end
					end
				end)
			end
		end)
	end
end
local module = {}

-- services
local reward = require(game.ReplicatedStorage.Modules.RewardHandler)
local rs = game:GetService("RunService")

-- events
local camEvent = game.ReplicatedStorage.Remotes.MiscRemotes.Cam
local questGUI = game.ReplicatedStorage.Remotes.MiscRemotes.QuestGUI
local quest2GUI = game.ReplicatedStorage.Remotes.MiscRemotes.Quest2GUI

local GUIs = {}
for _,v in game.ReplicatedFirst.GUI.MissionGUI:GetDescendants() do
	if v:IsA("Frame") or v:IsA("TextLabel") or v:IsA("TextButton") or v:IsA("ImageLabel") or v:IsA("ImageButton") then
		local Gooey = game.ReplicatedFirst.GUI.MissionGUI:FindFirstChild(v.Name)
		if Gooey then
			GUIs[v.Name] = Gooey
		end
	end
end

local cityAssests = { --TODO: make city images.
	Rathole = {
		Description = "An encampment of bandits, colloquially knonw as the Rathole. Here, a legendary blacksmith, said to be old as the desert itself, makes the finest weapons that can be found in the Southern Desert.",
		Color = Color3.fromRGB(100, 85, 117),
		Img = "rbxassetid://80085994447501",
		Personality = "War-Torn"
	},

	JaddatysHut = {
		Description = "A small hut owned by a Grandmother and her grandchildren. Travellers tend to avoid this place, as a sense of danger and malice hangs about the entireity of the encampent.",
		Color = Color3.fromRGB(171, 173, 64),
		Img = "rbxassetid://80085994447501",
		Personality = "Neutral"
	},

	AinJamala = {
		Description = "Ain Jamala was once a jewel of the southern sands, a thriving oasis thought to one day rival the great Qishan to the north. But those dreams have long since turned to dust. What now remains of the once great city is nothing but a den of smugglers, assassins, bandits, and slavers. ",
		Color = Color3.fromRGB(64, 37, 72),
		Img = "rbxassetid://80085994447501",
		Personality = "War-Torn"
	},

	Saleh = {
		Description = "Saleh is a small desert village, said to be as old as the desert itself. The Endless Desert looms just beyond its edge, a vast expanse of shifting sands. As the last bastion of civilization on the coast, Saleh stands guard against the lawless wastes that stretch beyond.",
		Color = Color3.fromRGB(85, 170, 127),
		Img = "rbxassetid://80085994447501",
		Personality = "Neutral",
	},

	IllegalPort = {
		Description = "A lawless port that sits tucked away on the coast of the Badlands. Officially, it does not exist. Unofficially, it thrives, trafficking in flesh, forbidden goods, and bloodstained coin. Here; slave galleys, smugger sloops, and black sails of pirates are all welcomed with open arms.",
		Color = Color3.fromRGB(0, 0, 0),
		Img = "rbxassetid://80085994447501",
		Personality = "Busy",
	},

	Sahraqin = {
		Description = "Sahraqin rose around the rarest treasure in the Southern Desert, an oasis of clear, endless water. Its people bear this gift with fierce pride, and the live-giving spring stands at the heart of their identity and culture.",
		Color = Color3.fromRGB(125, 167, 218),
		Img = "rbxassetid://80085994447501",
		Personality = "Busy"
	},

	Qarzin = {
		Description = "A bustling trade city, Qarzin measures worth by the weight of your purse. Outlaw, noblemen, magician, or slave; if you carry coin, Qarzin will accept you with welcoming arms.",
		Color = Color3.fromRGB(191, 132, 73),
		Img = "rbxassetid://80085994447501",
		Personality = "Busy"
	},
}

local Modifiers = {
	TimeCrunch = {
		Name = "Time Crunch",
		Desc = "Complete in 3:00."},
	CourierLoop = {
		Name = "Courier Loop",
		Desc = "Deliver the package and then return with another."},
	HighlyValuable = {
		Name = "Highly Valuable",
		Desc = "You are carrying something valuable, protect it."},
	HeavyCargo = {
		Name = "Heavy Cargo",
		Desc = "The package is heavy."},
	VIP = {
		Name = "Very Important Noble",
		Desc = "Protect them to the next city, they are important and will draw attention."},
	FragilePackage = {
		Name = "Fragile Package",
		Desc = "You are carrying something fragile, don't get into a fight."},
	CleartheRoute = {
		Name = "Clear the Route",
		Desc = "The route is dangerous, your Broker has requested you clear the way."},
}

module.DeliveryProtocol = function(player, button, city)
	button.Activated:Connect(function()
		local gooey = player.PlayerGui:FindFirstChild("DeliveryFrame")
		local event = game.ReplicatedStorage.Remotes.ImportantRemotes.Delivery

		for _,v in gooey.OutsideFrame.Frame.DescriptionFrame:GetChildren() do
			v.Visible = true

			if v.Name == "TextContainer" then
				v.CityDesc.Text = cityAssests[city].Description
				v.CityPic.Image = cityAssests[city].Img
				v.CityPic.BorderColor3 = cityAssests[city].Color
				v.PayRow.Money.Text = reward.rewardcaculation(player)

				v.PayRow.StartButton.Activated:Connect(function()   -- start button click
					gooey:Destroy() -- removing shop gui
					task.delay(0.25, function()
						event:FireServer("MissionStart", city) -- event call
					end)

					-- setting up tracker
					local tracker = game.ReplicatedFirst.GUI.MissionGUI.QuestTracker:Clone()
					tracker.Adornee = workspace.MAP.MISSION:FindFirstChild(city.."Delivery")
					tracker.Parent = workspace.MAP.MISSION:FindFirstChild(city.."Delivery")

					local tackerDis = tracker.Frame.Distance

					-- questline gui
					local questCore = player.PlayerGui:WaitForChild("QuestLine")
					questCore.Enabled = true

					local qBox = GUIs["QuestLineBox"]:clone() -- box
					qBox.Parent = questCore.Set
					qBox.Quest.Text = "DELIVERY"

					local DisDispaly = qBox.Distance -- setting up distance
					local testCheck = false -- needed variables
					local cam = workspace.CurrentCamera

					--modWork gui
					local conGUI
					local buttonCon
					local secondLoop
					local endGoal

					conGUI = questGUI.OnClientEvent:Connect(function(mod)
						local ModContainerGUI = GUIs["MODCONTAINER"]:Clone()
						ModContainerGUI.Parent = player.PlayerGui:FindFirstChild("QuestLine").Set.QuestLineBox.MODROW
						local PopOutFrame = GUIs["ModPopOut"]:Clone()

						local button = ModContainerGUI.BONUS -- pop out box
						PopOutFrame.ModType.Text = Modifiers[mod].Name
						PopOutFrame.Constraint.Text = Modifiers[mod].Desc

						local on = false
						buttonCon = button.Activated:connect(function() -- button 
							if not on then
								on = true
								PopOutFrame.Parent = player.PlayerGui:FindFirstChild("QuestLine").ModFrame
								button.BackgroundTransparency = 0.75
							elseif on then
								on = false
								PopOutFrame.Parent = nil
								button.BackgroundTransparency = 1
							end
						end)
						
						-- mod specific GUI work
						if mod == "TimeCrunch" then -- moving timer
							local timer = player:WaitForChild("TimerQuestMod")
							
							local conTimer
							conTimer = timer.Changed:Connect(function(v)
								if player:FindFirstChild("TimerQuestMod") then
									local min = math.floor(v/60)
									local seconds = v % 60
									PopOutFrame.Constraint.Text = "Complete in "..string.format("%d:%02d", min, seconds)
								end
							end)
							
							local conEnd
							conEnd = timer.AncestryChanged:Connect(function(o,p)
								if p == nil then
									if PopOutFrame then PopOutFrame.Constraint.Text = "Failed." button.TextColor3 = Color3.fromRGB(43, 43, 43) end
									conTimer:Disconnect()
									conEnd:Disconnect()
								end
							end)
						elseif mod == "FragilePackage" then -- break
							local ModCon
							ModCon = player.Character.Effects.ChildAdded:connect(function(c)
								if c.Name == "Hit" then
									PopOutFrame.Constraint.Text = "Failed."
									button.TextColor3 = Color3.fromRGB(43, 43, 43)
									ModCon:Disconnect()
								end
							end)
						elseif mod == "CourierLoop" then -- redesigning everything for the second loop
							local secondLoopCon
							secondLoopCon = quest2GUI.OnClientEvent:Connect(function(endGoalInt)
								PopOutFrame.Constraint.Text = "Return with the package to complete the Quest."
								secondLoop = true
								endGoal = endGoalInt

								tracker.Adornee = endGoalInt -- the tracker
								tracker.Parent = endGoalInt
								secondLoopCon:Disconnect()
							end)
						end
					end)

					local con
					con = rs.Heartbeat:Connect(function()
						local mag = (player.Character.HumanoidRootPart.Position - game.Workspace.MAP.MISSION:FindFirstChild(city.."Delivery").Position).Magnitude -- updating distance for tracker and the quest box
						if secondLoop then 
							mag = (player.Character.HumanoidRootPart.Position - endGoal.Position).Magnitude 
						end
						mag = math.floor(mag)
						tackerDis.Text = tostring(mag).."m"
						DisDispaly.Text = tostring(mag).."m"


						local con2
						con2 = player.Character:WaitForChild("Pack").AncestryChanged:Connect(function(c,p) -- quest end
							if p == nil then
								con:Disconnect()
								con2:Disconnect()
								conGUI:Disconnect()
								if buttonCon then buttonCon:Disconnect() 
									if player.PlayerGui:FindFirstChild("QuestLine"):FindFirstChild("ModPopOut") then player.PlayerGui:FindFirstChild("QuestLine"):FindFirstChild("ModPopOut"):Destroy() end end -- ridding button just in case it gets left over
								tracker:Destroy()
								qBox:Destroy()
								DisDispaly:Destroy()

								-- checking if the questCore has anything, if it doesn't delete it.
								local check = nil
								for _,v in questCore.Set:GetChildren() do 
									if v.Name ~= "UIListLayout" or v.Name ~= "BUFFER" then
										check = true
									end
								end
								if check then questCore.Enabled = false end
							end
						end)

						-- checking for whehter or not they can see the adorne part, if so hiding the qBox distance
						local part = workspace.MAP.MISSION:FindFirstChild(city.."Delivery")
						if secondLoop then
							part = endGoal
						end
						local vec, onScreen = cam:WorldToViewportPoint(part.Position)
						if onScreen == true and testCheck == false then -- onScreen
							testCheck = true

							DisDispaly.Parent = nil
						elseif onScreen == false and testCheck == true then -- offScreen
							testCheck = false

							DisDispaly.Parent = qBox
						end
					end)
				end)
			end
		end
	end)
end

return module

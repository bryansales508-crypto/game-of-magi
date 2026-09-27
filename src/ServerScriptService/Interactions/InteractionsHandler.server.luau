--Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local remotes = ReplicatedStorage.Remotes
local db = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local Run = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

--Remote Events
local runEvent = game.ReplicatedStorage.Remotes.Running
local footEvent = game.ReplicatedStorage.Remotes.MiscRemotes.Footstep
local hitEvent = game.ReplicatedStorage.Remotes.CombatRemotes.Hit
local blockEvent = game.ReplicatedStorage.Remotes.Blocking
local dashEvent = game.ReplicatedStorage.Remotes.CombatRemotes.Dash

-- Modules
local speedMod = require(game.ReplicatedStorage.Modules.SpeedHandler)
local colorMath = require(game.ReplicatedStorage.Modules.ColorMath)
local dmg = require(game.ServerScriptService.Services.DamageHandler)

--Interaction Handling

-- Foot and Run 
footEvent.OnServerEvent:Connect(function(ply, step, idle)
	local chara = ply.Character or ply.CharacterAdded:Wait()
	local charaHum = chara:WaitForChild("Humanoid")
	local torso = chara:WaitForChild("Torso")

	local effectsFold = chara:WaitForChild("Effects")



	-- Surface Function
	local function surfaceCall(trueMat)

		-- Prevent this from calling.
		if effectsFold:FindFirstChild("MutedStep") then
			return
		end

		local function soundPlayer(stepNeeded)
			local s = torso:FindFirstChild(stepNeeded)

			-- increasing sound they are running
			if chara.IntFold:FindFirstChild("Running?").Value == true then
				s.Volume = 0.25
			end

			s:Play()

			-- returning sound to normal
			s.Ended:Connect(function() s.Volume = 0.1 end)
		end

		-- wrapper protects it from overriding an already playing fire
		-- Hard Surface
		if trueMat == "Rock" or trueMat == "Sandstone" or trueMat == "RoofShingles" or trueMat == "Pavement" or trueMat == "Slate" then
			if step == "Right" then
				if torso:FindFirstChild("RightBlock").IsPlaying == false then
					soundPlayer("RightBlock")
				end
			elseif step == "Left" then
				if torso:FindFirstChild("LeftBlock").IsPlaying == false then
					soundPlayer("LeftBlock")
				end
			elseif step == "Jump" then
				if torso:FindFirstChild("LeftBlock").IsPlaying == false then
					soundPlayer("LeftBlock")
				end
			end
		end

		-- Dirt Surface
		if trueMat == "Sand" or trueMat == "Dirt" or trueMat == "Mud" then
			if step == "Right" then
				if torso:FindFirstChild("RightDirt").IsPlaying == false then
					soundPlayer("RightDirt")
				end
			elseif step == "Left" then
				if torso:FindFirstChild("LeftDirt").IsPlaying == false then
					soundPlayer("LeftDirt")
				end
			elseif step == "Jump" then
				if torso:FindFirstChild("LeftDirt").IsPlaying == false then
					soundPlayer("LeftDirt")
				end
			end
		end

		-- Thudish Surface
		if trueMat == "Wood" or trueMat == "Carpet" then
			if step == "Right" then
				if torso:FindFirstChild("RightCarpet").IsPlaying == false then
					soundPlayer("RightCarpet")
				end
			elseif step == "Left" then
				if torso:FindFirstChild("LeftCarpet").IsPlaying == false then
					soundPlayer("LeftCarpet")
				end
			elseif step == "Jump" then
				if torso:FindFirstChild("LeftCarpet").IsPlaying == false then
					soundPlayer("LeftCarpet")
				end
			end
		end

		-- producing steps for sand or mud
		-- getting a ray from under tha character
		local rO = chara:WaitForChild("Torso").Position 
		local rD = Vector3.new(0, -1000, 0)
		local params = RaycastParams.new()
		params.FilterDescendantsInstances = {workspace.Characters}
		params.FilterType = Enum.RaycastFilterType.Exclude
		local rResult = workspace:Raycast(rO, rD, params)

		if rResult and string.gsub(tostring(rResult.Material), "Enum.Material.", "") == "Sand" or string.gsub(tostring(rResult.Material), "Enum.Material.", "") == "Mud"  then
			-- making tha block
			local blockint = Instance.new("Part")
			blockint.CanCollide = false
			blockint.Anchored = true
			blockint.Size = Vector3.new(1.5,0.25,1.5)
			blockint.Material = rResult.Material
			blockint.Color = colorMath.mul(rResult.Instance.Color, Color3.new(0.8,0.8,0.8))

			-- positioning
			if step ~= "Jump" then
				-- adjusting for slight delay

				-- changing dependening on running or walking, increasing the predict if running
				local predict
				if chara:FindFirstChild("IntFold"):FindFirstChild("Running?").Value == true then predict = 8 else predict = 2 end

				local lookVec = chara:FindFirstChild(step.." Leg").CFrame.LookVector
				blockint.CFrame = chara:FindFirstChild(step.." Leg").CFrame + (lookVec * predict)

				blockint.Orientation = Vector3.new(0, blockint.Orientation.Y, blockint.Orientation.Z)
				blockint.Position = Vector3.new(blockint.Position.X,rResult.Position.Y,blockint.Position.Z)


				blockint.Parent = workspace.Projectiles

				-- fading it out and deleting
				-- TODO: add this to a general projectile handler later on.
				local tween = TweenService:Create(blockint, TweenInfo.new(0.75,Enum.EasingStyle.Linear), {Transparency = 1})
				tween:Play()
				tween.Completed:Connect(function()blockint:Destroy() end)
			else
				-- handling if it is a jump

				-- cloning to produce two
				-- changing dependening on running or walking, increasing the predict if running
				local predict
				if chara:FindFirstChild("IntFold"):FindFirstChild("Running?").Value == true then predict = 8 else predict = 2 end
				local lookVec= chara:FindFirstChild("Right Leg").CFrame.LookVector
				local b2 = blockint:Clone()

				blockint.CFrame = chara:FindFirstChild("Right Leg").CFrame + (lookVec * predict)
				blockint.Orientation = Vector3.new(0, blockint.Orientation.Y, blockint.Orientation.Z)
				blockint.Position = Vector3.new(blockint.Position.X,rResult.Position.Y,blockint.Position.Z)

				b2.CFrame = chara:FindFirstChild("Left Leg").CFrame  + (lookVec * predict)
				b2.Orientation = Vector3.new(0, b2.Orientation.Y, b2.Orientation.Z)
				b2.Position = Vector3.new(b2.Position.X,rResult.Position.Y,b2.Position.Z)

				-- placing
				blockint.Parent = workspace.Projectiles
				b2.Parent = workspace.Projectiles

				-- fading it out and deleting
				-- TODO: add this to a general projectile handler later on. need to adjust this so it doesn't fuck up so often.
				local tween = TweenService:Create(blockint, TweenInfo.new(0.75,Enum.EasingStyle.Linear), {Transparency = 1})
				tween:Play()
				tween.Completed:Connect(function()blockint:Destroy() end)

				local tween2 = TweenService:Create(b2, TweenInfo.new(0.75,Enum.EasingStyle.Linear), {Transparency = 1})
				tween2:Play()
				tween2.Completed:Connect(function()b2:Destroy() end)
			end
		end
	end

	-- if in the air
	if string.gsub(tostring(charaHum.FloorMaterial), "Enum.Material.", "") == "Air" then
		if step == "Jump" then

			-- Getting a Ray for Under the character
			local rO = chara:WaitForChild("HumanoidRootPart").Position
			local rD = Vector3.new(0, -1000, 0)
			local params = RaycastParams.new()
			params.FilterDescendantsInstances = {workspace.Characters}
			params.FilterType = Enum.RaycastFilterType.Exclude
			local rResult = workspace:Raycast(rO, rD, params)

			-- If we hit something, then call the surface function
			if rResult then
				local trueMat = string.gsub(tostring(rResult.Material), "Enum.Material.", "")

				surfaceCall(trueMat)
			end
		end
	else
		-- otherwise do as normal
		surfaceCall(string.gsub(tostring(charaHum.FloorMaterial), "Enum.Material.", ""))
	end
end)

runEvent.OnServerEvent:Connect(function(ply, val)
	local chara = ply.Character or ply.CharacterAdded:Wait()

	local runValue = chara:WaitForChild("IntFold"):WaitForChild("Running?")
	runValue.Value = val

	-- SpeedHandle

	if val == true then
		speedMod.SpeedHandle(chara, "Run")
	else
		speedMod.SpeedHandleRemove(chara, "Run")
	end
end)

-- Hitting
hitEvent.OnServerEvent:connect(function(ply, hl, partHit)
	if hl ~= "Highlight" then
		local chara = ply.Character or ply.CharacterAdded:Wait()
		local charaHum = chara:WaitForChild("Humanoid")
		local torso = chara:WaitForChild("Torso")

		local effectsFold = chara:WaitForChild("Effects")
		local function packetsender(targChara)
			print(targChara)
			local packet = {
				Damage = 5,
				Hit = "First",
				Knockback = 1,
				Slow = .25, 
				SlowDur = .75, 
				Stun = 1
			}
			
			dmg.damage(chara, targChara, packet)
		end
		
		if partHit:FindFirstAncestor("Characters") then
			packetsender(partHit:FindFirstAncestorOfClass("Model")) -- hit a character
			print("Test")
		elseif partHit:FindFirstAncestor("NPC") then
			print("Test1")
			packetsender(partHit:FindFirstAncestorOfClass("Model")) -- hit a npc
		else -- hit the map or projectile
			print("Test3")
		end
--[[ old 
		-- Variables
		local range = 4

		-- RayCast Set Up
		local rcPar = RaycastParams.new()
		rcPar.FilterType = Enum.RaycastFilterType.Exclude
		rcPar.FilterDescendantsInstances = {chara, workspace.Regions}

		-- attack formula
		local attacking = nil
		local locked = false 
		task.delay(0.1, function()
			attacking:Disconnect()
		end)

		local function packetsender(targChara)
			local packet = {
				Damage = 5,
				Hit = "Fist",
				Knockback = 1,
				Slow = .25,
				SlowDur = .75,
				Stun = 1
			}

			dmg.damage(chara, targChara, packet)
		end

		attacking = Run.Heartbeat:Connect(function()
			local ray = workspace:Raycast(chara.HumanoidRootPart.Position, chara.HumanoidRootPart.CFrame.LookVector * range, rcPar)

			if ray and not locked then
				locked = true

				if ray.Instance:FindFirstAncestor("Characters") then -- Hit a Character
					packetsender(ray.Instance:FindFirstAncestorOfClass("Model"))
				elseif ray.Instance:FindFirstAncestor("NPC") then -- Hit a NPC
					packetsender(ray.Instance:FindFirstAncestorOfClass("Model"))
				else -- Hit the map or a projectile.
					
				end
			elseif not ray and not locked then
				local hitBox = chara:FindFirstChild("HitBox")
				for _,v in game.Workspace:GetPartsInPart(hitBox) do
					if v:FindFirstAncestorOfClass("Model") and v:FindFirstAncestorOfClass("Model").Name ~= "MAP" and v:FindFirstAncestorOfClass("Model") ~= chara and v.Name == "HitBox" then
						locked = true
						packetsender(v:FindFirstAncestorOfClass("Model"))
					else
						if not locked then
							locked = true
							local sTable = {}
							for _,v in chara.Torso:GetChildren() do
								if v:IsA("Sound") and v.Name:find("MissSound") then
									table.insert(sTable, v)
								end
							end

							local s = sTable[math.random(1,3)]
							s:Play()
						end
					end
				end
			end
		end)]]
	else -- highlight
		local chara = ply.Character or ply.CharacterAdded:Wait()
		local hl = chara:WaitForChild("Cancel")

		hl.FillTransparency = 0.35
		local tween = TweenService:Create(hl, TweenInfo.new(0.5,Enum.EasingStyle.Linear),{FillTransparency = 1})
		tween:Play()
	end
end)

-- Blocking
blockEvent.OnServerEvent:connect(function(ply, val)
	if val then
		local blockInt = Instance.new("IntValue")
		blockInt.Name = "Block"
		blockInt.Value = 1
		blockInt.Parent = ply.Character.Effects

		task.delay(0.25, function()
			blockInt.Value = 0 -- parry interval
		end)

		speedMod.SpeedHandle(ply.Character, 0.5, "Block")
	elseif not val then
		if ply.Character.Effects:FindFirstChild("Block") then
			ply.Character.Effects:FindFirstChild("Block"):Destroy()
		end
		speedMod.SpeedHandleRemove(ply.Character, "Block")
	end
end)

-- Dashing
dashEvent.OnServerEvent:Connect(function(ply, val)
	local chara = ply.Character or ply.CharacterAdded:Wait()
	local charaHum = chara:WaitForChild("Humanoid")
	local torso = chara:WaitForChild("Torso")

	if val == "Release" then
		local chara = ply.Character or ply.CharacterAdded:Wait() --DashCancel
		local hl = chara:WaitForChild("Cancel")

		--[[hl.FillTransparency = 0.35
		local tween = TweenService:Create(hl, TweenInfo.new(0.5,Enum.EasingStyle.Linear),{FillTransparency = 1})
		tween:Play()]]
		
		speedMod.SpeedHandleRemove(chara, "Dash")
	elseif val == "Dash" then
		speedMod.SpeedHandle(chara, "Dash") -- dash
		torso.QuickDash:Play() -- sound
		
		for i=1,math.random(3,5),1 do -- lines
			local line = game.ReplicatedFirst.VFX.MiscEffects.DashTrail:Clone()

			-- Random Factor
			local random = CFrame.new(math.random(-2,2),math.random(-2,2),0)

			local attachment1 = Instance.new("Attachment")
			attachment1.CFrame = attachment1.CFrame * random
			attachment1.Parent = chara.Torso

			local attachment2 = Instance.new("Attachment")
			attachment2.CFrame = attachment2.CFrame * CFrame.new(0,0,1) * random
			attachment2.Parent = chara.Torso

			line.Attachment0 = attachment1
			line.Attachment1 = attachment2

			-- Random

			line.Parent = chara.Torso

			db:AddItem(line, 0.2)
			db:AddItem(attachment1, 0.2)
			db:AddItem(attachment2, 0.2)
		end
		
		
		task.delay(0.2, function() -- removal
			speedMod.SpeedHandleRemove(chara, "Dash")
		end)
	elseif val == "RunningHit" then
		speedMod.SpeedHandleRemove(chara, "Dash")
	end
end)
-- esoteric variables

if not script.Parent:IsA("Script") then
	local falsehead = script.Parent
	local chara = falsehead.Parent
	local player = game.Players:GetPlayerFromCharacter(chara)

	while chara:WaitForChild("AppearenceLoaded").Value == false do task.wait() end -- loading

	-- needed variables
	local parts = {} -- container tables

	for _,v in falsehead:GetChildren() do -- insert variables
		local c = falsehead:WaitForChild(v.Name)
		parts[v.Name] = v
	end


	-- defaults
	local mouthid = parts["MouthShape"].Texture
	local eyecolorid = parts["EyeColor"].Texture
	local facebaseid = parts["FaceBase"].Texture

	-- talking
	-- TODO: Knocked and Hit capability.

	local talking = false
	local locked = false 
	local locked2 = false 
	local allowedtoTalk = true
	local prev = nil

	local function yap()
		if locked == false and allowedtoTalk then
			locked = true 
			spawn(function()
				while talking == true do
					-- begin this
					local shapeTable = {mouthid, "rbxassetid://13473292861", "rbxassetid://13473295251"}

					local random = math.random(1,3)
					while random == prev do
						random = math.random(1,3)
						task.wait()
					end

					parts["MouthShape"].Texture = shapeTable[random]
					prev = random
					task.wait(0.25)

					if talking == false then -- making sure it always goes back to normal
						parts["MouthShape"].Texture = mouthid
					end
				end
			end)
		end

	end

	player.Chatted:connect(function(msg)
		if allowedtoTalk then
			if talking == false then
				talking = true
				yap()

				local startyap = 0
				if #msg > 20 then
					startyap = 20
				else
					startyap = #msg
				end
				script.TalkCount.Value += startyap
			else
				local yapcontinued = 0
				if script.TalkCount.Value < 20 then
					local currentcount = script.TalkCount.Value
					yapcontinued = #msg

					local newcount = yapcontinued + currentcount
					if newcount >= 20 then
						script.TalkCount.Value = 20
					else
						script.TalkCount.Value += yapcontinued
					end
				end
			end
		end
	end)

	script.TalkCount.Changed:Connect(function(v)
		if v > 0 and locked2 == false then
			locked2 = true

			spawn(function()
				while script.TalkCount.Value > 0 do
					script.TalkCount.Value -= 1
					task.wait(0.5)
				end

				locked = false
				locked2 = false
				talking = false 
				parts["MouthShape"].Texture = mouthid
			end)
		end
	end)

	-- blinking
	--TODO: Knocked + Hit capability.

	local allowedtoBlink = true
	local locked3 = false 


	local function blink()
		script.WateryEyes.Value = math.random(4,9)

		if allowedtoBlink then
			parts["EyeColor"].Texture = ""
			if facebaseid == "rbxassetid://13466958587" then -- human male 1
				parts["FaceBase"].Texture = "rbxassetid://13467199372"
			elseif facebaseid == "rbxassetid://13473200175" then -- human female 1
				parts["FaceBase"].Texture = "rbxassetid://13473251210"
			elseif facebaseid == "rbxassetid://13473204337" then -- human male 2
				parts["FaceBase"].Texture = "rbxassetid://13482990162"
			end

			delay(0.3, function()
				parts["EyeColor"].Texture = eyecolorid
				parts["FaceBase"].Texture = facebaseid
			end)
		end
	end

	script.WateryEyes.Changed:Connect(function(v)
		if v > 0 and locked3 == false then
			locked3 = true

			spawn(function()
				while script.WateryEyes.Value > 0 do
					script.WateryEyes.Value -= 1
					task.wait(1)
				end
			end)
		elseif v == 0 then
			blink()
		end
	end)

	blink()


	chara:WaitForChild("Effects").ChildAdded:Connect(function(v) 
		if v.Name == "Ragdoll" then -- Knocked locking blinking and mouth
			allowedtoTalk = false
			allowedtoBlink = false

			-- setting up neutral face and slobber mouth
			parts["EyeColor"].Texture = ""

			if facebaseid == "rbxassetid://13466958587" then -- human male 1
				parts["FaceBase"].Texture = "rbxassetid://13467199372"
			elseif facebaseid == "rbxassetid://13473200175" then -- human female 1
				parts["FaceBase"].Texture = "rbxassetid://13473251210"
			elseif facebaseid == "rbxassetid://13473204337" then -- human male 2
				parts["FaceBase"].Texture = "rbxassetid://13482990162"
			end

			parts["MouthShape"].Texture = "rbxassetid://95457103347003"
		elseif v.Name == "Hit" and not chara.Effects:FindFirstChild("Ragdoll") then -- Temporary Grunt
			allowedtoTalk = false
			allowedtoBlink = false
			
			-- setting up neutral face
			parts["EyeColor"].Texture = ""

			if facebaseid == "rbxassetid://13466958587" then -- human male 1
				parts["FaceBase"].Texture = "rbxassetid://13467199372"
			elseif facebaseid == "rbxassetid://13473200175" then -- human female 1
				parts["FaceBase"].Texture = "rbxassetid://13473251210"
			elseif facebaseid == "rbxassetid://13473204337" then -- human male 2
				parts["FaceBase"].Texture = "rbxassetid://13482990162"
			end
			
			parts["MouthShape"].Texture = "rbxassetid://76724770569093" --TODO: Eventually when in combat is added, just have this face become the default one.
		end
	end)

	chara:WaitForChild("Effects").ChildRemoved:Connect(function(v)
		if v.Name == "Ragdoll" or v.Name == "Hit" and not chara.Effects:FindFirstChild("Ragdoll") then -- Setting back to normal
			allowedtoTalk = true
			allowedtoBlink = true

			parts["EyeColor"].Texture = eyecolorid
			parts["FaceBase"].Texture = facebaseid
			parts["MouthShape"].Texture = mouthid
		end
	end)
end



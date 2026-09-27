local rub = {}

local camshakeEvent = game.ReplicatedStorage.Remotes.MiscRemotes.CameraShake


rub.RubbleCreate = function(int, colVal, setting)
	if setting == 1 then
		-- Grabing Info
		local SizeOfInt = int.Size
		local PositionOfInt = int.Position
		local MaterialOfInt = int.Material
		local ColorOfInt = int.Color
		
		-- Creating Particles
		local smokPart = script.DebrisSmoke:Clone()
		smokPart.CFrame = CFrame.new(PositionOfInt)
		smokPart.RubbleSmoke.Color = ColorSequence.new(ColorOfInt)
		
		smokPart.Parent = workspace.Rubble
		smokPart.RubbleSmoke:Emit(50)
		
		-- Setting up Screen Shaker
		for _,nearby in workspace.Characters:GetChildren() do
			local mag = (PositionOfInt - nearby.HumanoidRootPart.Position).Magnitude

			if mag < 150 then 
				camshakeEvent:FireClient(game.Players:GetPlayerFromCharacter(nearby), 4)
			end
		end
		
		-- Playing Sound
		local s = game.ReplicatedFirst.SFX.Magic.Strength.EarthBreak:Clone()
		s.Parent = smokPart
		s:Play()

		
		delay(2, function()
			smokPart:Destroy()
		end)
		
		-- Rubble Rocks
		for i=1,5,1 do
			local cube = Instance.new("Part")
			cube.Size = Vector3.new(2 + math.random(-1,1), 2 + math.random(-1,1), 2 + math.random(-1,1))
			cube.Name = "DebrisRocks"
			cube.Material = MaterialOfInt
			cube.Color = ColorOfInt
			
			cube.Anchored = false
			cube.CanCollide = true
			
			cube.Position = Vector3.new(PositionOfInt.X + math.random(-2,2), PositionOfInt.Y + math.random(-2,2), PositionOfInt.Z + math.random(-2,2))
			
			-- Attachments
			local att = Instance.new("Attachment", cube)
			local att2 = Instance.new("Attachment", cube)
			att2.CFrame = CFrame.new(Vector3.new(0,0,1))
			
			-- Vector Lines
			local line = game.ReplicatedStorage.VFX.MiscEffects.DashTrail:Clone()
			line.Attachment0 = att
			line.Attachment1 = att2
			line.Parent = att

			--Force
			local VFor = Instance.new("VectorForce")
			VFor.Attachment0 = att
			VFor.RelativeTo = Enum.ActuatorRelativeTo.World
			VFor.Force = Vector3.new(math.random(-1,1), 1, math.random(-1,1)) * 2500
			VFor.Parent = att
			
			cube.Parent = workspace.Rubble
			
			delay(0.3, function()
				VFor:Destroy()
				delay(2, function()
					line:Destroy()
				end)
			end)
		end
	end
end

return rub

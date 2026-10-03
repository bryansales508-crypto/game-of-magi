--!nocheck
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LimbTree          = require(script:WaitForChild("LimbTree"))

local Ragdoll = {}

local APPEARANCE_TIMEOUT = 5

function Ragdoll.RagdollCharacter(Character : Model)
	local Humanoid = Character:FindFirstChild("Humanoid")
	if not Humanoid then return end

	-- Players get an AppearenceLoaded BoolValue (CharacterService); wait for it,
	-- but never forever. NPCs have none, so they proceed at once.
	local Loaded = Character:FindFirstChild("AppearenceLoaded")
	if Loaded and Loaded:IsA("BoolValue") then
		local Deadline = os.clock() + APPEARANCE_TIMEOUT
		while Loaded.Value == false and os.clock() < Deadline and Character.Parent ~= nil do
			task.wait()
		end
	end

	if Humanoid.RigType == Enum.HumanoidRigType.R6 then
		local Head             = Character:FindFirstChild("Head")
		local Torso            = Character:FindFirstChild("Torso")
		local HumanoidRootPart = Character:FindFirstChild("HumanoidRootPart")
		local RightArm         = Character:FindFirstChild("Right Arm")
		local LeftArm          = Character:FindFirstChild("Left Arm")
		local RightLeg         = Character:FindFirstChild("Right Leg")
		local LeftLeg          = Character:FindFirstChild("Left Leg")


		if Torso and not Torso:FindFirstChild("NeckJoint") then
			local NeckAttachment = Instance.new("Attachment")
			NeckAttachment.Parent = Head
			NeckAttachment.Name = "NeckAttachment"
			NeckAttachment.Position = Vector3.new(0,-Head.Size.Y/2,0)
			NeckAttachment:SetAttribute("Ragdoll", true)

			local TorsoNeckAttachment = Instance.new("Attachment")
			TorsoNeckAttachment.Parent = Torso
			TorsoNeckAttachment.Name = "TorsoNeckAttachment"
			TorsoNeckAttachment.Position = Vector3.new(0,Torso.Size.Y/2,0)
			TorsoNeckAttachment:SetAttribute("Ragdoll", true)

			local NeckJoint              = script.Neck:Clone()
			NeckJoint.Parent             = Torso
			NeckJoint.Name               = "NeckJoint"
			NeckJoint.Attachment0        = NeckAttachment
			NeckJoint.Attachment1        = TorsoNeckAttachment
			NeckJoint:SetAttribute("Ragdoll", true)

			
			local RightArmAtt = Instance.new("Attachment")
			RightArmAtt.Name = "RightArmAttachment"
			RightArmAtt.Position = Vector3.new(0, RightArm.Size.Y/2, 0)
			RightArmAtt.Parent = RightArm
			RightArmAtt:SetAttribute("Ragdoll", true)

			local TorsoRightArmAttachment        = Instance.new("Attachment")
			TorsoRightArmAttachment.Parent       = Torso
			TorsoRightArmAttachment.Position     = Vector3.new(Torso.Size.X/2,Torso.Size.Y/2,0)
			TorsoRightArmAttachment.Name         = "TorsoRightArmAttachment"
			TorsoRightArmAttachment:SetAttribute("Ragdoll", true)

			local RightArmJoint         = script.Default:Clone()
			RightArmJoint.Parent        = Torso
			RightArmJoint.Name          = "RightArmJoint"
			RightArmJoint.Attachment0   = TorsoRightArmAttachment
			RightArmJoint.Attachment1   = RightArmAtt
			RightArmJoint:SetAttribute("Ragdoll", true)

			
			local LeftArmAtt = Instance.new("Attachment")
			LeftArmAtt.Name = "LeftArmAttachment"
			LeftArmAtt.Position = Vector3.new(0, LeftArm.Size.Y/2, 0)
			LeftArmAtt.Parent = LeftArm
			LeftArmAtt:SetAttribute("Ragdoll", true)

			local TorsoLeftArmAttachment        = Instance.new("Attachment")
			TorsoLeftArmAttachment.Parent       = Torso
			TorsoLeftArmAttachment.Position     = Vector3.new(-Torso.Size.X/2,Torso.Size.Y/2,0)
			TorsoLeftArmAttachment.Name         = "TorsoLeftArmAttachment"
			TorsoLeftArmAttachment:SetAttribute("Ragdoll", true)

			local LeftArmJoint         = script.Default:Clone()
			LeftArmJoint.Parent        = Torso
			LeftArmJoint.Name          = "LeftArmJoint"
			LeftArmJoint.Attachment0   = TorsoLeftArmAttachment
			LeftArmJoint.Attachment1   = LeftArmAtt
			LeftArmJoint:SetAttribute("Ragdoll", true)
			
			
			local RightLegAttachment       = Instance.new("Attachment")
			RightLegAttachment.Parent      = RightLeg
			RightLegAttachment.Name        = "RightLegAttachment"
			RightLegAttachment.Position    = Vector3.new(0,RightLeg.Size.Y/2,0)
			RightLegAttachment:SetAttribute("Ragdoll", true)

			local TorsoRightLegAttachment       = Instance.new("Attachment")
			TorsoRightLegAttachment.Parent      = Torso
			TorsoRightLegAttachment.Name        = "TorsoRightLegAttachment"
			TorsoRightLegAttachment.Position    = Vector3.new(-Torso.Size.X/4, -Torso.Size.Y/2, 0)
			TorsoRightLegAttachment:SetAttribute("Ragdoll", true)

			local RightLegJoint              = script.Default:Clone()
			RightLegJoint.Parent             = Torso
			RightLegJoint.Name               = "RightLegJoint"
			RightLegJoint.Attachment0        = RightLegAttachment
			RightLegJoint.Attachment1        = TorsoRightLegAttachment
			RightLegJoint:SetAttribute("Ragdoll", true)


			local LeftLegAttachment       = Instance.new("Attachment")
			LeftLegAttachment.Parent      = LeftLeg
			LeftLegAttachment.Name        = "LeftLegAttachment"
			LeftLegAttachment.Position    = Vector3.new(0,LeftLeg.Size.Y/2,0)
			LeftLegAttachment:SetAttribute("Ragdoll", true)

			local TorsoLeftLegAttachment       = Instance.new("Attachment")
			TorsoLeftLegAttachment.Parent      = Torso
			TorsoLeftLegAttachment.Name        = "TorsoLeftLegAttachment"
			TorsoLeftLegAttachment.Position    = Vector3.new(Torso.Size.X/4, -Torso.Size.Y/2, 0)
			TorsoLeftLegAttachment:SetAttribute("Ragdoll", true)

			local LeftLegJoint              = script.Default:Clone()
			LeftLegJoint.Parent             = Torso
			LeftLegJoint.Name               = "LeftLegJoint"
			LeftLegJoint.Attachment0        = LeftLegAttachment
			LeftLegJoint.Attachment1        = TorsoLeftLegAttachment
			LeftLegJoint:SetAttribute("Ragdoll", true)
		end
		
		HumanoidRootPart.CanCollide = false

		for _,v in pairs(Character:GetChildren()) do
			if v:IsA("BasePart") and v.Name ~= "HumanoidRootPart" and v.Name ~= "LowerTorso" and v.Name ~= "UpperTorso" then
				local NC  = Instance.new("NoCollisionConstraint")
				NC.Parent = Torso
				NC.Name   = v.Name
				NC.Part0  = v
				NC.Part1  = Torso
			end
		end
	end

	for _,v in pairs(Character:GetDescendants()) do
		if v:IsA("Motor6D") and v.Name ~= "Root" and v.Name ~= "RootJoint" then
			v.Enabled = false
		end
	end
end

function Ragdoll.UnRagdollCharacter(Character : Model)
	local HumanoidRootPart      = Character:FindFirstChild("HumanoidRootPart")
	if HumanoidRootPart then HumanoidRootPart.CanCollide = true end

	for _,v in pairs(Character:GetDescendants()) do
		if v:GetAttribute("Ragdoll") then
			v:Destroy()
		end

		if v:IsA("Motor6D") then
			v.Enabled = true
		end
	end
end

return Ragdoll

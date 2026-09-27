local dash = {}

local db = game:GetService("Debris")

dash.Create = function(chara, num, length)
	for i=1,num,1 do
		local line = game.ReplicatedStorage.VFX.MiscEffects.DashTrail:Clone()
		
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
		
		db:AddItem(line, length)
		db:AddItem(attachment1, length)
		db:AddItem(attachment2, length)
	end
end

return dash

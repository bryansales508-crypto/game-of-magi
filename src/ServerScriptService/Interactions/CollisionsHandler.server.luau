repeat task.wait() until game.Loaded

local ps = game:GetService("PhysicsService")

local MapCollisionGroup = "MapCollisionGroup"
ps:RegisterCollisionGroup(MapCollisionGroup)


for _,v in game.Workspace.MAP:GetDescendants() do
	if v:IsA("BasePart") then
		if not v:FindFirstAncestor("Areas") then
			v.CollisionGroup = "MapCollisionGroup"
		end
	elseif v:IsA("UnionOperation") then
		v.CollisionGroup = "MapCollisionGroup"
	end
end

local clothingRackGroup = "ClothingRackGroup"
if not ps:IsCollisionGroupRegistered(clothingRackGroup) then
	ps:RegisterCollisionGroup(clothingRackGroup)
end

for _,v in game.Workspace:GetDescendants() do 
	if v.Name == "ClothingRack" then
		for _,p in v:GetChildren() do
			if p:IsA("BasePart") then
				p.CollisionGroup = clothingRackGroup
			end
		end
	end
end
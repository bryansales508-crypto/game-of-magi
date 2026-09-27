local module = {}

local weaponInfo = {
	["Royal Dagger"] = {
		gripC0 = CFrame.new(0 ,-1.5, -0.8) * CFrame.Angles(math.rad(-45), 0, 0)
	}
}

local wepFold = game.ReplicatedFirst:WaitForChild("Tools"):WaitForChild("Weapons")
local basicWepFold = wepFold:FindFirstChild("BasicWeapons")

function module.rig(weaponModel, chara) -- equip
	local handle = weaponModel:FindFirstChild("Handle")
	if not handle then warn("WeaponHandler: no Handle on", weaponModel.Name); return end
	local weaponLoadedInfo = weaponInfo[weaponModel.Name]

	handle.Anchored = false
	handle.CanCollide = false
	
	-- connecting to hand
	local limb = chara:FindFirstChild("Right Arm")
	if not limb then warn("WeaponHandler: no arm on", chara.Name); return end
	
	local motor = Instance.new("Motor6D")
	motor.Name = "WeaponGrip"
	motor.Part0 = limb
	motor.Part1 = handle
	motor.C0 = (weaponLoadedInfo and weaponLoadedInfo.gripC0) or CFrame.new(0, -1, 0)
	motor.Parent = limb

	weaponModel.Parent = chara
	return motor
end

function module.equip(chara, weaponName)
	if not wepFold then warn("WeaponHandler: no Weapons folder"); return end
	module.unequip(chara)  -- only one weapon at a time

	local asset = wepFold.BasicWeapons:FindFirstChild(weaponName)
	if not asset then warn("WeaponHandler: no weapon", weaponName); return end

	local weapon = asset:Clone()
	weapon.Name = weaponName
	local motor = module.rig(weapon, chara)
	if not motor then weapon:Destroy(); return end
	
	chara:FindFirstChild("IntFold"):FindFirstChild("Weapon").Value = weaponName
	return weapon
end

function module.unequip(chara)
	local arm = chara:FindFirstChild("Right Arm")
	if arm then
		local motor = arm:FindFirstChild("WeaponGrip")
		if motor then motor:Destroy() end
	end
	local held = chara:FindFirstChild("IntFold"):FindFirstChild("Weapon")
	
	if held then
		local model = chara:FindFirstChild(held.Value)
		if model and model:FindFirstChild("Handle") then model:Destroy() end
	end
	
	chara:FindFirstChild("IntFold"):FindFirstChild("Weapon").Value = ""
end

return module

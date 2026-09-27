local toolBar = script.Parent

local weaponInfo = {
	["Royal Dagger"] = {
		ToolTip = "Violence in Style",
		Model   = game.ReplicatedFirst.Tools.Weapons.BasicWeapons["Royal Dagger"],
		bladeMesh = {
			StraightArrow = ""
		},
		handleMesh = {
			Flared = ""
		},
		bladeDesign = {
			Steel = ""
		},
		handleDesign = {
			GoldenFlorish = ""
		}
	}
}


toolBar.Equipped:Connect(function()
	
end)

toolBar.Unequipped:Connect(function()
	
end)
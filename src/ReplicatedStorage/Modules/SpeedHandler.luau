local module = {}

local db = game:GetService("Debris")

function module.Set(walkspeed, runspeed)

	--[[local StatsFold = module.player:WaitForChild("Stats")
	local race = StatsFold:WaitForChild("Race")
	local height = StatsFold:WaitForChild("Height")]]

	--Race Guide
	-- 1 = Fanalis, 2 = Human, 3 = Immuchak, 4 = Magician, 5 = Magi

	--[[if race.Value == 1 then
		walkspeed = 18
		walkspeed = walkspeed - height.Value
		runspeed = 50 
		runspeed = runspeed - height.Value * 3
	elseif race.Value == 2 then
		walkspeed = 16
		walkspeed = walkspeed - height.Value
		runspeed = 32
		runspeed = runspeed - height.Value * 2
	elseif race.Value  == 3 then
		walkspeed = 16
		walkspeed = walkspeed - height.Value
		runspeed = 36
		runspeed = runspeed - height.Value * 2
	elseif race.Value == 4 or race.Value == 5 then
		walkspeed = 16
		walkspeed = walkspeed + height.Value
		runspeed = 28
		runspeed = runspeed + height.Value * 2
	end]]

	walkspeed = 16
	walkspeed = walkspeed
	runspeed = 28
	runspeed = runspeed

	return walkspeed, runspeed
end

function module.SpeedHandle(chara, value, duration)
	local MoveFold = chara:WaitForChild("IntFold"):WaitForChild("MovementSpeed")

	local newVal = Instance.new("StringValue")
	newVal.Name = value
	newVal.Parent = MoveFold
	newVal.Value = ""

	-- If a number give, set the duration.
	if type(duration) == "number" then
		db:AddItem(newVal,duration)
	else
		-- If not, it will be handled by SpeedHandleRemove.
		if duration then
			newVal.Value = duration
		end
	end
end

function module.SpeedHandleRemove(chara, val)
	-- Finds a name given value.
	local MoveFold = chara:FindFirstChild("IntFold"):FindFirstChild("MovementSpeed")
	for _,v in MoveFold:GetChildren() do
		if v.Value == val then
			v:Destroy()
		elseif v.Name == val then
			v:Destroy()
		end
	end
end

return module

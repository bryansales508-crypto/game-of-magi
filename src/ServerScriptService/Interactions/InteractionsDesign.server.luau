local combatpress = game.ReplicatedStorage.Remotes.CombatRemotes.CombatPress
local speedMod = require(game.ReplicatedStorage.Modules.SpeedHandler)
local weap = require(game.ReplicatedStorage.Modules.Combat.WeaponHandler)
local db = game:GetService("Debris")

-- remotes
local parryEvent = game.ReplicatedStorage.Remotes.CombatRemotes.Parry
local getDamage = game.ReplicatedStorage.Remotes.GetDamage

game.Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		--while player:WaitForChild("Loaded").Value == false do task.wait() end
		while character:WaitForChild("AppearenceLoaded").Value == false do task.wait()end

		local intFold = Instance.new("Folder")
		intFold.Name = "IntFold"
		intFold.Parent = character
		
		-- Weapon Value
		local Weapon = Instance.new("StringValue")
		Weapon.Name = "Weapon"
		Weapon.Parent = intFold

		-- Running Value
		local Run = Instance.new("BoolValue")
		Run.Name = "Running?"
		Run.Parent = intFold

		-- HitTracker Value
		local HitTracker = Instance.new("IntValue")
		HitTracker.Value = 0
		HitTracker.Name = "HitTracker"
		HitTracker.Parent = intFold

		-- Block Value
		local block = Instance.new("NumberValue")
		block.Name = "BlockInt"
		block.Parent = intFold
		block.Value = 35 -- TODO: Change later for race.

		local maxblockhp = Instance.new("NumberValue")
		maxblockhp.Name = "MaxBlockHpInt"
		maxblockhp.Parent = intFold
		maxblockhp.Value = block.Value

		-- Block Handling
		local inv1 = game.ReplicatedFirst.GUI.Inversion1
		local inv2 = game.ReplicatedFirst.GUI.Inversion2
		
		getDamage.Event:Connect(function(testChara, dmg, parry, enemyChara)
			if testChara == character then
				local poseCheck = block.value - dmg

				if parry == 0 then
					if poseCheck <= 0 and not character.Effects:FindFirstChild("BlockBroken") then
						block.Value = 0 -- zero pose

						local blockBroken = Instance.new("IntValue") -- block break
						blockBroken.Name = "BlockBroken"
						blockBroken.Parent = character.Effects

						blockBroken.Destroying:Connect(function()
							block.Value = maxblockhp.Value -- restoring
						end)
						
						if character.Effects:FindFirstChild("Block") then -- ending block
							character.Effects.Block:Destroy()
						end

						task.delay(3, function()
							blockBroken:Destroy()
						end)
					else -- not enough to block break
						if not character.Effects:FindFirstChild("BlockBroken") then
							block.Value -= dmg
						end
					end
				else -- parried
					local truestunInt = Instance.new("IntValue") -- Stun int for enemy
					truestunInt.Name = "Stun"
					truestunInt.Parent = enemyChara.Effects
					db:AddItem(truestunInt, 1)
					
					speedMod.SpeedHandle(enemyChara, .25, "Parry")
					task.delay(.75, function()
						speedMod.SpeedHandleRemove(enemyChara, "Parry")
					end)
					
					local posecheck = block.Value + dmg -- restoring pose 35 + 3 = 38
					if poseCheck >= maxblockhp.Value then
						block.Value = maxblockhp.Value
					else
						block.Value += dmg 
					end
					
					parryEvent:FireClient(game.Players:GetPlayerFromCharacter(character)) -- client effects
					character.Torso.Parry:Play() -- sound
					character.Torso.CenterHook.Sparks1:Emit(10) -- particles
					character.Torso.CenterHook.Sparks2:Emit(10)
					
					for _,v in character.Effects:GetChildren() do -- removing preventers
						if v.Name == "Stun" or v.Name == "Hit" then
							v:Destroy()
							speedMod.SpeedHandleRemove(character, "Parry")
						end
					end
					
					if character.Effects:FindFirstChild("Block") then -- ending block
						character.Effects.Block:Destroy()
					end
				end
			end
		end)

		-- MovementSpeed
		local MovementSpeed = Instance.new("Folder")
		MovementSpeed.Name = "MovementSpeed"
		MovementSpeed.Parent = intFold

		-- Setting Startspeeds
		local walkspeed, runspeed = nil, nil
		walkspeed, runspeed = speedMod.Set(walkspeed, runspeed)
		character:FindFirstChild("Humanoid").WalkSpeed = walkspeed

		local SpeedStableWalk = Instance.new("NumberValue")
		SpeedStableWalk.Name = "SpeedStableWalk"
		SpeedStableWalk.Value = walkspeed
		SpeedStableWalk.Parent = MovementSpeed
		
		local WalkTrueStable = walkspeed

		local SpeedStableRun = Instance.new("NumberValue")
		SpeedStableRun.Name = "SpeedStableRun"
		SpeedStableRun.Value = runspeed
		SpeedStableRun.Parent = MovementSpeed
		
		local TrueStable = SpeedStableRun.Value
		
		local DashStable = Instance.new("NumberValue")
		DashStable.Name = "DashStable"
		DashStable.Value = 30
		DashStable.Parent = SpeedStableRun

		-- Speed Handling
		MovementSpeed.ChildAdded:Connect(function(Mover)
			local Values = {}
			
			if Mover.Name == "Run" then -- run
				character.Humanoid.WalkSpeed = SpeedStableRun.Value
			end
			
			if Mover.Name == "Dash" then -- dashing
				character.Humanoid.WalkSpeed = character.Humanoid.WalkSpeed + DashStable.Value --TODO: Just make this customizable for special dashes
			end

			for _,v in MovementSpeed:GetChildren() do
				if string.find(v.Name, "SpeedStable") or v.Name == "Run" or v.Name == "Dash" then -- add all possible movers together beside run, dash, and the stables
				else
					table.insert(Values, tonumber(v.Name))
				end
			end

			if #Values ~= 0 then -- if there are actual movers
				local min = math.huge
				for i = 1, #Values  do -- sort through them and find the smallest one
					min = min < Values[i] and min or Values[i]
				end

				if min == 0 then -- if it is zero, automatically drop the speed
					character.Humanoid.WalkSpeed = 0
				else
					local dashMover = DashStable.Value
					if not MovementSpeed:FindFirstChild("Dash") then dashMover = 0 end -- only count when dashing
					
					if character:FindFirstChild("IntFold"):FindFirstChild("Running?").Value == true then -- multiple stable by the smallest value
						character.Humanoid.WalkSpeed = (SpeedStableRun.Value * min) + (dashMover * min)
					else
						character.Humanoid.WalkSpeed = (SpeedStableWalk.Value * min) + (dashMover * min)
					end
				end
			end
		end)

		MovementSpeed.ChildRemoved:Connect(function(Mover)
			local checkTable = {}

			-- Handling Running
			if Mover.Name == "Run" then
				character.Humanoid.WalkSpeed = SpeedStableWalk.Value 
			end
			
			if Mover.Name == "Dash" then -- dashing
				if Mover:FindFirstChild("Run") then
					character.Humanoid.WalkSpeed = SpeedStableRun.Value
				else
					character.Humanoid.WalkSpeed = SpeedStableWalk.Value
				end
			end
			
			for _,v in MovementSpeed:GetChildren() do
				if string.find(v.Name, "SpeedStable") or v.Name == "Run" then
				else
					table.insert(checkTable, v.Name)
				end
			end

			if #checkTable == 0 then
				-- If no other values, then just set the speed back to normal.

				if character:FindFirstChild("IntFold"):FindFirstChild("Running?").Value then
					character.Humanoid.WalkSpeed = SpeedStableRun.Value
				else
					character.Humanoid.WalkSpeed = SpeedStableWalk.Value
				end
			else
				-- Checking all speeds, assigning the lowest. Only does this if there is another value when one leaves.
				local Values = {}
				for _,v in MovementSpeed:GetChildren() do
					if string.find(v.Name, "SpeedStable") or v.Name == "Run" or v.Name == "Dash" then
					else
						table.insert(Values, tonumber(v.Name))
					end
				end

				if #Values ~= 0 then
					local min = math.huge
					for i = 1, #Values  do
						min = min < Values[i] and min or Values[i]
					end

					if min == 0 then
						character.Humanoid.WalkSpeed = 0
					else
						local dashMover = DashStable.Value
						if not MovementSpeed:FindFirstChild("Dash") then dashMover = 0 end -- only count when dashing

						if character:FindFirstChild("IntFold"):FindFirstChild("Running?").Value == true then -- multiple stable by the smallest value
							character.Humanoid.WalkSpeed = (SpeedStableRun.Value * min) + (dashMover * min)
						else
							character.Humanoid.WalkSpeed = (SpeedStableWalk.Value * min) + (dashMover * min)
						end
					end
				end
			end
		end)
		
		spawn(function() -- for health dropping speed
			while true do
				while character.Humanoid.Health < character.Humanoid.MaxHealth do
					task.wait(0.1)
					local hth = character.Humanoid.Health
					local maxhth = character.Humanoid.MaxHealth
					local rh = hth/maxhth
					
					local scale = TrueStable/2 + (TrueStable - TrueStable/2) * rh
					SpeedStableRun.Value = scale
					
					local scale2 = WalkTrueStable/4 + (WalkTrueStable - WalkTrueStable/4) * rh
					SpeedStableWalk.Value = scale2
				end
				
				if character.Humanoid.Health == character.Humanoid.MaxHealth then
					SpeedStableRun.Value = TrueStable
					SpeedStableWalk.Value = WalkTrueStable
				end
				
				--Wait
				character.Humanoid.HealthChanged:Wait()
			end
		end)
		
		task.wait(10)
		weap.equip(character, "Royal Dagger")
	end)
end)

-- NPCs

local function npcInteractions(character)
	-- Setting Startspeeds
	local walkspeed, runspeed = nil, nil
	walkspeed, runspeed = speedMod.Set(walkspeed, runspeed)
	character:FindFirstChild("Humanoid").WalkSpeed = walkspeed

	local SpeedStableWalk = Instance.new("NumberValue")
	SpeedStableWalk.Name = "SpeedStableWalk"
	SpeedStableWalk.Value = walkspeed
	SpeedStableWalk.Parent = character.IntFold.MovementSpeed

	local SpeedStableRun = Instance.new("NumberValue")
	SpeedStableRun.Name = "SpeedStableRun"
	SpeedStableRun.Value = runspeed - 2 --TODO: Edit this obviously. Whenver you update speedhandle.
	SpeedStableRun.Parent = character.IntFold.MovementSpeed

	-- Speed Handling
	character.IntFold.MovementSpeed.ChildAdded:Connect(function(Mover)
		local Values = {}

		-- Handling Running
		if Mover.Name == "Run" then
			character.Humanoid.WalkSpeed = SpeedStableRun.Value
		end

		for _,v in character.IntFold.MovementSpeed:GetChildren() do
			if string.find(v.Name, "SpeedStable") or v.Name == "Run" then
			else
				table.insert(Values, tonumber(v.Name))
			end
		end

		if #Values ~= 0 then
			local min = math.huge
			for i = 1, #Values  do
				min = min < Values[i] and min or Values[i]
			end

			if min == 0 then
				character.Humanoid.WalkSpeed = 0
			else
				if character:FindFirstChild("IntFold"):FindFirstChild("Running?").Value == true then
					character.Humanoid.WalkSpeed = SpeedStableRun.Value * min
				else
					character.Humanoid.WalkSpeed = SpeedStableWalk.Value * min
				end
			end
		end
	end)

	character.IntFold.MovementSpeed.ChildRemoved:Connect(function(Mover)
		local checkTable = {}

		-- Handling Running
		if Mover.Name == "Run" then
			character.Humanoid.WalkSpeed = SpeedStableWalk.Value 
		end

		for _,v in character.IntFold.MovementSpeed:GetChildren() do
			if string.find(v.Name, "SpeedStable") or v.Name == "Run" then
			else
				table.insert(checkTable, v.Name)
			end
		end

		if #checkTable == 0 then
			-- If no other values, then just set the speed back to normal.

			if character:FindFirstChild("IntFold"):FindFirstChild("Running?").Value then
				character.Humanoid.WalkSpeed = SpeedStableRun.Value
			else
				character.Humanoid.WalkSpeed = SpeedStableWalk.Value
			end
		else
			-- Checking all speeds, assigning the lowest. Only does this if there is another value when one leaves.
			local Values = {}
			for _,v in character.IntFold.MovementSpeed:GetChildren() do
				if string.find(v.Name, "SpeedStable") or v.Name == "Run" then
				else
					table.insert(Values, tonumber(v.Name))
				end
			end

			if #Values ~= 0 then
				local min = math.huge
				for i = 1, #Values  do
					min = min < Values[i] and min or Values[i]
				end

				if min == 0 then
					character.Humanoid.WalkSpeed = 0
				else
					if character:FindFirstChild("IntFold"):FindFirstChild("Running?").Value == true then
						character.Humanoid.WalkSpeed = SpeedStableRun.Value * min
					else
						character.Humanoid.WalkSpeed = SpeedStableWalk.Value * min
					end
				end
			end
		end
	end)
end

-- Making sure we ascertain all NPCs
for _,NPC in game.Workspace.NPC:GetChildren() do
	npcInteractions(NPC)
end

game.Workspace.NPC.ChildAdded:Connect(function(NPC)
	npcInteractions(NPC)
end)
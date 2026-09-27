local module = {}

local wayp
local nextW
local reach
local block

function module.PathFinder(goal, chara)
	local pfs = game:GetService("PathfindingService")

	local hum = chara:FindFirstChild("Humanoid")

	-- Movement
	local path = pfs:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		WaypointSpacing = 4,
		AgentCanClimb = true
	})

	-- Variables
	local wayp
	local nextW
	local reach
	local jumpindex = 1
	local oljump = 0

	local Knocked = false
	local con1
	local con2
	local failureProtection = false

	-- Debounce
	local jdb = false
	local jdb2 = false

	-- Functions
	local comp = nil
	
	local function Move() -- ai pathfinding move
		if not Knocked then
			nextW = 2

			if chara.NPCFetch.CurrentAct.Value ~= "Running" then
				chara.NPCFetch.CurrentAct.Value = "Running"
			end


			hum:MoveTo(wayp[nextW].Position)

			local reach
			reach = hum.MoveToFinished:connect(function(reached)
				if not Knocked then
					if reached and nextW < #wayp then
						nextW += 1
						hum:MoveTo(wayp[nextW].Position)

						if wayp[nextW].Action == Enum.PathWaypointAction.Jump then
							task.wait(0.5)
							hum:ChangeState(Enum.HumanoidStateType.Jumping)
						end
					elseif nextW == #wayp then
						comp()
						reach:Disconnect()
					end
				end
			end)
		end
	end

	local function dummyPlug() -- just tracking player
		spawn(function()
			while chara.Parent ~= nil and goal.Parent ~= nil and not failureProtection and chara.NPCFetch.Target.Value ~= nil and (goal.HumanoidRootPart.Position - chara.HumanoidRootPart.Position).magnitude <= 20 do
				if chara.NPCFetch.CurrentAct.Value ~= "Running" then
					chara.NPCFetch.CurrentAct.Value = "Running"
				end

				chara.Humanoid:MoveTo(goal.HumanoidRootPart.Position + goal.HumanoidRootPart.CFrame.LookVector*2)
				task.wait()
			end

			-- moved out of range and still the same target
			if chara.Parent ~= nil and goal.Parent ~= nil and not failureProtection and chara.NPCFetch.Target.Value == goal then
				local targPos = goal.HumanoidRootPart.Position
				local mag = (targPos - chara.HumanoidRootPart.Position).magnitude

				if mag <= 40 then -- if distance is still below 40 then, recall the function
					comp()
				else -- otherwise give up
					failureProtection = true

					con2:Disconnect()
					con1:Disconnect()
					Knocked = true
					chara.NPCFetch.CurrentAct.Value = "Standing"
					chara.NPCFetch.Target.Value = nil
				end
			end
		end)
	end
	

	comp = function()-- computation
		if not Knocked then
			local targPos = goal.HumanoidRootPart.Position
			local mag = (targPos - chara.HumanoidRootPart.Position).magnitude

			if mag <= 10 then
				dummyPlug()
			elseif mag > 10 and mag <= 40 then
				local success, errorMessage = pcall(function()
					if chara.NPCFetch.npcType.Value == "Target" then
						path:ComputeAsync(chara.PrimaryPart.Position, goal.HumanoidRootPart.Position + goal.HumanoidRootPart.CFrame.LookVector*2)
					end
				end)

				if success and path.Status == Enum.PathStatus.Success then
					wayp = path:GetWaypoints()

					local con

					con = path.Blocked:Connect(function(blockedWaypointIndex)
						if blockedWaypointIndex >= nextW then
							con:Disconnect()
							comp()
						end
					end)

					Move()
				else -- Failure
					warn("Failure to compute path.")
					dummyPlug()

					task.delay(3, function() -- wait, try to compute again.
						local mag = (goal.HumanoidRootPart.Position - chara.HumanoidRootPart.Position).magnitude

						if mag > 40 then
							failureProtection = true

							con2:Disconnect()
							con1:Disconnect()
							Knocked = true
							chara.NPCFetch.CurrentAct.Value = "Standing"
							chara.NPCFetch.Target.Value = nil
							
						elseif mag <= 40 then
							failureProtection = true

							comp()
						end
					end)
				end
			else -- completely out of range
				con2:Disconnect()
				con1:Disconnect()
				Knocked = true
				chara.NPCFetch.CurrentAct.Value = "Standing"
				chara.NPCFetch.Target.Value = nil
			end
		end
	end

	comp()

	-- Post-Effects
	if goal.Parent ~= nil then
		con1 = goal.Effects.ChildAdded:Connect(function(v)
			if v.Name == "Knocked" then
				con2:Disconnect()
				con1:Disconnect()
				Knocked = true
				chara.NPCFetch.CurrentAct.Value = "Standing"
				chara.NPCFetch.Target.Value = nil
			end
		end)
	end
	
	con2 = chara.Effects.ChildAdded:Connect(function(v)
		if v.Name == "Knocked" then
			con2:Disconnect()
			con1:Disconnect()
			Knocked = true
			chara.NPCFetch.CurrentAct.Value = "Standing"
			chara.NPCFetch.Target.Value = nil
		end
	end)
end

return module

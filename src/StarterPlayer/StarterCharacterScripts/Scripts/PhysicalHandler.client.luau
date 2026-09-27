-- Disabling GUI
game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)

--Services
local userinputserv = game:GetService("UserInputService")
local db = game:GetService("Debris")
local Tween = game:GetService("TweenService")
local replicatedstorage = game:GetService("ReplicatedStorage")
local remotes = replicatedstorage.Remotes
local speedMod = require(game.ReplicatedStorage.Modules.SpeedHandler)

--Events
local runEvent = remotes.Running
local footEvent = remotes.MiscRemotes.Footstep
local hitEvent = remotes.CombatRemotes.Hit
local blockEvent = remotes.Blocking
local dashEvent = remotes.CombatRemotes.Dash

--Player Variables
local player = game.Players.LocalPlayer
local chara = player.Character or player.CharacterAdded:Wait()

local charaHum = chara:WaitForChild("Humanoid")
local animator = charaHum:WaitForChild("Animator")
local cam = game.Workspace.CurrentCamera -- camera

while chara:WaitForChild("AppearenceLoaded").Value == false do task.wait() end -- Waiting for Appearence
local effects = chara:WaitForChild("Effects")

--Debounce Variables
local runDebounce = false

--Animations

local runAnim = Instance.new("Animation")
runAnim.AnimationId = "rbxassetid://15421855688"

local runTrack = animator:LoadAnimation(runAnim)
runTrack.Priority = Enum.AnimationPriority.Action2

local runAnimIsPlaying = false

local m1FistAnim = Instance.new("Animation")
m1FistAnim.AnimationId = "rbxassetid://125726557974534"

local m1fistTrack = animator:LoadAnimation(m1FistAnim)
m1fistTrack.Priority = Enum.AnimationPriority.Action2

local  HitStag1Ani = Instance.new("Animation")
HitStag1Ani.AnimationId = "rbxassetid://15430342283"

local HitStag1Track = animator:LoadAnimation(HitStag1Ani)
HitStag1Track.Priority = Enum.AnimationPriority.Action4

local  HitStag2Ani = Instance.new("Animation")
HitStag2Ani.AnimationId = "rbxassetid://15430496352"

local HitStag2Track = animator:LoadAnimation(HitStag2Ani)
HitStag2Track.Priority = Enum.AnimationPriority.Action4

local  HitStag3Ani = Instance.new("Animation")
HitStag3Ani.AnimationId = "rbxassetid://15430593084"

local HitStag3Track = animator:LoadAnimation(HitStag3Ani)
HitStag3Track.Priority = Enum.AnimationPriority.Action4

local blockAnim = Instance.new("Animation")
blockAnim.AnimationId = "rbxassetid://15429144750"

local blockTrack = animator:LoadAnimation(blockAnim)
blockTrack.Priority = Enum.AnimationPriority.Action3

local BlockBrokAnim = Instance.new("Animation")
BlockBrokAnim.AnimationId = "rbxassetid://13489368315"

local BlockBrokTrack = animator:LoadAnimation(BlockBrokAnim)
BlockBrokTrack.Priority = Enum.AnimationPriority.Action3

local BlockStagger1Ani = Instance.new("Animation")
BlockStagger1Ani.AnimationId = "rbxassetid://15430386843"

BlockStagger1Track = animator:LoadAnimation(BlockStagger1Ani)

local BlockBreakAni = Instance.new("Animation")
BlockBreakAni.AnimationId = "rbxassetid://86794346470329"

BlockBreakTrack = animator:LoadAnimation(BlockBreakAni)

local dashTracks = {}
local dashAnis = {}

local WDashAni = Instance.new("Animation")
WDashAni.AnimationId = "rbxassetid://18100686685"
WDashAni.Name = "WDash"
table.insert(dashAnis, WDashAni)

local ADashAni = Instance.new("Animation")
ADashAni.AnimationId = "rbxassetid://18101513350"
ADashAni.Name = "ADash"
table.insert(dashAnis, ADashAni)

local SDashAni = Instance.new("Animation")
SDashAni.AnimationId = "rbxassetid://18101228314"
SDashAni.Name = "SDash"
table.insert(dashAnis, SDashAni)

local DDashAni = Instance.new("Animation")
DDashAni.AnimationId = "rbxassetid://18101385205"
DDashAni.Name = "DDash"
table.insert(dashAnis, DDashAni)

for i=1,4,1 do
	local track = animator:LoadAnimation(dashAnis[i])
	dashTracks[dashAnis[i].Name.."Track"] = track
end

local m1HalberdAnim = Instance.new("Animation")
m1HalberdAnim.AnimationId = "rbxassetid://98208946205762"

local m1HalberdTrack = animator:LoadAnimation(m1HalberdAnim)

local m1rDaggerAnim = Instance.new("Animation")
m1rDaggerAnim.AnimationId = "rbxassetid://115894342135428"

local m1rDaggerTrack = animator:LoadAnimation(m1rDaggerAnim)

local m1rDaggerIdleAnim = Instance.new("Animation")
m1rDaggerIdleAnim.AnimationId = "rbxassetid://129406226968584"

local m1rDaggerIdleTrack = animator:LoadAnimation(m1rDaggerIdleAnim)


--[[local DWDashAni = Instance.new("Animation")
DWDashAni.AnimationId = ""

DWDashTrack = animator:LoadAnimation(DWDashAni)

local AWDashAni = Instance.new("Animation")
AWDashAni.AnimationId = ""

AWDashTrack = animator:LoadAnimation(AWDashAni)]]


---------------------------------------


---------------------------------------



--Running

local accelSpeed = 2
local DefaultFieldOFView = cam.FieldOfView

local TweenSpeed = accelSpeed
local Running = false

local SprintingTween = Tween:Create(cam, TweenInfo.new(TweenSpeed), { FieldOfView = DefaultFieldOFView + (charaHum.WalkSpeed) })
local WalkingTween = Tween:Create(cam, TweenInfo.new(1), { FieldOfView = DefaultFieldOFView })

last = 0
dp = 0.5

for _,v in workspace.Characters:GetChildren() do -- Ridding Running Sound from Self and Others
	for _,x in v:GetChildren() do
		if x.Name == "HumanoidRootPart" then
			x:WaitForChild("Running"):Destroy()
		end
	end
end


workspace.Characters.ChildAdded:Connect(function(NewChara) -- Clearing any new character that joins
	for _,v in NewChara:GetChildren() do
		if v.Name == "HumanoidRootPart" then
			v:WaitForChild("Running"):Destroy()
		end
	end
end)


-- Footsteps
local conFeet1 = nil
local conFeet2 = nil
local conFeet3 = nil
local conFeet4 = nil

userinputserv.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.W and not runDebounce then
		local ct = tick()
		local ts = ct - last

		if ts <= dp then
			runDebounce = true
			runTrack:Play()

			Running = true
			runAnimIsPlaying = true
			runEvent:FireServer(true)

			-- Dealing with Feet
			conFeet1 = runTrack:GetMarkerReachedSignal("RightFoot"):Connect(function()
				-- Checking whether or not the player is in the air.
				if charaHum.FloorMaterial ~= Enum.Material.Air then
					footEvent:FireServer("Right")
				end
			end)

			conFeet2 = runTrack:GetMarkerReachedSignal("LeftFoot"):Connect(function()
				-- Checking whether or not the player is in the air.
				if charaHum.FloorMaterial ~= Enum.Material.Air then
					footEvent:FireServer("Left")
				end
			end)

			-- Jumping Sound for Feet
			conFeet3 = charaHum.StateChanged:Connect(function(old, new)
				if old == Enum.HumanoidStateType.Freefall then
					footEvent:FireServer("Jump", true)
				end
			end)

			task.wait(3)
			runDebounce = false
		end

		last = ct
	end
end)

local function runend()
	WalkingTween:Play()

	Running = false
	runEvent:FireServer(false)
	runTrack:Stop()

	-- Disconnecting the Footsteps
	if conFeet1 then
		conFeet1:Disconnect()
		conFeet2:Disconnect()
		conFeet3:Disconnect()
	end

	task.wait()
	runDebounce = false
end


userinputserv.InputEnded:Connect(function(input, gpe)
	if gpe then return end
	if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.W then
		runend()
	end
end)


charaHum:GetPropertyChangedSignal("MoveDirection"):Connect(function()
	if charaHum.MoveDirection.Magnitude == 0 then
		runTrack:Stop()
		runAnimIsPlaying = false
	elseif Running and not runAnimIsPlaying then
		runTrack:Play()
		runAnimIsPlaying = true
	end
end)


--M1s

local checks1 = {
	Hit = true,
	Stun = true,
	Block = true,
	TrueStun = true,
}

local checkLength1 = 0
chara.Effects.ChildAdded:connect(function(v) -- setting up a check table, essentially making sure nothing is preventing the hit without this being so messy.
	if checks1[v.Name] then
		checkLength1 += 1
		
		local con
		con = v.Destroying:connect(function()
			checkLength1 -= 1
			con:Disconnect()
		end)
	end
end)
-- weaponInfo

local weaponInfo = {
	["Fist"] = {
		Track = m1fistTrack,
		aniSpeed = 1.6,
		Range = 4,
		m1Recover = 0.6,
		Length = 2,
		comboReset = 2
	},
	["Royal Dagger"] = {
		Track = m1rDaggerTrack,
		aniSpeed = 0.25,
		Range = 5,
		m1Recover = 0.6,
		Length = 3,
		comboReset = 2,
		Idle = m1rDaggerIdleTrack
	}
}


local hitBoxTest = require(game.ReplicatedFirst.ShapecastHitbox.Hitbox)

local intFold     = chara:WaitForChild("IntFold")
local effects     = chara:WaitForChild("Effects")
local runningFlag = intFold:WaitForChild("Running?")

-- variable on weapon set up
local mainWeapon = (intFold.Weapon.Value ~= "" and intFold.Weapon.Value) or "Fist"
chara:WaitForChild("IntFold").Weapon.Changed:connect(function(v) -- updating weapon
	mainWeapon = v
	
	-- idle
	local idleTrack = weaponInfo[mainWeapon].Idle
	if idleTrack then
		idleTrack:Play()
		idleTrack:AdjustSpeed(0.1)
	end
end)

-- RayCast Set Up
local rcPar = RaycastParams.new()
rcPar.FilterType = Enum.RaycastFilterType.Exclude
rcPar.FilterDescendantsInstances = {chara, workspace.Regions}

local olPar = OverlapParams.new()
olPar.FilterType = Enum.RaycastFilterType.Exclude
olPar.FilterDescendantsInstances = {chara, workspace.Regions}

-- needed variables
m1db = false
resetTimer = false
cancelCheck = false
m1Count = 1

local dashHitChance = Instance.new("BoolValue")
dashHitChance.Value = false

local liveConns = {} -- connection table
local function killConns()
	for _, c in liveConns do c:Disconnect() end
	table.clear(liveConns)
end

local function hitFunc(count, range) -- hit function
	local locked, missLocked = false, false
	local points = 2
	
	local objPoint = nil
	
	if mainWeapon == "Fist" then
		objPoint = (count % 2 == 1) and chara["Left Arm"] or chara["Right Arm"]
		for i =1, points do
			local attach = Instance.new("Attachment")
			attach.Name = "DmgPoint"
			
			local inc = (i == 1) and 2 or 4
			attach.Position = Vector3.new(0, -objPoint.Size.Y/inc + -objPoint.Size.Y/2, 0)
			attach.Parent = objPoint 
			db:AddItem(attach, 0.15)
		end
	elseif mainWeapon == "Royal Dagger" then
		objPoint = chara:FindFirstChild("Royal Dagger").Handle
		local attach = Instance.new("Attachment")
		attach.Name = "DmgPoint"
		attach.Position = Vector3.new(0, objPoint.Size.Y, 0)
		attach.Parent = objPoint 
		db:AddItem(attach, 0.15)
	end
	
	local hitPoint = hitBoxTest(objPoint, rcPar)
	hitPoint:HitStart(0.1):OnUpdate(function()
		if hitPoint.RaycastResult and not locked then
			locked = true
			hitPoint:HitStop():Destroy()
			hitEvent:FireServer(nil, hitPoint.RaycastResult.Instance)
		elseif not hitPoint.RaycastResult and not locked and not missLocked then
			local possibleHits = workspace:GetPartBoundsInBox(objPoint.CFrame, objPoint.Size, olPar)
			for _, v in possibleHits do
				if v.Name == "HitBox" then
					locked = true
					hitEvent:FireServer(nil, v)
				end
			end
			if not locked then missLocked = true end
		end
	end)
end

userinputserv.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if Running == true then runend() end -- cancel run

		m1db = true -- db
		resetTimer = os.clock()
		local lastCheck = resetTimer

		local cancelChance = true -- internal variables
		dashHitChance.Value = true

		local connectTable = {} -- setting up connections table
		local mainWeaponInfo = weaponInfo[mainWeapon]
		
		if m1Count==1 then mainWeaponInfo["Track"]:Play() end -- initial start
		mainWeaponInfo["Track"]:AdjustSpeed(mainWeaponInfo["aniSpeed"]) -- otherwise just resume
		
		local function reset(cd, wep) -- reset function
			m1Count = 1 -- reset count
			mainWeaponInfo["Track"]:Stop() -- stop Animation
			killConns() -- clean all Connections
			dashHitChance.Value = false -- reset dash openning
			task.delay(cd, function()
				cancelCheck = false -- db
			end)
		end

		table.insert(liveConns, userinputserv.InputBegan:Connect(function(i, g)
			if not g and i.UserInputType == Enum.UserInputType.MouseButton2 and cancelChance then
				hitEvent:FireServer("Highlight")
				cancelCheck = true
				reset(0.6)
			end
		end))

		table.insert(liveConns, runningFlag.Changed:Connect(function(v)
			if v == true then
				if cancelChance then hitEvent:FireServer("Highlight") end
				cancelCheck = true
				reset(cancelChance and 0.6 or 1, mainWeapon)
			end
		end))

		table.insert(liveConns, charaHum.StateChanged:Connect(function(_, new)
			if new == Enum.HumanoidStateType.Jumping then
				if cancelChance then hitEvent:FireServer("Highlight") end
				cancelCheck = true
				reset(cancelChance and 2 or 3, mainWeapon)
			end
		end))

		table.insert(liveConns, effects.ChildAdded:Connect(function(v)
			if v.Name == "Hit" or v.Name == "Block" then
				cancelCheck = true
				reset(0.6, mainWeapon)
			end
		end))

		table.insert(liveConns, intFold.MovementSpeed.ChildAdded:Connect(function(v)
			if v.Name == "Dash" then
				reset(0, mainWeapon)
			end
		end))

		table.insert(liveConns, mainWeaponInfo["Track"]:GetMarkerReachedSignal("Hit"..tostring(m1Count)):Connect(function() -- processing swing
			cancelChance = false
			hitFunc(m1Count, mainWeaponInfo["Range"])
		end))
		
		table.insert(liveConns, mainWeaponInfo["Track"]:GetMarkerReachedSignal("ReelBack"..tostring(m1Count)):Connect(function()
			print(m1Count)
			
			m1Count += 1
			if m1Count > mainWeaponInfo["Length"]then
				mainWeaponInfo["Track"].Stopped:Connect(function()
					reset(0, mainWeapon)
				end)
			end
			
			mainWeaponInfo["Track"]:AdjustSpeed(0) -- freeze on the hit frame until next click
		end))

		task.delay(mainWeaponInfo["comboReset"], function()
			if lastCheck == resetTimer then 
				reset(0)
			end
		end)

		task.delay(mainWeaponInfo["m1Recover"], function()
			m1db = false
		end)
	end
end)

--Blocking
local blockDebounce = false
local blockCD = 0.75
local blockLock = false
local Parry = false

--[[local checks = {
	Hit = true,
	TrueStun = true,
}
local checkLength = 0
chara.Effects.ChildAdded:connect(function(v) -- setting up a check table, essentially making sure nothing is preventing the block without this being so messy.
	if checks[v.Name] then
		checkLength += 1
		
		local con
		con = v.Destroying:connect(function()
			checkLength -= 1
			con:Disconnect()
		end)
	end
end)]]


userinputserv.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.F and not blockDebounce and not effects:FindFirstChild("Hit") and not effects:FindFirstChild("TrueStun") then
		if Running == true then runend() end -- canceling running
		blockDebounce = true
		blockTrack:Play()

		-- Reset Block Function
		local con
		local conKeyPress
		local conAnimStagger
		local conRunning
		local conBehind

		local function reset(v)
			blockTrack:Stop()

			con:Disconnect()
			conKeyPress:Disconnect()
			conAnimStagger:Disconnect()
			conRunning:Disconnect()
			conBehind:Disconnect()

			blockEvent:FireServer(false)
			if Parry == true then
				blockDebounce = false
				Parry = false
			else
				task.delay(blockCD, function()
					blockDebounce = false
				end)
			end
		end

		conKeyPress = userinputserv.InputEnded:Connect(function(input, gpe) -- keypress end
			if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.F then
				reset()
				conKeyPress:Disconnect()
			end
		end)

		conRunning = chara.IntFold:WaitForChild("Running?").Changed:Connect(function(v) -- running
			reset()
			conRunning:Disconnect()
		end)

		conBehind = chara.Effects.ChildRemoved:Connect(function(v) -- someone hit from behind
			if v.Name == "Block" then
				reset()
				conBehind:Disconnect()
			end
		end)

		con = blockTrack:GetMarkerReachedSignal("GuardUp"):Connect(function() -- firing
			blockEvent:FireServer(true)
			con:Disconnect()
		end)

		-- Animation

		conAnimStagger = chara.Effects.ChildAdded:Connect(function(v)
			if v.Name == "Hit" and chara.Effects:FindFirstChild("Block") then
				BlockStagger1Track:Play()
				--TODO: Another stagger animation.
			elseif v.Name == "Hit" and not chara.Effects:FindFirstChild("Block") then
				conAnimStagger:Disconnect()
			elseif v.Name == "BlockBroken" then
				reset()

				BlockBreakTrack:Play()
				conAnimStagger:Disconnect()
			end
		end)
	end
end)

-- Dashing
local dashDebounce = false
local dashCD = 2.75
local dashKey = {Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D, Enum.KeyCode.W}

local jarringZoomOut = Tween:Create(cam, TweenInfo.new(0.2), { FieldOfView = DefaultFieldOFView + 10 })
local jarringZoomIn = Tween:Create(cam, TweenInfo.new(0.2), { FieldOfView = DefaultFieldOFView})


--[[local checks2 = {
	Block = true,
	TrueStun = true,
	Hit = true,
}
local checkLength2 = 0
chara.Effects.ChildAdded:connect(function(v) -- setting up a check table, essentially making sure nothing is preventing the block without this being so messy.
	if checks2[v.Name] then
		checkLength2 += 1
		
		local con
		con = v.Destroying:connect(function()
			checkLength2 -= 1
			con:Disconnect()
		end)
	end
end)]]


userinputserv.InputBegan:Connect(function(input, gpe)
	if gpe then return end 
	if input.KeyCode == Enum.KeyCode.Q then
		local touchStone = nil
		local input = ""
		local anim

		for i=1,4,1 do
			if userinputserv:IsKeyDown(dashKey[i]) and charaHum.FloorMaterial ~= Enum.Material.Air then -- seeing what keys they are holding down
				local key = string.gsub(tostring(dashKey[i]), "Enum.KeyCode.", "") -- creating that input
				input = input..key

				local con
				con = userinputserv.InputEnded:Connect(function(input, gpe) -- cancelling dash if they let go of key.
					if input.KeyCode == dashKey[i] then
						dashEvent:FireServer("Release")
						if anim ~= nil then anim:Stop() end
						con:Disconnect()
					end
				end)

				task.delay(0.2, function() con:Disconnect() end) -- getting rid of connection if they don't release.
			end
		end

		anim = dashTracks[input.."DashTrack"] -- match up a dash track with the input
		if anim and not dashDebounce and not effects:FindFirstChild("Block") and not effects:FindFirstChild("TrueStun") and not effects:FindFirstChild("Hit") and weaponInfo[mainWeapon]["Track"].Speed == 0 then -- if we find one, then play said animation and also fire the event, and if dash can happen
			dashDebounce = true

			jarringZoomOut:Play() -- quickzoom and out
			jarringZoomOut.Completed:Connect(function() jarringZoomIn:Play() end)

			anim:Play()
			dashEvent:FireServer("Dash")

			local dashHitCon
			dashHitCon = dashHitChance.Changed:Connect(function(v)
				if v == true then
					dashEvent:FireServer("RunningHit")
					dashHitCon:Disconnect()
				end
			end)

			task.delay(dashCD, function()
				dashDebounce = false
			end)
		end
	end
end)

-- Menu Operation

local MenuActive = false

userinputserv.InputBegan:Connect(function(input, gpe)
	if gpe then return end 
	if input.KeyCode == Enum.KeyCode.M then
		if not MenuActive then -- add Menu
			MenuActive = true

			local men = game.ReplicatedFirst.GUI.UIGUI.MenuGUI:Clone()
			men.Parent = player.PlayerGui

			local selectSound2 = game.ReplicatedFirst.SFX.UISounds.SelectSound2:Clone()
			selectSound2.Parent = player.Character:WaitForChild("Torso")
			selectSound2:Play()
			selectSound2.Ended:Connect(function() selectSound2:Destroy() end)

		else -- rid Menu
			MenuActive = false 

			if player.PlayerGui:FindFirstChild("MenuGUI") then
				player.PlayerGui.MenuGUI:Destroy()
			end
		end
	end
end)

----------------------------------------------------------------------------------------------------------


-- ragdoll event
local ragdollEvent = game.ReplicatedStorage.Remotes.RagdollEvent

ragdollEvent.OnClientEvent:Connect(function(v)
	if v then
		chara.Humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false) -- slumping
		chara.Humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	else
		charaHum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
		charaHum:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
end)

-- hit event
local hitEvent = game.ReplicatedStorage.Remotes.Hit

hitEvent.OnClientEvent:Connect(function(v)
	local aniRandom = math.random(1,3)

	local h
	if not chara.Effects:FindFirstChild("Block") and not chara.Effects:FindFirstChild("BorgBlock") and not chara.Effects:FindFirstChild("Parry") then
		local n = h	
		repeat
			h = math.random(1,3)
		until n ~= h

		if h == 1 then
			HitStag1Track:Play()
			HitStag1Track:AdjustSpeed(0.8)
		elseif h == 2 then
			HitStag2Track:Play()
			HitStag2Track:AdjustSpeed(0.8)
		else
			HitStag3Track:Play()
			HitStag3Track:AdjustSpeed(0.8)
		end
	end
end)

-- parried event
local parryEvent = game.ReplicatedStorage.Remotes.CombatRemotes.Parry
local jarringZoomOut = Tween:Create(cam, TweenInfo.new(0.125), { FieldOfView = DefaultFieldOFView - 10 })
local jarringZoomIn = Tween:Create(cam, TweenInfo.new(0.125), { FieldOfView = DefaultFieldOFView})

parryEvent.OnClientEvent:Connect(function()
	jarringZoomOut:Play() -- quickzoom and out
	jarringZoomOut.Completed:Connect(function() jarringZoomIn:Play() end)

	local i1 = game.ReplicatedFirst.GUI.Inversion1:Clone() -- inverting their screen
	local i2 = game.ReplicatedFirst.GUI.Inversion2:Clone()
	i1.Parent = game.Lighting
	i2.Parent = game.Lighting
	db:AddItem(i1,0.25)
	db:AddItem(i2,0.25)

	Parry = true -- signaling parry
end)

-- truestun
chara.Effects.ChildAdded:Connect(function(v)
	if v.Name == "TrueStun" then
		charaHum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)

		v.Destroying:Connect(function()
			charaHum:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		end)
	end
end)

-- LocalScript, variables are NOT defined.
--[[chara.ChildAdded:Connect(function(child)
	if child:IsA("Tool") and child:FindFirstChild("BodyAttach") then
		chara.Torso.ToolGrip.Part1 = child.BodyAttach
	end
end)]]





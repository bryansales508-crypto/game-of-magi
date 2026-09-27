local module = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local db = game:GetService("Debris")

-- bindables
local getDamage = game.ReplicatedStorage.Remotes.GetDamage

-- services

local spdHandle = require(game.ReplicatedStorage.Modules.SpeedHandler)

module.damage = function(chara, hitChara, packet)
	-- Variables
	local player = game.Players:GetPlayerFromCharacter(chara)
	if player == nil then player = chara end -- npc checker
	
	local targPlayer = game.Players:GetPlayerFromCharacter(hitChara)

	local charEffects = chara:WaitForChild("Effects")
	local targEffects = hitChara:WaitForChild("Effects")

	local charaHum = chara:WaitForChild("Humanoid")
	local targHum = hitChara:WaitForChild("Humanoid")
	
	-- Packet Variables
	local damagePckt = packet.Damage
	local hitTypePckt = packet.Hit
	local knockBackPckt = packet.Knockback
	local slowPckt = packet.Slow
	local slowDurPckt = packet.SlowDur
	local stunPckt = packet.Stun
	
	if stunPckt then
		local Stun = Instance.new("StringValue")
		Stun.Name = "Stun"
		
		if not targEffects:FindFirstChild("Block") then
		Stun.Parent = targEffects
		end
		
		task.delay(stunPckt, function()
			Stun:Destroy()
		end)
	end
	
	if slowPckt then
		spdHandle.SpeedHandle(hitChara, slowPckt, slowDurPckt)
	end
	
	if knockBackPckt then
		local enemyRoot = hitChara:WaitForChild("HumanoidRootPart")
		local charRoot = chara:WaitForChild("HumanoidRootPart")

		local enemyX = enemyRoot.Position.X
		local enemyZ = enemyRoot.Position.Z

		local charX = charRoot.Position.X
		local charZ = charRoot.Position.Z

		local force = Instance.new("BodyVelocity")
		force.Name = "BodyMover"

		force.MaxForce = Vector3.new(1, 1, 1) * math.huge

		local dir = (Vector3.new(enemyX, 0, enemyZ) - Vector3.new(charX, 0, charZ)).Unit
		
		hitChara.IntFold.HitTracker.Value += 1 -- 5th hit knockback
		if hitChara.IntFold.HitTracker.Value >= 5 then
			hitChara.IntFold.HitTracker.Value = 0
			knockBackPckt *= 10
		end
		
		force.Velocity = (dir).Unit * (knockBackPckt * 4)
		
		force.Parent = enemyRoot
		game.Debris:AddItem(force, .25)
	end
	
	if hitTypePckt then
		local hit = Instance.new("StringValue")
		hit.Name = "Hit"
		hit.Value = "Fist"
		hit.Parent = targEffects
		
		task.delay(0.5, function()
			hit:Destroy()
		end)
	end
	
	if damagePckt ~= nil and not targEffects:FindFirstChild("Knocked") then -- checking before knock
		local targHealthCheck = targHum.Health - damagePckt
		
		if targHealthCheck <= 0 then
			targHum.Health = 1 -- dropping health
			
			local knocked = Instance.new("IntValue")
			knocked.Name = "Knocked"
			knocked.Value = math.random(3,5)
			knocked.Parent = targEffects
			
			local personKnocker = Instance.new("StringValue")
			personKnocker.Name = player.Name
			personKnocker.Parent = knocked
		else -- not enough to knock
			if not targEffects:FindFirstChild("Block") then -- not blocking
				targHum.Health = targHum.Health - damagePckt
			else -- blocking
				
				local targHRT = hitChara.HumanoidRootPart -- quickly check to see if behind the target
				local charaHRT = chara.HumanoidRootPart
				
				local dto = (targHRT.Position - charaHRT.Position).Unit
				local dot = targHRT.CFrame.LookVector:Dot(dto)
				
				if dot < 0 then
					getDamage:Fire(hitChara, damagePckt, targEffects.Block.Value, chara)
				else
					targEffects:FindFirstChild("Block"):Destroy()
					targHum.Health = targHum.Health - damagePckt
				end
			end
		end
	end
end


return module
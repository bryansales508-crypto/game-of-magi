--Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local db = game:GetService("Debris")
local rs = game:GetService("RunService")

local ragdollMod = require(ReplicatedStorage.Modules.Ragdoll)
local speedMod = require(ReplicatedStorage.Modules.SpeedHandler)
local DamageService = require(game.ServerScriptService.Services.DamageHandler)
local dashMod = require(ReplicatedStorage.Modules.DashHandler)

--Variables
local GUIFolder = game.ReplicatedFirst.GUI
local GUITable = {}
for _,v in GUIFolder:GetChildren() do
	local vGUI = GUIFolder:FindFirstChild(v.Name)
	if vGUI then
		GUITable[v.Name] = v
	end

	if vGUI:IsA("Folder") then
		for _,p in vGUI:GetChildren() do
			local pGUI = vGUI:FindFirstChild(p.Name)
			if pGUI then
				GUITable[p.Name] = p
			end
		end
	end
end

-- Remotes
local RemoteFold = game.ReplicatedStorage.Remotes

local ragdollEvent = RemoteFold.RagdollEvent
local hitEvent = RemoteFold.Hit

--Effects List

-- MutedStep: Handled in InteractionHandler
-- Reading: Handled in MissionHandler
-- MissionVal: Handled in MissionHandler
-- BigFreeze: Handled in InputHandler
-- ActionFreeze: Handled in InputHandler
-- Stun: Handled in DamageService --TODO: Maybe something to indicate? IDK yet.
-- Block: Handled in InteractionHandler/InteractionDesign


local function knockedFunc(chara, NPC, remove)
	if not remove then
		local ragdoll = Instance.new("IntValue") -- creating a rag doll instance
		ragdoll.Name = "Ragdoll"
		ragdoll.Parent = chara.Effects

		if not NPC then 
			local SleepyTime = GUITable["Blind"]:Clone() -- blinding player
			SleepyTime.Parent = game.Players:GetPlayerFromCharacter(chara).PlayerGui

			local frzInt = Instance.new("StringValue") -- creating a freeze input instance
			frzInt.Name = "BigFreezeInput"
			frzInt.Parent = chara.Effects
		end
	else 
		chara.Effects:FindFirstChild("Ragdoll"):Destroy() -- removing rag doll

		if not NPC then
			if game.Players:GetPlayerFromCharacter(chara).PlayerGui:FindFirstChild("Blind") then
				game.Players:GetPlayerFromCharacter(chara).PlayerGui:FindFirstChild("Blind"):Destroy() -- removing blind
			end
			if chara.Effects:FindFirstChild("BigFreezeInput") then
				chara.Effects:FindFirstChild("BigFreezeInput"):Destroy() -- removing freeze input
			end
		end
	end
end

local function ragdollFunc(chara, NPC, remove)
	if not remove then
		ragdollMod.RagdollCharacter(chara) -- ragdolling

		if not NPC then
			ragdollEvent:FireClient(game.Players:GetPlayerFromCharacter(chara), true) -- slumping
		else
			chara.Humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false) -- slumping
			chara.Humanoid:ChangeState(Enum.HumanoidStateType.Physics)
		end
	else
		ragdollMod.UnRagdollCharacter(chara) -- unragdolling

		if not NPC then
			ragdollEvent:FireClient(game.Players:GetPlayerFromCharacter(chara), false) -- unslumping
		else
			chara.Humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
			chara.Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
	end
end

local function hitFunc(chara, NPC, remove)
	if not remove then
		local sTable = {}
		if not chara.Effects:FindFirstChild("Block") then -- not blocking
			for _,v in chara.Torso:GetChildren() do
				if v:IsA("Sound") and v.Name:find("LightHitSound") then
					table.insert(sTable, v)
				end
			end

			local s = sTable[math.random(1,4)]
			s:Play() -- sound play
			chara.Torso.HitParticle:Emit(1) -- particle hit

			if not NPC then
				hitEvent:FireClient(game.Players:GetPlayerFromCharacter(chara))
			end
		else -- blocking
			for _,v in chara.Torso:GetChildren() do
				if v:IsA("Sound") and v.Name:find("BlockSound") then
					table.insert(sTable, v)
				end
			end

			local s = sTable[math.random(1,2)]
			s:Play() -- sound play
			
			chara.Torso.BlockParticle.Color = ColorSequence.new(Color3.fromRGB(14,0,217), Color3.fromRGB(0,170,255)) -- normal block color
			if chara.Effects.Block.Value == 1 then chara.Torso.BlockParticle.Color = ColorSequence.new(Color3.fromRGB(127, 106, 29), Color3.fromRGB(255, 228, 146)) end -- parry block golden
			chara.Torso.BlockParticle:Emit(1) -- particle block
		end
	end
end

local function truestunFunc(chara, NPC, remove)
	if not remove then
		speedMod.SpeedHandle(chara, 0, "TrueStun") -- remove speed
	else
		speedMod.SpeedHandleRemove(chara, "TrueStun") -- speed update
	end
end

local function blockbrokenFunc(chara, NPC, remove)
	if not remove then
		local truestunInt = Instance.new("StringValue") -- creating a truestun input
		truestunInt.Name = "TrueStun"
		truestunInt.Parent = chara.Effects

		chara.Torso:FindFirstChild("BlockBroken"):Play() -- sound
		chara.Torso:FindFirstChild("BlockBreakParticle"):Emit(15) -- particle
		chara.Head.HairAttachment.Confusion:Emit(5)
	else
		if chara.Effects:FindFirstChild("TrueStun") then
			chara.Effects:FindFirstChild("TrueStun"):Destroy() -- removing truestun
		end
	end
end
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Setting up 


game.Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		-- Waiting on Appearence
		while character:WaitForChild("AppearenceLoaded").Value == false do task.wait() end

		--Creating Effects Folder
		local effectsFolder = Instance.new("Folder")
		effectsFolder.Name = "Effects"
		effectsFolder.Parent = character

		local hum = character:WaitForChild("Humanoid")
		local IntFold = character:WaitForChild("IntFold")

		local RegIn = character:WaitForChild("RegionInfo")
		effectsFolder.ChildAdded:Connect(function(child) -- effect added
			if child.Name == "Knocked" then -- Knocked
				knockedFunc(character, false, false)
			elseif child.Name == "Ragdoll" then -- Ragdoll
				ragdollFunc(character, false, false)
			elseif child.Name == "Hit" then -- Hit
				hitFunc(character, false, false)
			elseif child.Name == "BlockBroken" then -- BlockBroken
				blockbrokenFunc(character, false, false)
			elseif child.Name == "TrueStun" then -- TrueStun
				truestunFunc(character, false, false)
			end
		end)

		effectsFolder.ChildRemoved:Connect(function(child) -- effect removed
			if child.Name == "Knocked" then -- Knocked
				knockedFunc(character, false, true)
			elseif child.Name == "Ragdoll" then -- Ragdoll
				ragdollFunc(character, false, true)
			elseif child.Name == "BlockBroken" then -- BlockBroken
				blockbrokenFunc(character, false, true)
			elseif child.Name == "TrueStun" then -- TrueStun
				truestunFunc(character, false, true)
			end
		end)
	end)
end)   

-- NPCEffects

local function npcEffects(NPC)
	local effectsFolder = NPC:WaitForChild("Effects")

	effectsFolder.ChildAdded:Connect(function(child)
		if child.Name == "Knocked" then -- Knocked
			knockedFunc(NPC, true, false)
		elseif child.Name == "Ragdoll" then -- Ragdoll
			ragdollFunc(NPC, true, false)
		elseif child.Name == "Hit" then -- Hit
			hitFunc(NPC, true, false)
		end
	end)

	effectsFolder.ChildRemoved:Connect(function(child) -- effect removed
		if child.Name == "Knocked" then -- Knocked
			knockedFunc(NPC, true, true)
		elseif child.Name == "Ragdoll" then -- Ragdoll
			ragdollFunc(NPC, true, true)
		end
	end)
end

-- Making sure we ascertain all NPCs
for _,NPC in game.Workspace.NPC:GetChildren() do
	npcEffects(NPC)
end

game.Workspace.NPC.ChildAdded:Connect(function(NPC)
	npcEffects(NPC)
end)
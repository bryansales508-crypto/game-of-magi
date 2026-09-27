--Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ragdollMod = require(ReplicatedStorage.Modules.Ragdoll)

-- Remotes
local RemoteFold = game.ReplicatedStorage.Remotes
local ragdollEvent = RemoteFold.RagdollEvent

-- REVIEW-M3-03 L7: trimmed to only what the client EffectsController
-- (already built, M3-06) does NOT do. That's just two things now: creating
-- character.Effects (still the only thing that does, for a player - M3-01's
-- StatusService only ever waits for it), and the actual server-side
-- ragdoll physics on Knocked (client visuals can't move a Humanoid's
-- physics state; the ragdollEvent fire below is only for syncing the
-- client's own "slumping" animation/camera reaction to it). Un-ragdolling
-- on Recovered isn't separate code: StatusService.Remove(character,
-- "Knocked") destroys this bridge's "Knocked" marker, whose ChildRemoved
-- destroys "Ragdoll" below it, whose own ChildRemoved calls
-- ragdollFunc(..., true) - the same chain, run backwards.
--
-- Removed: hitFunc (hit sound/particle), blockbrokenFunc (block-break
-- sound/particle - the "TrueStun" marker it also used to create was
-- already removed in M3-03), truestunFunc (CombatService.onStatusChanged
-- already zeroes the "TrueStun" MovementService modifier directly), and
-- the Blind GUI / BigFreezeInput the old knockedFunc put up for a
-- player - all of that is the client EffectsController's job now.

local function knockedFunc(chara, NPC, remove)
	if not remove then
		local ragdoll = Instance.new("IntValue") -- creating a rag doll instance
		ragdoll.Name = "Ragdoll"
		ragdoll.Parent = chara.Effects
	else
		local existing = chara.Effects:FindFirstChild("Ragdoll")
		if existing then
			existing:Destroy() -- removing rag doll
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

		effectsFolder.ChildAdded:Connect(function(child) -- effect added
			if child.Name == "Knocked" then -- Knocked
				knockedFunc(character, false, false)
			elseif child.Name == "Ragdoll" then -- Ragdoll
				ragdollFunc(character, false, false)
			end
		end)

		effectsFolder.ChildRemoved:Connect(function(child) -- effect removed
			if child.Name == "Knocked" then -- Knocked
				knockedFunc(character, false, true)
			elseif child.Name == "Ragdoll" then -- Ragdoll
				ragdollFunc(character, false, true)
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

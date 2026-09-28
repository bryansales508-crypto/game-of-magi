--!strict
-- Lives per character (M3B-05, Bryan 2026-09-28). A character ("a life",
-- e.g. "Jamil") gets Config.Life.LivesPerCharacter (4) lives. Every REAL
-- death - Humanoid.Died from any cause: falling, the void, drowning, later
-- executions - costs one and the SAME character just respawns, no scene. A
-- combat knockout never touches this (StatusService.Apply "Knocked" never
-- sets Humanoid.Health to 0, so it never fires Died). The death that takes
-- the LAST life goes through the same afterlife scene a fatal heart attack
-- does (AgeService.StartDeathSequence, cause = "lastLife") and wipes to a
-- brand-new character with a fresh 4 lives. A fatal heart attack (old age)
-- is unrelated to LivesLeft entirely - it always wipes, cause = "heartAttack",
-- unchanged from before this milestone.
--
-- Players.RespawnTime is bumped well past Config.Aging.SceneTimeout at
-- Init: with the default CharacterAutoLoads/RespawnTime (5s), Roblox's own
-- automatic respawn would otherwise race AgeService.StartDeathSequence's
-- own (up to 30s) scene-then-LoadCharacter on a real Humanoid.Died and fire
-- a SECOND, unwanted respawn moments after the real one - a heart attack
-- never hit this because it's a scripted freeze, not a real Health-reaches-
-- 0 death, so Humanoid.Died never fires for it and there was never a timer
-- to race. The LivesLeft > 0 path still "just respawns, no scene" - this
-- service calls player:LoadCharacter() itself rather than waiting out that
-- now-much-longer timer.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local SaveSchema = require(ReplicatedStorage.Shared.SaveSchema)
local DataService = require(script.Parent.DataService)
local AgeService = require(script.Parent.AgeService)
local LegacyBridge = require(script.Parent.LegacyBridge)
local DevService = require(script.Parent.DevService)

local log = Log.new("LifeService")

type Data = SaveSchema.Data

local LifeService = {}

local function refreshLivesLeftAttribute(player: Player, data: Data)
	player:SetAttribute("LivesLeft", data.Character.LivesLeft)
end

-- Decrements LivesLeft and returns which path this death takes - pure on
-- `data` alone, so self-tests can exercise the exact branch logic without a
-- live DataService-backed profile (Player.Character/:LoadCharacter() aren't
-- fakeable the way a bare attribute read/write is). The actual respawn/
-- scene side effects are onDied's own job below.
function LifeService.HandleDeath(data: Data): "respawn" | "lastLife"
	data.Character.LivesLeft -= 1
	if data.Character.LivesLeft > 0 then
		return "respawn"
	end
	return "lastLife"
end

-- Runs on the player's own current character's Humanoid.Died. Never for an
-- NPC (LifeService only ever hooks a Player's own character).
local function onDied(player: Player)
	if player:GetAttribute("Dying") == true then
		-- The heart-attack sequence (AgeService) already owns this death -
		-- it freezes the humanoid rather than ever zeroing its health, so in
		-- practice this only guards against a stray/duplicate Died fire
		-- during the scene, not a real double-death.
		return
	end

	local data = DataService.Get(player)
	if data == nil then
		return
	end

	local outcome = LifeService.HandleDeath(data)
	refreshLivesLeftAttribute(player, data)
	log:Info(string.format("%s died (%s, %d life/lives left)", player.Name, outcome, data.Character.LivesLeft))
	LegacyBridge.Refresh(player, data)
	DataService.Save(player)

	if outcome == "respawn" then
		-- "Simply respawns as the same character with no scene" - the join
		-- pipeline (PlayerService's CharacterAdded/CharacterRemoving) does
		-- everything else exactly like any other respawn.
		player:LoadCharacter()
		return
	end

	task.spawn(function()
		AgeService.StartDeathSequence(player, data, "lastLife")
	end)
end

local function hookCharacter(player: Player, character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end
	humanoid.Died:Connect(function()
		onDied(player)
	end)
end

local function registerDevCommands()
	DevService.Register("lives", "<n> [player] - set Character.LivesLeft", function(caller: Player, args: { string })
		local n = tonumber(args[1])
		if n == nil then
			return "usage: .lives <n> [player]"
		end
		local target, err = DevService.ResolvePlayer(caller, args[2])
		if target == nil then
			return err or "player not found"
		end
		local data = DataService.Get(target)
		if data == nil then
			return string.format("%s: no save loaded", target.Name)
		end
		data.Character.LivesLeft = math.floor(n)
		refreshLivesLeftAttribute(target, data)
		LegacyBridge.Refresh(target, data)
		return string.format("%s's LivesLeft: %d", target.Name, data.Character.LivesLeft)
	end)

	DevService.Register("kill", "[player] - kills the humanoid outright (test lives without falling)", function(caller: Player, args: { string })
		local target, err = DevService.ResolvePlayer(caller, args[1])
		if target == nil then
			return err or "player not found"
		end
		local character = target.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid == nil then
			return string.format("%s has no character to kill", target.Name)
		end
		humanoid.Health = 0
		return string.format("Killed %s", target.Name)
	end)
end

function LifeService:Init()
	-- See the header comment: this only matters for the LivesLeft == 0
	-- path's own scene; the LivesLeft > 0 path already respawns itself
	-- explicitly (onDied above) rather than depending on this timer at all.
	Players.RespawnTime = Config.Aging.SceneTimeout + 5

	registerDevCommands()
end

function LifeService:Start()
	local function watchPlayer(player: Player)
		player.CharacterAdded:Connect(function(character: Model)
			hookCharacter(player, character)
		end)
		if player.Character then
			hookCharacter(player, player.Character)
		end
	end

	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end

	DataService.Loaded:Connect(function(player: Player)
		local data = DataService.Get(player)
		if data then
			refreshLivesLeftAttribute(player, data)
		end
	end)
	for _, player in Players:GetPlayers() do
		if DataService.IsLoaded(player) then
			local data = DataService.Get(player)
			if data then
				refreshLivesLeftAttribute(player, data)
			end
		end
	end
end

return LifeService

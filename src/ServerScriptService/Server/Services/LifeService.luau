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
-- REVIEW-M3B-05 M1: the "still has lives" respawn waits Config.Life.
-- RespawnDelay (3s) instead of firing the same frame - an instant pop-back
-- left no death moment at all - via a guarded task.delay rather than
-- touching Players.RespawnTime (left at the engine default; a global
-- change there had its own side effects on paths this service doesn't
-- otherwise touch, e.g. a death this service skips outright). The guard
-- (player.Character == the character that just died) only protects against
-- OUR OWN delayed call firing after something else already respawned the
-- player by the time it runs - it can't reach into Roblox's own separate
-- CharacterAutoLoads/RespawnTime(5s) timer, which is still live and still a
-- possible second respawn; the playtester needs to confirm in Studio that
-- one doesn't show up 5s after a `.kill` with lives left.

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

-- REVIEW-M3B-05 M1: guarded so this specific delayed call is a no-op if the
-- player already has a DIFFERENT character (already respawned some other
-- way) by the time it fires - `character` is the one that just died, not
-- whatever player.Character happens to be when this runs.
local function respawnAfterDelay(player: Player, character: Model)
	task.delay(Config.Life.RespawnDelay, function()
		if player.Parent == Players and player.Character == character then
			player:LoadCharacter()
		end
	end)
end

-- Runs on the player's own current character's Humanoid.Died. Never for an
-- NPC (LifeService only ever hooks a Player's own character).
local function onDied(player: Player, character: Model)
	if player:GetAttribute("Dying") == true then
		-- The heart-attack sequence (AgeService) already owns this death -
		-- it freezes the humanoid rather than ever zeroing its health, so in
		-- practice this only guards against a stray/duplicate Died fire
		-- during the scene, not a real double-death.
		return
	end

	local data = DataService.Get(player)
	if data == nil then
		-- No save to charge a life against (not loaded yet, or the profile
		-- was already released) - still owe the player SOME respawn, the
		-- same delayed/guarded way as an ordinary "lives left" death.
		respawnAfterDelay(player, character)
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
		-- everything else exactly like any other respawn, just not on the
		-- very same frame (REVIEW-M3B-05 M1 - a real death moment, not an
		-- instant pop-back).
		respawnAfterDelay(player, character)
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
	-- REVIEW-M3B-05 L1: :Once, not :Connect - a stray second Died fire on
	-- the same (already-dead) character can never charge a second life.
	humanoid.Died:Once(function()
		onDied(player, character)
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
		-- REVIEW-M3B-05 L2: clamped, not raw - a negative or absurdly large
		-- value would otherwise reach the exact same field HandleDeath does
		-- unconditional arithmetic on.
		data.Character.LivesLeft = math.clamp(math.floor(n), 0, 99)
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

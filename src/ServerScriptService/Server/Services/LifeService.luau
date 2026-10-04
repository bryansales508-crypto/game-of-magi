--!strict
-- Lives per character. A character gets Config.Life.LivesPerCharacter lives. Every real death
-- (Humanoid.Died from any cause: falling, void, drowning, ...) costs one and the same character
-- respawns with no scene. A combat knockout never fires Died, so never touches this. The death
-- that takes the LAST life goes through the afterlife scene (AgeService.StartDeathSequence,
-- cause = "lastLife") and wipes to a brand-new character with fresh lives. A fatal heart attack
-- always wipes (cause = "heartAttack") regardless of LivesLeft.
-- The "still has lives" respawn waits Config.Life.RespawnDelay via a guarded task.delay (guard:
-- player.Character is still the character that died). Init pushes Players.RespawnTime far out
-- (Config.Life.EngineRespawnSeconds) so the engine never respawns anyone: every death is
-- respawned by this service or by AgeService.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local SaveSchema = require(ReplicatedStorage.Shared.SaveSchema)
local DataService = require(script.Parent.DataService)
local AgeService = require(script.Parent.AgeService)
local DevService = require(script.Parent.DevService)

local log = Log.new("LifeService")

type Data = SaveSchema.Data

local LifeService = {}

local function refreshLivesLeftAttribute(player: Player, data: Data)
	player:SetAttribute("LivesLeft", data.Character.LivesLeft)
end

-- Decrements LivesLeft and returns which path this death takes. Pure on `data`, so self-tests
-- can exercise the branch logic; side effects are onDied's job.
function LifeService.HandleDeath(data: Data): "respawn" | "lastLife"
	data.Character.LivesLeft -= 1
	if data.Character.LivesLeft > 0 then
		return "respawn"
	end
	return "lastLife"
end

-- Guarded: a no-op if the player already has a different character by the time it fires.
local function respawnAfterDelay(player: Player, character: Model)
	task.delay(Config.Life.RespawnDelay, function()
		if player.Parent == Players and player.Character == character then
			player:LoadCharacter()
		end
	end)
end

-- Runs on the player's current character's Humanoid.Died. Never for an NPC.
local function onDied(player: Player, character: Model)
	if player:GetAttribute("Dying") == true then
		-- The heart-attack sequence owns this death (it freezes the humanoid rather than
		-- zeroing health), so this only guards a stray duplicate Died fire.
		return
	end

	local data = DataService.Get(player)
	if data == nil then
		-- No save to charge (not loaded, or profile released): still respawn, the same
		-- delayed/guarded way.
		respawnAfterDelay(player, character)
		return
	end

	local outcome = LifeService.HandleDeath(data)
	refreshLivesLeftAttribute(player, data)
	-- A killer that wants the death named in the log (gripping) sets this on the character first.
	local cause = character:GetAttribute("DeathCause")
	log:Info(string.format("%s died (%s, %d life/lives left)%s", player.Name, outcome, data.Character.LivesLeft, if type(cause) == "string" then ", " .. cause else ""))
	DataService.Save(player)

	if outcome == "respawn" then
		-- Same character, no scene; the join pipeline does the rest, just not on the same
		-- frame.
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
	-- :Once, so a stray second Died fire can't charge a second life.
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
		-- Clamped: a negative or huge value would otherwise reach unconditional arithmetic in
		-- HandleDeath.
		data.Character.LivesLeft = math.clamp(math.floor(n), 0, 99)
		refreshLivesLeftAttribute(target, data)
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
	-- The engine's 5 s auto-respawn is pushed far out so it can't cut the last-life scene
	-- short; every death path respawns on its own schedule.
	Players.RespawnTime = Config.Life.EngineRespawnSeconds
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

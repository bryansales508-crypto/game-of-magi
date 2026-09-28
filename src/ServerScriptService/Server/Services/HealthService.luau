--!strict
-- Max health and health/block regen (TRIAGE #14, DESIGN.md section 3a "Rank
-- raises max health"). Rank/Epithet/Alignment are M4-01's RankService's
-- attributes now, not this service's - see RankService.luau.
-- Replaces the old StarterCharacterScripts/Health.server.luau and
-- BlockHealthRegen.server.luau. The old "revive from Knocked" countdown
-- those scripts also did (decrementing character.Effects.Knocked.Value
-- once a second) is gone (REVIEW-M3-03 L6): M3-03's CombatService/
-- StatusService are the sole authority on when a knockout ends now, so a
-- second, independent timer here was a real conflict, not just a
-- documented overlap - no health clamping loop besides regen.
--
-- Health/Block/MaxBlock/RegenTier aren't part of the save (SaveSchema has
-- no Health section): Humanoid.Health/MaxHealth is the one source of
-- truth for health, and Block is fresh runtime state per spawn, same as
-- the old IntFold.BlockInt was. Player attributes are the cheap
-- replication path the client (M2-04's HudController) reads.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local SaveSchema = require(ReplicatedStorage.Shared.SaveSchema)
local Ranks = require(ReplicatedStorage.Shared.Data.Ranks)
local DataService = require(script.Parent.DataService)
local PlayerService = require(script.Parent.PlayerService)
local DevService = require(script.Parent.DevService)
-- M3-FIX4-S: the bleed tick below reads StatusService's own Bleed status
-- (stacks/config) - safe to require (StatusService only ever requires
-- PlayerService, no cycle back here).
local StatusService = require(script.Parent.StatusService)

local log = Log.new("HealthService")

type Data = SaveSchema.Data
export type Tier = "Idle" | "Combat" | "Knocked"

-- REVIEW-M3-04 H1: NPCs take the identical health path as players now -
-- every function below accepts either. A Player is resolved to its own
-- `.Character` (unchanged); a Model (an NPC) is its own character
-- already. Attributes are set directly on whichever was passed in - a
-- Player's own attributes for a player (what the HUD reads), the NPC's
-- own character attributes for an NPC (the same place every other M3
-- service, keyed by character Model, already puts its attributes).
export type Combatant = Player | Model

local APPEARENCE_WAIT_TIMEOUT = 30

local HealthService = {}

local function isPlayerCombatant(combatant: Combatant): boolean
	return typeof(combatant) == "Instance" and combatant:IsA("Player")
end

local function resolveCharacter(combatant: Combatant): Model?
	if isPlayerCombatant(combatant) then
		return (combatant :: Player).Character
	end
	return combatant :: Model
end

-- ==================== pure helpers (self-tested directly) ====================

-- `rankIndex` is Ranks.rankFor's first return (1 = Street Rat .. 7 =
-- King/Queen). FIX M11: the old Height.Changed handler called the wrong
-- branch and never actually added height's bonus; this just always
-- recomputes from scratch, so there's no branch to get wrong.
function HealthService.MaxHealthFor(height: number, rankIndex: number): number
	local rankBonus = Config.Health.RankBonus[rankIndex] or 0
	return Config.Health.Base + Config.Health.HeightBonus * height + rankBonus
end

-- FIX L8: a flat per-second rate, independent of how often the regen loop
-- actually ticks (the old scripts' rate scaled with their own wait time,
-- so the Regen "tiers" never changed anything).
function HealthService.RegenAmount(tier: Tier, seconds: number): number
	return Config.Health.RegenPerSecond[tier] * seconds
end

-- ==================== per-combatant state ====================
-- None of this is saved (SaveSchema has no Health section): Block is
-- fresh every spawn, same as the old IntFold.BlockInt was. Keyed by
-- whatever HealthService.Register (NPCs) or PlayerService.Ready (players)
-- put in - a Player or a character Model, never mixed for the same
-- combatant.

local active: { [Combatant]: boolean } = {}
local tierState: { [Combatant]: Tier } = {}
local blockingState: { [Combatant]: boolean } = {}
local blockAmount: { [Combatant]: number } = {}

local function initCharacterState(combatant: Combatant)
	tierState[combatant] = "Idle"
	blockingState[combatant] = false
	blockAmount[combatant] = Config.Health.MaxBlock
end

local function clearState(combatant: Combatant)
	active[combatant] = nil
	tierState[combatant] = nil
	blockingState[combatant] = nil
	blockAmount[combatant] = nil
end

-- ==================== public API (M3 combat calls these) ====================

function HealthService.TakeDamage(combatant: Combatant, amount: number, _source: string?)
	local character = resolveCharacter(combatant)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or amount <= 0 then
		return
	end
	humanoid.Health = math.max(0, humanoid.Health - amount)
	combatant:SetAttribute("Health", humanoid.Health)
end

function HealthService.SetTier(combatant: Combatant, tier: Tier)
	tierState[combatant] = tier
	combatant:SetAttribute("RegenTier", tier)
end

function HealthService.SpendBlock(combatant: Combatant, amount: number): boolean
	local current = blockAmount[combatant] or 0
	if amount <= 0 or current < amount then
		return false
	end
	blockAmount[combatant] = current - amount
	combatant:SetAttribute("Block", blockAmount[combatant])
	return true
end

function HealthService.IsBlocking(combatant: Combatant): boolean
	return blockingState[combatant] == true
end

function HealthService.SetBlocking(combatant: Combatant, blocking: boolean)
	blockingState[combatant] = blocking
end

-- ==================== NPC registration (REVIEW-M3-04 H1) ====================
-- The Player path (PlayerService.Ready, below) still does its own rank-
-- based setupCharacter; this is the parallel entry point NpcService uses -
-- max health is just given directly (Config.Npc.MaxHealth[type], no rank
-- ladder), not computed here.

export type RegisterOptions = { maxHealth: number }

function HealthService.Register(character: Model, opts: RegisterOptions?)
	if active[character] then
		return
	end
	active[character] = true
	initCharacterState(character)

	local maxHealth = (opts and opts.maxHealth) or Config.Health.Base
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.MaxHealth = maxHealth
		humanoid.Health = maxHealth
	end

	pcall(function()
		character:SetAttribute("MaxHealth", maxHealth)
		character:SetAttribute("Health", if humanoid then humanoid.Health else maxHealth)
		character:SetAttribute("MaxBlock", Config.Health.MaxBlock)
		character:SetAttribute("Block", Config.Health.MaxBlock)
		character:SetAttribute("RegenTier", "Idle")
	end)
end

function HealthService.Unregister(character: Model)
	clearState(character)
end

-- ==================== build / rebuild ====================

-- Sets Humanoid.MaxHealth from the current save (height + rank), keeping
-- current health if the character was already full (so a mid-life
-- MaxHealth change from a rank-up doesn't waste the player's health, but
-- a fresh spawn still starts full).
local function setupCharacter(player: Player, character: Model, data: Data)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end

	local rankIndex = (Ranks.rankFor(data.Progress.Magoi))
	local maxHealth = HealthService.MaxHealthFor(data.Character.Height, rankIndex)
	local wasFull = humanoid.Health >= humanoid.MaxHealth
	humanoid.MaxHealth = maxHealth
	if wasFull then
		humanoid.Health = maxHealth
	end

	player:SetAttribute("MaxHealth", maxHealth)
	player:SetAttribute("Health", humanoid.Health)
	player:SetAttribute("MaxBlock", Config.Health.MaxBlock)
	player:SetAttribute("Block", blockAmount[player] or Config.Health.MaxBlock)
	player:SetAttribute("RegenTier", tierState[player] or "Idle")
end

-- ==================== dev commands ====================
-- Registered via DevService.Register (not a direct require of HealthService
-- from DevService), same reasoning as AgeService's .birthday/.heart: Roblox
-- errors on a cyclic ModuleScript require.

local function registerDevCommands()
	DevService.Register("hp", "<n> [player] - set current health", function(caller: Player, args: { string })
		local n = tonumber(args[1])
		if n == nil then
			return "usage: .hp <n> [player]"
		end
		local playerArg = args[2]
		local target, err = DevService.ResolvePlayer(caller, playerArg)
		if target == nil then
			return err or "player not found"
		end
		local character = target.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid == nil then
			return string.format("%s has no character", target.Name)
		end
		local old = humanoid.Health
		humanoid.Health = math.clamp(n, 0, humanoid.MaxHealth)
		target:SetAttribute("Health", humanoid.Health)
		return string.format("%s's health: %.0f -> %.0f", target.Name, old, humanoid.Health)
	end)

	DevService.Register("tier", "<Idle|Combat|Knocked> [player] - set the regen tier", function(caller: Player, args: { string })
		local tierArg = args[1]
		if tierArg ~= "Idle" and tierArg ~= "Combat" and tierArg ~= "Knocked" then
			return "usage: .tier <Idle|Combat|Knocked> [player]"
		end
		local target, err = DevService.ResolvePlayer(caller, args[2])
		if target == nil then
			return err or "player not found"
		end
		HealthService.SetTier(target, tierArg :: Tier)
		return string.format("%s's regen tier: %s", target.Name, tierArg)
	end)
end

-- ==================== service ====================

function HealthService:Init()
	registerDevCommands()

	-- BUG-15: `.age`/`.age+` used to leave MaxHealth stale until the next
	-- birthday; recompute it (rank can move too, so not just height)
	-- right away instead.
	DevService.OnAgeChanged(function(player: Player, data: Data)
		local character = player.Character
		if character then
			setupCharacter(player, character, data)
		end
	end)
end

function HealthService:Start()
	PlayerService.Ready:Connect(function(player: Player, character: Model)
		initCharacterState(player)
		active[player] = true

		local data = DataService.Get(player)
		if data then
			setupCharacter(player, character, data)
		else
			log:Error(string.format("%s is Ready but has no loaded save; can't set max health", player.Name))
		end

		task.spawn(function()
			local appearenceLoaded = character:WaitForChild("AppearenceLoaded", APPEARENCE_WAIT_TIMEOUT)
			if appearenceLoaded == nil or not appearenceLoaded:IsA("BoolValue") then
				return
			end
			if not appearenceLoaded.Value then
				appearenceLoaded.Changed:Wait()
			end
			if player.Parent ~= Players or player.Character ~= character then
				return
			end
			local freshData = DataService.Get(player)
			if freshData then
				setupCharacter(player, character, freshData)
			end
		end)
	end)

	Players.PlayerRemoving:Connect(clearState)

	-- One shared loop: health/block regen (M4-01 moved the Rank/Epithet/
	-- Alignment attribute refresh out to RankService, which updates them
	-- itself on every Progress change instead of every tick).
	task.spawn(function()
		while true do
			task.wait(Config.Health.Tick)
			for combatant in active do
				local character: Model?

				if isPlayerCombatant(combatant) then
					local player = combatant :: Player
					if player.Parent ~= Players then
						clearState(combatant)
						continue
					end

					character = player.Character
					local data = DataService.Get(player)

					-- REVIEW-M2-03 finding 1: recomputed every tick, not only
					-- at Ready/AppearenceLoaded. AgeService.resizeCharacter
					-- changes Character.Height in place on a birthday, with
					-- no respawn to re-fire PlayerService.Ready, so without
					-- this MaxHealth stayed stuck at spawn's height until
					-- the player's next death/rejoin - the exact M11 bug
					-- this service exists to fix, just moved. setupCharacter
					-- already applies the "top up only if already full"
					-- rule; calling it here reuses that instead of a second
					-- copy of it, and keeps AgeService and HealthService
					-- decoupled (no new call from AgeService into
					-- HealthService needed).
					-- M4-01: Rank/Epithet/Alignment are RankService's attributes
					-- now (one writer) - it refreshes them itself on every
					-- Progress change instead of this loop refreshing them
					-- every tick.
					if character and data then
						setupCharacter(player, character, data)
					end
				else
					-- An NPC (REVIEW-M3-04 H1): no rank/save, just health/
					-- block regen below, same as a player gets.
					local model = combatant :: Model
					if model.Parent == nil then
						clearState(combatant)
						continue
					end
					character = model
				end

				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if humanoid then
					local regen = HealthService.RegenAmount(tierState[combatant] or "Idle", Config.Health.Tick)
					if regen > 0 and humanoid.Health > 0 and humanoid.Health < humanoid.MaxHealth then
						humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + regen)
					end

					-- M3-FIX4-S: Bleed ticks once a second, `stacks` x the
					-- causing style's own damagePerStackPerSecond - and never
					-- knocks out on its own (floors at 1 HP, not 0, so
					-- Humanoid.Died never fires from bleed alone; CombatService/
					-- StatusService stay the only knockout authority).
					local bleedInfo = character and StatusService.Get(character :: Model, "Bleed")
					if bleedInfo and type(bleedInfo.data) == "table" and humanoid.Health > 1 then
						local data = bleedInfo.data :: any
						local bleedConfig = data.config
						local stacks = data.stacks
						if type(bleedConfig) == "table" and type(stacks) == "number" and stacks > 0 then
							local bleedDamage = (bleedConfig.damagePerStackPerSecond :: number) * stacks * Config.Health.Tick
							humanoid.Health = math.max(1, humanoid.Health - bleedDamage)
						end
					end

					combatant:SetAttribute("Health", humanoid.Health)
				end

				if not blockingState[combatant] then
					local current = blockAmount[combatant] or Config.Health.MaxBlock
					local refilled = math.min(Config.Health.MaxBlock, current + Config.Health.BlockRegenPerSecond * Config.Health.Tick)
					blockAmount[combatant] = refilled
					combatant:SetAttribute("Block", refilled)
				end
			end
		end
	end)
end

return HealthService

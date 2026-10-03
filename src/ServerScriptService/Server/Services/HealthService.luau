--!strict
-- Max health and health/block regen. Rank raises max health; Rank/Epithet/Alignment attributes
-- belong to RankService.
-- Humanoid.Health/MaxHealth is the one source of truth for health; Block/MaxBlock/RegenTier are
-- per-spawn runtime state (not saved). Player attributes are the replication path the HUD
-- reads. Knockout end is owned by CombatService/StatusService, not here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local SaveSchema = require(ReplicatedStorage.Shared.SaveSchema)
local Ranks = require(ReplicatedStorage.Shared.Data.Ranks)
local DataService = require(script.Parent.DataService)
local PlayerService = require(script.Parent.PlayerService)
local DevService = require(script.Parent.DevService)
-- Bleed ticks read StatusService's Bleed status (no require cycle).
local StatusService = require(script.Parent.StatusService)

local log = Log.new("HealthService")

type Data = SaveSchema.Data
export type Tier = "Idle" | "Combat" | "Knocked"

-- NPCs take the same health path as players: every function accepts a Player (resolved to its
-- Character) or a character Model. Attributes go on whichever was passed in.
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

-- `rankIndex` is Ranks.rankFor's first return (1 = Street Rat .. 7 = King/Queen). Always
-- recomputes from scratch.
function HealthService.MaxHealthFor(height: number, rankIndex: number): number
	local rankBonus = Config.Health.RankBonus[rankIndex] or 0
	return Config.Health.Base + Config.Health.HeightBonus * height + rankBonus
end

-- A flat per-second rate, independent of the regen loop's tick rate.
function HealthService.RegenAmount(tier: Tier, seconds: number): number
	return Config.Health.RegenPerSecond[tier] * seconds
end

-- ==================== per-combatant state ====================
-- Not saved. Keyed by whatever Register (NPCs) or PlayerService.Ready (players) put in: a
-- Player or a character Model, never mixed for one combatant.

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

-- ==================== public API ====================

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

-- ==================== NPC registration ====================
-- Parallel entry point for NpcService: max health comes straight from
-- Config.Npc.MaxHealth[type], no rank ladder.

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
-- Registered via DevService.Register, not a direct require, since Roblox errors on cyclic
-- requires.

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

	-- Recompute MaxHealth immediately on .age/.age+ (rank can move too, not just height).
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

	-- One shared loop for health/block regen.
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

					-- Recomputed every tick: AgeService changes Character.Height in place on a
					-- birthday with no respawn, so setupCharacter (which tops up only if
					-- already full) is re-run here.
					if character and data then
						setupCharacter(player, character, data)
					end
				else
					-- An NPC: health/block regen only.
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

					-- Bleed ticks once a second: stacks x the style's damagePerStackPerSecond.
					-- Floors at 1 HP so Humanoid.Died never fires from bleed;
					-- CombatService/StatusService own knockouts.
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

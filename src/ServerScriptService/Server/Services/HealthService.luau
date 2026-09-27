--!strict
-- Max health, health/block regen and the Rank/Epithet/Alignment display
-- attributes (TRIAGE #14, DESIGN.md section 3a "Rank raises max health").
-- Replaces the old StarterCharacterScripts/Health.server.luau and
-- BlockHealthRegen.server.luau; keeps the "revive from Knocked" countdown
-- those scripts also did (DamageHandler still creates the Knocked marker
-- and damages the Humanoid directly - that's M3's rebuild, not this one -
-- so this service must not fight it: no health clamping loop besides regen).
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
local Alignment = require(ReplicatedStorage.Shared.Data.Alignment)
local DataService = require(script.Parent.DataService)
local PlayerService = require(script.Parent.PlayerService)
local DevService = require(script.Parent.DevService)

local log = Log.new("HealthService")

type Data = SaveSchema.Data
export type Tier = "Idle" | "Combat" | "Knocked"

local KNOCKED_NAME = "Knocked"
local APPEARENCE_WAIT_TIMEOUT = 30
local EFFECTS_WAIT_TIMEOUT = 10

local HealthService = {}

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

-- ==================== per-player state ====================
-- None of this is saved (SaveSchema has no Health section): Block is
-- fresh every spawn, same as the old IntFold.BlockInt was.

local active: { [Player]: boolean } = {}
local tierState: { [Player]: Tier } = {}
local blockingState: { [Player]: boolean } = {}
local blockAmount: { [Player]: number } = {}

local function initCharacterState(player: Player)
	tierState[player] = "Idle"
	blockingState[player] = false
	blockAmount[player] = Config.Health.MaxBlock
end

local function clearState(player: Player)
	active[player] = nil
	tierState[player] = nil
	blockingState[player] = nil
	blockAmount[player] = nil
end

-- ==================== public API (M3 combat calls these) ====================

function HealthService.TakeDamage(player: Player, amount: number, _source: string?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or amount <= 0 then
		return
	end
	humanoid.Health = math.max(0, humanoid.Health - amount)
	player:SetAttribute("Health", humanoid.Health)
end

function HealthService.SetTier(player: Player, tier: Tier)
	tierState[player] = tier
	player:SetAttribute("RegenTier", tier)
end

function HealthService.SpendBlock(player: Player, amount: number): boolean
	local current = blockAmount[player] or 0
	if amount <= 0 or current < amount then
		return false
	end
	blockAmount[player] = current - amount
	player:SetAttribute("Block", blockAmount[player])
	return true
end

function HealthService.IsBlocking(player: Player): boolean
	return blockingState[player] == true
end

function HealthService.SetBlocking(player: Player, blocking: boolean)
	blockingState[player] = blocking
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

-- Ported from the old Health.server.luau: while Knocked and above the
-- revive threshold, count the marker down once a second; destroy it at 0
-- (how a knocked-out player gets back up). DamageHandler still creates
-- this marker and sets Health to 1 when it does.
local function reviveLoop(character: Model, knockedValue: IntValue)
	task.spawn(function()
		while knockedValue.Parent do
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.MaxHealth > 0 and humanoid.Health > humanoid.MaxHealth * Config.Health.KnockedReviveThreshold then
				knockedValue.Value -= 1
				if knockedValue.Value <= 0 then
					knockedValue:Destroy()
				end
			end
			task.wait(1)
		end
	end)
end

local function watchKnocked(character: Model)
	local effects = character:WaitForChild("Effects", EFFECTS_WAIT_TIMEOUT)
	if effects == nil then
		return
	end

	for _, child in effects:GetChildren() do
		if child.Name == KNOCKED_NAME and child:IsA("IntValue") then
			reviveLoop(character, child)
		end
	end
	effects.ChildAdded:Connect(function(child: Instance)
		if child.Name == KNOCKED_NAME and child:IsA("IntValue") then
			reviveLoop(character, child)
		end
	end)
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
		watchKnocked(character)

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

	-- One shared loop: health/block regen, and the Rank/Epithet/Alignment
	-- display attributes (M2-06's Shared/Data modules), refreshed from
	-- Progress every tick rather than hooked to a change signal - simplest
	-- correct option, per the M2-03 task's own suggestion.
	task.spawn(function()
		while true do
			task.wait(Config.Health.Tick)
			for player in active do
				if player.Parent ~= Players then
					clearState(player)
					continue
				end

				local character = player.Character
				local data = DataService.Get(player)

				-- REVIEW-M2-03 finding 1: recomputed every tick, not only at
				-- Ready/AppearenceLoaded. AgeService.resizeCharacter changes
				-- Character.Height in place on a birthday, with no respawn
				-- to re-fire PlayerService.Ready, so without this MaxHealth
				-- stayed stuck at spawn's height until the player's next
				-- death/rejoin - the exact M11 bug this service exists to
				-- fix, just moved. setupCharacter already applies the "top
				-- up only if already full" rule; calling it here reuses
				-- that instead of a second copy of it, and keeps AgeService
				-- and HealthService decoupled (no new call from AgeService
				-- into HealthService needed).
				if character and data then
					setupCharacter(player, character, data)
				end

				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if humanoid then
					local regen = HealthService.RegenAmount(tierState[player] or "Idle", Config.Health.Tick)
					if regen > 0 and humanoid.Health > 0 and humanoid.Health < humanoid.MaxHealth then
						humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + regen)
					end
					player:SetAttribute("Health", humanoid.Health)
				end

				if not blockingState[player] then
					local current = blockAmount[player] or Config.Health.MaxBlock
					local refilled = math.min(Config.Health.MaxBlock, current + Config.Health.BlockRegenPerSecond * Config.Health.Tick)
					blockAmount[player] = refilled
					player:SetAttribute("Block", refilled)
				end

				if data then
					player:SetAttribute("Rank", Ranks.titleFor(data.Progress.Magoi, data.Character.Gender))
					player:SetAttribute("Epithet", data.Progress.Epithet)
					player:SetAttribute("Alignment", Alignment.label(Alignment.alignmentFor(data.Progress.GoldRukh, data.Progress.BlackRukh)))
				end
			end
		end
	end)
end

return HealthService

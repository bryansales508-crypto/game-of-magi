--!strict
-- The wallet (M5A-01, M5-PLAN.md Phase 5A, Bryan's rules 2026-09-29):
-- Copper/Silver/Gold on the save, exact-coin payment (no automatic
-- change-making - that's the Bank milestone), CanAfford/Pay/Give, and the
-- Currency (Copper/Silver/Gold) player attributes the purse HUD reads.
--
-- Paying is EXACT COIN ONLY: Pay(player, "Silver", 1, ...) only ever
-- spends Silver, even if the player is holding enough Copper+Gold to
-- cover the same price converted - 120 Copper can't pay a 1-Silver price.
-- On failure it fires CoinMessage with one of the old MarketHandler
-- flavour lines (ForcedChat, generalized to any coin): "I need more
-- money" when the player's total wealth (converted to Copper) doesn't
-- reach the price at all, or "I need to convert" when it does, just not
-- in that one coin - exchanging coins is the Bank's job, a later
-- milestone; nothing here converts.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local SaveSchema = require(ReplicatedStorage.Shared.SaveSchema)
local Economy = require(ReplicatedStorage.Shared.Data.Economy)
local DataService = require(script.Parent.DataService)
local DevService = require(script.Parent.DevService)

local log = Log.new("EconomyService")

type Data = SaveSchema.Data
export type Coin = Economy.Coin
export type Wallet = { Copper: number, Silver: number, Gold: number }
export type PayFailure = "no" | "convert"

local EconomyService = {}

-- ==================== flavour lines (old MarketHandler, generalized) ====================
-- The old MarketHandler/ForcedChat pools (SYSTEMS.md section 6), kept for
-- the feel; Convert only ever had a Copper version there (its only coin
-- was Copper-priced goods), so these are the same lines generalized to
-- name whichever coin the price actually needed.

local NEED_MONEY_LINES = {
	"I need more money...",
	"Oh wait, I'm broke!",
	"I don't have that much...",
	"No IOU's?",
}

local CONVERT_LINES = {
	"This place only takes %s, huh...",
	"I need to convert my money...",
	"Forgot, I don't have %s on me...",
	"I'd need the Bank to turn this into %s...",
}

local function pick(pool: { string }): string
	return pool[math.random(1, #pool)]
end

local function flavourLine(failure: PayFailure, coin: Coin): string
	if failure == "no" then
		return pick(NEED_MONEY_LINES)
	end
	local line = pick(CONVERT_LINES)
	if line:find("%%s") then
		return string.format(line, coin)
	end
	return line
end

-- ==================== pure core (self-tested directly) ====================
-- Every field access below is an explicit branch, not data.Economy[coin]:
-- SaveSchema.Data.Economy is a fixed-field record (Copper/Silver/Gold), not
-- an indexable one, so a dynamic string key doesn't type-check under
-- --!strict the way it does against Economy.Value (which IS declared
-- {[Coin]: number}) - see getCoin/setCoin below.

local function getCoin(data: Data, coin: Coin): number
	if coin == "Copper" then
		return data.Economy.Copper
	elseif coin == "Silver" then
		return data.Economy.Silver
	end
	return data.Economy.Gold
end

local function setCoin(data: Data, coin: Coin, value: number)
	if coin == "Copper" then
		data.Economy.Copper = value
	elseif coin == "Silver" then
		data.Economy.Silver = value
	else
		data.Economy.Gold = value
	end
end

-- Pure: whether the wallet already holds at least `amount` of `coin` -
-- exact coin only, never converted from the other two.
function EconomyService.Affords(data: Data, coin: Coin, amount: number): boolean
	return getCoin(data, coin) >= amount
end

-- Pure: the dev `.coins` set form - every coin at once, clamped at 0 and
-- floored to an integer. The wallet is never negative or fractional.
function EconomyService.ApplySet(data: Data, copper: number, silver: number, gold: number)
	data.Economy.Copper = math.max(0, math.floor(copper))
	data.Economy.Silver = math.max(0, math.floor(silver))
	data.Economy.Gold = math.max(0, math.floor(gold))
end

-- Pure: adds `amount` of one coin, clamped at 0 - a negative Give (e.g. a
-- dev `.coins+` with a negative number) can empty a coin but never push it
-- below 0.
function EconomyService.ApplyGive(data: Data, coin: Coin, amount: number)
	setCoin(data, coin, math.max(0, math.floor(getCoin(data, coin) + amount)))
end

-- Pure: exact-coin payment against `coin` only - never looks at the other
-- two to make change. On failure, tells the caller which flavour line
-- fits: "no" (total wealth across all three coins, converted to Copper,
-- doesn't reach the price either) or "convert" (it does, just not in this
-- coin).
--
-- REVIEW-M5A-01 L1: a bad `amount` (less than 1, or not a whole number -
-- an exploit sending Pay(player, "Copper", 0.5, ...) or a negative amount
-- from a bad caller) is rejected as "no" before anything else runs, and
-- never touches the wallet - a price is always at least 1 whole coin, so
-- there's no real purchase a bad amount could ever legitimately be.
function EconomyService.ApplyPay(data: Data, coin: Coin, amount: number): (boolean, PayFailure?)
	if amount < 1 or amount ~= math.floor(amount) then
		return false, "no"
	end

	if getCoin(data, coin) >= amount then
		setCoin(data, coin, getCoin(data, coin) - amount)
		return true, nil
	end

	local totalCopper = data.Economy.Copper * Economy.Copper + data.Economy.Silver * Economy.Silver + data.Economy.Gold * Economy.Gold
	local priceCopper = amount * Economy.Value[coin]

	if totalCopper < priceCopper then
		return false, "no"
	end
	return false, "convert"
end

-- ==================== attributes ====================

-- Also re-run by DataService.Replaced (see Start) and self-tested directly.
local function refreshAttributes(player: Player, data: Data)
	player:SetAttribute("Copper", data.Economy.Copper)
	player:SetAttribute("Silver", data.Economy.Silver)
	player:SetAttribute("Gold", data.Economy.Gold)
end

function EconomyService.RefreshAttributes(player: Player, data: Data)
	refreshAttributes(player, data)
end

-- ==================== public API ====================

function EconomyService.Get(player: Player): Wallet
	local data = DataService.Get(player)
	if data == nil then
		return { Copper = 0, Silver = 0, Gold = 0 }
	end
	return { Copper = data.Economy.Copper, Silver = data.Economy.Silver, Gold = data.Economy.Gold }
end

function EconomyService.CanAfford(player: Player, coin: Coin, amount: number): boolean
	local data = DataService.Get(player)
	if data == nil then
		return false
	end
	return EconomyService.Affords(data, coin, amount)
end

-- Exact-coin only; see the module comment. Fires CoinMessage with a
-- flavour line on failure. Returns whether the payment went through.
function EconomyService.Pay(player: Player, coin: Coin, amount: number, reason: string): boolean
	local data = DataService.Get(player)
	if data == nil then
		log:Warn(string.format("Pay(%s, %d %s, %s): no save loaded", player.Name, amount, coin, reason))
		return false
	end

	local ok, failure = EconomyService.ApplyPay(data, coin, amount)
	if not ok then
		local line = flavourLine(failure :: PayFailure, coin)
		Remotes.Server.Fire("CoinMessage", player, line)
		log:Info(string.format("%s Pay %d %s failed (%s, %s)", player.Name, amount, coin, tostring(failure), reason))
		return false
	end

	refreshAttributes(player, data)
	log:Info(string.format("%s paid %d %s (%s)", player.Name, amount, coin, reason))
	return true
end

function EconomyService.Give(player: Player, coin: Coin, amount: number, reason: string)
	local data = DataService.Get(player)
	if data == nil then
		log:Warn(string.format("Give(%s, %d %s, %s): no save loaded", player.Name, amount, coin, reason))
		return
	end

	EconomyService.ApplyGive(data, coin, amount)
	refreshAttributes(player, data)
	log:Info(string.format("%s given %d %s (%s), now %d", player.Name, amount, coin, reason, getCoin(data, coin)))
end

-- Pays out a reward/payout given as a Copper amount. Copper only for now
-- (Bryan's refinement, 2026-09-29): rewards don't round into Silver/Gold
-- until the Bank milestone makes those reachable without the dev `.coins`
-- command - Economy.roundReward is ready for that switch (call it here
-- instead of always giving Copper), unused until then.
function EconomyService.GiveCopperValue(player: Player, copper: number, reason: string)
	EconomyService.Give(player, "Copper", copper, reason)
end

-- ==================== dev commands ====================
-- `.coins`/`.coins+` are re-registered here under their existing names
-- (same DevService.Register overwrite trick RankService uses for
-- `.magoi`/`.rukh`) so they route through EconomyService instead of
-- writing data.Economy directly. `.price`/`.pay` are new.

-- Mirrors DevService's own splitTrailingPlayer (not exported): every value
-- before an optional trailing player name is a number, so a non-numeric
-- last token is unambiguously the player name.
local function splitTrailingPlayer(args: { string }): ({ string }, string?)
	if #args == 0 then
		return args, nil
	end
	local last = args[#args]
	if tonumber(last) == nil then
		local rest = table.clone(args)
		table.remove(rest, #rest)
		return rest, last
	end
	return args, nil
end

local function coinsCommand(mode: "set" | "add"): (Player, { string }) -> string
	return function(caller: Player, args: { string })
		local rest, playerArg = splitTrailingPlayer(args)
		local copper = tonumber(rest[1])
		if copper == nil then
			return string.format("usage: .coins%s <copper> [silver] [gold] [player]", if mode == "add" then "+" else "")
		end
		local silver = tonumber(rest[2]) or 0
		local gold = tonumber(rest[3]) or 0

		local target, err = DevService.ResolvePlayer(caller, playerArg)
		if target == nil then
			return err or "player not found"
		end
		local data = DataService.Get(target)
		if data == nil then
			return string.format("%s has no save loaded", target.Name)
		end

		local oldCopper, oldSilver, oldGold = data.Economy.Copper, data.Economy.Silver, data.Economy.Gold
		if mode == "add" then
			EconomyService.ApplyGive(data, "Copper", copper)
			EconomyService.ApplyGive(data, "Silver", silver)
			EconomyService.ApplyGive(data, "Gold", gold)
		else
			EconomyService.ApplySet(data, copper, silver, gold)
		end
		refreshAttributes(target, data)

		return string.format(
			"%s's coins: %d/%d/%d -> %d/%d/%d",
			target.Name,
			oldCopper,
			oldSilver,
			oldGold,
			data.Economy.Copper,
			data.Economy.Silver,
			data.Economy.Gold
		)
	end
end

local function parseCoin(text: string?): Coin?
	if text == nil then
		return nil
	end
	local lower = text:lower()
	if lower == "copper" then
		return "Copper"
	elseif lower == "silver" then
		return "Silver"
	elseif lower == "gold" then
		return "Gold"
	end
	return nil
end

local function priceCommand(_caller: Player, args: { string }): string
	local copper = tonumber(args[1])
	if copper == nil then
		return "usage: .price <copper>"
	end
	-- Explicit annotations, not decoration: luau-lsp 1.54.0 widens a
	-- required module's returned union type to plain `string` when it's
	-- read back through a module boundary without one (same reproduction as
	-- RankService.ApplyDeed's own comment).
	local coin: Coin, amount: number = Economy.toPrice(copper)
	return string.format("%d Copper -> %s", copper, Economy.format(coin, amount))
end

local function payCommand(caller: Player, args: { string }): string
	local coin: Coin? = parseCoin(args[1])
	local amount = tonumber(args[2])
	if coin == nil or amount == nil then
		return "usage: .pay <Copper|Silver|Gold> <amount>"
	end
	local ok = EconomyService.Pay(caller, coin, amount, "dev")
	return string.format("%s: Pay(%d %s) -> %s", caller.Name, amount, coin, tostring(ok))
end

local function registerDevCommands()
	DevService.Register("coins", "<copper> [silver] [gold] [player] - set coins", coinsCommand("set"))
	DevService.Register("coins+", "<copper> [silver] [gold] [player] - add coins", coinsCommand("add"))
	DevService.Register("price", "<copper> - print how a copper amount displays", priceCommand)
	DevService.Register("pay", "<Copper|Silver|Gold> <amount> - test a purchase against yourself", payCommand)
end

-- ==================== service ====================

function EconomyService:Init()
	registerDevCommands()
end

function EconomyService:Start()
	DataService.Loaded:Connect(function(player: Player)
		local data = DataService.Get(player)
		if data then
			refreshAttributes(player, data)
		end
	end)

	-- BUG-50: a Wipe (`.fresh`) / NewLife swaps the save's contents in place
	-- without a new Loaded, so the purse attributes must be re-published.
	DataService.Replaced:Connect(function(player: Player)
		local data = DataService.Get(player)
		if data then
			refreshAttributes(player, data)
		end
	end)

	-- Catches a player whose DataService.Loaded already fired before this
	-- connection was made (the same race RankService/PlayerService's own
	-- catch-up loops guard against).
	for _, player in Players:GetPlayers() do
		if DataService.IsLoaded(player) then
			local data = DataService.Get(player)
			if data then
				refreshAttributes(player, data)
			end
		end
	end
end

return EconomyService

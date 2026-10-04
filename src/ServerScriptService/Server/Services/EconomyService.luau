--!strict
-- The wallet: Copper/Silver/Gold on the save, CanAfford/Pay/Give, and the Currency player
-- attributes the purse HUD reads.
-- Paying is EXACT COIN ONLY: Pay(player, "Silver", 1, ...) only spends Silver, even if the
-- player holds enough Copper+Gold to cover it; nothing here converts coins (that is the Bank's
-- job). On failure it fires CoinMessage with a flavour line: "I need more money" when total
-- wealth (in Copper) doesn't reach the price, or "I need to convert" when it does but not in
-- that coin.

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
-- Flavour lines, generalized to name whichever coin the price needed.

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
-- Every field access is an explicit branch, not data.Economy[coin]: SaveSchema.Data.Economy is
-- a fixed-field record, so a dynamic string key doesn't type-check under --!strict (see
-- getCoin/setCoin).

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

-- Pure: whether the wallet holds at least `amount` of `coin` (exact coin, never converted).
function EconomyService.Affords(data: Data, coin: Coin, amount: number): boolean
	return getCoin(data, coin) >= amount
end

-- Pure: the dev `.coins` set form: every coin at once, clamped at 0 and floored to an integer.
function EconomyService.ApplySet(data: Data, copper: number, silver: number, gold: number)
	data.Economy.Copper = math.max(0, math.floor(copper))
	data.Economy.Silver = math.max(0, math.floor(silver))
	data.Economy.Gold = math.max(0, math.floor(gold))
end

-- Pure: adds `amount` of one coin, clamped at 0 (a negative Give can empty a coin, never go
-- below 0).
function EconomyService.ApplyGive(data: Data, coin: Coin, amount: number)
	setCoin(data, coin, math.max(0, math.floor(getCoin(data, coin) + amount)))
end

-- Pure: exact-coin payment against `coin` only, never making change. On failure says which
-- flavour line fits: "no" (total wealth in Copper doesn't reach the price) or "convert" (it
-- does, just not in this coin).
-- A bad `amount` (below 1 or not a whole number) is rejected as "no" before touching the
-- wallet.
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

-- Pays out a reward given as a Copper amount. Copper only until the Bank makes Silver/Gold
-- reachable; Economy.roundReward is ready for that switch.
function EconomyService.GiveCopperValue(player: Player, copper: number, reason: string)
	EconomyService.Give(player, "Copper", copper, reason)
end

-- ==================== dev commands ====================
-- `.coins`/`.coins+` are re-registered here (DevService.Register overwrite) so they route
-- through EconomyService. `.price`/`.pay` are new.

-- Mirrors DevService's splitTrailingPlayer: a non-numeric last token is the player name.
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
	-- Explicit annotations: luau-lsp 1.54.0 widens a required module's union type to `string`
	-- across a module boundary without one.
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

	-- A Wipe/NewLife swaps the save in place without a new Loaded, so re-publish the purse
	-- attributes.
	DataService.Replaced:Connect(function(player: Player)
		local data = DataService.Get(player)
		if data then
			refreshAttributes(player, data)
		end
	end)

	-- Catches a player whose Loaded fired before this connection.
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

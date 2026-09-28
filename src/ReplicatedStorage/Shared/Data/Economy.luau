--!strict
-- Coin ratios and the "one coin, banded" display rule (M5-PLAN.md
-- Phase 5A, Bryan's rules 2026-09-29, price rule replaced 2026-09-29).
-- Pure: no Player, no save, no remotes - EconomyService is the only thing
-- that touches a wallet.
--
-- 1 Gold = 100 Silver = 10,000 Copper. Whole numbers only, never a
-- decimal/mixed-coin price - the self-test in SelfTestService.testEconomy
-- runs the exact table below through toPrice.

export type Coin = "Copper" | "Silver" | "Gold"

local Economy = {}

-- The value of one of each coin, in Copper. Also the field names on a
-- wallet (SaveSchema.Data.Economy.Copper/Silver/Gold) and on the Currency
-- player attributes EconomyService keeps current.
Economy.Copper = 1
Economy.Silver = 100
Economy.Gold = 10000

-- Same three numbers, indexable by a Coin value (Economy[coin] would work
-- too since the field names match, but that needs an `any` cast at every
-- call site - this avoids it).
Economy.Value = {
	Copper = Economy.Copper,
	Silver = Economy.Silver,
	Gold = Economy.Gold,
} :: { [Coin]: number }

-- ceil(copper / coinValue) - 1, in integer arithmetic (no float
-- division/epsilon issues): the band index within `coinValue`'s coin once
-- `copper` has cleared it - the first Copper past a full `coinValue` (e.g.
-- 101 Copper, one past 100) is band 1, the next 100 (up to 200) is still
-- band 1, 201-300 is band 2, and so on. copper and coinValue are always
-- non-negative integers, so `//` (floor division) computes the ceiling
-- exactly via the usual (a + b - 1) // b identity.
local function bandAmount(copper: number, coinValue: number): number
	return (copper + coinValue - 1) // coinValue - 1
end

-- The coin a price/reward displays and pays in, and its amount - BANDS,
-- not rounding (Bryan, 2026-09-29, replacing the earlier round-half-up
-- rule): 1-100 Copper is that many Copper; every full 100 Copper above
-- that is one more Silver (101-200 -> 1 Silver, 201-300 -> 2 Silver, ...);
-- the same banding then applies Silver-flat-value into Gold once past
-- 10,000 Copper (10,001-20,000 -> 1 Gold). A price is always in the
-- LARGEST coin whose band applies - Gold is checked first, so 10,001+
-- Copper is never shown in Silver even though it also clears the Silver
-- threshold.
function Economy.toPrice(copper: number): (Coin, number)
	if copper > Economy.Gold then
		return "Gold", bandAmount(copper, Economy.Gold)
	elseif copper > Economy.Silver then
		return "Silver", bandAmount(copper, Economy.Silver)
	end
	return "Copper", copper
end

-- Self-test table (SelfTestService.testEconomy runs every row through
-- toPrice): copper in, the coin and amount it must display as.
Economy.PriceExamples = {
	{ copper = 40, coin = "Copper" :: Coin, amount = 40 },
	{ copper = 100, coin = "Copper" :: Coin, amount = 100 },
	{ copper = 101, coin = "Silver" :: Coin, amount = 1 },
	{ copper = 150, coin = "Silver" :: Coin, amount = 1 },
	{ copper = 200, coin = "Silver" :: Coin, amount = 1 },
	{ copper = 201, coin = "Silver" :: Coin, amount = 2 },
	{ copper = 5000, coin = "Silver" :: Coin, amount = 49 },
	{ copper = 10000, coin = "Silver" :: Coin, amount = 99 },
	{ copper = 10001, coin = "Gold" :: Coin, amount = 1 },
	{ copper = 20001, coin = "Gold" :: Coin, amount = 2 },
}

-- Same banding rule as toPrice - a reward "prices" itself the coin/amount
-- it pays out the same way a purchase prices what it costs. UNUSED for now
-- (Bryan's refinement, 2026-09-29): every reward and payout goes through
-- EconomyService.GiveCopperValue, which gives Copper only until the Bank
-- milestone makes Silver/Gold reachable without the dev `.coins` command.
-- Kept as one pure function so that switch is a one-line change in
-- GiveCopperValue (call this instead of always giving Copper) rather than a
-- new banding rule to write.
function Economy.roundReward(copper: number): (Coin, number)
	return Economy.toPrice(copper)
end

function Economy.format(coin: Coin, amount: number): string
	return string.format("%d %s", amount, coin)
end

table.freeze(Economy.Value)
for _, example in Economy.PriceExamples do
	table.freeze(example)
end
table.freeze(Economy.PriceExamples)
table.freeze(Economy)

return Economy

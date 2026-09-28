--!strict
-- Coin ratios and the "one rounded coin" display/rounding rule (M5-PLAN.md
-- Phase 5A, Bryan's rules 2026-09-29). Pure: no Player, no save, no
-- remotes - EconomyService is the only thing that touches a wallet.
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

-- Round-half-up on copper/coinValue, done in integer arithmetic (no
-- float division/epsilon issues at an exact .5 tie, e.g. 150 Copper / 100
-- Silver = 1.5 -> 2). copper and coinValue are always non-negative
-- integers, so `//` (floor division) is exact here.
local function roundHalfUp(copper: number, coinValue: number): number
	return (copper * 2 + coinValue) // (2 * coinValue)
end

-- The coin a price/reward displays and pays in: the largest coin worth
-- MORE than half a copper amount holds (copper * 2 > coinValue - a strict
-- inequality, so an EXACT half, like 5,000 Copper being exactly half a
-- Gold, does NOT promote to the bigger coin and instead displays in the
-- next one down), then that coin's own amount rounded half up. This is
-- why 5,000 Copper reads "50 Silver" but 6,000 (which clears the strict
-- half-Gold threshold) reads "1 Gold" - the two rules only look the same
-- once you're already a full coin in, per the self-test table below.
function Economy.toPrice(copper: number): (Coin, number)
	if copper * 2 > Economy.Gold then
		return "Gold", roundHalfUp(copper, Economy.Gold)
	elseif copper * 2 > Economy.Silver then
		return "Silver", roundHalfUp(copper, Economy.Silver)
	end
	return "Copper", copper
end

-- Self-test table (SelfTestService.testEconomy runs every row through
-- toPrice): copper in, the coin and amount it must display as.
Economy.PriceExamples = {
	{ copper = 40, coin = "Copper" :: Coin, amount = 40 },
	{ copper = 60, coin = "Silver" :: Coin, amount = 1 },
	{ copper = 103, coin = "Silver" :: Coin, amount = 1 },
	{ copper = 149, coin = "Silver" :: Coin, amount = 1 },
	{ copper = 150, coin = "Silver" :: Coin, amount = 2 },
	{ copper = 5000, coin = "Silver" :: Coin, amount = 50 },
	{ copper = 6000, coin = "Gold" :: Coin, amount = 1 },
	{ copper = 15000, coin = "Gold" :: Coin, amount = 2 },
}

-- Same rounding rule as toPrice - a reward "prices" itself the coin/amount
-- it pays out the same way a purchase prices what it costs. UNUSED for now
-- (Bryan's refinement, 2026-09-29): every reward and payout goes through
-- EconomyService.GiveCopperValue, which gives Copper only until the Bank
-- milestone makes Silver/Gold reachable without the dev `.coins` command.
-- Kept as one pure function so that switch is a one-line change in
-- GiveCopperValue (call this instead of always giving Copper) rather than a
-- new rounding rule to write.
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

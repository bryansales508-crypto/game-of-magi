--!strict
-- Coin ratios and the "one coin, banded" display rule. Pure: no Player, no save, no remotes; EconomyService is the only thing that touches a wallet. 1 Gold = 100 Silver = 10,000 Copper. Whole numbers only, never a decimal/mixed-coin price.

export type Coin = "Copper" | "Silver" | "Gold"

local Economy = {}

-- The value of one of each coin, in Copper. Also the field names on a wallet (SaveSchema.Data.Economy) and on the Currency player attributes EconomyService keeps current.
Economy.Copper = 1
Economy.Silver = 100
Economy.Gold = 10000

-- The same numbers indexable by a Coin value without an `any` cast.
Economy.Value = {
	Copper = Economy.Copper,
	Silver = Economy.Silver,
	Gold = Economy.Gold,
} :: { [Coin]: number }

-- ceil(copper / coinValue) - 1 in integer arithmetic: the band index within a coin once copper has cleared it (101-200 Copper is band 1, 201-300 band 2, ...). Inputs are non-negative integers, so `//` gives the exact ceiling via (a + b - 1)
-- b.
local function bandAmount(copper: number, coinValue: number): number
	return (copper + coinValue - 1) // coinValue - 1
end

-- The coin a price/reward displays and pays in, and its amount, by bands: 1-100 Copper is that many Copper; each further full 100 Copper is one more Silver (101-200 -> 1 Silver); past 10,000 Copper the same banding applies in Gold (10,001-20,000 -> 1 Gold). Gold is checked first, so the largest applicable coin is always used.
function Economy.toPrice(copper: number): (Coin, number)
	if copper > Economy.Gold then
		return "Gold", bandAmount(copper, Economy.Gold)
	elseif copper > Economy.Silver then
		return "Silver", bandAmount(copper, Economy.Silver)
	end
	return "Copper", copper
end

-- Rows for the self-test (SelfTestService.testEconomy runs each through toPrice): copper in, coin and amount out.
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

-- Same banding as toPrice, for rewards. Unused for now: every payout goes through EconomyService.GiveCopperValue, which gives Copper only until Silver/Gold are reachable without the dev `.coins` command; switching is a one-line change there.
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

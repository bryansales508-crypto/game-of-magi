--!strict
-- The Magoi rank ladder (DESIGN 3a). Data only: thresholds and titles.
-- Bryan can retune the Magoi numbers here; the ladder shape (7 ranks) is
-- fixed by the epithet banks in Epithets.luau, which are keyed by title.

export type RankEntry = {
	magoi: number,
	title: string,
}

local Ranks: { RankEntry } = {
	{ magoi = 0, title = "Street Rat" },
	{ magoi = 300, title = "Wanderer" },
	{ magoi = 600, title = "Adventurer" },
	{ magoi = 1500, title = "Renowned" },
	{ magoi = 2400, title = "Hero" },
	{ magoi = 4200, title = "Legend" },
	{ magoi = 6000, title = "King/Queen" },
}

for _, entry in Ranks do
	table.freeze(entry)
end
table.freeze(Ranks)

local RanksModule = {}

RanksModule.List = Ranks

-- The rank at or below `magoi`: index into RanksModule.List and its title.
function RanksModule.rankFor(magoi: number): (number, string)
	local index = 1
	for i, entry in Ranks do
		if magoi >= entry.magoi then
			index = i
		else
			break
		end
	end
	return index, Ranks[index].title
end

-- Same as rankFor, but renders "King/Queen" as "King" or "Queen" for a
-- known gender (1 = male, 2 = female). Gender 0 (unset) or any other rank
-- title is returned unchanged.
function RanksModule.titleFor(magoi: number, gender: number): string
	local _, title = RanksModule.rankFor(magoi)
	if title == "King/Queen" then
		if gender == 1 then
			return "King"
		elseif gender == 2 then
			return "Queen"
		end
	end
	return title
end

-- The Magoi needed to reach the next rank, or nil if already at the top.
function RanksModule.nextThreshold(magoi: number): number?
	for _, entry in Ranks do
		if entry.magoi > magoi then
			return entry.magoi
		end
	end
	return nil
end

table.freeze(RanksModule)

return RanksModule

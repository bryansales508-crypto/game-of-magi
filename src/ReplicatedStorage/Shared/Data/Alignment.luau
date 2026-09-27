--!strict
-- Rukh alignment (DESIGN 3a): a mix of two hidden tallies (Gold/Black
-- deeds), not a single scale. Data + the one pure classifier function.

export type Alignment = "White" | "Gold" | "Black" | "GoldBlack"

local Alignment = {}

-- Below this many total deeds, there isn't enough history to judge: White.
Alignment.MinDeeds = 5

-- A side needs at least this share of all deeds to "lean" that way;
-- otherwise it's close to the middle (GoldBlack).
Alignment.Lean = 0.65

function Alignment.alignmentFor(goldRukh: number, blackRukh: number): Alignment
	local total = goldRukh + blackRukh
	if total < Alignment.MinDeeds then
		return "White"
	end

	local goldShare = goldRukh / total
	local blackShare = blackRukh / total

	if goldShare >= Alignment.Lean then
		return "Gold"
	elseif blackShare >= Alignment.Lean then
		return "Black"
	end
	return "GoldBlack"
end

local LABELS: { [Alignment]: string } = {
	White = "White Rukh",
	Gold = "Gold Rukh",
	Black = "Black Rukh",
	GoldBlack = "Gold & Black Rukh",
}

function Alignment.label(alignment: Alignment): string
	return LABELS[alignment]
end

table.freeze(LABELS)
table.freeze(Alignment)

return Alignment

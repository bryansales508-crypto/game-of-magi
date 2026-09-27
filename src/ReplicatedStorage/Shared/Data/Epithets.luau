--!strict
-- Epithet banks (DESIGN 3a), keyed [rankTitle][alignment]. Bryan can add,
-- rename or cut epithets at any time; only the shape below matters.
--
-- Two title/DESIGN entries name both genders in one line ("The Exiled
-- Prince/Princess", "The Fisherman's Son/Daughter"). Those are stored as
-- a { male = ..., female = ... } pair instead of two separate bank
-- entries, so bankFor can resolve the right one for a known gender while
-- still returning the combined "X/Y" form when the gender is 0/unknown
-- (matching Ranks.titleFor's King/Queen behaviour). Every other entry is
-- a plain string.
--
-- Street Rat is the origin rank, always chosen at birth while the
-- character is still White Rukh, so DESIGN gives it one bank reused for
-- every alignment key (documented there as "same bank at birth").
--
-- DESIGN's per-rank tables only list Gold/GoldBlack/Black columns above
-- Street Rat: "White" shouldn't occur past Street Rat once missions have
-- generated deeds, but bankFor still needs an answer if it ever does, so
-- it falls back to that rank's GoldBlack bank (the neutral middle) rather
-- than erroring or returning an empty list.

local Alignment = require(script.Parent.Alignment)

type AlignmentKey = Alignment.Alignment
type GenderedEntry = { male: string, female: string }
type BankEntry = string | GenderedEntry
type Bank = { BankEntry }
type AlignmentBanks = { [AlignmentKey]: Bank }

local STREET_RAT: Bank = {
	"The Merchant's Child",
	{ male = "The Exiled Prince", female = "The Exiled Princess" },
	"The Unwanted",
	{ male = "The Fisherman's Son", female = "The Fisherman's Daughter" },
	"The Sand-Born",
	"The Orphan of Qarzin",
}

local RANKS: { [string]: AlignmentBanks } = {
	["Street Rat"] = {
		White = STREET_RAT,
		Gold = STREET_RAT,
		Black = STREET_RAT,
		GoldBlack = STREET_RAT,
	},
	Wanderer = {
		Gold = { "The Wayfarer", "The Dune Walker", "The Far-Traveled", "The Lost Star" },
		GoldBlack = { "The Grey Wanderer", "The Masked", "The Dusk Walker", "The Coin-Flip" },
		Black = { "The Road Thief", "The Dust Jackal", "The Drifting Blade", "The Vagrant" },
	},
	Adventurer = {
		Gold = { "The Bold", "The Treasure Seeker", "The Caravan's Shield", "The Sword of the Sands" },
		GoldBlack = { "The Sellsword", "The Fortune Hunter", "The Smuggler", "The Double-Edged" },
		Black = { "The Caravan Raider", "The Hired Knife", "The Vulture", "The Bandit" },
	},
	Renowned = {
		Gold = { "The Wise", "The Generous", "The Silver-Tongued", "The Pride of the South" },
		GoldBlack = { "The Enigma", "The Shadow Broker", "The Silver Serpent", "The Two-Faced" },
		Black = { "The Impaler", "The Merciless", "The Scourge of the Roads", "The Cruel" },
	},
	Hero = {
		Gold = { "The Lionheart", "The Shield of the Desert", "The Liberator", "The Unbowed" },
		GoldBlack = { "The Reluctant Hero", "The Twilight Blade", "The Dark Champion", "The Scarred" },
		Black = { "The Butcher", "The Slaver", "The Black Viper", "The Tyrant-in-Waiting" },
	},
	Legend = {
		Gold = { "The Voyager of Seven Seas", "The Undying", "The Star of the South", "The Unbroken" },
		GoldBlack = { "The Eclipse", "The Sandstorm", "The Storm of the South", "The Unreadable" },
		Black = { "The Harbinger", "The Desert's Nightmare", "The Fallen Star", "The Plague of the Sands" },
	},
	["King/Queen"] = {
		Gold = { "The Just", "The Beloved", "The Great", "The Conqueror" },
		GoldBlack = { "The King/Queen of Two Rukh", "The Iron-Handed", "The Pragmatic", "The Unyielding" },
		Black = { "The Tyrant", "The Usurper", "The Bloody", "The Terrible" },
	},
}

-- BUG-09: Street Rat's four alignment keys all alias the same STREET_RAT
-- table (its one shared bank), so this loop visits it - and its gendered
-- entries - more than once. table.freeze errors on an already-frozen
-- table, so every freeze here is guarded instead of unconditional.
for _, banks in RANKS do
	for _, bank in banks do
		for _, entry in bank do
			if type(entry) == "table" and not table.isfrozen(entry) then
				table.freeze(entry)
			end
		end
		if not table.isfrozen(bank) then
			table.freeze(bank)
		end
	end
	if not table.isfrozen(banks) then
		table.freeze(banks)
	end
end
table.freeze(RANKS)

local Epithets = {}

local function resolveEntry(entry: BankEntry, gender: number): string
	if type(entry) == "string" then
		return entry
	end
	if gender == 1 then
		return entry.male
	elseif gender == 2 then
		return entry.female
	end
	return entry.male .. "/" .. entry.female
end

-- The list of epithet strings (already resolved for `gender`) available
-- at `rankTitle` and `alignment`.
function Epithets.bankFor(rankTitle: string, alignment: AlignmentKey, gender: number): { string }
	local banks = RANKS[rankTitle]
	if not banks then
		return {}
	end

	local bank = banks[alignment]
		or banks["GoldBlack" :: AlignmentKey]
		or banks["Gold" :: AlignmentKey]
		or banks["Black" :: AlignmentKey]
		or banks["White" :: AlignmentKey]
	if not bank then
		return {}
	end

	local resolved: { string } = table.create(#bank)
	for _, entry in bank do
		table.insert(resolved, resolveEntry(entry, gender))
	end
	return resolved
end

-- 3 random, distinct epithets from that bank, for the rank-up choice
-- screen. `exclude` (already-taken epithets) is honoured when the bank
-- still has at least 3 left after removing them; otherwise it's ignored
-- so a pick is always returned.
function Epithets.pick3(rankTitle: string, alignment: AlignmentKey, gender: number, exclude: { string }?): { string }
	local bank = Epithets.bankFor(rankTitle, alignment, gender)

	local pool = bank
	if exclude and #exclude > 0 then
		local excluded: { [string]: boolean } = {}
		for _, name in exclude do
			excluded[name] = true
		end

		local filtered: { string } = {}
		for _, name in bank do
			if not excluded[name] then
				table.insert(filtered, name)
			end
		end

		if #filtered >= 3 then
			pool = filtered
		end
	end

	local remaining = table.clone(pool)
	local picks: { string } = {}
	for _ = 1, math.min(3, #remaining) do
		local i = math.random(1, #remaining)
		table.insert(picks, remaining[i])
		table.remove(remaining, i)
	end
	return picks
end

table.freeze(Epithets)

return Epithets

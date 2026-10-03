--!strict
-- Epithet banks, keyed [rankTitle][alignment]. Entries are plain strings, except the two that name both genders ("The Exiled Prince/Princess", "The Fisherman's Son/Daughter"), stored as { male, female } so bankFor resolves the right one for a known gender and returns the combined "X/Y" form when gender is 0/unknown. Street Rat is the origin rank, chosen at birth while still White Rukh, so one bank serves every alignment key. Higher ranks list only Gold/GoldBlack/Black; bankFor falls back to GoldBlack for anything else (e.g. White).

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

-- Street Rat's four alignment keys alias the same bank table, so this loop visits it more than once; table.freeze errors on an already-frozen table, hence the guards.
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

-- Epithet strings available at `rankTitle` and `alignment`, resolved for `gender`.
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

-- Three random, distinct epithets from that bank. `exclude` is honoured only when at least 3 remain after removing them.
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

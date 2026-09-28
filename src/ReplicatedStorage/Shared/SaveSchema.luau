--!strict
-- The save schema: the template ProfileStore deep-copies for every new
-- profile, and the migration chain that brings an old save up to the
-- current Config.Data.SchemaVersion. Data-only, so it's easy for Bryan to
-- read; DataService is the only thing that runs Migrate.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

local Config = require(ReplicatedStorage.Shared.Config)
local Assets = require(ReplicatedFirst.Assets)

export type Data = {
	Version: number,
	-- Same meanings as the old Stats folder (SYSTEMS.md section 1).
	Character: {
		FirstName: string,
		Gender: number, -- 0 = not chosen yet
		Race: number, -- 2 = Human (only race in this renovation; DESIGN.md section 4)
		Kingdom: number,
		SkinTone: number, -- 0 = not chosen yet
		HairColor: { R: number, G: number, B: number },
		EyeColor: number,
		FaceBase: number,
		MouthShape: number,
		Height: number, -- 10 = "not rolled yet" sentinel
		GrowthProfile: string, -- "" until AgeHandler rolls one; format "v1|start|adult|spurtAge|fatEnd"
	},
	Age: {
		Years: number,
		TimePassed: number, -- os.time() of the last aging tick; set on first load
		ProgToAge: number, -- seconds banked toward the next birthday
	},
	-- DESIGN.md section 3a.
	Progress: {
		Magoi: number,
		GoldRukh: number,
		BlackRukh: number,
		Epithet: string,
		-- Schema v2 (M4-01). The epithet choice offered at the last rank-up
		-- (or the origin choice at birth) and not yet answered by
		-- ChooseEpithet. nil when nothing is pending. Optional, so a v1 save
		-- (missing the key entirely) already reads the same as nil - nothing
		-- for Migrations[2] to fill in.
		PendingEpithet: { rank: number, choices: { string } }?,
	},
	Bounty: number,
	Economy: {
		Copper: number,
		Silver: number,
		Gold: number,
	},
	Gear: {
		Shirt: string, -- item code string, e.g. "S|Short Sleeve Rags|35,35,35"
		Pants: string,
		Hats: { string }, -- 3 slots; "" = empty
		Inventory: { string }, -- item code strings
	},
	Family: { [string]: any }, -- reserved, DESIGN.md section 3
	Magic: { [string]: any }, -- reserved, DESIGN.md section 4
	Meta: {
		Created: number, -- os.time() of first load; 0 until then
		LastSeen: number, -- os.time() of the most recent load
		Lives: number,
		-- Schema v3 (M3B-01): combat is earned, not automatic (DESIGN: a
		-- tutorial unlocks it; until that ships, Config.Combat.
		-- UnlockedByDefault blanket-unlocks everyone regardless of this).
		-- Lives in Meta, not Progress: it's per-player forever, not per-life -
		-- DataService.NewLife carries it over the same way it carries
		-- Meta.Lives/.Created; only DataService.Wipe clears it (a wipe makes a
		-- brand-new player). CombatService.SetStance/.SetUnlocked are the
		-- only writers.
		Unlocks: { Combat: boolean },
	},
}

local SaveSchema = {}

local template: Data = {
	Version = 1,
	Character = {
		FirstName = "",
		Gender = 0,
		Race = 2,
		Kingdom = 1,
		SkinTone = 0,
		HairColor = { R = 0, G = 0, B = 0 },
		EyeColor = 1,
		FaceBase = 1,
		MouthShape = 1,
		Height = 10,
		GrowthProfile = "",
	},
	Age = {
		Years = 13,
		TimePassed = 0,
		ProgToAge = 0,
	},
	Progress = {
		Magoi = 0,
		GoldRukh = 0,
		BlackRukh = 0,
		Epithet = "",
	},
	Bounty = 0,
	Economy = {
		Copper = 20,
		Silver = 0,
		Gold = 0,
	},
	Gear = {
		Shirt = "",
		Pants = "",
		Hats = { "", "", "" },
		Inventory = {},
	},
	Family = {},
	Magic = {},
	Meta = {
		Created = 0,
		LastSeen = 0,
		Lives = 1,
		Unlocks = { Combat = false },
	},
}

-- Deep-copied per player by ProfileStore.New()'s template argument.
SaveSchema.Template = template

-- One migration per version, keyed by the TARGET version it produces (so
-- Migrations[2] turns a v1 save into a v2 save). Migrate below runs
-- Migrations[data.Version + 1], then [+2], and so on up to
-- Config.Data.SchemaVersion. Schema v1 is the baseline: no real save is
-- ever below it, so there's no Migrations[1] entry.
SaveSchema.Migrations = {} :: { [number]: (data: Data) -> () }

-- v2 (M4-01, DESIGN.md 3a) only adds Progress.PendingEpithet, an optional
-- field: a v1 save missing the key entirely already reads as nil, the
-- field's own "nothing pending" value, so there's nothing to backfill.
-- Kept as an explicit (empty) entry rather than left out, so Migrate's
-- version bump and the self-test's v1 -> v2 case both walk through a real
-- migration, not just the loop's own version-number increment.
SaveSchema.Migrations[2] = function(_data: Data) end

-- v3 (M3B-01): adds Meta.Unlocks.Combat. Migrate is always called after
-- Profile:Reconcile() (DataService.onPlayerAdded), which already backfilled
-- the whole Unlocks table from the template's own {Combat = false} default
-- before this runs - so this only has to flip it, not create it. Explicitly
-- true here (not left at the template's false): an EXISTING save already
-- had full combat access before v3 ever existed, and nobody should lose
-- that just because the schema grew a flag for it. Only a save that's
-- genuinely new as of v3 (never reconciled before, so there's no "existing
-- access" to preserve) starts at the template's own false.
SaveSchema.Migrations[3] = function(data: Data)
	data.Meta.Unlocks.Combat = true
end

-- Runs every migration from data.Version + 1 up to Config.Data.SchemaVersion,
-- in order. Call Profile:Reconcile() before this, so missing template keys
-- already exist and a migration can assume its own version's shape.
function SaveSchema.Migrate(data: Data)
	for version = data.Version + 1, Config.Data.SchemaVersion do
		local migration = SaveSchema.Migrations[version]
		if migration then
			migration(data)
		end
		data.Version = version
	end
end

-- Rolls the same "new life" randomness the old MainStore2/init.server.luau
-- gave a first-time player: first name, hair colour, eye colour, face base
-- and mouth shape (exact ranges copied from its setNewPlayerData). Race and
-- Kingdom are fixed by the template now (old code fixed them too, per its
-- own TODOs); Gender, SkinTone, Height and GrowthProfile stay at the
-- template's "not chosen/rolled yet" values, chosen later by the player or
-- by AppearanceController/AgeHandler. Progress.Magoi is left alone (old
-- MaxMagoi's race-based roll doesn't apply now that Race is fixed to Human).
-- Called by DataService on a brand-new save (Meta.Created == 0) and after
-- DataService.Wipe.
function SaveSchema.NewLife(data: Data)
	data.Character.FirstName = Assets.FirstNames.sindria.male[math.random(1, 50)]
	data.Character.HairColor = {
		R = math.random(1, 1000) / 1000,
		G = math.random(1, 1000) / 1000,
		B = math.random(1, 1000) / 1000,
	}
	data.Character.EyeColor = math.random(1, 5)
	data.Character.FaceBase = math.random(1, 2)
	data.Character.MouthShape = math.random(1, 6)
end

return SaveSchema

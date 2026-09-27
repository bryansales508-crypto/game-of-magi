--!strict
-- The save schema: the template ProfileStore deep-copies for every new
-- profile, and the migration chain that brings an old save up to the
-- current Config.Data.SchemaVersion. Data-only, so it's easy for Bryan to
-- read; DataService is the only thing that runs Migrate.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

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
	},
}

-- Deep-copied per player by ProfileStore.New()'s template argument.
SaveSchema.Template = template

-- One migration per version, keyed by the version it upgrades FROM (so
-- Migrations[1] turns a v1 save into a v2 save). v1 has nothing to migrate
-- yet. Example for when v2 adds, say, a Progress.Rank field that Reconcile
-- won't backfill correctly on its own (Reconcile only fills top-level
-- template keys that are nil; it can't tell a "0 by intent" from "missing"):
--
-- SaveSchema.Migrations[1] = function(data: Data)
-- 	(data :: any).Progress.Rank = "Street Rat"
-- end
SaveSchema.Migrations = {
	[1] = function(_data: Data) end,
} :: { [number]: (data: Data) -> () }

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

return SaveSchema

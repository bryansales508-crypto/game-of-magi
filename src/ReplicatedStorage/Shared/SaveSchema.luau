--!strict
-- The save schema: the template ProfileStore deep-copies for every new profile, and the migration chain that brings an old save up to Config.Data.SchemaVersion. Data-only; DataService is the only caller of Migrate.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

local Config = require(ReplicatedStorage.Shared.Config)
local Assets = require(ReplicatedFirst.Assets)

export type Data = {
	Version: number,
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
		-- This character's remaining lives (Config.Life.LivesPerCharacter at birth). A real death (Humanoid.Died, not a combat knockout) costs one; the last one wipes to a brand-new character (LifeService). Not Meta.Lives, which counts characters.
		LivesLeft: number,
	},
	Age: {
		Years: number,
		TimePassed: number, -- os.time() of the last aging tick; set on first load
		ProgToAge: number, -- seconds banked toward the next birthday
	},
	Progress: {
		Magoi: number,
		GoldRukh: number,
		BlackRukh: number,
		Epithet: string,
		-- The epithet choice offered at the last rank-up (or origin choice at birth) and not yet answered by ChooseEpithet; nil when nothing is pending.
		PendingEpithet: { rank: number, choices: { string } }?,
		-- DeliveryStreak: consecutive successful deliveries; +1 on completion, reset to 0 on any failed/intercepted run. Routes: city key -> completed delivery count (missing = 0).
		DeliveryStreak: number,
		Routes: { [string]: number },
		-- Intercepted mark: +1 each time this player is intercepted mid-delivery; cleared to 0 only by completing a delivery (paid at the reduced rate). See MissionService.OfferMultiplier.
		Intercepted: number,
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
	Family: { [string]: any },
	Magic: { [string]: any }, -- reserved, DESIGN.md section 4
	Meta: {
		Created: number, -- os.time() of first load; 0 until then
		LastSeen: number, -- os.time() of the most recent load
		-- Incarnation count: how many characters this player has had (bumped by DataService.NewLife). Not Character.LivesLeft.
		Lives: number,
		-- Combat unlock. Per-player forever, so DataService.NewLife carries it over and only DataService.Wipe clears it. Config.Combat.UnlockedByDefault blanket-unlocks everyone regardless. CombatService.SetStance/.SetUnlocked are the only writers.
		Unlocks: { Combat: boolean },
	},
}

local SaveSchema = {}

local template: Data = {
	-- A fresh template is already current, so Migrate and DataService.ResetToTemplate (Wipe/NewLife) never run migrations on a brand-new profile; Migrations[3] would otherwise grandfather combat access onto it.
	Version = Config.Data.SchemaVersion,
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
		LivesLeft = Config.Life.LivesPerCharacter,
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
		DeliveryStreak = 0,
		Routes = {},
		Intercepted = 0,
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

-- Deep-copied per player by ProfileStore.New().
SaveSchema.Template = template

-- One migration per version, keyed by the target version it produces. Migrate runs Migrations[data.Version + 1] up to Config.Data.SchemaVersion. v1 is the baseline, so there is no Migrations[1].
SaveSchema.Migrations = {} :: { [number]: (data: Data) -> () }

-- v2 adds the optional Progress.PendingEpithet; a missing key already reads as nil. Kept as an explicit empty entry so the version bump walks a real migration.
SaveSchema.Migrations[2] = function(_data: Data) end

-- v3 adds Meta.Unlocks.Combat and Character.LivesLeft. Migrate runs after Profile:Reconcile(), which has already backfilled both from the template, so this only sets them. Unlocks.Combat is true because an existing save already had full combat access before v3.
SaveSchema.Migrations[3] = function(data: Data)
	data.Meta.Unlocks.Combat = true
	data.Character.LivesLeft = Config.Life.LivesPerCharacter
end

-- v4 adds Progress.DeliveryStreak, Routes and Intercepted. A no-op: Profile:Reconcile() already backfills their defaults before Migrate runs.
SaveSchema.Migrations[4] = function(_data: Data) end

-- Runs every migration from data.Version + 1 up to Config.Data.SchemaVersion, in order. Call Profile:Reconcile() first so a migration can assume its own version's shape.
function SaveSchema.Migrate(data: Data)
	for version = data.Version + 1, Config.Data.SchemaVersion do
		local migration = SaveSchema.Migrations[version]
		if migration then
			migration(data)
		end
		data.Version = version
	end
end

-- Rolls the first-time-player randomness: first name, hair colour, eye colour, face base and mouth shape. Gender, SkinTone, Height and GrowthProfile stay at the template's "not chosen/rolled yet" values (set later by the player, AppearanceController or AgeHandler). Called by DataService on a brand-new save (Meta.Created == 0) and after DataService.Wipe.
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

--!strict
-- Regions and their music (M6 Phase 6A, docs/M6-PLAN.md, Bryan approved
-- 2026-09-29). Pure data: the client RegionController finds every part named
-- "<Key>REGION" under Workspace.Regions and looks its Key up here; the
-- MusicController plays what it finds. Nothing on the server reads this.
--
-- To add a region: drop an invisible, CanCollide=false part (or a folder of
-- parts) named "<Key>REGION" in Workspace.Regions and add a "<Key>" entry
-- below. Track names are the Sound names under ReplicatedFirst.SFX.OSTs.
--
-- The keys that exist in the place today (docs/reference/m6-studio-dump.md):
-- Qarzin, SakuraIsland, Ocean. The others below were in the old script but
-- have no parts any more (previous-game leftovers, AUDIT D5); they are kept
-- here, commented, so Bryan can bring one back by placing a part.

export type Region = {
	-- Higher wins when two regions overlap (a city inside the ocean box
	-- keeps the city music; the ocean ambient still layers underneath).
	priority: number,
	-- Shuffled playlist (no immediate repeats). Empty = no music change.
	playlist: { string },
	-- A looping ambient layer that plays alongside any music, with its own
	-- volume (the old code used 0.2 for rain and 0.6 for the ocean).
	ambient: { name: string, volume: number }?,
	-- The bounce-in banner ("Q A R Z I N" / "The Merchant's Playground").
	banner: { title: string, subtitle: string }?,
}

local Regions: { [string]: Region } = {
	Qarzin = {
		priority = 10,
		playlist = { "Danse Bizzare", "Tostarena Ruins", "Paix D'espirit" },
		banner = { title = "Q A R Z I N", subtitle = "The Merchant's Playground" },
	},
	SakuraIsland = {
		priority = 10,
		playlist = { "Resort Island", "We Did It" },
	},
	Ocean = {
		priority = 1,
		playlist = {},
		ambient = { name = "OceanAmbi", volume = 0.6 },
	},
	-- Badlands = { priority = 10, playlist = { "L'imminence", "Notre Empire Dévastation" } },
	-- QishanCity = { priority = 10, playlist = { "Danse Bizzare", "Tostarena Ruins", "Paix D'espirit", "Gerudo Town Day" } },
	-- Rain = { priority = 1, playlist = {}, ambient = { name = "RainAmbi", volume = 0.2 } },
}

for _, region in Regions do
	table.freeze(region.playlist)
	table.freeze(region)
end
table.freeze(Regions)

return Regions

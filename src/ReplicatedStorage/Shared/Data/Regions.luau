--!strict
-- Regions and their music. Pure data: the client RegionController finds every part named "<Key>REGION" under Workspace.Regions and looks its Key up here; MusicController plays what it finds. Nothing on the server reads this. To add a region: place an invisible, CanCollide=false part (or folder of parts) named "<Key>REGION" there and add a "<Key>" entry. Track names are the Sound names under ReplicatedFirst.SFX.OSTs.

export type Region = {
	-- Higher wins when two regions overlap (the ocean ambient still layers underneath a city inside the ocean box).
	priority: number,
	-- Shuffled playlist (no immediate repeats). Empty = no music change.
	playlist: { string },
	-- A looping ambient layer that plays alongside any music, with its own volume.
	ambient: { name: string, volume: number }?,
	-- The bounce-in banner.
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
}

for _, region in Regions do
	table.freeze(region.playlist)
	table.freeze(region)
end
table.freeze(Regions)

return Regions

--!strict
-- Shared configuration, read by both server and client.
--
-- One frozen table. Later milestones add their own sections here
-- (Aging, Rank, Economy, ...) alongside Debug and Data. Don't invent
-- those sections yet.

local RunService = game:GetService("RunService")

local Config = {}

Config.IsStudio = RunService:IsStudio()

Config.Debug = {
	Enabled = Config.IsStudio,
	-- M1-03: forces a brand-new save every time DataService loads, in Studio only.
	FreshSave = false,
	SaveScope = if Config.IsStudio then "Studio" else "Live",
	LogLevel = if Config.IsStudio then "Debug" else "Info",
	-- Speeds up aging and day/night for tests; 1 = real time.
	TimeScale = 1,
}

Config.Data = {
	StoreName = "GameOfMagi_v1",
	SchemaVersion = 1,
}

-- M1-05: SYSTEMS.md section 16's UserId, kept as the one source of truth.
-- A player also counts as a dev when Config.Debug.Enabled (Studio) is true;
-- see DevService.IsDev.
Config.Dev = {
	Admins = { 27938432 },
}

-- M2-02: aging (DESIGN.md section 3, "Aging while offline"/"Aging and
-- death"). AgeService multiplies the online tick's banked seconds, and
-- SceneTimeout's wait, by DevService.GetTimeScale() (a runtime override of
-- Config.Debug.TimeScale, since Config is frozen); offline aging is always
-- real time, never scaled.
Config.Aging = {
	SecondsPerYear = if Config.IsStudio then 60 else 1800,
	OfflineYearsPerDay = 2,
	OfflineAgeCap = 59,
	AdultAge = 18,
	-- Hair visibly greys from GreyStart to GreyEnd (CharacterService.applyHairColor).
	GreyStart = 45,
	GreyEnd = 70,
	-- From DeathStart, every online birthday carries a heart-attack moment;
	-- DeathChance is the odds it's fatal, linearly interpolated between points.
	DeathStart = 60,
	DeathChance = {
		{ 60, 0.05 },
		{ 65, 0.10 },
		{ 70, 0.20 },
		{ 75, 0.35 },
		{ 80, 0.50 },
		{ 90, 0.80 },
		{ 100, 1.0 },
	},
	-- How long the server waits for RukhSceneDone before starting the new
	-- life anyway.
	SceneTimeout = 30,
	-- How often the online aging loop ticks, in real seconds.
	Tick = 10,
}

table.freeze(Config.Debug)
table.freeze(Config.Data)
table.freeze(Config.Dev.Admins)
table.freeze(Config.Dev)
for _, point in Config.Aging.DeathChance do
	table.freeze(point)
end
table.freeze(Config.Aging.DeathChance)
table.freeze(Config.Aging)
table.freeze(Config)

return Config

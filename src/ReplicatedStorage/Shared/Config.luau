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

-- M2-05: the heart-attack/death scene's sound. Bryan: swap for your own sound.
Config.Sfx = {
	Heartbeat = "rbxassetid://102383912898742",
}

table.freeze(Config.Debug)
table.freeze(Config.Data)
table.freeze(Config.Dev.Admins)
table.freeze(Config.Dev)
table.freeze(Config.Sfx)
table.freeze(Config)

return Config

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

table.freeze(Config)

return Config

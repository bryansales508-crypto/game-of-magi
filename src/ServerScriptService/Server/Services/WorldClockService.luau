--!strict
-- The shared world clock. The server never touches Lighting: it publishes Workspace attributes
-- once, and every client derives Lighting.ClockTime from workspace:GetServerTimeNow() each
-- frame with the same maths as ClockTimeAt below (client LightingController mirrors it), so all
-- players see the same hour with no replication traffic.
--
--   DayStart   number  GetServerTimeNow() at which the current in-game day
--                      began (at DawnHour, 06:00)
--   DayLength  number  real seconds for one whole in-game day
--   DayPaused  number? only while paused: the frozen hour (0-24)
--
-- The day part (DawnHour..DuskHour) spans DaySeconds and the night part
-- NightSeconds, each linear (Config.World.DayNight). `.time speed x` scales
-- DayLength by 1/x and keeps the day/night ratio, so it is a pure scale.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local DevService = require(script.Parent.DevService)

local log = Log.new("WorldClockService")

local WorldClockService = {}

local Cfg = Config.World.DayNight
local BASE_DAY_LENGTH = Cfg.DaySeconds + Cfg.NightSeconds
local DAY_FRACTION = Cfg.DaySeconds / BASE_DAY_LENGTH
local DAY_HOURS = Cfg.DuskHour - Cfg.DawnHour
local NIGHT_HOURS = 24 - DAY_HOURS

local started = false
local speed = 1

-- Hours 0-24 at server time `now` for a day that began at `dayStart` and
-- lasts `dayLength` seconds. Pure; the client mirrors it.
function WorldClockService.ClockTimeAt(now: number, dayStart: number, dayLength: number): number
	local phase = ((now - dayStart) / dayLength) % 1
	if phase < DAY_FRACTION then
		return Cfg.DawnHour + DAY_HOURS * (phase / DAY_FRACTION)
	end
	local nightPhase = (phase - DAY_FRACTION) / (1 - DAY_FRACTION)
	return (Cfg.DuskHour + NIGHT_HOURS * nightPhase) % 24
end

-- Inverse: how far into the day (0-1) an hour sits.
local function phaseOfHour(hour: number): number
	local sinceDawn = (hour - Cfg.DawnHour) % 24
	if sinceDawn < DAY_HOURS then
		return DAY_FRACTION * (sinceDawn / DAY_HOURS)
	end
	return DAY_FRACTION + (1 - DAY_FRACTION) * ((sinceDawn - DAY_HOURS) / NIGHT_HOURS)
end

local function ensureStarted()
	if started then
		return
	end
	started = true
	Workspace:SetAttribute("DayStart", Workspace:GetServerTimeNow())
	Workspace:SetAttribute("DayLength", BASE_DAY_LENGTH)
end

function WorldClockService.IsPaused(): boolean
	return type(Workspace:GetAttribute("DayPaused")) == "number"
end

function WorldClockService.GetSpeed(): number
	return speed
end

function WorldClockService.CurrentHour(): number
	ensureStarted()
	local paused = Workspace:GetAttribute("DayPaused")
	if type(paused) == "number" then
		return paused
	end
	return WorldClockService.ClockTimeAt(
		Workspace:GetServerTimeNow(),
		Workspace:GetAttribute("DayStart") :: number,
		Workspace:GetAttribute("DayLength") :: number
	)
end

-- Re-anchors DayStart so the clock reads `hour` right now (keeps DayLength).
local function anchor(hour: number, dayLength: number)
	Workspace:SetAttribute("DayLength", dayLength)
	Workspace:SetAttribute("DayStart", Workspace:GetServerTimeNow() - phaseOfHour(hour) * dayLength)
end

function WorldClockService.SetHour(hour: number)
	ensureStarted()
	local h = hour % 24
	if WorldClockService.IsPaused() then
		Workspace:SetAttribute("DayPaused", h)
	end
	anchor(h, Workspace:GetAttribute("DayLength") :: number)
end

-- x > 0; 1 restores the configured length. The current hour is kept.
function WorldClockService.SetSpeed(x: number)
	ensureStarted()
	local hour = WorldClockService.CurrentHour()
	speed = x
	anchor(hour, BASE_DAY_LENGTH / x)
end

function WorldClockService.Pause()
	ensureStarted()
	if not WorldClockService.IsPaused() then
		Workspace:SetAttribute("DayPaused", WorldClockService.CurrentHour())
	end
end

function WorldClockService.Resume()
	ensureStarted()
	local frozen = Workspace:GetAttribute("DayPaused")
	if type(frozen) ~= "number" then
		return
	end
	Workspace:SetAttribute("DayPaused", nil)
	anchor(frozen, Workspace:GetAttribute("DayLength") :: number)
end

local function formatHour(hour: number): string
	local h = math.floor(hour)
	local m = math.floor((hour - h) * 60)
	return string.format("%02d:%02d", h, m)
end

local function describe(): string
	local state = if WorldClockService.IsPaused() then " (paused)" else ""
	return string.format("Time %s%s, speed x%s", formatHour(WorldClockService.CurrentHour()), state, tostring(speed))
end

function WorldClockService:Init()
	DevService.Register("time", "[0-24 | speed <x> | pause | resume] - world clock", function(_caller, args)
		local first = args[1] and args[1]:lower()
		if first == nil then
			return describe()
		elseif first == "pause" then
			WorldClockService.Pause()
		elseif first == "resume" then
			WorldClockService.Resume()
		elseif first == "speed" then
			local x = tonumber(args[2])
			if x == nil or x ~= x or x <= 0 or x > 1000 then
				return "usage: .time speed <x> (0 < x <= 1000, 1 = normal)"
			end
			WorldClockService.SetSpeed(x)
		else
			local hour = tonumber(first)
			if hour == nil or hour ~= hour or hour < 0 or hour > 24 then
				return "usage: .time [0-24 | speed <x> | pause | resume]"
			end
			WorldClockService.SetHour(hour)
		end
		return describe()
	end)
end

function WorldClockService:Start()
	ensureStarted()
	log:Info(string.format("day %ds + night %ds, clock at %s", Cfg.DaySeconds, Cfg.NightSeconds, formatHour(WorldClockService.CurrentHour())))
end

return WorldClockService

--!strict
-- Growth-curve maths: height and "fatness" (build) over a life (13-18),
-- and the versioned profile string Character.GrowthProfile round-trips
-- through ("v1|startHeight|adultHeight|spurtAge|fatEnd"). Same numbers and
-- format as the old Character/AgeHandler.luau; only the typing changed.

export type Profile = {
	startHeight: number,
	adultHeight: number,
	spurtAge: number,
	fatEnd: number,
}

local AgeHandler = {}

-- ===== height tuning =====
local MIN_START = 0.75
local MAX_ADULT = 1.25
local START_GENE = 0.10
local GAIN_MIN = 0.20
local GAIN_MAX = 0.45
local SPURT_MIN = 14.5
local SPURT_MAX = 16.5
local SPURT_SHARP = 1.8

-- ===== build (fat) tuning =====
local FAT_START = -0.5 -- skinny kid at 13
local FAT_END_MEAN = 0.3 -- standard adult on average
local FAT_SPREAD = 0.5 -- buff tail (-) / lean tail (+)
local FAT_SKEW = 0.0 -- <0 biases adults buff-ward

local AGE_START, AGE_END = 13, 18

local function logistic(x: number): number
	return 1 / (1 + math.exp(-x))
end

local function clampAge(age: number): number
	return math.clamp(age, AGE_START, AGE_END)
end

local function round(n: number, p: number): number
	local m = 10 ^ p
	return math.floor(n * m + 0.5) / m
end

local function growthFraction(age: number, spurtAge: number): number
	local k = SPURT_SHARP
	local lo = logistic(k * (AGE_START - spurtAge))
	local hi = logistic(k * (AGE_END - spurtAge))
	local cur = logistic(k * (age - spurtAge))
	return (cur - lo) / (hi - lo)
end

-- ===== serialization: "v1|startHeight|adultHeight|spurtAge|fatEnd" =====
function AgeHandler.pack(profile: Profile): string
	return table.concat({
		"v1",
		tostring(round(profile.startHeight, 3)),
		tostring(round(profile.adultHeight, 3)),
		tostring(round(profile.spurtAge, 2)),
		tostring(round(profile.fatEnd, 3)),
	}, "|")
end

function AgeHandler.unpack(str: string?): Profile?
	if type(str) ~= "string" then
		return nil
	end
	local parts = str:split("|")
	if parts[1] ~= "v1" or #parts < 5 then
		return nil
	end

	local startHeight = tonumber(parts[2])
	local adultHeight = tonumber(parts[3])
	local spurtAge = tonumber(parts[4])
	local fatEnd = tonumber(parts[5])
	if startHeight == nil or adultHeight == nil or spurtAge == nil or fatEnd == nil then
		return nil
	end

	return { startHeight = startHeight, adultHeight = adultHeight, spurtAge = spurtAge, fatEnd = fatEnd }
end

function AgeHandler.heightAt(profile: Profile, age: number): number
	local f = growthFraction(clampAge(age), profile.spurtAge)
	return profile.startHeight + (profile.adultHeight - profile.startHeight) * f
end

function AgeHandler.fatAt(profile: Profile, age: number): number
	local f = growthFraction(clampAge(age), profile.spurtAge)
	return FAT_START + (profile.fatEnd - FAT_START) * f
end

-- Rolls a brand-new profile for a first spawn. `_race` is accepted (old
-- signature) but unused, same as before: every race but Human is parked
-- (DESIGN.md section 4). Returns (packed profile string, height at `age`).
function AgeHandler.start(age: number, _race: number, gender: number): (string, number)
	local startHeight = MIN_START + math.random() * START_GENE
	local totalGain = GAIN_MIN + math.random() * (GAIN_MAX - GAIN_MIN)
	if gender == 2 then
		totalGain *= 0.9
	end
	local adultHeight = math.min(MAX_ADULT, startHeight + totalGain)
	local spurtAge = SPURT_MIN + math.random() * (SPURT_MAX - SPURT_MIN)

	local s = (math.random() + math.random()) / 2 -- triangular, peaks at standard
	local fatEnd = FAT_END_MEAN + FAT_SKEW + (s - 0.5) * 2 * FAT_SPREAD

	local profile: Profile = {
		startHeight = startHeight,
		adultHeight = adultHeight,
		spurtAge = spurtAge,
		fatEnd = fatEnd,
	}
	return AgeHandler.pack(profile), AgeHandler.heightAt(profile, age)
end

return AgeHandler

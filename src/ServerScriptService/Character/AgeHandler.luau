local module = {}

-- ===== height tuning =====
local MIN_START   = 0.75
local MAX_ADULT   = 1.25
local START_GENE  = 0.10
local GAIN_MIN    = 0.20
local GAIN_MAX    = 0.45
local SPURT_MIN   = 14.5
local SPURT_MAX   = 16.5
local SPURT_SHARP = 1.8

-- ===== build (fat) tuning =====
local FAT_START    = -0.5   -- skinny kid at 13
local FAT_END_MEAN =  0.3  -- standard adult on average
local FAT_SPREAD   =  0.5   -- buff tail (-) / lean tail (+)
local FAT_SKEW     =  0.0   -- <0 biases adults buff-ward

local AGE_START, AGE_END = 13, 18

local function logistic(x) return 1 / (1 + math.exp(-x)) end
local function clampAge(age) return math.clamp(age, AGE_START, AGE_END) end
local function round(n, p) local m = 10 ^ p return math.floor(n * m + 0.5) / m end

local function growthFraction(age, spurtAge)
	local k = SPURT_SHARP
	local lo  = logistic(k * (AGE_START - spurtAge))
	local hi  = logistic(k * (AGE_END   - spurtAge))
	local cur = logistic(k * (age - spurtAge))
	return (cur - lo) / (hi - lo)
end

-- ===== serialization: "v1|startHeight|adultHeight|spurtAge|fatEnd" =====
module.pack = function(p)
	return table.concat({
		"v1", round(p.startHeight,3), round(p.adultHeight,3),
		round(p.spurtAge,2), round(p.fatEnd,3),
	}, "|")
end

module.unpack = function(str)
	if type(str) ~= "string" then return nil end
	local p = str:split("|")
	if p[1] ~= "v1" or #p < 5 then return nil end
	local profile = {
		startHeight = tonumber(p[2]),
		adultHeight = tonumber(p[3]),
		spurtAge    = tonumber(p[4]),
		fatEnd      = tonumber(p[5]),
	}
	for _, v in profile do if v == nil then return nil end end
	return profile
end

-- ===== rolling + reading =====
-- returns (profileString, heightAtCurrentAge)
module.start = function(age, race, gender)
	local startHeight = MIN_START + math.random() * START_GENE
	local totalGain   = GAIN_MIN + math.random() * (GAIN_MAX - GAIN_MIN)
	if gender == 2 then totalGain *= 0.9 end
	local adultHeight = math.min(MAX_ADULT, startHeight + totalGain)
	local spurtAge    = SPURT_MIN + math.random() * (SPURT_MAX - SPURT_MIN)

	local s = (math.random() + math.random()) / 2          -- triangular, peaks at standard
	local fatEnd = FAT_END_MEAN + FAT_SKEW + (s - 0.5) * 2 * FAT_SPREAD

	local profile = {
		startHeight = startHeight,
		adultHeight = adultHeight,
		spurtAge    = spurtAge,
		fatEnd      = fatEnd,
	}
	return module.pack(profile), module.heightAt(profile, age)
end

module.heightAt = function(profile, age)
	local f = growthFraction(clampAge(age), profile.spurtAge)
	return profile.startHeight + (profile.adultHeight - profile.startHeight) * f
end

module.fatAt = function(profile, age)
	local f = growthFraction(clampAge(age), profile.spurtAge)
	return FAT_START + (profile.fatEnd - FAT_START) * f
end

return module
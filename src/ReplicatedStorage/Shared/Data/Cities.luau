--!strict
-- Delivery missions data (M5-PLAN.md Phase 5C, Bryan's rules 2026-09-29):
-- the seven cities, their trade routes, and the modifier table. Pure data
-- (plus the one pure roll function below) - MissionService is the only
-- thing that touches a Player or a save.
--
-- Lore text, colours and personality are moved verbatim from the old
-- RS/Modules/MissionDeliniation.luau's `cityAssests` table and the Studio
-- dump (docs/reference/m5c-studio-dump.md section 1). The trade-route table
-- is the old SSS/MISC/MissionHandler/init.server.luau one (line 26), with
-- its two broken names fixed (AUDIT: "the route table names two cities that
-- don't exist"):
--   - "JADDATYSHUT" (no space) was always meant to be JaddatysHut - the
--     button/city key just has a space ("JADDATYS HUT") the route table
--     never matched, so the lookup silently returned nil.
--   - "CITYF" was never a real city at all (an 8th city that was never
--     built). Routes are placeholders regardless (Bryan, 2026-09-29: only
--     Qarzin is a built city, the rest are markers), so it's pointed at
--     Sahraqin, a real placeholder city, rather than left broken.
--
-- Safety (M12 fix - "city Personality is only used for display; route
-- history and personality never actually shape the modifiers"): the old
-- data only ever had a cosmetic Personality string. Safety is a new, static
-- 0-1 rating derived from that same Personality, standing in for the old
-- (never-updated) global successRate counter: Busy cities read as safer
-- (more people, more eyes) than a War-Torn one. PlayerActive is likewise
-- wired to something real - the PLAYER's own delivery count to that city
-- (Progress.Routes, schema v4), not a global counter nothing ever wrote to.

export type CityKey = "Qarzin" | "Sahraqin" | "IllegalPort" | "AinJamala" | "Saleh" | "Rathole" | "JaddatysHut"

export type City = {
	key: CityKey,
	name: string, -- display name, as shown on the old board buttons
	color: { r: number, g: number, b: number }, -- 0-1, straight from the Studio dump
	lore: string, -- verbatim from the old MissionDeliniation.cityAssests
	image: string, -- rbxassetid:// - every city shares one placeholder today (old code's own "TODO: make city images.")
	personality: string, -- display only, same as before
	safety: number, -- 0-1; > Config.Missions.SafeRouteThreshold = "SafeRoute"
}

export type ModifierDef = {
	name: string,
	chance: number,
	text: string, -- the pop-out description, verbatim from MissionDeliniation.Modifiers
	payMultiplier: number, -- 1 = no change; "Nothing" has none, it's the empty draw
	-- Only the keys actually present are checked (meetsReqs below) - the old
	-- reqs tables didn't always name both factors (e.g. CleartheRoute only
	-- ever checked SafeRoute, never PlayerActive).
	requires: { PlayerActive: boolean?, SafeRoute: boolean? }?,
}

export type ModifierRoll = {
	name: string,
	chance: number,
	text: string,
	payMultiplier: number,
}

export type Factors = {
	PlayerActive: boolean,
	SafeRoute: boolean,
}

local Cities = {}

-- ==================== cities ====================
-- Order matches the old Studio dump's button table (section 1).

local cityList: { City } = {
	{
		key = "Saleh",
		name = "SALEH",
		color = { r = 0.333, g = 0.667, b = 0.498 },
		lore = "Saleh is a small desert village, said to be as old as the desert itself. The Endless Desert looms just beyond its edge, a vast expanse of shifting sands. As the last bastion of civilization on the coast, Saleh stands guard against the lawless wastes that stretch beyond.",
		image = "rbxassetid://80085994447501",
		personality = "Neutral",
		safety = 0.6,
	},
	{
		key = "AinJamala",
		name = "AIN JAMALA",
		color = { r = 0.251, g = 0.145, b = 0.282 },
		lore = "Ain Jamala was once a jewel of the southern sands, a thriving oasis thought to one day rival the great Qishan to the north. But those dreams have long since turned to dust. What now remains of the once great city is nothing but a den of smugglers, assassins, bandits, and slavers. ",
		image = "rbxassetid://80085994447501",
		personality = "War-Torn",
		safety = 0.2,
	},
	{
		key = "Qarzin",
		name = "QARZIN",
		color = { r = 0.749, g = 0.518, b = 0.286 },
		lore = "A bustling trade city, Qarzin measures worth by the weight of your purse. Outlaw, noblemen, magician, or slave; if you carry coin, Qarzin will accept you with welcoming arms.",
		image = "rbxassetid://80085994447501",
		personality = "Busy",
		safety = 0.9,
	},
	{
		key = "Sahraqin",
		name = "SAHRAQIN",
		color = { r = 0.490, g = 0.655, b = 0.855 },
		lore = "Sahraqin rose around the rarest treasure in the Southern Desert, an oasis of clear, endless water. Its people bear this gift with fierce pride, and the live-giving spring stands at the heart of their identity and culture.",
		image = "rbxassetid://80085994447501",
		personality = "Busy",
		safety = 0.9,
	},
	{
		key = "IllegalPort",
		name = "ILLEGAL PORT",
		color = { r = 0, g = 0, b = 0 },
		lore = "A lawless port that sits tucked away on the coast of the Badlands. Officially, it does not exist. Unofficially, it thrives, trafficking in flesh, forbidden goods, and bloodstained coin. Here; slave galleys, smugger sloops, and black sails of pirates are all welcomed with open arms.",
		image = "rbxassetid://80085994447501",
		personality = "Busy",
		safety = 0.9,
	},
	{
		key = "Rathole",
		name = "RATHOLE",
		color = { r = 0.392, g = 0.333, b = 0.459 },
		lore = "An encampment of bandits, colloquially knonw as the Rathole. Here, a legendary blacksmith, said to be old as the desert itself, makes the finest weapons that can be found in the Southern Desert.",
		image = "rbxassetid://80085994447501",
		personality = "War-Torn",
		safety = 0.2,
	},
	{
		key = "JaddatysHut",
		name = "JADDATY'S HUT",
		color = { r = 0.671, g = 0.678, b = 0.251 },
		lore = "A small hut owned by a Grandmother and her grandchildren. Travellers tend to avoid this place, as a sense of danger and malice hangs about the entireity of the encampent.",
		image = "rbxassetid://80085994447501",
		personality = "Neutral",
		safety = 0.6,
	},
}

Cities.List = cityList
Cities.ByKey = {} :: { [string]: City }
Cities.Keys = {} :: { string }
for _, city in Cities.List do
	Cities.ByKey[city.key] = city
	table.insert(Cities.Keys, city.key)
end

-- ==================== trade routes ====================
-- The old table (MissionHandler:26), names fixed (see the header comment).

local routes: { [string]: { string } } = {
	Qarzin = { "AinJamala", "IllegalPort", "Sahraqin", "Saleh" },
	Sahraqin = { "AinJamala", "Qarzin" },
	IllegalPort = { "Qarzin", "Saleh" },
	AinJamala = { "Sahraqin", "Qarzin" },
	Saleh = { "Qarzin", "IllegalPort", "Rathole", "JaddatysHut" }, -- was "JADDATYSHUT"
	Rathole = { "Saleh", "JaddatysHut", "Sahraqin" }, -- was "CITYF"
	JaddatysHut = { "Saleh", "Rathole", "Sahraqin" }, -- was "CITYF"
}
Cities.Routes = routes

-- Delivery drop zone part names (docs/reference/m5c-studio-dump.md section
-- 3): Workspace.MAP.MISSION.<key>Delivery. Only Qarzin is a built city today
-- (Bryan) - the rest are markers, same as before.
function Cities.DeliveryPartName(key: string): string
	return key .. "Delivery"
end

-- ==================== modifiers ====================
-- One copy (AUDIT D2: "the Modifiers table is copied 3 times" - moved here
-- from MissionHandler/RewardHandler/MissionDeliniation). An ordered array,
-- not the old scripts' dictionaries (`for name, data in Modifiers`, table
-- iteration order is unspecified in Lua) - the weighted roll below needs a
-- stable order to be deterministic/testable. "Nothing" is the empty draw:
-- it occupies a roll same as any other modifier (so real modifiers don't
-- always win a slot) but is never handed back to a caller.

local modifiers: { ModifierDef } = {
	{ name = "TimeCrunch", chance = 20, payMultiplier = 1.2, text = "Complete in 3:00." },
	{ name = "CourierLoop", chance = 10, payMultiplier = 1, text = "Deliver the package and then return with another." },
	{
		name = "HighlyValuable",
		chance = 10,
		payMultiplier = 1.5,
		text = "You are carrying something valuable, protect it.",
		requires = { SafeRoute = true },
	},
	{ name = "HeavyCargo", chance = 3, payMultiplier = 1.3, text = "The package is heavy." },
	{
		name = "VIP",
		chance = 1,
		payMultiplier = 2,
		text = "Protect them to the next city, they are important and will draw attention.",
		requires = { PlayerActive = false, SafeRoute = false },
	},
	{ name = "FragilePackage", chance = 20, payMultiplier = 1.3, text = "You are carrying something fragile, don't get into a fight." },
	{
		name = "CleartheRoute",
		chance = 3,
		payMultiplier = 1.5,
		text = "The route is dangerous, your Broker has requested you clear the way.",
		requires = { SafeRoute = false },
	},
	{ name = "Nothing", chance = 40, payMultiplier = 1, text = "" },
}
Cities.Modifiers = modifiers

-- Only the keys a def's own `requires` actually names are checked (the old
-- reqs tables didn't always name both factors - e.g. CleartheRoute only
-- ever checked SafeRoute, never PlayerActive).
local function meetsReqs(def: ModifierDef, factors: Factors): boolean
	local reqs = def.requires
	if reqs == nil then
		return true
	end
	if reqs.PlayerActive ~= nil and factors.PlayerActive ~= reqs.PlayerActive then
		return false
	end
	if reqs.SafeRoute ~= nil and factors.SafeRoute ~= reqs.SafeRoute then
		return false
	end
	return true
end

local function eligiblePool(factors: Factors): { ModifierDef }
	local pool: { ModifierDef } = {}
	for _, def in Cities.Modifiers do
		if meetsReqs(def, factors) then
			table.insert(pool, def)
		end
	end
	return pool
end

Cities.EligiblePool = eligiblePool

-- Pure, self-tested: rolls 1-3 modifiers for one destination. `nextRoll(max)`
-- returns an integer in [1, max] - production passes math.random, a
-- self-test passes a canned sequence so the exact draw is deterministic.
-- Ported unchanged from the old modDeterminant (MissionHandler:129-210):
-- draw one (always, weighted by `chance` among the eligible pool, "Nothing"
-- included); 50% chance to draw a second from whatever's left; if a second
-- was drawn, 30% chance to draw a third. Each draw removes its pick from
-- the pool, so nothing is ever picked twice. "Nothing" draws are never
-- added to `selected` - a drawn "Nothing" just means one of the up-to-3
-- rolls turned up empty (AUDIT M12 didn't touch this odds shape; only the
-- eligibility factors feeding it are new).
function Cities.RollModifiers(factors: Factors, nextRoll: (max: number) -> number): { ModifierRoll }
	local pool = eligiblePool(factors)
	local selected: { ModifierRoll } = {}

	local function drawOne(): boolean
		local totalWeight = 0
		for _, def in pool do
			totalWeight += def.chance
		end
		if totalWeight <= 0 then
			return false
		end

		local roll = nextRoll(totalWeight)
		local cumulative = 0
		for i, def in pool do
			cumulative += def.chance
			if roll <= cumulative then
				if def.name ~= "Nothing" then
					table.insert(selected, { name = def.name, chance = def.chance, text = def.text, payMultiplier = def.payMultiplier })
				end
				table.remove(pool, i)
				return true
			end
		end
		return false
	end

	drawOne()
	if #pool > 0 and nextRoll(10) <= 5 then
		drawOne()
		if #pool > 0 and nextRoll(10) <= 3 then
			drawOne()
		end
	end

	return selected
end

-- Pure: the combined pay multiplier for a set of rolled modifiers - the old
-- RewardHandler.citymodifier + 1 (each modifier's payMultiplier contributes
-- payMultiplier - 1; a bare mission with none rolled is exactly 1x).
function Cities.CombinedMultiplier(rolled: { ModifierRoll }): number
	local total = 1
	for _, mod in rolled do
		total += mod.payMultiplier - 1
	end
	return total
end

for _, city in Cities.List do
	table.freeze(city.color)
	table.freeze(city)
end
table.freeze(Cities.List)
table.freeze(Cities.ByKey)
table.freeze(Cities.Keys)
for _, route in Cities.Routes do
	table.freeze(route)
end
table.freeze(Cities.Routes)
for _, def in Cities.Modifiers do
	if def.requires then
		table.freeze(def.requires)
	end
	table.freeze(def)
end
table.freeze(Cities.Modifiers)
table.freeze(Cities)

return Cities

--!strict
-- Delivery mission data: the seven cities, their trade routes, and the modifier
-- table. Pure data plus one pure roll function; MissionService is the only thing
-- that touches a Player or a save.
--
-- Safety is a static 0-1 rating derived from each city's Personality (Busy cities
-- are safer than War-Torn ones). PlayerActive is the player's own delivery count
-- to that city (Progress.Routes). Routes are placeholders: only Qarzin is a built
-- city, the rest are markers.
--
-- Wire contract: every modifier MissionService sends the client (in a
-- MissionBoard destination's `modifiers` and in MissionUpdate's `modifiers`) is
-- `{ key, name, chance, text }`: `key` is a ModifierRoll's internal key (matched
-- by the client's greying logic and ModifierFailed updates) and `name` is
-- `displayName`. Never send the key as `name`: the client matches its Time
-- Crunch/Courier Loop special-cases and every pop-out title on it.

export type CityKey = "Qarzin" | "Sahraqin" | "IllegalPort" | "AinJamala" | "Saleh" | "Rathole" | "JaddatysHut"

export type City = {
	key: CityKey,
	name: string, -- display name
	color: { r: number, g: number, b: number }, -- 0-1
	lore: string, -- flavour text
	image: string, -- rbxassetid:// - every city shares one placeholder
	personality: string, -- display only
	safety: number, -- 0-1; > Config.Missions.SafeRouteThreshold = "SafeRoute"
}

export type ModifierDef = {
	key: string, -- the internal name (e.g. "TimeCrunch") - what MissionService compares against, and the wire "key" field
	displayName: string, -- e.g. "Time Crunch"; the client matches modifier pop-outs by this, not the internal key
	-- The roll WEIGHT among the eligible pool (RollModifiers), not a true
	-- percentage: the real odds depend on which other modifiers are eligible.
	-- Sent to the client as-is; label it a weight.
	chance: number,
	text: string, -- the pop-out description
	payMultiplier: number, -- 1 = no change; "Nothing" has none, it's the empty draw
	-- Only the keys present are checked (meetsReqs); a def need not name both
	-- factors.
	requires: { PlayerActive: boolean?, SafeRoute: boolean? }?,
}

export type ModifierRoll = {
	key: string,
	displayName: string,
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

local routes: { [string]: { string } } = {
	Qarzin = { "AinJamala", "IllegalPort", "Sahraqin", "Saleh" },
	Sahraqin = { "AinJamala", "Qarzin" },
	IllegalPort = { "Qarzin", "Saleh" },
	AinJamala = { "Sahraqin", "Qarzin" },
	Saleh = { "Qarzin", "IllegalPort", "Rathole", "JaddatysHut" },
	Rathole = { "Saleh", "JaddatysHut", "Sahraqin" },
	JaddatysHut = { "Saleh", "Rathole", "Sahraqin" },
}
Cities.Routes = routes

-- Delivery drop zone part names: Workspace.MAP.MISSION.<key>Delivery.
function Cities.DeliveryPartName(key: string): string
	return key .. "Delivery"
end

-- ==================== modifiers ====================
-- An ordered array (not a dictionary) so the weighted roll below is deterministic
-- and testable. "Nothing" is the empty draw: it occupies a roll like any
-- modifier, so real modifiers do not always win a slot, but is never handed back
-- to a caller.

local modifiers: { ModifierDef } = {
	{ key = "TimeCrunch", displayName = "Time Crunch", chance = 20, payMultiplier = 1.2, text = "Complete in 3:00." },
	{
		key = "CourierLoop",
		displayName = "Courier Loop",
		chance = 10,
		payMultiplier = 1,
		text = "Deliver the package and then return with another.",
	},
	{
		key = "HighlyValuable",
		displayName = "Highly Valuable",
		chance = 10,
		payMultiplier = 1.5,
		text = "You are carrying something valuable, protect it.",
		requires = { SafeRoute = true },
	},
	{ key = "HeavyCargo", displayName = "Heavy Cargo", chance = 3, payMultiplier = 1.3, text = "The package is heavy." },
	{
		key = "VIP",
		displayName = "Very Important Noble",
		chance = 1,
		payMultiplier = 2,
		text = "Protect them to the next city, they are important and will draw attention.",
		requires = { PlayerActive = false, SafeRoute = false },
	},
	{
		key = "FragilePackage",
		displayName = "Fragile Package",
		chance = 20,
		payMultiplier = 1.3,
		text = "You are carrying something fragile, don't get into a fight.",
	},
	{
		key = "CleartheRoute",
		displayName = "Clear the Route",
		chance = 3,
		payMultiplier = 1.5,
		text = "The route is dangerous, your Broker has requested you clear the way.",
		requires = { SafeRoute = false },
	},
	{ key = "Nothing", displayName = "", chance = 40, payMultiplier = 1, text = "" },
}
Cities.Modifiers = modifiers

-- Only the keys a def's own `requires` names are checked.
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
-- returns an integer in [1, max] (math.random in production, a canned sequence in
-- the self-test). Draw one (always, weighted by `chance` among the eligible pool,
-- "Nothing" included); 50% chance to draw a second from what is left; if a second
-- was drawn, 30% chance of a third. Each pick leaves the pool. "Nothing" draws
-- are never added to `selected`.
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
				if def.key ~= "Nothing" then
					table.insert(selected, {
						key = def.key,
						displayName = def.displayName,
						chance = def.chance,
						text = def.text,
						payMultiplier = def.payMultiplier,
					})
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

-- Pure: the combined pay multiplier for a set of rolled modifiers, ADDITIVE: `1 +
-- sum(payMultiplier - 1)`. TimeCrunch (1.2) and HeavyCargo (1.3) together give
-- 1.5x, not 1.56x. A bare mission with none rolled is exactly 1x.
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

--!strict
-- Combat tuning numbers. Data only, frozen; the one bit of logic is the
-- track-to-real-seconds conversion below, run once at load. CombatService,
-- MovementService, StatusService and HealthService read these numbers.
--
-- Every hit is a Light: it lands, applies LightStun (target can't block or
-- parry but can still attack or dash). Any landed hit interrupts the target's
-- own in-progress attack, including a chain frozen between clicks; Stun,
-- TrueStun and Knocked interrupt too. Each weapon is a Style: a chain of hits
-- plus style traits.
--
-- Timings (windupAt, cancelUntil, hitWindow, loopOffset) are authored in
-- ANIMATION-TRACK seconds and divided by Config.Combat.ComboSpeed[styleName]
-- at load, so the exported Styles hold REAL seconds since each segment's
-- start. Change ComboSpeed in Config to speed a combo up or down.
--
-- Every hit is one click. windupAt, cancelUntil and hitWindow are measured
-- from the start of that hit's own segment: hit 1's starts at AttackStart,
-- later hits' at the accepted AttackContinue click. The client freezes the
-- animation at each later hit's start until that click.
--
-- The chain loops (hit 1, hit 2, hit 1, ...) while clicks keep coming, and
-- the animation freezes ON the punch. A later hit's segment starts with the
-- previous punch's follow-through. Every pass of hit 1 after the first starts
-- with the last hit's follow-through; that length is `loopOffset`, which the
-- server adds to hit 1's windupAt/cancelUntil/hitWindow (the client's cancel
-- check mirrors it).
--
-- Style fields: cancelInto is "Any" (free to act after a cancel) or "Jab"
-- (the server starts chain[1] as a feint; if it lands blocked, the attacker
-- takes feintRecoverySeconds of Recovery). speedMult/dashCooldownMult scale
-- walk/run speed and dash cooldown while equipped. bleed is
-- {damagePerStackPerSecond, seconds, maxStacks} or nil; it ticks each second,
-- floors at 1 HP, and a new stack resets its duration.
--
-- Retuning rules: each cancelUntil must leave a human time to read the swing,
-- and each hitWindow.min must fall after that hit's windupAt.
--
-- ComboStep stays 1 as a character attribute; there is no combo-step chain.

local Config = require(script.Parent.Parent.Config)

export type HitWindow = {
	min: number,
	max: number,
}

export type ChainHit = {
	name: string,
	windupAt: number,
	cancelUntil: number,
	hitWindow: HitWindow,
	damage: number,
	range: number,
	radius: number,
	lightStun: number,
	blockDrain: number,
	bleedStacks: number,
}

export type BleedTrait = {
	damagePerStackPerSecond: number,
	seconds: number,
	maxStacks: number,
}

export type Style = {
	displayName: string,
	cancelInto: "Any" | "Jab",
	feintRecoverySeconds: number?,
	speedMult: number,
	dashCooldownMult: number,
	bleed: BleedTrait?,
	loopOffset: number,
	chain: { ChainHit },
}

local Combat = {}

-- Authored in ANIMATION-TRACK seconds; converted to real seconds below.
local Styles: { [string]: Style } = {
	Fist = {
		displayName = "Fist",
		cancelInto = "Any",
		speedMult = 1.0,
		dashCooldownMult = 1.0,
		loopOffset = 0.5,
		chain = {
			{
				name = "Jab",
				windupAt = 0.0,
				cancelUntil = 0.05,
				hitWindow = { min = 0.35, max = 0.65 },
				damage = 4,
				range = 4.5,
				radius = 1.6,
				lightStun = 0.9,
				blockDrain = 15,
				bleedStacks = 0,
			},
			{
				name = "Cross",
				windupAt = 0.5,
				cancelUntil = 0.5,
				hitWindow = { min = 0.85, max = 1.15 },
				damage = 4,
				range = 4.5,
				radius = 1.6,
				lightStun = 0.9,
				blockDrain = 15,
				bleedStacks = 0,
			},
		},
	},

	Dagger = {
		displayName = "Royal Dagger",
		cancelInto = "Jab",
		feintRecoverySeconds = 0.5,
		speedMult = 1.10,
		dashCooldownMult = 0.75,
		bleed = {
			damagePerStackPerSecond = 1,
			seconds = 4,
			maxStacks = 3,
		},
		loopOffset = 0,
		chain = {
			{
				name = "Stab",
				windupAt = 0.025,
				cancelUntil = 0.025,
				hitWindow = { min = 0.0625, max = 0.1125 },
				damage = 3,
				range = 5,
				radius = 1.5,
				lightStun = 0.8,
				blockDrain = 10,
				bleedStacks = 1,
			},
			-- Segments 2 and 3: measured from their own click.
			{
				name = "Slash",
				windupAt = 0,
				cancelUntil = 0,
				hitWindow = { min = 0.0375, max = 0.0875 },
				damage = 3,
				range = 5,
				radius = 1.5,
				lightStun = 0.8,
				blockDrain = 10,
				bleedStacks = 1,
			},
			{
				name = "Lunge",
				windupAt = 0,
				cancelUntil = 0.0625,
				hitWindow = { min = 0.15, max = 0.2375 },
				damage = 3,
				range = 5,
				radius = 1.7,
				lightStun = 0.8,
				blockDrain = 10,
				bleedStacks = 2,
			},
		},
	},
}

-- Track seconds -> real seconds, once. A style with no ComboSpeed entry plays
-- at 1x.
for styleName, style in Styles do
	local speed = (Config.Combat.ComboSpeed :: { [string]: number })[styleName] or 1
	style.loopOffset /= speed
	for _, hit in style.chain do
		hit.windupAt /= speed
		hit.cancelUntil /= speed
		hit.hitWindow.min /= speed
		hit.hitWindow.max /= speed
	end
end
Combat.Styles = Styles

-- Every landed hit adds 1 to the target's HitCount attribute; on the
-- `everyHits`th hit one impulse fires away from the attacker and CombatEvent
-- KnockedBack fires. The count resets after `resetAfterSeconds` without a hit
-- and on knockout.
Combat.Knockback = {
	everyHits = 6,
	resetAfterSeconds = 3,
	impulse = 40,
}

Combat.Block = {
	parryWindow = 0.25,
	-- Minimum seconds between parries per combatant.
	parryCooldown = 1.5,
	-- TrueStun length on a block break.
	breakStun = 3.0,
	-- WalkSpeed multiplier applied by MovementService while Block holds.
	blockSpeedMult = 0.6,
}

Combat.Dash = {
	cooldown = 1.2,
	distance = 18,
	duration = 0.25,
	-- MovementService sweeps a sphere of castRadius along the dash and stops
	-- wallMargin short of a hit; a dash shorter than minDistance doesn't happen
	-- and costs no cooldown.
	castRadius = 1.2,
	wallMargin = 1.5,
	minDistance = 1,
}

Combat.Run = {
	speedMult = 1.75,
}

Combat.Knockout = {
	getUpSeconds = 8,
	healthOnGetUp = 0.25,
}

table.freeze(Combat.Knockback)
table.freeze(Combat.Block)
table.freeze(Combat.Dash)
table.freeze(Combat.Run)
table.freeze(Combat.Knockout)
for _, style in Combat.Styles do
	for _, hit in style.chain do
		table.freeze(hit.hitWindow)
		table.freeze(hit)
	end
	table.freeze(style.chain)
	if style.bleed then
		table.freeze(style.bleed)
	end
	table.freeze(style)
end
table.freeze(Combat.Styles)

-- The named weapon set's style (e.g. "Fist"), or nil if unknown.
-- CombatService uses this to resolve a combatant's WeaponSet attribute.
function Combat.styleFor(name: string): Style?
	return Combat.Styles[name]
end

table.freeze(Combat)

return Combat

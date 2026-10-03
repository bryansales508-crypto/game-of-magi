--!strict
-- Combat tuning numbers (M3-01/M3-FIX3-S/M3-FIX4-S/M3-FIX7-S, TRIAGE #10/#13).
-- Data only, frozen (the one bit of logic is the track-to-real-seconds
-- conversion below, run once at load). Bryan tunes the feel by editing the
-- numbers below; CombatService/MovementService/StatusService/HealthService
-- read them, they never own a copy of their own.
--
-- M3-FIX7-S (Bryan, 2026-10-02): the Light/Heavy framework is gone. Every
-- hit is a Light: it lands, applies LightStun (the target can't block or
-- parry, but CAN still attack or dash) and nothing else - no full Stun, no
-- flinch. ANY landed hit interrupts the target's own in-progress attack
-- (including a chain frozen between clicks), so a chain loops for as long as
-- the clicks come and ends when the defender blocks, parries, dashes away or
-- hits first; Stun/TrueStun/Knocked (block break, parry, knockout) interrupt
-- too. Each weapon is a Combat.Style: a chain of hits plus style traits.
--
-- ONE SPEED KNOB. The authored timings below (windupAt, cancelUntil,
-- hitWindow, loopOffset) are ANIMATION-TRACK seconds - the times the
-- animation editor shows. At module load they are divided by
-- Config.Combat.ComboSpeed[styleName], so the exported Combat.Styles holds
-- REAL seconds since each segment's start, which is what CombatService and
-- the client read. To make a combo faster or slower, change ComboSpeed in
-- Config; never hand-convert numbers here.
--
--   chain      - in order. Each ChainHit:
--     name          - display/log name.
--     windupAt      - seconds since the segment start the wind-up marker
--                      plays.
--     cancelUntil   - seconds since the segment start until which
--                      AttackCancel is still honoured for THIS hit, while
--                      it's still the next unlanded one.
--     hitWindow     - {min, max}: seconds since the segment start inside
--                      which this hit's AttackHit report is accepted (+/-
--                      Config.Combat.HitTolerance either way).
--     damage/range/radius - damage, and the server's own forward hit-check
--                      sphere (range/radius).
--     lightStun     - LightStun duration on a landed hit.
--     blockDrain    - block HP a facing, holding block loses to THIS hit
--                      if it's blocked (not parried).
--     bleedStacks   - Bleed stacks a landed hit adds (0 = none); only
--                      meaningful for a style with a `bleed` trait.
--   cancelInto       - what a successful AttackCancel turns into: "Any"
--                      (free to block/attack/dash next, no extra cooldown)
--                      or "Jab" (the server immediately starts chain[1] as a
--                      new attack flagged feint=true; if THAT lands blocked,
--                      not parried, the attacker pays feintRecoverySeconds of
--                      Recovery - can't attack/block/dash - for
--                      overcommitting the bait).
--   speedMult/dashCooldownMult - MovementService.SetStyle multiplies the
--                      walk/run baseline and the dash cooldown by these
--                      (1.0 = no change) while this style is equipped.
--   bleed            - {damagePerStackPerSecond, seconds, maxStacks} or
--                      nil for a style with no bleed hits. HealthService
--                      ticks it once a second; never knocks out on its own
--                      (floors at 1 HP). Refreshed (duration reset, not
--                      extended) on every new stack.
--   loopOffset       - see M3-FIX6 below.
--
-- M3-FIX5 (Bryan, 2026-09-30): one click per hit. Every hit's windupAt,
-- cancelUntil and hitWindow are measured from the start of THAT HIT'S OWN
-- SEGMENT, not from the first click: hit 1's segment starts at Swing
-- (AttackStart accepted); hit 2's starts when the player's second click
-- (AttackContinue) is accepted, and so on. The client freezes the combo
-- animation at each later hit's start until that click. The pacing between
-- hits (gap, timeout, recovery) is Config.Combat.Chain, shared by every
-- style.
--
-- M3-FIX6 (Bryan, 2026-10-01): the animation freezes ON THE PUNCH (not at
-- the next wind-up) and the chain LOOPS: hit 1, hit 2, hit 1, hit 2, ...
-- for as long as the clicks keep coming. So every segment after the first
-- starts with the PREVIOUS punch's follow-through (the track resumes from
-- the frozen punch), then the live hit's wind-up, then its punch: a later
-- hit's windupAt is the track time from the frozen punch to its wind-up
-- marker (it can be that follow-through's length). Hit 1 is special: its
-- first segment starts at the animation's very start, but every LATER pass
-- of hit 1 starts with the LAST hit's follow-through before the track wraps
-- - that length is the style's `loopOffset`, and the server adds it to hit
-- 1's windupAt/cancelUntil/hitWindow on every pass after the first (the
-- client's cancel check mirrors that).
--
-- Keep two things true whenever these numbers are retuned against a real
-- animation: every hit's own cancelUntil should give a human enough time
-- to actually read the swing and decide whether to bait or commit; and
-- every hit's hitWindow.min must fall after that hit's own windupAt, so an
-- AttackHit report is never valid before its wind-up has even finished
-- playing (every entry below already satisfies that).
--
-- ComboStep is kept as a character attribute for compatibility but stays 1 -
-- there's no combo-step chain to advance through, just the one style's own
-- chain.

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
		-- Punch2's follow-through: track 1.5s -> 2.0s (the end) before the
		-- loop wraps into WindUp1.
		loopOffset = 0.5,
		chain = {
			-- Bryan's Fist animation (rbxassetid://104341608277955), keyframes
			-- read off the asset 2026-10-01: WindUp1 0.0s, Punch1 0.5s, WindUp2
			-- 1.0s, Punch2 1.5s, end 2.0s (track time).
			--
			-- Segment 1 (from Swing): WindUp1 on the first frame, Punch1 at
			-- track 0.5.
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
			-- Segment 2 (from the click, frozen on Punch1 at track 0.5):
			-- WindUp2 at track 1.0, Punch2 at track 1.5.
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

	-- M5: the Royal Dagger's style. Present now so the data shape is
	-- exercised, but nothing grants "Dagger" as a WeaponSet yet outside
	-- `.weapon Dagger` (M3 keeps everyone on Fist by default).
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
		-- Unknown until Bryan makes the Dagger combo animation; the old swing
		-- it plays today has no measured follow-through. The chain numbers
		-- below are PLACEHOLDERS (now read as track seconds, and divided by
		-- Config.Combat.ComboSpeed.Dagger) until that animation exists.
		loopOffset = 0,
		chain = {
			{
				name = "Stab",
				windupAt = 0.10,
				cancelUntil = 0.10,
				hitWindow = { min = 0.25, max = 0.45 },
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
				hitWindow = { min = 0.15, max = 0.35 },
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
				cancelUntil = 0.25,
				hitWindow = { min = 0.60, max = 0.95 },
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

-- M3-FIX4-S: knockback is no longer per-hit (no hit knocks back on its own) -
-- instead every landed hit (from any source) adds 1 to the target's own
-- HitCount attribute; on the `everyHits`th hit, one impulse fires (away
-- from whoever landed that hit), CombatEvent KnockedBack fires, and the
-- count resets to 0. The count also resets on its own after
-- `resetAfterSeconds` without a further hit, and on knockout.
Combat.Knockback = {
	everyHits = 6,
	resetAfterSeconds = 3,
	impulse = 40,
}

-- Blocking and parrying (SYSTEMS 9: 0.25s parry window on every Block(true),
-- the parry-cap bug (AUDIT M2) fixed by CombatService never adding block
-- above HealthService's MaxBlock). M3-FIX4-S: the flat drainPerHit is gone -
-- every ChainHit carries its own blockDrain now.
Combat.Block = {
	parryWindow = 0.25,
	-- AUDIT H5: no duplicate parry markers / endless parries. CombatService
	-- enforces this cooldown per combatant between parries.
	parryCooldown = 1.5,
	-- TrueStun length on a block break (old: fixed 3s task.delay).
	breakStun = 3.0,
	-- WalkSpeed multiplier applied by MovementService while Block holds.
	blockSpeedMult = 0.6,
}

Combat.Dash = {
	cooldown = 1.2,
	distance = 18,
	duration = 0.25,
	-- Bryan (2026-09-30), no wall flings: MovementService sweeps a sphere of
	-- castRadius studs along the dash first and stops the dash wallMargin
	-- studs short of whatever it hits; a dash that would move less than
	-- minDistance doesn't happen (and costs no cooldown).
	castRadius = 1.2,
	wallMargin = 1.5,
	minDistance = 1,
}

-- Old runspeed was 28 against a 16 base walk (SYSTEMS 8): 28/16 = 1.75.
Combat.Run = {
	speedMult = 1.75,
}

-- Getting up from a knockout (old: DamageHandler's math.random(3,5) seconds,
-- health set to 1; the new Knockout.getUpSeconds/healthOnGetUp are fixed,
-- tunable numbers instead of a random old range).
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

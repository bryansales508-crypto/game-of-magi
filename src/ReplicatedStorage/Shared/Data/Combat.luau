--!strict
-- Combat tuning numbers (M3-01/M3-FIX3-S/M3-FIX4-S, TRIAGE #10/#13). Data
-- only, frozen: nothing in here runs any logic. Bryan tunes the feel by
-- editing the numbers below; CombatService/MovementService/StatusService/
-- HealthService read them, they never own a copy of their own.
--
-- M3-FIX4-S (Bryan, 2026-09-28) replaced the flat "Moves" swing/punch shape
-- with a fighting-style framework: every weapon is a Combat.Style - a
-- chain of hits, each Light or Heavy, plus style-level traits. This is the
-- rock-paper-scissors basis for every future weapon, not just Fist/Dagger.
--
--   chain      - in order. Each ChainHit:
--     kind          - "Light" (fast, can't be interrupted, small damage,
--                      NO knockback of its own - see Combat.Knockback
--                      below; a landed Light applies LightStun for
--                      lightStun seconds: the target can't block or parry,
--                      but CAN still attack or dash) or "Heavy" (slow,
--                      readable wind-up, big damage, big block drain;
--                      while a combatant's next unlanded hit is a Heavy,
--                      ANY hit landing on them interrupts their attack -
--                      AttackCancelled reason="interrupted" - a Light's
--                      own wind-up carries no such risk).
--     windupAt      - seconds since Swing the wind-up marker plays (the
--                      client slows the animation here, Config.Combat -
--                      client-only; the server never reads windupSpeed for
--                      timing, only for the client's own slow-down).
--     cancelUntil   - seconds since Swing until which AttackCancel is
--                      still honoured for THIS hit, while it's still the
--                      next unlanded one (a Light's own cancelUntil equals
--                      its windupAt; a Heavy's is partway into its own
--                      wind-up).
--     hitWindow     - {min, max}: seconds since Swing inside which this
--                      hit's AttackHit report is accepted (+/-
--                      Config.Combat.HitTolerance either way).
--     damage/range/radius - as before (range/radius describe the server's
--                      own forward hit-check sphere; not part of Bryan's
--                      own design shorthand, added here since the hit-
--                      check needs them - same numbers the old Fist/Dagger
--                      moves used).
--     stun          - full Stun (can't attack/block/dash) on a landed hit;
--                      0 for every Light in the data below - a Light's own
--                      LightStun is the separate, softer stun.
--     lightStun     - LightStun duration on a landed hit; 0 for Heavies
--                      (they use the full `stun` above instead).
--     blockDrain    - block HP a facing, holding block loses to THIS hit
--                      if it's blocked (not parried) - replaces the old
--                      flat Combat.Block.drainPerHit.
--     bleedStacks   - Bleed stacks a landed hit adds (0 = none); only
--                      meaningful for a style with a `bleed` trait.
--     windupSpeed   - client-only: the animation's speed during this
--                      hit's own wind-up, as a MULTIPLIER on the style's
--                      Config.Combat.ComboSpeed (1 = no slowdown, 0.5 =
--                      half speed). Bryan 2026-09-30: a Heavy's slow
--                      should be barely noticeable but enough to punish.
--                      Retune that hit's hitWindow whenever this changes
--                      (slower wind-up = the hit marker arrives later).
--   cancelInto       - what a successful AttackCancel turns into: "Any"
--                      (free to block/attack/dash next, no extra cooldown)
--                      or "Jab" (the server immediately starts chain[1] -
--                      always a Light - as a new attack flagged feint=true;
--                      if THAT lands blocked, not parried, the attacker
--                      pays feintRecoverySeconds of Recovery - can't
--                      attack/block/dash - for overcommitting the bait).
--   speedMult/dashCooldownMult - MovementService.SetStyle multiplies the
--                      walk/run baseline and the dash cooldown by these
--                      (1.0 = no change) while this style is equipped.
--   bleed            - {damagePerStackPerSecond, seconds, maxStacks} or
--                      nil for a style with no bleed hits. HealthService
--                      ticks it once a second; never knocks out on its own
--                      (floors at 1 HP). Refreshed (duration reset, not
--                      extended) on every new stack.
--
-- M3-FIX5 (Bryan, 2026-09-30): one click per hit. Every hit's windupAt,
-- cancelUntil and hitWindow are measured from the start of THAT HIT'S OWN
-- SEGMENT, not from the first click: hit 1's segment starts at Swing
-- (AttackStart accepted); hit 2's starts when the player's second click
-- (AttackContinue) is accepted, and so on. The client freezes the combo
-- animation at each later hit's wind-up marker until that click, so a
-- later hit's windupAt is 0 (its wind-up begins the instant the click
-- lands) and a later Light's cancelUntil is 0 too (the pause before the
-- click is the decision point - a cancel there is always honoured). The
-- pacing between hits (gap, timeout, recovery) is Config.Combat.Chain,
-- shared by every style; the old per-style recovery/timeout are gone.
--
-- Keep two things true whenever these numbers are retuned against a real
-- animation: every hit's own cancelUntil should give a human enough time
-- to actually read the swing and decide whether to bait or commit; and
-- every hit's hitWindow.min must fall after that hit's own windupAt, so an
-- AttackHit report is never valid before its wind-up has even finished
-- playing (every entry below already satisfies that).
--
-- The numbers below are PLACEHOLDERS - Bryan re-tunes them once he reads
-- the real wind-up/hit marker times off his animations with `.combat log
-- on`. Old numbers this replaces (M3-FIX3-S's flat Swing/Punch shape, and
-- before that SYSTEMS 9 / DamageHandler's 3-step Jab/Cross/Finisher combo):
-- both had every weapon set as one server-timed shape with no Light/Heavy
-- distinction, no feints, no bleed, and knockback on every hit instead of
-- the count-based Combat.Knockback below. ComboStep is kept as a character
-- attribute for compatibility but stays 1 - there's no combo-step chain to
-- advance through, just the one style's own chain.

export type HitWindow = {
	min: number,
	max: number,
}

export type HitKind = "Light" | "Heavy"

export type ChainHit = {
	name: string,
	kind: HitKind,
	windupAt: number,
	cancelUntil: number,
	hitWindow: HitWindow,
	damage: number,
	range: number,
	radius: number,
	stun: number,
	lightStun: number,
	blockDrain: number,
	bleedStacks: number,
	windupSpeed: number,
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
	chain: { ChainHit },
}

local Combat = {}

local Styles: { [string]: Style } = {
	Fist = {
		displayName = "Fist",
		cancelInto = "Any",
		speedMult = 1.0,
		dashCooldownMult = 1.0,
		chain = {
			-- Bryan's Fist animation at ComboSpeed 1.6 (read off the marker
			-- log 2026-09-30): WindUp1 at +0.07s, Punch1 at +0.30s.
			{
				name = "Jab",
				kind = "Light",
				windupAt = 0.07,
				cancelUntil = 0.07,
				hitWindow = { min = 0.20, max = 0.45 },
				damage = 4,
				range = 4.5,
				radius = 1.6,
				stun = 0.0,
				lightStun = 0.9,
				blockDrain = 15,
				bleedStacks = 0,
				windupSpeed = 1.0,
			},
			-- Segment 2: measured from the second click. The wind-up starts
			-- at the click (windupAt 0), slowed by windupSpeed; cancel is
			-- honoured a little way into it. WindUp2 -> Punch2 is 0.36s of
			-- track time: at 1.6 x 0.6 that's Punch2 at +0.38s.
			{
				name = "Heavy",
				kind = "Heavy",
				windupAt = 0,
				cancelUntil = 0.15,
				hitWindow = { min = 0.25, max = 0.55 },
				damage = 12,
				range = 4.5,
				radius = 1.6,
				stun = 0.8,
				lightStun = 0,
				blockDrain = 45,
				bleedStacks = 0,
				windupSpeed = 0.6,
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
		chain = {
			{
				name = "Stab",
				kind = "Light",
				windupAt = 0.10,
				cancelUntil = 0.10,
				hitWindow = { min = 0.25, max = 0.45 },
				damage = 3,
				range = 5,
				radius = 1.5,
				stun = 0.0,
				lightStun = 0.8,
				blockDrain = 10,
				bleedStacks = 1,
				windupSpeed = 1.0,
			},
			-- Segments 2 and 3: measured from their own click.
			{
				name = "Slash",
				kind = "Light",
				windupAt = 0,
				cancelUntil = 0,
				hitWindow = { min = 0.15, max = 0.35 },
				damage = 3,
				range = 5,
				radius = 1.5,
				stun = 0.0,
				lightStun = 0.8,
				blockDrain = 10,
				bleedStacks = 1,
				windupSpeed = 1.0,
			},
			{
				name = "Lunge",
				kind = "Heavy",
				windupAt = 0,
				cancelUntil = 0.25,
				hitWindow = { min = 0.60, max = 0.95 },
				damage = 8,
				range = 5,
				radius = 1.7,
				stun = 0.7,
				lightStun = 0,
				blockDrain = 35,
				bleedStacks = 2,
				windupSpeed = 0.6,
			},
		},
	},
}
Combat.Styles = Styles

-- M3-FIX4-S: knockback is no longer per-hit (a Light never knocks back at
-- all; a Heavy's own "big damage" doesn't need its own impulse either) -
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
-- every ChainHit carries its own blockDrain now (a Heavy costs far more
-- meter than a Light).
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

-- The Stagger status's own short hit-stun feel (Combat.Stagger.hitStun),
-- distinct from a full Stun/LightStun status: it's what MovementService's
-- "Hit" speed modifier and StatusService's "Hit" status duration use.
-- M3-FIX4-S: applies to a landed HEAVY hit only now - a Light's own
-- LightStun already carries its own (softer) feel, with no extra flinch.
Combat.Stagger = {
	hitStun = 0.35,
}

table.freeze(Combat.Knockback)
table.freeze(Combat.Block)
table.freeze(Combat.Dash)
table.freeze(Combat.Run)
table.freeze(Combat.Knockout)
table.freeze(Combat.Stagger)
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

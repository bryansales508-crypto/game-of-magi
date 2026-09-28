--!strict
-- Combat tuning numbers (M3-01/M3-FIX3-S, TRIAGE #10/#13). Data only,
-- frozen: nothing in here runs any logic. Bryan tunes the feel by editing
-- the numbers below; CombatService/MovementService/StatusService read them,
-- they never own a copy of their own.
--
-- M3-FIX3-S (Bryan, 2026-09-28) replaced the old multi-move combo chain
-- with animation-driven punches: one weapon set is now ONE swing
-- (Combat.Swing), and one swing contains several punches (Combat.Punch) -
-- for Fist, a right then a left, both thrown by the same click. The client
-- plays one swing animation with a wind-up marker and a hit marker per
-- punch, and fires one AttackHit report per hit marker; the server is the
-- only one that decides whether that report is on time.
--
--   punches   - in order. Each punch's `hitWindow = {min, max}` is how many
--               seconds after CombatEvent Swing fires the server will
--               accept that punch's AttackHit report; outside it (even by
--               Config.Combat.HitTolerance either way) the report is
--               dropped. damage/stun/knockback apply on a landed hit;
--               range/radius describe the server's own hit-check sphere,
--               same convention as before (a sphere cast forward from the
--               attacker; knockback is a speed added away from the
--               attacker).
--   cancelWindow    - seconds after Swing during which AttackCancel is
--                      still honoured (only before punch 1 has landed).
--                      This is meant to line up with the animation's own
--                      first wind-up marker - Bryan cancels the swing
--                      before that marker plays.
--   cancelRecovery  - added to the cooldown after a successful cancel. 0
--                      (Bryan, 2026-09-28): a cancel costs nothing, so
--                      cancelling into an immediate re-swing is a real,
--                      punishing bait - see the comment above Moves.Fist.
--   recovery        - added to the cooldown after the LAST punch actually
--                      lands (accepted, whether it hit or whiffed).
--   timeout         - CombatService's own watchdog: if the final punch's
--                      AttackHit report never arrives by
--                      punches[#punches].hitWindow.max + HitTolerance +
--                      timeout, the attack just ends (client desync),
--                      silently, with no CombatEvent.
--
-- Old numbers this replaces (SYSTEMS 9 / DamageHandler / the pre-M3-FIX3-S
-- 3-step Jab/Cross/Finisher combo): every weapon set used to be an array of
-- combo steps, each fully server-timed (no client hit reports at all,
-- AUDIT C2). ComboStep is kept as a character attribute for compatibility
-- but stays 1 for now (M3-FIX3-S) - there's no combo chain to advance
-- through any more, just the one swing's punches.

export type HitWindow = {
	min: number,
	max: number,
}

export type Punch = {
	name: string,
	damage: number,
	range: number,
	radius: number,
	stun: number,
	knockback: number,
	hitWindow: HitWindow,
}

export type Swing = {
	name: string,
	punches: { Punch },
	cancelWindow: number,
	cancelRecovery: number,
	recovery: number,
	timeout: number,
}

local Combat = {}

local Moves: { [string]: Swing } = {
	-- M3-FIX3-S (Bryan, 2026-09-28): the read-and-punish loop this timing
	-- is built around -
	--   Player 1 swings. The enemy reads the Swing CombatEvent and clicks
	--   to interrupt back. Player 1 cancels (allowed only up to the first
	--   wind-up marker) to bait that click, then swings again and
	--   interrupts the ENEMY during the enemy's own wind-up - which the
	--   enemy can no longer cancel, since their own first wind-up marker
	--   has already passed by then.
	-- For that loop to work, keep three things true whenever these numbers
	-- are retuned against the real animation:
	--   1. cancelWindow (swing start -> first wind-up marker) must be long
	--      enough for a human to actually read the swing and react - about
	--      0.35s or more.
	--   2. Each punch's windup (its own wind-up marker -> its own hit
	--      marker) must be LONGER than a fresh swing's own start -> first
	--      hit time, so a counter-attack thrown once the wind-up is read
	--      still lands before the original punch does.
	--   3. Every punch's hitWindow.min must fall after cancelWindow (and
	--      after that punch's own wind-up), so an AttackHit report is never
	--      valid before the wind-up that's supposed to gate it has even
	--      finished playing.
	-- The numbers below satisfy rule 1 and rule 3 on paper; they are
	-- PLACEHOLDERS - Bryan re-tunes them once he reads the real wind-up/hit
	-- marker times off his fist animation with `.combat log on`.
	Fist = {
		name = "Fist",
		punches = {
			{
				name = "Right",
				damage = 5,
				range = 4.5,
				radius = 1.6,
				stun = 0.6,
				knockback = 12,
				hitWindow = { min = 0.75, max = 1.10 },
			},
			{
				name = "Left",
				damage = 6,
				range = 4.5,
				radius = 1.6,
				stun = 0.8,
				knockback = 18,
				hitWindow = { min = 1.30, max = 1.70 },
			},
		},
		cancelWindow = 0.35,
		cancelRecovery = 0,
		recovery = 0.30,
		timeout = 0.6,
	},

	-- M5: the Royal Dagger's swing. Present now so the data shape is
	-- exercised, but nothing grants "Dagger" as a WeaponSet yet (M3 keeps
	-- everyone on Fist). Same three rules as Fist's comment above; same
	-- placeholder caveat.
	Dagger = {
		name = "Dagger",
		punches = {
			{
				name = "Slash",
				damage = 6,
				range = 5,
				radius = 1.5,
				stun = 0.5,
				knockback = 10,
				hitWindow = { min = 0.65, max = 0.95 },
			},
			{
				name = "Reverse",
				damage = 7,
				range = 5,
				radius = 1.5,
				stun = 0.5,
				knockback = 12,
				hitWindow = { min = 1.05, max = 1.35 },
			},
			{
				name = "Finisher",
				damage = 11,
				range = 5,
				radius = 1.7,
				stun = 1.0,
				knockback = 42,
				hitWindow = { min = 1.45, max = 1.85 },
			},
		},
		cancelWindow = 0.35,
		cancelRecovery = 0,
		recovery = 0.28,
		timeout = 0.6,
	},
}
Combat.Moves = Moves

-- Blocking and parrying (SYSTEMS 9: 35 block drain per hit, 0.25s parry
-- window on every Block(true), the parry-cap bug (AUDIT M2) fixed by
-- CombatService never adding block above HealthService's MaxBlock).
Combat.Block = {
	drainPerHit = 35,
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
-- distinct from a full Stun/TrueStun status: it's what MovementService's
-- "Hit" speed modifier and StatusService's "Hit" status duration use.
Combat.Stagger = {
	hitStun = 0.35,
}

table.freeze(Combat.Block)
table.freeze(Combat.Dash)
table.freeze(Combat.Run)
table.freeze(Combat.Knockout)
table.freeze(Combat.Stagger)
for _, swing in Combat.Moves do
	for _, punch in swing.punches do
		table.freeze(punch.hitWindow)
		table.freeze(punch)
	end
	table.freeze(swing.punches)
	table.freeze(swing)
end
table.freeze(Combat.Moves)

-- The named weapon set's swing (e.g. "Fist"), or nil if unknown.
-- CombatService uses this to resolve a combatant's WeaponSet attribute.
function Combat.swingFor(name: string): Swing?
	return Combat.Moves[name]
end

table.freeze(Combat)

return Combat

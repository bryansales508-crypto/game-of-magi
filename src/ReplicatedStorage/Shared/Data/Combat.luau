--!strict
-- Combat tuning numbers (M3-01, TRIAGE #10/#13). Data only, frozen: nothing
-- in here runs any logic. Bryan tunes the feel by editing the numbers below;
-- CombatService/MovementService/StatusService read them, they never own a
-- copy of their own.
--
-- Move sets: each move is one step of a combo chain. Timings are seconds,
-- measured from the swing starting:
--   windup   - before the hit can land (plays the wind-up part of the swing)
--   hitTime  - when the server actually checks what got hit (from swing start)
--   recovery - after hitTime before another attack is allowed
--   comboWindow - how long after THIS move lands the next click still
--                 continues the combo (past it, the next click restarts at 1)
-- range/radius describe the server's hit-check shapecast (a capsule/sphere
-- cast forward from the attacker). knockback is a speed added along the
-- direction away from the attacker.
--
-- stun (0.6-1.0s, per move) is how long the FULL "Stun" status (can't
-- attack/block) lasts on a landed hit: StatusService.Apply(target, "Stun",
-- move.stun). This is separate from Combat.Stagger.hitStun below (a fixed,
-- much shorter 0.35s) - that one drives the "Hit" status/MovementService's
-- "Hit" speed modifier instead, the brief stagger every hit applies
-- regardless of which move landed (see Combat.Stagger's own comment).
--
-- Old numbers this replaces (SYSTEMS 9 / DamageHandler): flat 5 damage, 1s
-- stun, every 5th hit a 10x knockback multiplier, no real combo steps (the
-- client just replayed a 2-swing animation loop with no server timing at
-- all). The 3-hit Fist chain and the Dagger set (present for M5, not
-- granted to anyone yet) keep that same "every few hits hits harder" spirit
-- as a real finisher instead of an every-5th-hit roll.

export type Move = {
	name: string,
	windup: number,
	hitTime: number,
	recovery: number,
	damage: number,
	range: number,
	radius: number,
	stun: number,
	knockback: number,
	comboWindow: number,
	finisher: boolean?,
}

export type MoveSet = { Move }

local Combat = {}

local Moves: { [string]: MoveSet } = {
	Fist = {
		{
			name = "Jab",
			windup = 0.18,
			hitTime = 0.22,
			recovery = 0.30,
			damage = 5,
			range = 4.5,
			radius = 1.6,
			stun = 0.6,
			knockback = 12,
			comboWindow = 0.9,
		},
		{
			name = "Cross",
			windup = 0.18,
			hitTime = 0.22,
			recovery = 0.32,
			damage = 6,
			range = 4.5,
			radius = 1.6,
			stun = 0.6,
			knockback = 14,
			comboWindow = 0.9,
		},
		{
			name = "Finisher",
			windup = 0.22,
			hitTime = 0.28,
			recovery = 0.5,
			damage = 9,
			range = 4.5,
			radius = 1.8,
			stun = 1.0,
			knockback = 40,
			comboWindow = 0.9,
			finisher = true,
		},
	} :: MoveSet,

	-- M5: the Royal Dagger's combo. Present now so the data shape and
	-- Combat.move/moveSet API are exercised, but nothing grants "Dagger" as
	-- a WeaponSet yet (M3 keeps everyone on Fist).
	Dagger = {
		{
			name = "Slash",
			windup = 0.14,
			hitTime = 0.18,
			recovery = 0.24,
			damage = 6,
			range = 5,
			radius = 1.5,
			stun = 0.5,
			knockback = 10,
			comboWindow = 0.85,
		},
		{
			name = "Reverse",
			windup = 0.14,
			hitTime = 0.18,
			recovery = 0.26,
			damage = 7,
			range = 5,
			radius = 1.5,
			stun = 0.5,
			knockback = 12,
			comboWindow = 0.85,
		},
		{
			name = "Finisher",
			windup = 0.2,
			hitTime = 0.26,
			recovery = 0.45,
			damage = 11,
			range = 5,
			radius = 1.7,
			stun = 1.0,
			knockback = 42,
			comboWindow = 0.85,
			finisher = true,
		},
	} :: MoveSet,
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
for _, moveSet in Combat.Moves do
	for _, move in moveSet do
		table.freeze(move)
	end
	table.freeze(moveSet)
end
table.freeze(Combat.Moves)

-- The named move set (e.g. "Fist"), or nil if unknown. CombatService uses
-- this to resolve a combatant's WeaponSet attribute into its moves.
function Combat.moveSet(name: string): MoveSet?
	return Combat.Moves[name]
end

-- One move by 1-based index within a set, wrapping combo steps that run
-- past the set's length back to 1 so ComboStep math never has to special-
-- case "off the end" itself.
function Combat.move(setName: string, index: number): Move?
	local set = Combat.Moves[setName]
	if set == nil or #set == 0 then
		return nil
	end
	local wrapped = ((index - 1) % #set) + 1
	return set[wrapped]
end

table.freeze(Combat)

return Combat

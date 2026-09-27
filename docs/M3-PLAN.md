# Milestone 3: Combat (plan for Bryan's approval)

Scope from the approved TRIAGE: movement and speed (#9), server combat (#10), client combat (#11), status effects (#13), training dummies (#20). The Royal Dagger auto-equip (#12) was already removed in M1. DESIGN says: a **server-authoritative fist**, the combo chain finished, the block-break feel tuned with Bryan, and bought weapons (M5) using the same system. Bryan's animations, sounds, particles, ragdoll and camera feel stay as they are.

## What the player will notice

- Combat feels the same (same swings, block, parry, dash, hit sounds and stagger) but the **server decides every hit**: range, timing, cooldowns, stun, block and parry windows. A modified client can no longer hit anyone on the map, stack dashes, or parry forever.
- The **fist combo is a real 3-hit chain** (two lights and a finisher with heavier knockback), with the timings in a config table so Bryan can tune the feel during the milestone. Fast clicking no longer multiplies hits.
- **Blocking works as intended:** a blocker is immune to the knockout while the block holds; block HP drains and breaks at 0 with the TrueStun; the parry window is 0.25 s with a cooldown; the parry cap bug is gone.
- **Dash works from the first second** (no need to punch first), including diagonals, with a server cooldown. Low health slows you immediately and restores fully.
- **The training dummies live in synced code.** The Target dummy chases, gives up at range, and starts again after losing a target or getting back up. Punching a dummy's pack or a player's weapon hits the character behind it.
- No leaked listeners or threads on respawn.

## Tasks

| ID | Task | Owner | Replaces (deleted when done) |
|---|---|---|---|
| M3-01 | **Shared combat data + StatusService** (server). `Shared/Data/Combat.luau`: move sets (Fist: 3-hit chain; Dagger data present for M5), damage, range, windup, recovery, stun, knockback, parry window and cooldown, block drain, dash cooldown and distance, all as editable numbers. `StatusService`: the one owner of Hit / Stun / Knocked / Ragdoll / Block / BlockBroken / TrueStun for players AND NPCs, with durations, safe removal, and character attributes (`Stunned`, `Knocked`, `Blocking`) for clients. Keeps writing the old `character.Effects` markers as a bridge for old readers until M5/M6. Fixes M18. | server-builder | `Services/EffectsService.server.luau` (server-side marker logic; the client visuals move to M3-06) |
| M3-02 | **MovementService** (server). One speed-modifier stack for players and NPCs (named multipliers, smallest wins, 0 = frozen), run and dash with server cooldowns and distance, low-health slow applied immediately and restored fully; writes WalkSpeed itself. Bridges the old `IntFold.MovementSpeed` for old readers until M5. Fixes H10, M4, M5, M6, D2. | server-builder | `RS/Modules/SpeedHandler.luau`, the speed and IntFold parts of `Interactions/InteractionsDesign.server.luau`, the `Running`/`Dash` remotes |
| M3-03 | **CombatService** (server, the core). Remotes carry intentions only: `Attack`, `Block(bool)`, `Dash(x, z)`, `Run(bool)`. The server validates state (alive, not stunned, not knocked, cooldown, combo step), runs the hit check itself at the move's hit time (a server-side shapecast from the attacker's hand, same reach as today), finds the character behind a weapon or pack, applies damage through `HealthService.TakeDamage`, knockback, stun and statuses, handles block drain, break and parry, and the knockout at 0 HP. NPC punches go through the same path. Broadcasts `CombatEvent` (swing, hit, blocked, parried, block broken, knocked, dash) so every client plays the right animation and effect. Fixes C2, H5, H6, M1, M2, M3/P2. | server-builder | `Interactions/InteractionsHandler.server.luau`, the rest of `InteractionsDesign.server.luau`, `Services/DamageHandler.luau`, `RS/Modules/Combat/WeaponHandler.luau`, remotes `Hit`, `Blocking`, `Parry`, `RagdollEvent`, `GetDamage` |
| M3-04 | **NpcService** (server), written fresh (Bryan, 2026-09-27: "Man was bad. Use behavior trees... NPCs should be treated like normal players but with obvious AI controllers"). A small `Shared/BehaviorTree.luau` (Selector, Sequence, Condition, Action, Cooldown nodes) and an `AiController` per NPC that ticks a tree: idle/wander, chase within 30 studs, give up beyond 40, attack within reach through CombatService, recover after a knockout, restart after losing the target. NPCs are combatants exactly like players: same StatusService, MovementService, CombatService and HealthService paths, keyed by character model. Dummy models stay in Workspace as art; the service finds them by the `NPC` tag or the `Workspace.NPC` folder. | server-builder | `RS/Modules/NPController.luau` (the old Studio-only `NPCFetch`/`Health` scripts are already deleted by Bryan) |
| M3-05 | **CombatController** (client). Input to intentions: M1 attack (respects the server's stun and cooldown attributes, no stacked listeners), F block, Q + direction dash, double-tap W run, right-click or jump cancels. Plays Bryan's swing animations locally on `CombatEvent` so they stay in sync with the server's timing. Fixes H6 (client side), L11. | client-builder | `SCS/Scripts/PhysicalHandler.client.luau` (its run/dash/attack input and animation parts) |
| M3-06 | **EffectsController** (client). Hit sounds and particles, stagger, hurt face trigger, parry and block-break effects, knockout blind screen and input freeze, ragdoll visuals through the existing `Ragdoll` module, run camera zoom, dash trail; all driven by `CombatEvent` and the status attributes. Same assets, same look. | client-builder | the client-facing half of `EffectsService`, the rest of `PhysicalHandler` |
| M3-07 | `PLAYTEST.md` M3 scenarios and the playtest: Bryan plays the feel (combo, block, parry, dash, dummies) and tunes `Config.Combat` numbers; the agent runs the cheat checks only (attack from across the map, click flood, dash stacking, parry spam, hitting a pack). | Bryan + lead + playtester | |

**Order:** M3-01 → M3-02 → M3-03 → M3-04 in one server session; M3-05 → M3-06 in one client session. Opus review for M3-03 (the security core) and M3-01; Sonnet for the rest.

**Contracts** (fixed now so both sides build in parallel):
- Client → server: `Attack()` (rate 6/s), `Block(bool)` (4/s), `Dash(x: number, z: number)` (2/s), `Run(bool)` (4/s). Nothing else; the client never reports what it hit.
- Server → client: `CombatEvent(kind: string, data: table)` with kinds `Swing {attacker, moveIndex}`, `Hit {attacker, target, moveIndex, finisher}`, `Blocked {target}`, `Parried {attacker, target}`, `BlockBroken {target}`, `Knocked {target, by}`, `Recovered {target}`, `Dash {character, x, z}`, `Run {character, on}`.
- Character attributes set by the server: `Stunned` (bool), `Knocked` (bool), `Blocking` (bool), `ComboStep` (number), `SpeedMult` (number), `NextAttackAt` (server clock).
- `Config.Combat` (numbers Bryan tunes) lives in `Shared/Data/Combat.luau`.

**Bridges kept until M5/M6:** `character.Effects` markers and `IntFold.MovementSpeed` Values for the old mission, region and market scripts. The legacy Stats/OnCharacter bridge is untouched.

**Save format:** no change.

**Bryan (2026-09-27):** plan approved; the old dummy scripts are deleted in Studio and NOT ported.

**Reminder of your open follow-ups** (`docs/FOLLOWUPS.md`): heartbeat sound, afterlife cutscene, viewport framing, and the Studio-only script deletions.

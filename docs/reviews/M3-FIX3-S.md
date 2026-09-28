CHANGES NEEDED

# REVIEW-M3-FIX3-S: animation-driven punches, interrupts, right-click cancel (server)

Branch `claude/m3-01-combat-status-mhf1a6` @ 4c24197, reviewed `git diff origin/main...` (7 files, all in scope).
Client contract checked against `claude/combat-controller-85cacr`; merge simulated with `git merge-tree`.

## check.sh
selene: 0 errors, 0 warnings, 0 parse errors. luau-lsp: 0 errors. PASS.

## Findings

**H1 (high) - the two branches both define `Config.Combat`; merged, the client's wins and `HitTolerance` disappears.**
`src/ReplicatedStorage/Shared/Config.luau:98-110`. The server adds `Config.Combat = {HitTolerance, WindupSpeed = 0.6}` after `Config.Health`; the client branch adds its own `Config.Combat = {Markers, LogMarkers, CancelFlashSeconds, WindupSpeed = 0.5}` after `Config.Npc`. `git merge-tree` merges them with NO conflict, giving two assignments (merged lines 98 and 173). The second one replaces the first, so `Config.Combat.HitTolerance` is nil. Then `AttackStart` errors while it arms the watchdog (after `Attacking = true` and `Swing` have already gone out), and `AttackHit`/`AttackCancel` error too. Every player ends up stuck with `Attacking = true`.
Fix: `git merge origin/claude/combat-controller-85cacr` (already reviewed and PASSED), then add `HitTolerance` (with its comment) to the ONE `Config.Combat` table and drop this branch's duplicate `WindupSpeed` block and extra `table.freeze(Config.Combat)`. Or the lead does the same when merging the second branch. Re-run check.sh on the merged tree.

**M1 (medium) - the "too late" self-test fails every time.**
`SelfTestService.luau:1362-1368`. When the late `AttackHit(2)` is sent, about 0.93 + 2.15 = 3.08 s have passed. The watchdog already ended the attack at 1.70 + 0.15 + 0.6 = 2.45 s, so `Attacking` is false and the check `Attacking == true` fails. The server code is fine; the test is wrong, and the playtester would see a false FAIL.
Fix: wait only until just past the window, measured from the swing start: `task.wait(p2.max + tolerance + 0.1 - <elapsed so far>)`. That is still before the watchdog (0.6 s of margin). Or check that `Attacking` is still true AND no `Hit` happened.

**L1 (low) - a death leaves `Attacking = true` on the body.** `CombatService.luau:888-892`: `Unregister` sets `entry.attack = nil` but not the attribute. It's harmless (a new character gets new attributes), but for tidiness call `clearAttack` when the character still exists.

**L2 (low) - stale NPC timers aren't tied to their own attack.** `CombatService.luau:787-791`: the `task.delay` closures call `AttackHit(character, index)` without checking `attackGeneration`. If an NPC is interrupted and swings again, an old timer could consume a punch of the new swing. With today's numbers that can't happen: the re-swing is at least 0.6 s later (stun plus cooldown), and a stale punch 1 needs it within 0.33 s. But it depends on those numbers. Fix: capture `entry.attackGeneration` and skip if it changed.

**L3 (low) - spam from cancelling and restarting.** With `cancelRecovery = 0`, a client can start and cancel at the remote limits of 4/s each. That sends up to 8 `CombatEvent`s per second to all players (fist animation plus Cancel highlight). It's bounded by the rate limit and it's Bryan's design. If playtests show griefing, a floor like `cancelRecovery = 0.1` or `AttackStart` at 3/s is enough. No gameplay advantage is gained (see below).

**N1 (nit)** `CombatService.luau:441`: the log prints `punch.name` twice ("with Right's Right"). **N2 (nit)** Dropped reports are logged only with `.combat log on` (no throttled Warn when it's off). That's acceptable, but SYSTEMS/TINKER say "throttled warn". **N3 (note for Bryan's tuning)** The client slows each wind-up (`WindupSpeed` 0.5), so the real hit-marker times are later than the animation's natural times. Read them from `.combat log on`, not from the animation editor.

## Verified OK
- **Punch reports:** a punch report is dropped if it is early (`< min - tol`), late (`> max + tol`), out of order, a duplicate, sent with no `AttackStart`, sent while dead, stunned, knocked, true-stunned or blocking, sent after an interrupt or cancel (the attack is gone), or sent after a teleport (`didNotTeleport` uses the real elapsed time). An `integer >= 1` finite index is validated.
- **Hit geometry:** unchanged (closest registered target, facing, line of sight).
- **Watchdog:** guarded by the generation number, so a stale watchdog can't end a later attack.
- **Interrupts:** a hit that lands (not a block or parry) interrupts the target with `AttackCancelled{interrupted}` and `NextAttackAt = now + that punch's stun`. Stun/TrueStun/Knocked turning on (`onStatusChanged`) interrupts too; a parry interrupts the parried attacker through its Stun.
- **Cancel:** accepted only with `nextPunch == 1` and `elapsed <= cancelWindow + tol`. `clearAttack(..., 0)` sets `NextAttackAt` to exactly now, and `AttackStart` checks `now < NextAttackAt`, so a new swing is accepted immediately (self-tested).
- **Cancel/restart loop:** leaves nothing behind (the attack is set to nil, the generation is bumped). Restarting resets the anti-teleport baseline AND `elapsed` together, so it grants no extra movement budget. Blocking stays impossible while attacking.
- **NPCs:** `Attack()` goes through the same `AttackStart`/`AttackHit` validation on timers and can be interrupted.
- **Contract with the client branch:** `AttackStart()`, `AttackHit(index)`, `AttackCancel()`; `Swing.punchCount`, `Hit.punchIndex`, `AttackCancelled.reason`, the `Attacking` attribute. All match what the client sends and reads (only Config conflicts, H1).
- **Data:** Fist has 2 punches (0.75-1.10 and 1.30-1.70), `cancelWindow` 0.35, `cancelRecovery` 0. The 3 rules and the loop comment are present, and every `hitWindow.min` is after `cancelWindow` (min - tol 0.60 > cancel + tol 0.50). Dagger has 3 punches. `HitTolerance` is 0.15.
- **Style and docs:** `--!strict`, Log only, `task.*`. SYSTEMS 9 and TINKER "Combat" are accurate apart from N2. `.combat log` prints elapsed times.

## For Bryan
1. The server now checks every punch report the client sends: right time, right order, once each, and never while stunned, blocking or after a cancel. The hit itself is still decided by the server.
2. Getting hit mid-swing cancels your swing. Right-click cancels only before the first wind-up, and costs nothing, so you can swing again at once.
3. Two fixes before merging: both branches added a `Config.Combat` table, and combined, the server's timing slack vanishes (every swing would get stuck). Also one self-test checks at the wrong moment and would falsely fail.

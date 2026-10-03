# REVIEW-M3-FIX7-S: CHANGES NEEDED

Branch `claude/m3-fix7-light-only-combat-fgtif7` (server side of the all-Light, interruptible, infinite-chain change).
`scripts/check.sh` on the branch ALONE: FAIL (1 luau-lsp error, `SwingTrack.luau:134`) - but only because the branch
is based on a commit from before M3-FIX7-C merged. With `origin/main` merged in, `check.sh` is PASS (selene 0, luau-lsp 0).
Main's client no longer reads `kind`, `windupSpeed` or `Config.Combat.WindupSpeed` (grepped), so the field names agree.

## Findings

1. **MEDIUM - Mohammed's self-cancel will often be rejected by the server.** `Trees.luau` (mohammedDecide, the `segmentAt` /
   `FIST_HIT2_CANCEL_UNTIL` block). He waits until `cancelUntil` (0.5/1.5 = 0.33s) AFTER first seeing `CurrentHitIndex == 2`,
   but the AI only ticks every 0.2s (`Config.Npc.TickSeconds`), so the real time since the segment began is 0.33s plus 0..0.4s
   of tick lag. `CombatService.AttackCancel` refuses anything later than `cancelUntil + HitTolerance` (0.33 + 0.15 = 0.48s), so
   many cancels silently fail, the hit 2 goes through, and the "feint" never happens. Fix: cancel on the first tick that sees
   hit 2 (like Dalila does), or cancel at `cancelUntil - TickSeconds`. The self-test (`pollUntil(2, ...)`) is loose enough to hide it.
2. **LOW - stale `Heavy` comment in code.** `CombatService.luau:85` still says "interrupts a target whenever a HEAVY lands on them".
   `MissionService.luau:19` still says "not just the Heavy-only `Hit` status". Also `CombatService.luau:19-25` header comment has one
   over-long line (`...interrupts too (block break, parry, knockout). Cancel is per-hit...`); reflow it.
3. **LOW - stale docs.** `docs/SYSTEMS.md:200` (`HitLanded (target, attacker, kind...)` should be `hitName`), `:315` (still lists
   `Config.Combat.WindupSpeed`), `:318` (`Hit {..., kind, ...}` and `Miss {..., kind}` should be `hitName`), `:281` (describes Heavy
   as current rules; it is marked superseded but is long and contradictory). `docs/TINKER.md:60` still says the client slows
   wind-ups "by that hit's `windupSpeed`". COMBAT-DESIGN.md has no leftover Heavy wording.
4. **INFO - branch base is stale.** Merge `origin/main` before/at merge time (no conflicts; clean merge, check.sh PASS).

## Verified OK

- **Combat.luau:** divides `windupAt`, `cancelUntil`, both `hitWindow` bounds and `loopOffset` by `ComboSpeed[style]` once at load
  for every style (nil ComboSpeed -> 1x); the freeze loop runs after conversion; `Config` does not require `Combat` (no cycle).
  Fist = Jab {0.0, 0.05, 0.35-0.65}, Cross {0.5, 0.5, 0.85-1.15}, loopOffset 0.5 - matches keyframes. `hitWindow.min > windupAt`
  for all hits (Fist, Dagger) before and after conversion. `kind/windupSpeed/stun/HitKind/Stagger/WindupSpeed` have no reader left in `src/`.
- **CombatService:** `interruptAttack(target)` in ApplyHit is unconditional and works while `waitingForContinue` (`entry.attack` is
  set for both); it clears `Attacking`/`CurrentHitIndex`, pays `Chain.Recovery`, fires `AttackCancelled reason="interrupted"`. No double
  cancel: it is a no-op once `entry.attack` is nil, and the NPC `attackGeneration` stops stale timers. "Hit" stagger is gone;
  `HitLanded` fires (with `hit.name`) before the knockout early-return; `CurrentHitIndex` is a number on Swing/Continue and nil in
  clearAttack (the single end path, so landed-last, dropped, cancelled, interrupted, knockout, respawn) and in Register. `.combat`
  dev print updated. Timing still validated against the server clock with `HitTolerance`.
- **Trees:** Jamal (any attack start), Pete (`== 1`), Dalila (dash on any attack; self-cancel at index 2), Sam/Tariq/Sinbad unchanged;
  `wasHit` now reads `LightStun`, which every landed hit applies. No tree waits on a phase that can no longer happen.
- **Self-tests:** interrupt-mid-chain and interrupt-between-segments tests exist; stun-path test kept; block-break count derived from
  `MaxBlock / blockDrain`; conversion test present; trainer tests match; nothing asserts a removed field.

## For Bryan
1. The server change is right: every hit is a Light, any landed hit interrupts a mid-attack target (even one waiting for its next click).
2. The timing numbers are now in animation seconds and divided by ComboSpeed once; Fist matches your keyframes.
3. One real bug: Feinting Mohammed's cancel is often too late for the server (AI tick lag) - small fix in `Trees.luau`.
4. A few stale comments/doc lines still mention Heavy/`kind`; cosmetic. Merge main into the branch before merging it.

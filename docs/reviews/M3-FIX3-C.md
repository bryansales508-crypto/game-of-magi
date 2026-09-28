PASS

check.sh (branch `claude/combat-controller-85cacr`): selene 0 errors / 0 warnings / 0 parse errors; luau-lsp analyze 0 errors.

Scope: only `Shared/Config.luau`, `CombatController/init.luau`, `EffectsController/init.luau` touched (matches task); last commit `DONE M3-FIX3-C: ...`.

## Findings

1. **LOW** `CombatController/init.luau:486-493` — the per-punch Hit marker handler has no client-side de-dup: if `GetMarkerReachedSignal` for a Hit marker ever fires twice in one swing (bad animation authoring, engine edge case), `AttackHit(hitIndex)` fires twice. Not exploitable — M3-FIX3-S documents dropping duplicate/out-of-order reports server-side — but a defensive guard (track fired indices in `SwingState`, early-return on repeat) would keep `.combat log` clean once Bryan is tuning real marker names. Fix: add `hit: {[number]: boolean}` to `SwingState`, check/set it before firing.

## Verified against spec
- Security: only `AttackStart()` / `AttackHit(index: integer)` / `AttackCancel()` ever fired; no damage/target sent; nothing plays before the server's `Swing` (`tryAttackStart` only fires the remote).
- Cancel/interrupt rules match exactly: wind-up marker stops the track locally only on `Stunned`/`Knocked`; right-click/jump sends `AttackCancel` only before `firstWindupReached` and never stops the track itself; `AttackCancelled` stops the local track for both reasons (`stopSwing(0.1)`); EffectsController flashes `Cancel` Highlight for `CancelFlashSeconds` on "cancelled" and plays stagger + stops the fist track on "interrupted" (per the fuller C-prompt step 6, which explicitly adds the stop-track call — matches).
- `Config.Combat.Markers`/`LogMarkers` match the spec's placeholder names and comment exactly; `KeyframeReached` and every configured marker log `"marker: <name> at <t>s"`.
- Robustness: marker connections created per swing, disconnected via the idempotent `stopSwing` on track-end, cancel, and `CharacterRemoving`; other characters' swings get no special handling here (pre-existing, unchanged pattern — animations replicate on their own); miss sound correctly keyed off `punchCount`/`Hit.punchIndex`.
- `--!strict` on both files, `task.*` only (no bare `wait`), `Log` only (no raw `print`), tracked connections throughout.
- `Remotes.Client.Fire` on `AttackStart`/`AttackHit`/`AttackCancel` (not yet declared pending M3-FIX3-S) fails soft via `Remotes.luau`'s existing `log:Error` + return, confirmed pre-existing behavior — no hard error until the server branch merges.

## For Bryan
The client now plays one fist animation per click and reports each punch off that animation's own wind-up/hit markers, instead of a single server-timed swing. Right-click still cancels, but only in the split-second before the animation's first wind-up point — after that the punch always finishes. One low-severity, non-blocking suggestion (defensive duplicate-hit guard); everything else matches your design and passes checks.

## Refinement round (lead review, 2026-09-28, commit 91ab7bb): PASS
Wind-up slowed to `Config.Combat.WindupSpeed` (0.5) between each wind-up marker and its hit marker, restored on hit/cancel/stop; no gating after a cancel (re-reads `NextAttackAt`, which the server sets to now); duplicate hit markers ignored via `swing.hit[index]`. Lint clean. Client branch ready; merges with M3-FIX3-S.

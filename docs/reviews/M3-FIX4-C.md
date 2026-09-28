# REVIEW-M3-FIX4-C

**Verdict: PASS**

`scripts/check.sh` on `claude/combat-controller-85cacr` (b2da982): selene 0 errors/0 warnings/0 parse errors; luau-lsp analyze 0 errors. `[check.sh] PASS`.

Files touched (matches task scope, nothing else): `Shared/Config.luau`, `CombatController/init.luau`, `EffectsController/init.luau`.

## Checks

**(a) Security** — Client fires only `AttackStart`, `AttackHit(index)`, `AttackCancel`, `Block`, `Dash`, `Run` (verified every `Remotes.Client.Fire` call site). The swing track only plays from `onLocalSwing`, called solely off the server's `Swing` CombatEvent — nothing plays on click. The Royal Dagger clone was decompiled and inspected directly: its instance tree is only `Model > Part/MeshPart/SurfaceAppearance/WeldConstraint` — no `Tool`, no `Script`/`LocalScript`/`ModuleScript` anywhere in it, so it's confirmed visual-only with no server effect.

**(b) Data-driven** — Chain, marker names, `windupSpeed`, and `cancelUntil` are all read from `Combat.Styles[WeaponSet]` via `styleHitData`/`windupSpeedFor`, with `typeof` guards rather than hardcoded shape assumptions (correct defensive stance since `Combat.Styles` isn't in `Shared/Data/Combat.luau` yet — M3-FIX4-S is still in progress). Markers are keyed per style in `Config.Combat.Markers.{Fist,Dagger}`, and the swing loop (`for hitIndex, name in markers.Hit`) iterates the chain, not a fixed count — a 3-hit style (Dagger) works the same as a 2-hit one.

**(c) Rules** — Cancel gate (`tryCancelAttack`, init.luau:451-474) correctly branches Light (gated on `windupReached[nextIndex]`) vs. Heavy (gated on `os.clock() - startedAt > cancelUntil`), never stops the track locally. Input gating (`isIncapacitated`/`canBlock`) matches: LightStunned leaves Attack/Dash open but blocks Block; Recovering blocks everything the same as Stunned/Knocked/TrueStunned. Wind-up slowdown is per-hit via `windupSpeedFor`, and reset to speed 1 both on each Hit marker and in `stopSwing`. A feint replays as an ordinary `Swing` from hit 1 — no special-casing needed.

**(d) Visuals** — Dagger grip: decompiled the cloned `Royal Dagger.rbxm` (Model, no Tool) and confirmed only cosmetic parts, consistent with "visual only". The grip `CFrame.new(0, -1.5, -0.8) * CFrame.Angles(math.rad(-45), 0, 0)` matches the old `RS/Modules/Combat/WeaponHandler.luau`'s `weaponInfo["Royal Dagger"].gripC0` byte-for-byte (verified via `git show a70f9ae:.../WeaponHandler.luau`). **However**, the comment at init.luau:703-705 cites the source as `git show 862c195:...` — that SHA does not exist anywhere in this repo's history (`git rev-list --all` has no match, not even as a prefix). The real commit is `a70f9ae` (or its content-identical predecessor). Fix the citation so it's actually checkable. Shown for own and other characters, keyed off the `WeaponSet` attribute, removed on style change, and never double-cloned (`daggerToolByCharacter[character]` guard). Bleed particles/decal scale `Rate` off each template's own authored base rate × stacks, removed at 0, also driven by the `Bleed` attribute directly (catches late-attached controllers). `KnockedBack` reuses the existing hit particle only — correctly no camera shake was added, since the old `CameraShaker` module lives under `ServerStorage/Parked` (unused). Light hits play no stagger; Heavy hits do (`onHit`'s `isHeavy` branch).

**(e) Leaks/respawn/style** — `--!strict` on both files, no bare `print`/`wait()`, tracked/idempotent `stopSwing`, weak-keyed per-character caches, particles parented under the character so they die with it. `Bleed`/`KnockedBack` CombatEvent kinds aren't restricted by any enum in `Remotes.luau`, so they're a true no-op today until M3-FIX4-S lands, as intended.

## Findings

| Sev | File:Line | Issue | Fix |
|---|---|---|---|
| Low | `CombatController/init.luau:703` | Comment cites `git show 862c195:...` as the source of the dagger grip CFrame; `862c195` isn't a real object in this repo (confirmed with `git rev-list --all`) — the actual (verified-matching) commit is `a70f9ae`. | Swap the cited SHA for `a70f9ae` (or `git log --all --oneline -- .../WeaponHandler.luau` and re-cite whichever commit is intended) so the provenance claim is checkable. |

## For Bryan

This adds real fighting-style support: each weapon's punch/stab chain, timing, and wind-up speed now come from data instead of being hardcoded to two punches, so Dagger's 3-hit chain works the same way Fist's 2-hit one does. The Royal Dagger now visibly appears in the right hand (reusing your old grip position) whenever someone's using that style, purely for looks — it's not a real equippable weapon yet, that's M5. Bleed now shows droplets and a cut decal that get more intense with more stacks, and knockback reuses the old hit particle. One tiny paperwork fix needed: a code comment cites the wrong commit hash for where the dagger grip position came from (the actual number is right, just the "receipt" pointing to it is wrong) — one-line fix, not a behavior bug. Recommend: fix that comment, then this is ready to merge once the matching server branch (M3-FIX4-S) lands.

## Fix (lead, 2026-09-28, branch client-m3): PASS
The grip-provenance comment now cites a70f9ae. Client side ready; merges with M3-FIX4-S.

CHANGES NEEDED

# REVIEW-M3-FIX4-S: fighting-style framework (server)
Branch `origin/claude/m3-01-combat-status-mhf1a6` @ d9537fd, diff `main...branch`, 9 files (+1124/−427). All inside the task's files.

**check.sh:** selene 0 errors, 0 warnings, 0 parse errors; luau-lsp 0 errors. PASS.
**Merge with `origin/client-m3`:** `git merge-tree` is clean (no conflicts). The server branch doesn't touch `Shared/Config.luau`, so there are no duplicate definitions. The client's `Config.Combat.Markers.{Fist,Dagger}` sits next to the server's `Combat.Styles` without overlap.

## Findings

**H1 (high, contract).** `client-m3` CombatController `styleHitData` (init.luau:121) reads `Combat.Styles[style].hits`, but the server data is `.chain` (Shared/Data/Combat.luau:126). Every lookup returns nil, so on the client every hit falls back: Lights play at the flat `WindupSpeed = 0.5` (slowed like a Heavy), and a Heavy's cancel falls into the Light branch ("before its wind-up marker") instead of using `cancelUntil`. Fix (one line, on client-m3): `local hits = style.chain`.

**H2 (high, rules 3/4).** A blocked feint doesn't end the feinter's chain. In CombatService.luau:464-467, Recovery is applied but `entry.attack` stays live, and Recovery isn't in `INTERRUPTS_ATTACK` (:73). AttackHit only drops reports *while* Recovery lasts (:828). Example: Stab blocked at 0.35s gives Recovery until 0.85s; Slash reports up to 1.05s and Lunge (1.65s) are then accepted and land on the blocker who is trying to punish. Otherwise the attacker stays `Attacking` (can't block) until the 2.75s watchdog. Fix: on a blocked feint, `clearAttack(attacker, entry, 0)` and fire `AttackCancelled{reason="interrupted"}` (or add Recovery to `INTERRUPTS_ATTACK`). Add a self-test: after a blocked feint, `Attacking == false` and a hit-2 report is dropped.

**H3 (high, exploit: attack rate).** Cancelling is free (`clearAttack(...,0)` at :950), so "land hit 1, cancel hit 2, restart" skips the rest of the chain and its recovery:
- Fist: AttackStart right after the Jab lands. That's one Jab per ~0.35s with a normal client (~11 dps, and 16 dps at the AttackStart cap of 4/s) against the ~7 dps a full chain is designed to give.
- Dagger `cancelInto="Jab"`: this doesn't even need AttackStart. The feint's Stab can be reported at 0.10s (0.25 − HitTolerance), so the limit is AttackCancel's 4/s: 4 stabs/s with bleed, and knockback every 1.5s.

Fix: when cancelling after ≥1 landed hit, set `NextAttackAt = startedAt + chain[1].hitWindow.min` (or charge `style.recovery`), and have the feint path respect `NextAttackAt` (beginAttack already checks it, so setting it before the call is enough). Bryan should confirm the intended jab-cancel cadence.

**M1 (medium, design, flag to Bryan).** Permanent LightStun lock. Jab `lightStun` is 0.9s, longer than the 0.35s loop in H3, so the target never regains Block or parry while in range. There's no LightStun immunity or diminishing. The only breakers are the 6th-hit knockback (~10 studs), the target's own Light or dash, and a parry, which they can't do. Rule 1 allows this literally (they can still attack and dash), so I'd call it acceptable per design *only once H3 is fixed*. Ask Bryan whether he wants a short "can block again" immunity after N light-stuns.

**M2 (medium, rule 2).** A landed Heavy still interrupts a Light. `ApplyHit` applies `Stun` for `hit.stun > 0` (:574-575), and `onStatusChanged` interrupts on any Stun (:73, :289). So the kind check at :534-540 is bypassed whenever a Heavy lands during the target's Light. The comment at :529-531 says the opposite. Either drop Stun from interrupting while the pending hit is a Light, or document that Heavy stun overrides and get Bryan's OK. The self-test (SelfTest ~:1455) only lands a Light, so it doesn't cover this.

**L1 (low).** `HitCount` isn't reset on a knockout that doesn't come from `ApplyHit` (`.knock`, or any other `StatusService.Apply(...,"Knocked")`). Move `resetHitCount` into `onStatusChanged` when `status=="Knocked" and active` (:293).

**L2 (low).** Stale comment at CombatService.luau:915 says "Moves.Fist"; it should say `Combat.Styles.Fist`.

**L3 (low).** `ComboStep` is always 1 (:758, :1073). It's harmless, but the attribute could be dropped later with approval.

## Verified OK
- The previous review's checks all still hold: report order/duplicate (:808), window ± tolerance (:842/857), anti-teleport (:874), a watchdog per generation (:780), a stale NPC timer guard (:982), geometry/LOS/closest target, remote rate limits (Start 4/s, Hit 8/s, Cancel 4/s).
- The rules:
  - LightStun blocks Block and ends an active block, but doesn't block Attack or Dash.
  - Recovery blocks Attack, Block and Dash (MovementService `BLOCKS_DASH`).
  - The cancel check uses the next unlanded hit's `cancelUntil`.
  - The feint is flagged, and a parried feint gives the normal parry Stun.
  - Per-hit knockback is removed. HitCount counts every landed hit from any attacker (NPCs included), knocks back and fires `KnockedBack` on the 6th, and resets on knockback, on knockout via a hit, and after 3s.
  - Bleed is capped, refreshed on a new stack, ticks stacks × dmg per 1s tick, floors at 1 HP, never knocks out, and works for NPCs too.
  - `SetStyle` applies `speedMult` and `dashCooldownMult`.
- Exploits: `.weapon`/`.style` go through `DevService.Register`, so the server `IsDev` check applies. The style is server-only (`entry.weaponSet` and the `WeaponSet` attribute are set by the server, and no remote carries a style).
- Contract (apart from H1):
  - Events: `Swing{character,style,hitCount}`, `Hit{attacker,target,hitIndex,kind,feint}`, `Bleed{target,stacks}`, `KnockedBack{target}`.
  - Attributes: `LightStunned`, `Recovering`, `Bleed` (a number), `HitCount`, `WeaponSet`.
  - Per-hit fields: `kind`, `windupAt`, `cancelUntil`, `windupSpeed`, `hitWindow.min/max`.
- NPCs register as Fist and attack through the same `beginAttack`/`AttackHit`; there are no old Moves/punches callers left.
- Code: `--!strict`, Log only (no `print`), `task.*` only.
- Self-test covers every listed case.
- Docs: SYSTEMS §9 and TINKER "Combat" (including "How to add a weapon") are updated. §8, §10 and §15 got small wording fixes that match the change.

## For Bryan
1. The new rock-paper-scissors combat is mostly right. Bleed, hit-count knockback, dagger speed and the dev commands all work as you designed them.
2. There are three real problems. The client looks for the hit list under the wrong name (a one-word fix). A blocked dagger feint doesn't actually stop the rest of the combo. And "jab, cancel, jab" lets players attack much faster than a full combo is meant to.
3. After those are fixed, you should decide one thing: can a fast jabber keep someone from ever blocking, or do you want a short immunity?

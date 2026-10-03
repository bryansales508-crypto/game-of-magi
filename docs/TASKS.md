# Task board

Current phase: **Phase 5: Build. Phases 5A (currency) and 5B (clothing shop) merged 2026-09-29, awaiting Bryan's playtests; combat package (M3B) also awaiting his playtest** (see CLAUDE.md for all phases)

## Phase 1: Inventory and extract (done, gate passed 2026-09-26)

| ID | Task | Owner | Status | Acceptance criteria |
| --- | --- | --- | --- | --- |
| P1-01 | Inventory every script in the place (read-only) | playtester | done | Full path and class of every Script, LocalScript, and ModuleScript; scripts in Workspace flagged |
| P1-02 | Write default.project.json covering only code containers | lead | done | No Workspace; no asset-only containers; every inventoried script covered or listed as "not synced" |
| P1-03 | Bryan runs syncback on the copy; verify and commit | lead | done | File count in src/ matches the inventory (68 .luau + 10 inside .rbxm) |

## Phase 2: Understand (done, gate passed 2026-09-26)

| ID | Task | Owner | Status | Acceptance criteria |
| --- | --- | --- | --- | --- |
| P2-01 | Read the Studio-only scripts (10 inside .rbxm, plus the not-synced scripts that run) | playtester | done | Plain summary of each: what it does, remotes, requires, DataStores |
| P2-02 | Read every script in src/ | lead | done | Every .luau file read |
| P2-03 | Write docs/SYSTEMS.md | lead | done | Per system: purpose, files, depends on / depended on by, remotes, DataStore keys and data shapes, admin/dev commands; ends with a dependency list |

## Phase 3: Diagnose (done, gate passed 2026-09-26)

Bryan's direction: judge each system by what it was **meant** to do (comments, Trello board, DESIGN.md), not just what the code does now.

| ID | Task | Owner | Status | Acceptance criteria |
| --- | --- | --- | --- | --- |
| P3-01 | Full code audit: security, bugs, race conditions, leaks, dead code, performance, fragile patterns | reviewer | done | Every finding has file, line, severity, what's wrong, plain explanation |
| P3-02 | Playtest every system and capture every Output error and warning | playtester | done (stopped early; Bryan confirmed the rest) | Each system in SYSTEMS.md tried; every error/warning reported with repro steps |
| P3-03 | Write docs/AUDIT.md | lead | done | Findings with ID, severity, system, file:line, what's wrong, plain explanation |

## Phase 4: Triage (done, gate passed 2026-09-26)

| ID | Task | Owner | Status | Acceptance criteria |
| --- | --- | --- | --- | --- |
| P4-01 | Draft docs/TRIAGE.md | lead | done | One line per system with keep/fix/rewrite/remove and a reason tied to AUDIT.md / DESIGN.md |
| P4-02 | Bryan approves, vetoes or changes every line | Bryan | done | Every line approved; open questions answered |
| P4-03 | Turn approved TRIAGE.md into Phase 5 milestones | lead | done | Milestones and tasks in this file |

## Phase 5: Build

The milestones come from the approved TRIAGE.md, and each ends with a playtest and Bryan's approval. Task IDs are used in commit messages (`M1-03: ...`).

| Milestone | Scope (TRIAGE #) | Status |
| --- | --- | --- |
| M1 Foundation | Layout, data service (#1), remotes, join pipeline (#2), dev commands (#21), debug tools (#29), data wipe, parks and removals | **done (gate passed 2026-09-27)** |
| M2 A life | Creation (#3), aging, visible aging and death (#4), health (#14), menu (#18) | **done (gate passed 2026-09-27)** |
| M3 Combat | Movement (#9), status (#13), combat (#10, #11), dummies (#20), dagger removal (#12) | **done (gate passed 2026-09-27; feel tuning = Bryan follow-up)** |
| M4 Status and Rukh | Rank, alignment, epithets (#25), HUD (#17) | **done (gate passed 2026-09-28; tweaks = Bryan follow-up)** |
| M5 Economy and missions | Currency (#6), shop (#7), weapons (#28), delivery (#8), Bounty Hunting (#26) | todo |
| M6 World | Day/night and lights (#27), regions and music (#15), footsteps (#16), ocean (#23), collisions (#22), legacy bridge removal | **merged to main 2026-09-29** (M6-01 Opus-reviewed, M6-02 Sonnet PASS, lead fixes at merge); Bryan plays PLAYTEST "M6" A-E, tags city lights, deletes the ocean scripts |
| **Roadmap** | Restoration scorecard, renumbered milestones M7 close-out, M8 NPCs/tutorial, M9 bounties, M10 weapons, M11 bank/economy, M12 legacy, and the gameplay-loop draft: `docs/ROADMAP.md` (2026-09-29) | for Bryan |

### M1 Foundation: plan

**Key decisions:**
- **Layout:**
  - Server code lives in `ServerScriptService/Server`: one bootstrap script plus `Services/*` modules.
  - Client code lives in `StarterPlayerScripts/Client`: one bootstrap script plus `Controllers/*` modules.
  - Shared code lives in `ReplicatedStorage/Shared`: config, logger, remote definitions, and game data.
  - Parked code lives in `ServerStorage/Parked`.
  - Art, GUIs, sounds and models stay where they are.
- **Saves:** vendor **ProfileStore** (loleris, MIT; a widely used, session-locked save library) instead of hand-rolling session locks.
- **Legacy bridge:** until each old system is rebuilt in M2–M6, the data service also mirrors the save into the old `player.Stats` / `player.OnCharacter` Value folders and sets `player.Loaded`. That way the old scripts keep working. The bridge is deleted in the last milestone that needs it.
- **Studio safety:** play tests in Studio use a separate save scope (`Studio`), so they never touch live saves. `Config.Debug.FreshSave` gives a brand-new save on every run.

| ID | Task | Owner | Status | Acceptance criteria |
| --- | --- | --- | --- | --- |
| M1-01 | New folder layout and Rojo project update (`Server`, `Client`, `Shared`, `ServerStorage/Parked`) | server-builder | done | Rojo builds; old scripts still sync; new folders exist |
| M1-02 | Shared core: `Config` (with `Debug` flags auto-on in Studio), `Log` (tagged levels, no raw prints), `Remotes` registry (every remote declared once, with argument-type validation and per-player rate limits) | server-builder | done (2 Opus reviews, merged) | Unit-style self-check runs on server start; a bad remote call is rejected and logged, not errored |
| M1-03 | `DataService` on ProfileStore: one key, schema v1 (DESIGN §3a fields included), versioned migrations, session lock, save on leave and shutdown, Studio scope, FreshSave, wipe; plus the legacy bridge | server-builder | done (merged) | Join, change a value, rejoin: the value persists. Two servers can't load the same save. Old systems still work through the bridge. Old save scripts removed |
| M1-04 | Join pipeline: `PlayerService` runs load → character ready → spawn at `QarzinSpawn` → `Ready`, in order. The client loading screen waits on the server instead of racing it. Split: **M1-04S** (server: PlayerService, JoinState attribute, ClientReady remote, spawn placement; removes LocationHandler and Protection) and **M1-04C** (client: LoadController replaces the old Load script, same look) | server-builder + client-builder | done (merged; playtest pending) | No missed signal; spawns at QarzinSpawn every time; no kick during character creation; slow-load test passes |
| M1-05 | Dev tools: `DevService` (UserId check; commands for coins, age, Magoi, Rukh, bounty, teleport to any city, time scale, fresh save, `.state` dump to Output) plus a client **dev panel** and **debug overlay** (F8: live status, speed modifiers, save state). Split: **M1-05S** (DevService, `.cmd` commands, DevCommand/DevReply/DevState remotes) and **M1-05C** (F8 overlay, F9 dev panel) | server-builder + client-builder | done (merged; playtest pending) | Every command works in play; non-devs are rejected on the server; `.state` gives a readable dump the playtester can use instead of clicking around |
| M1-06 | Parks (K1–K3) and removals (R1–R9) from TRIAGE, including the dagger auto-equip and the hunger HUD bar | server-builder | done (R7, R8 left for Bryan in Studio) | Parked code doesn't run; removed files are gone; game still runs. (Studio-only removals R7/R8 are listed for Bryan) |
| M1-07 | `docs/PLAYTEST.md`: repeatable scenarios per system with exact dev-command setup, then the M1 playtest | lead + playtester | M1 playtest done: A, B, C, D, F, G, J PASS; I partial (BUG-04, low). E, H, K not run | Scenarios written; M1 playtest passes |
| M1-08 | Wipe the live debug data (Bryan approved) | lead | todo | Old `GameOfMagi_v0.01am` data no longer loaded; new store in use |

### M1 follow-ups noted by reviews
- selene: `roblox.yml` committed 2026-09-27 so cloud checks include style. Local selene on M1-02 code: see commit for counts.
- **Merge order for M1:** server branch (M1-03 + M1-04S + M1-05S) merges BEFORE the client branch (M1-04C + M1-05C). The new LoadController fires `ClientReady`, not the old `MainScreen`, so the old server scripts hang until M1-04S lands. (REVIEW-M1-04C)
- M1-04C: rename the unused `character` param to `_character` in LoadController (selene warning). Fold into the next client follow-up.
- M2 note (REVIEW-M1-04S F6, AUDIT M9): `AppearanceController:81` spins forever if the player leaves before Ready. Left as is for M1 (file is rebuilt in M2 #3).
- Lead approved after the fact (REVIEW-M1-04S F5): the builder's comment-only edits to vendored `Packages/ProfileStore.luau`; indentation restored in the fix round.
- REVIEW-M1-05S notes (self-test non-dev, position "n/a", shared spawn constant): fixed and merged.

### M2 A life: plan (approved by Bryan 2026-09-27; details in docs/M2-PLAN.md)

Bryan's additions: old-age death styled as a heart attack (every online birthday from 60: heartbeat + red pulse, then it passes; a fatal roll plays heavier and ends in the return-to-the-Rukh scene). Bryan supplies the old `AfterLife` model at `ReplicatedFirst.AfterLife` in Studio; the scene falls back to a stand-in without it.

| ID | Task | Owner | Status | Acceptance criteria |
| --- | --- | --- | --- | --- |
| M2-06 | Shared data: Ranks, Alignment, Epithets (DESIGN 3a) | server-builder | done (lead-reviewed, merged) | rankFor/alignmentFor/pick3 pass the self-test |
| M2-01 | CharacterService: appearance from the save, `CreateCharacter` remote, gender-matched names, fixes M8/P4/L2/L6/L3 | server-builder | done (merged) | New life shows the creation screen once; look identical to before; two players share one collision group |
| M2-02 | AgeService: 30 min/year (60 s Studio), offline 2/day capped at 59, growth kept, grey hair, heart-attack birthdays from 60, death roll, new life with Lives+1 | server-builder | done (merged) | `.birthday` ages and resizes; `.heart` / `.heart fatal` drive the client; a fatal roll ends in a fresh 13-year-old with Lives+1 |
| M2-03 | HealthService: max HP from height and rank, real regen tiers, block refill; attributes for the HUD/menu | server-builder | done (merged) | Height/rank change MaxHealth; `.tier` changes regen; bars follow |
| M2-04 | Client: CreationController, MenuController (rank/epithet/alignment, fixed stat line, live preview), HudController | client-builder | done (merged) | Same look; M menu shows the new fields; creation works through the remote |
| M2-05 | Client: RukhController (heart attack pulses, fatal message, return-to-the-Rukh scene with AfterLife or stand-in) | client-builder | done (merged) | `.heart` passes in ~1 s; `.heart fatal` plays the scene and respawns fresh |
| M2-07 | PLAYTEST.md M2 scenarios and the M2 playtest | Bryan + lead + playtester | playtest 1 done (Bryan A,C-I; agent B PASS, J blocked): E, H, I(title) pass; character build crash blocks the rest (BUG-09..16). Fix round M2-FIX merged; second pass done (A, C, D, I pass; BUG-17..22 logged). done: final check passed 2026-09-27 (Bryan) | All scenarios pass |

### M3 Combat: plan (approved by Bryan 2026-09-27; details in docs/M3-PLAN.md)

Bryan's rules: NPCs are combatants like players with AI controllers (behavior trees); the old dummy scripts are deleted, not ported; Bryan tunes feel numbers in `Shared/Data/Combat.luau` during the playtest.

| ID | Task | Owner | Status | Acceptance criteria |
| --- | --- | --- | --- | --- |
| M3-01 | Shared combat data + StatusService (markers, durations, attributes, `Effects` bridge) | server-builder | done (merged) | Self-test passes; old readers of `character.Effects` still work |
| M3-02 | MovementService (speed stack, run, dash with server cooldown, low-health slow, IntFold bridge) | server-builder | done (merged) | Dash from spawn incl. diagonals; second dash within cooldown rejected; hurt slows immediately |
| M3-03 | CombatService (server hit checks, combo chain, block/parry/break, knockout, NPC API, removals, footsteps kept alive) | server-builder | done (merged) | A client can't hit out of range or spam; blocker immune while block holds; 3-hit fist chain |
| M3-04 | NpcService + Shared/BehaviorTree + AiController (Dummy, Target trees) | server-builder | done (lead checked the fix; merged) | Target chases within 30, gives up at 40, punches within 4, restarts; NPCs take hits like players |
| M3-05 | CombatController (client input -> intentions; animations on server events) | client-builder | done (merged) | Same feel; no stacked listeners; no client-side hit reports |
| M3-06 | EffectsController (hit fx, parry/block-break, knockout blind + freeze, ragdoll visuals, dash trail, run zoom) | client-builder | done (merged) | Same sounds and particles as today |
| M3-07 | PLAYTEST.md M3 scenarios; Bryan plays the feel and tunes numbers; agent runs cheat checks only | Bryan + lead + playtester | agent cheat checks PASS; fix round merged; Bryan does the feel pass later (FOLLOWUPS) | Feel approved by Bryan; every cheat check rejected |
- **M3 merge gate (REVIEW-M3-02 finding 1):** the server branch removes the old `Running`/`Dash`/`Hit`/`Blocking` remotes, which the old InteractionsHandler and PhysicalHandler index at load. Merge the server branch only once M3-03 (deletes those server scripts) is in, and merge the client branch (M3-05 + M3-06, deletes PhysicalHandler) in the same push. Never sync a half state to Studio.

### M4 Status and Rukh: plan (approved by Bryan 2026-09-27; details in docs/M4-PLAN.md)

| ID | Task | Owner | Status | Acceptance criteria |
| --- | --- | --- | --- | --- |
| M4-01 | RankService (rank-up detection, pending epithet choice in the save, ChooseEpithet, AddMagoi/AddDeed API, attributes) + schema v2 | server-builder | done (merged) | `.magoi 300` sends RankUp with 3 choices; choice persists across rejoin; bad ChooseEpithet rejected; v1 save migrates to v2 |
| M4-02 | RankController: Rukh flutter in the alignment colour + epithet card (menu style), origin choice at birth | client-builder | done (merged) | Flutter and card on rank-up; 1/2/3 or click chooses; card returns if a choice is pending at join |
| M4-03 | PLAYTEST.md M4 scenarios; Bryan plays the moments, agent checks the remote | Bryan + lead + playtester | done: Bryan passed A-E 2026-09-28 after BUG-28; tweaks in FOLLOWUPS | All pass |
- **M3 combat flow change (Bryan, 2026-09-28):** one click = one fist animation with two punches driven by animation events; the client reports each hit marker; wind-ups are interruptible; right-click cancel only before the first wind-up, with the cancel highlight. Tasks M3-FIX3-S (server) and M3-FIX3-C (client), contracts in the prompts. M3-FIX3-C reviewed PASS and refined (lead-checked). M3-FIX3-S reviewed (Opus) and fixed; server + client merged 2026-09-28. Asymmetric jab/heavy plan proposed to Bryan 2026-09-28, awaiting his OK. Marker names are configurable (`Config.Combat.Markers`) and logged, since the animation can't be read from files. Bryan refinement (2026-09-28): no recovery after a cancel (instant re-attack), the wind-up plays slowed (`Config.Combat.WindupSpeed`) so the enemy can read it; intended loop: swing -> enemy swings to interrupt -> cancel to bait -> swing again and interrupt them mid wind-up.
- **Two-click combo (Bryan, 2026-09-30, M3-FIX5, built by the lead during Bryan's combat playtest, committed straight to main; needs an Opus review once the feel settles):** one combo animation per style, but one click per hit - after hit 1 lands the animation freezes at hit 2's wind-up marker until the next click (`AttackContinue`), times out otherwise; pacing in `Config.Combat.Chain`; every animation id moved into `Config.Combat`; Bryan's Studio edits to Config/CombatController folded into the files. Per-hit timings in `Combat.luau` are now measured from each hit's own click. Same day, second pass: the chain logic was driven off keyframe names too (Bryan's animation has no event markers), `NpcAnimController` + `SwingTrack` give every NPC the player's full animation set, `windupSpeed` became a multiplier on ComboSpeed (Heavy 0.6, Bryan: "barely noticeable, but sizable to punish"), and `Config.Character.Animations` holds the locomotion ids.
- **Freeze on the punch, looping chain, dash lines (Bryan, 2026-10-01, M3-FIX6, built by the lead during Bryan's playtest, committed straight to main; joins M3-FIX5 in needing an Opus review once the feel settles):** the combo animation freezes on each punch (not the next wind-up) and loops "1, 2, 1, 2, ..." for as long as the clicks keep coming, ending only by a drop/cancel/interrupt (or `AttackEnd` for an NPC's single pass); Fist `ComboSpeed` 1.6 → 1.3 with `Combat.luau` retuned off the asset's real keyframes, plus a per-style `loopOffset`; miss sound now server-driven (`CombatEvent Miss`); dash trail became `Config.Combat.DashTrail.Count` thin lines from random torso points.
- **All hits are Lights, interruptible, infinite chain (Bryan, 2026-10-02, M3-FIX7-S/C, cloud-built, Sonnet review PASS after one fix):** the Light/Heavy framework is removed (`kind`, `windupSpeed`, `stun`, `Combat.Stagger`, `Config.Combat.WindupSpeed` gone); Fist = Jab, Cross with identical stats; every landed hit applies LightStun and **interrupts the target's attack in progress** (also while frozen waiting for the next click); the chain is infinite unless the defender blocks, parries, dashes out, or lands a hit first. `Combat.luau` timings are authored in animation-track seconds and divided by `Config.Combat.ComboSpeed` at load, so ComboSpeed (Fist 1.5) is the one speed knob. `CurrentHit` -> `CurrentHitIndex` (number). Trainers retargeted: Jamal and Dalila react to any swing start, Pete to hit 1, Mohammed self-cancels on the first tick of his hit 2. Open: whether a landed hit should flinch (nothing applies the `Hit` status now); the Opus review of the whole combo package (FIX5-7) is still owed.
- **Playtest round 2026-10-02 (Bryan's M3B-A/B/J/K, M3-C/D notes; BUG-33..38):** lead-local fixes BUG-36 (hurt runner sped up), BUG-37 (dash shortens with low health), BUG-38 (engine 5 s auto-respawn cut the last-life Rukh scene; `Players.RespawnTime` pushed to `Config.Life.EngineRespawnSeconds`). Cloud: **M7-02** (client, merged) SwingTrack timer fallback so a style whose animation has no hit keyframes still lands (Dagger, BUG-34); **M7-01** (server, Sonnet review PASS, merged) new `RagdollService` folds `Services/EffectsService.server.luau` (deleted; the ROADMAP M7 close-out item) so knocked NPCs and trainers ragdoll (BUG-35), `.lock combat` wins over `UnlockedByDefault` (BUG-33), Dagger timings restored to pre-FIX7 real seconds. Left for Bryan's OK: delete the unused `ReplicatedStorage/Remotes/RagdollEvent` remote. `RagdollEvent` remote deleted 2026-10-03 (Bryan's OK). **Combat SHELVED (Bryan, 2026-10-03):** `docs/COMBAT-PLAN.md` not approved, M3-FIX8 not built; combat will be erased and redesigned from the top as its own milestone after everything else is complete. Until then: log combat bugs, don't fix them unless they break something outside combat. Bryan's next playtests: M5A, M5B, M5C, M6 (`docs/WHEN-HOME.md` items 3-5, 8).
- **Playtest round 2026-10-03 (M5A PASS; M5B/M5C/M6 notes; BUG-39..48, all merged):** **M7-03** (server, lead-checked) `DestinationPositionFor` per city with refuse+log on a missing part, `DevLocalCommand` remote forwards a dev's unknown chat command to their own client; **M7-04** (client, Sonnet review CHANGES NEEDED -> fixed, merged) hovered rack shows its E prompt, coin sound on every purse change, city colours and tracker anchor both read the server's `{r,g,b}`/`{x,y,z}` shape (the anchor used to sit at the world origin: BUG-46), modifier chips in their own row with one clamped description card at a time, beacon fades in/out every 45 s, FOV-proof tracker, `.region/.music/.lights` from chat, footstep distance fallback + `Config.World.Footsteps.Debug` (root cause of silent steps still unknown). **Bryan re-runs:** M5B-A/B, M5C-A/B/C/G, M6-A/C; M6-B after he tags `CityLight`.
- **Fighting styles (Bryan, approved 2026-09-28):** every weapon is a style = chain of Light/Heavy hits + traits (cancelInto, speed, dash cooldown, bleed). Rules: lights fast and uninterruptible, land -> LightStun (no block, may jab/dash); heavies slow, readable, interruptible, big drain; cancel until each hit's cancelUntil (Fist: into anything; Dagger: automatic feint jab, punishable if blocked); parry beats both; knockback only on the 6th hit taken (any source); Dagger lights apply Bleed. Tasks M3-FIX4-S / M3-FIX4-C. Sword etc. later on the same basis. Client reviewed PASS; server Opus review: 3 real fixes (blocked feint must end the chain, cancel after a landed hit charges the chain time, client key name), fixed and merged 2026-09-28 (styles round complete).
| M7 Talking NPCs and tutorial | Dialogue system, the alley teacher, the combat tutorial that unlocks combat (Bryan, 2026-09-28) | todo (after M6) |
- **M3B (stance, unlock, training dummies):** plan drafted 2026-09-28 in docs/M3B-PLAN.md, approved 2026-09-28 (lead decisions accepted). Prompts M3B-01..03.
- **Decisions (Bryan, 2026-09-28):** no LightStun immunity for now (outs: jab back, dash, 6th-hit knockback; revisit after feel); a landed Heavy interrupts a Light in progress; M3B plan approved. No agent playtests unless a check needs tooling; Bryan tests when home.

### M3B Stance, unlock, training dummies (approved 2026-09-28; docs/M3B-PLAN.md)

| ID | Task | Owner | Status | Acceptance criteria |
| --- | --- | --- | --- | --- |
| M3B-01 | Stance (`SetStance`, `InCombat` gating), tool-to-style mapping, unlock flag + schema v3, dev commands | server-builder | done (merged) | Clicks do nothing outside the stance, server-side; a weapon tool sets the style; locked players can't enter |
| M3B-02 | Seven trainer dummies (trees, `Config.Npc.Trainers`, `.dummy spawn|clear|list`, name billboards, reset after knockout) | server-builder | done (merged) | Each dummy does only its habit; spawn/clear work |
| M3B-03 | Client: `C` stance toggle, clicks only in stance, weapon-click enters combat, stance idle placeholders, locked message | client-builder | done (merged) | Same on every client; no style sent by the client |
| M3B-04 | PLAYTEST.md M3B scenarios (one per dummy); Bryan plays; agent only if a check needs tooling | Bryan + lead | scenarios drafted; Bryan plays when home | Bryan approves the feel |
| M3B-05 | Lives per character: `Character.LivesLeft` (4), ordinary death costs one and respawns, the last one runs the afterlife wipe, a fatal heart attack wipes regardless; `.lives`, `.kill` | server-builder | done (merged) | Rules hold in the self-test; Meta.Unlocks survives a new character |
| M3B-06 | Client: `Died {cause="lastLife"}` plays the Rukh scene without the heartbeat; overlay shows livesLeft | client-builder | done (merged) | Same scene, no pulses; no stacking |

### M5 Economy and missions, Phase 5A Currency (approved 2026-09-29; docs/M5-PLAN.md)

| ID | Task | Owner | Status | Acceptance criteria |
| --- | --- | --- | --- | --- |
| M5A-01 | `Shared/Data/Economy.luau` (1/100/10,000, whole-coin rounding rule) + `EconomyService` (wallet, exact-coin Pay, Give, reward rounding, attributes, coin messages; bridge stops writing the purse) | server-builder | done (merged) | Rounding table passes; 120 Copper cannot pay 1 Silver; purse follows attributes |
| M5A-02 | `CurrencyController`: the old purse HUD from attributes; coin messages posted as the character speaking | client-builder | done (merged) | Same look; messages show |
| M5A-03 | PLAYTEST.md 5A scenarios; Bryan plays | Bryan + lead | ready: Bryan plays when home | Bryan OK |

### Phase 5B Clothing shop (approved 2026-09-29)

| ID | Task | Owner | Status | Acceptance criteria |
| --- | --- | --- | --- | --- |
| M5B-00 | Read-only Studio dump of the stand model and the ClothingSpawn script for the builders | lead (agent) | done (106k Sonnet tokens) | `docs/reference/m5b-studio-dump.md` |
| M5B-01 | `Shared/Data/Shop.luau` + `ShopService` (stock the stand from data, server prompts, checks before charging, exact-coin Pay, wear through `ItemService`) + `ItemService` (old ItemHandler ported); old MarketHandler removed; the Studio-only script disabled at startup | server-builder | done (merged) | Same stock and look; no double charge; colour-aware ownership |
| M5B-02 | `ShopController`: hover highlight for the hovering player only; price on the prompt | client-builder | done (merged) | Only you see your highlight |
| M5B-03 | PLAYTEST.md 5B scenarios; Bryan plays | Bryan + lead | ready: Bryan plays when home | Bryan OK |
| M8 Missions | Bounty Hunting, Carriage Escort and other mission types, the bounty board (Bryan, 2026-09-29: pushed out of M5) | todo |
| M9 Weapons and gear | The Rathole blacksmith, several weapon types as fighting styles, gear with stats (Bryan, 2026-09-29: after multiple weapon types exist) | todo |

### Phase 5C Delivery missions (approved 2026-09-29; 5D deferred; 5E/5F -> M9/M8)

| ID | Task | Owner | Status | Acceptance criteria |
| --- | --- | --- | --- | --- |
| M5C-00 | Read-only Studio dump of the delivery board, city panels, delivery parts | lead (agent) | done (129k Sonnet tokens; lore turned out to live in code) | `docs/reference/m5c-studio-dump.md` |
| M5C-01 | `Shared/Data/Cities.luau` + `MissionService` (board per player, route check, modifiers from history/personality, package, timers, instant payout to an interceptor, courier beacon, streak/history, Magoi/Rukh) + schema v4; old mission scripts removed | server-builder | built (3add52f): Opus review + Sonnet re-review fixed, modifier failure only drops its bonus, permanent HighlyValuable beacon, the intercepted mark; reviewed three times (Opus, Sonnet x2), merged to main 0bc4507 | Full run, intercepted run, each modifier; no money printed; no loops left |
| M5C-02 | `MissionController`: the same board and panels, start button, tracker, modifier pop-outs and buttons fixed, timers, pay preview with modifiers, beacon visuals | client-builder | built (7e80623, lead-checked): ModifierFailed, return-leg failed list, intercepted notice; merged to main with M5C-01 | Same look; buttons work; panel only with a quest |
| M5C-03 | PLAYTEST.md 5C scenarios; Bryan plays | Bryan + lead | ready: Bryan plays A-G (G = the intercepted mark) | Bryan OK |

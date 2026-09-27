# Task board

Current phase: **Phase 5: Build, Milestone 2 (A life)** (M1 gate passed 2026-09-27; see CLAUDE.md for all phases)

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
| M2 A life | Creation (#3), aging, visible aging and death (#4), health (#14), menu (#18) | **planning** |
| M3 Combat | Movement (#9), status (#13), combat (#10, #11), dummies (#20), dagger removal (#12) | todo |
| M4 Status and Rukh | Rank, alignment, epithets (#25), HUD (#17) | todo |
| M5 Economy and missions | Currency (#6), shop (#7), weapons (#28), delivery (#8), Bounty Hunting (#26) | todo |
| M6 World | Day/night and lights (#27), regions and music (#15), footsteps (#16), ocean (#23), collisions (#22) | todo |

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
| M2-01 | CharacterService: appearance from the save, `CreateCharacter` remote, gender-matched names, fixes M8/P4/L2/L6/L3 | server-builder | re-reviewed: one small item left (collision group race) | New life shows the creation screen once; look identical to before; two players share one collision group |
| M2-02 | AgeService: 30 min/year (60 s Studio), offline 2/day capped at 59, growth kept, grey hair, heart-attack birthdays from 60, death roll, new life with Lives+1 | server-builder | fixes in, re-review running | `.birthday` ages and resizes; `.heart` / `.heart fatal` drive the client; a fatal roll ends in a fresh 13-year-old with Lives+1 |
| M2-03 | HealthService: max HP from height and rank, real regen tiers, block refill; attributes for the HUD/menu | server-builder | reviewed and fixed (lead checked the fix; merges with the server branch) | Height/rank change MaxHealth; `.tier` changes regen; bars follow |
| M2-04 | Client: CreationController, MenuController (rank/epithet/alignment, fixed stat line, live preview), HudController | client-builder | reviewed and fixed (client branch, merges after server) | Same look; M menu shows the new fields; creation works through the remote |
| M2-05 | Client: RukhController (heart attack pulses, fatal message, return-to-the-Rukh scene with AfterLife or stand-in) | client-builder | reviewed and fixed (lead checked the fix round; client branch, merges after server) | `.heart` passes in ~1 s; `.heart fatal` plays the scene and respawns fresh |
| M2-07 | PLAYTEST.md M2 scenarios and the M2 playtest | lead + playtester | todo | All scenarios pass |

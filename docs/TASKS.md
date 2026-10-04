# Task board

Current phase: **Phase 5: Build, M9 Bounty Hunting (M7 closed 2026-10-03).** Milestones M1 to M6 are done and playtested green (2026-10-03). Combat (M3 and M3B) is shelved for a from-scratch redesign after everything else. See CLAUDE.md for all phases; bugs live in `docs/BUGS.md`, the plan and loop draft in `docs/ROADMAP.md`.

## Phases 1 to 4 (all done, gates passed 2026-09-26)

| Phase | What | Status |
| --- | --- | --- |
| 1 Inventory and extract | Every script inventoried, `default.project.json` written, syncback checked into `src/` | done |
| 2 Understand | Every script read, `docs/SYSTEMS.md` written and corrected by Bryan | done |
| 3 Diagnose | Code audit plus a playtest of every system, findings in `docs/AUDIT.md` | done |
| 4 Triage | `docs/TRIAGE.md` approved line by line; it became the milestones below | done |

## Phase 5: Build

Each milestone ends with a playtest and Bryan's approval. Commit messages start with the task ID (`M5-02: ...`).

| Milestone | What it covers | Status |
| --- | --- | --- |
| M1 Foundation | Folder layout, saves on ProfileStore, remotes, join flow, dev commands, debug tools, parks and removals | done |
| M2 A life | Character creation, aging, visible aging, heart attacks and death, health, character menu | done |
| M3 Combat | Movement, status effects, server-checked combat, dummies | **shelved**: redesigned from scratch after M12 |
| M3B Combat package | Combat redesign pass: styles, parry and block, NPC fighters, effects | **shelved** with M3 |
| M4 Status and Rukh | Rank, alignment, epithets, Rukh flutter, HUD | done |
| M5 Economy and missions | Currency bands and exact-coin pay, Qarzin clothes shop, delivery missions with the intercepted mark | done (5D supply and demand deferred by Bryan to M11) |
| M6 World | Regions and music, day/night clock, footsteps, ocean, collisions | done |
| M7 Restoration close-out | Fold the last old scripts into the new controllers, strip embedded scripts, final regression pass | **done, gate passed 2026-10-03** |
| M8 to M12 | Talking NPCs and tutorial, bounties, weapons and gear, bank, legacy | not started (see "Next") |

## What is open (M7 close-out)

| Item | Detail | Owner |
| --- | --- | --- |
| Fold `StarterCharacterScripts/Scripts/InputHandler.client.luau` | Its input locks move into the new client controllers; the file is then deleted | done (M7-09-C: the input locks were dead, nothing wrote their markers; the file is deleted) |
| Fold `StarterPlayerScripts/BackpackGUI.client.luau` | The hotbar and backpack become a controller in `Client/Controllers`, same look | done (M7-09-C: `Controllers/HotbarController`, same look; the file is deleted) |
| Strip embedded GUI scripts | `Gender.Decisions`, `MenuMechanics` and the DeliveryFrame X-button script live inside `.rbxm` GUI files; they never run, but are still in the files | done as "destroyed at runtime": the controllers delete those scripts when they clone the GUI, so they never run; the `.rbxm` files stay untouched (Bryan's art) |
| `CityLight` tagging | Deferred by Bryan; lamps, torches and fires stay unlit until he tags them | Bryan |
| BUG-58 desert dash fling | Needs a repro: where Bryan was, and whether on a slope | Bryan |
| Silent footsteps | The original cause of the first silent-footsteps report is still unexplained | lead |
| Studio deletions | Done 2026-10-03; Bryan saves and publishes the place (see `docs/WHEN-HOME.md`) | Bryan |

**Restoration complete (lead, 2026-10-03; Bryan approved closing M7 the same day).** Every TRIAGE system is rebuilt or kept on the new services, every old script is folded or deleted (files and Studio), the comments and docs describe the game as it is, and M1 to M6 playtested green. Still open but not blocking: `CityLight` tags (deferred by Bryan), BUG-58 (needs a repro), the original silent-footsteps cause (steps work via the fallback). M7 is closed.

## Next (Bryan, 2026-10-03)

1. **Finish M7:** M7-09-C (cloud, running) folds `InputHandler.client.luau` and `BackpackGUI.client.luau` into the new controllers; then the "restoration complete" note.
2. **M9 Bounty Hunting + jail + carry** comes next: `docs/M9-PLAN.md` drafted, awaiting Bryan's answers and approval (bounty board and wanted list, picking up a knocked-out player and carrying them, the jail with a bounty-based sentence that survives rejoin).
3. **M8 Talking NPCs and tutorial:** SHELVED until the new combat exists (the tutorial teaches combat).
4. **Gameplay-loop conversation** (`docs/ROADMAP.md` section 4), one question at a time, when Bryan wants it.
4. **M10 Weapons and gear:** the Rathole blacksmith, weapons as items, gear stats, and the shelved dagger and jewelry kits (`assets/dagger-kit-roblox.zip`, `assets/jewelry-kit-roblox-r6.zip`, notes in `docs/reference/dagger-kit.md` and `docs/reference/jewelry-kit.md`).
5. **M11 Bank:** the money changer, then supply and demand once two shops exist.
6. **M12 Legacy:** what survives a death, a lives-lived record, a hall of past names.
7. **Combat redesign** from the top, after M12.

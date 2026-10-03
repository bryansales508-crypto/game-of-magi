# Task board

Current state: **Phase 5 (Build), milestone M7 close-out.** Bug history is in `docs/BUGS.md` and git; the long-range plan is `docs/ROADMAP.md`.

## Phases

| Phase | What | Status |
|---|---|---|
| 1 Inventory and extract | every script listed, Rojo project written, syncback verified | done |
| 2 Understand | `docs/SYSTEMS.md` | done |
| 3 Diagnose | `docs/AUDIT.md` | done |
| 4 Triage | `docs/TRIAGE.md` approved by Bryan | done |
| 5 Build | milestones below | in progress |

## Phase 5 milestones

| Milestone | Scope | Status |
|---|---|---|
| M1 Foundation | folder layout, saves (ProfileStore), remotes, join pipeline, dev tools, self-tests | done |
| M2 A life | creation, appearance, aging, death, health, menu | done |
| M3 Combat | movement, status, combat, dummies | built; **shelved** (redesign from scratch after M12); feel tuning dropped with it |
| M3B Stance and trainers | stance, unlock flag, seven trainers, lives per character | built; lives are live, the rest shelved with combat |
| M4 Status and Rukh | rank, alignment, epithets, HUD | done |
| M5A Currency | three coins, exact-coin payment | done (Bryan passed) |
| M5B Clothes shop | `ShopService`, `ItemService`, `ShopController` | merged; Bryan re-runs M5B-A/B |
| M5C Delivery missions | `MissionService`, `MissionController`, intercepted mark | merged; Bryan re-runs M5C-A/B/C/G |
| M6 World | regions, music, day and night, footsteps, collisions, ocean | merged; Bryan re-runs M6-A/C, M6-B once lights are tagged |
| M7 Restoration close-out | fold the last old scripts, bug rounds from Bryan's playtests, docs cleanup | **in progress** (below) |
| M8 Talking NPCs and tutorial | dialogue as data, the alley teacher, flavour NPCs | next, after the gameplay-loop talk |
| M9 Bounty hunting | bounty boards, wanted list, turn-ins | planned |
| M10 Weapons and gear | blacksmith, weapons as styles, gear stats | planned |
| M11 Bank and world economy | money changer, supply and demand | planned |
| M12 Legacy | what survives a death, lives lived record | planned |
| Combat redesign | erase and rebuild combat from the top | after M12 |

## What is open (M7 close-out)

- Fold `StarterCharacterScripts/Scripts/InputHandler.client.luau` into a controller (input freezes, forced chat), then retire the `character.Effects` and `IntFold` value folders and the `SpeedHandler` shim that exist only for old scripts.
- Fold `StarterPlayerScripts/BackpackGUI.client.luau` into a `BackpackController`.
- Strip the scripts embedded in `.rbxm` GUIs (`Gender.Decisions`, `MenuMechanics`, the DeliveryFrame X-button LocalScript) and re-sync those files.
- Bryan's Studio deletions: `ClothingSpawn` (clothes stocker), the old dummy scripts (`NPCFetch`, `Health` under `Workspace.NPC.DUMMY`), the ServerStorage previous-game folder, the R7 wagon seat script, the R8 empty scripts.
- Tag city lamps, torches and fires `CityLight` (Bryan; unblocks M6-B).
- BUG-58: the desert dash fling needs a repro (where, and whether on a slope).
- The silent-footstep root cause (BUG-48) is still unknown; the distance fallback and `Config.World.Footsteps.Debug` cover it.
- Bug rounds in flight: M7-07 (BUG-65, the empty clothes rack hover, and the rest of Bryan's latest notes).
- Bryan's re-runs: M5B-A/B, M5C-A/B/C/G, M6-A/C, plus the M7 spot checks in `docs/PLAYTEST.md`.

## Next

1. The gameplay-loop conversation (`docs/ROADMAP.md` section 4), one question at a time.
2. A written "restore complete" gate for Bryan once the list above is clear.
3. M8 talking NPCs and tutorial.

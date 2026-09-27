# TRIAGE

**Status: DRAFT, waiting for Bryan.** Every line needs Bryan's approve, veto or change. Nothing is built or removed until it is approved.

**How to read this:**
- **Keep:** leave it as is.
- **Fix:** repair it in place, in Bryan's style.
- **Rewrite:** rebuild it, because fixing costs more than starting over.
- **Remove:** delete it.

Each line cites the findings in AUDIT.md. Per Bryan's direction, a system is judged by what it was **meant** to do. Much of the code is left over from the previous game, and the save data is debug-only and can be wiped.

## Systems

| # | System | Call | Why | Findings |
|---|---|---|---|---|
| 1 | Saving (Stats and OnCharacter) | **fix** | The two save scripts erase each other and have no safety net. Fixing them is small once each has its own key: separate keys (or one merged key), a bad-load guard on both, cleanup when players leave, save retries, one save per player at shutdown, and wiping the debug data. | C1, H1, H2, M20, L19 |
| 2 | Join flow (loading → spawn) | **fix** | The one-time "loading done" signal can be missed, which leaves players stuck or spawned in the wrong place. The 30-second kick also counts time spent picking a gender. | H3, P1, M9 |
| 3 | Spawn location | **fix** | Should spawn at `QarzinSpawn`; the saved-position path would error if it were ever turned on. | P1, L4 |
| 4 | Character creation and appearance | **fix** | Works, but needs these fixes:<br>• female characters get male names<br>• skin template names/colours don't match<br>• one collision group per player hits Roblox's cap<br>• magician eye colours can't appear<br>• move the gender picker to a client GUI plus the existing `GenderSelected` remote, with server checks, so it isn't a fragile server-script-reads-clicks setup | L3, P4, M8, L2, H4, L6 |
| 5 | Aging and growth | **fix** | The age math works. Needed: set `SECONDS_PER_YEAR` back to its real value (the comment says 5 min) and **build death from old age**, which was always intended. That makes the huge ages and the cut-off menu line go away. | M10, P3, L5 |
| 6 | Items, clothing and hats (ItemHandler) | **keep** | Works in play; no real findings. | none |
| 7 | Market and currency (MarketHandler) | **fix** | Needed:<br>• agree on what a Gold coin is worth<br>• compare prices in the same unit<br>• "already owned" must check colour too (black pants block white)<br>• add convert messages for all coins | M15, M22, L12 |
| 8 | Qarzin clothes shop (Workspace) | **fix** | Needed:<br>• mannequin hover should show only for the player hovering (not intended for everyone)<br>• every rack sells the same pants<br>• colours should be white, **tan** and black, per the design | L12 |
| 9 | Delivery missions | **fix** | Works end to end and matches the design. Needed:<br>• server checks on the chosen city<br>• the interception money exploit and its crashes<br>• server loops that never end<br>• client connection pile-up<br>• Heavy Cargo slow sticking<br>• broken route names<br>• hook up the intended route history and city personality<br>• a real success streak | H7, H8, H9, M12, M13, M14, M21, L14, L15 |
| 10 | Movement and speed | **fix** | Needed:<br>• dash shouldn't need a first punch<br>• server cooldown on dash and run<br>• low-health slow should apply right away and fully restore<br>• merge the 4 pasted copies of the speed maths | H10, M4, M6, D2 |
| 11 | Combat (server side) | **fix** | PvP works but trusts the client. Needed:<br>• server checks on range, cooldown and attacker state for hits and blocks<br>• blocking must protect at low health<br>• parry pose cap<br>• hits on a weapon or package must find the character<br>• stop leaks on respawn | C2, H5, M1, M2, M3/P2, M5, M18 |
| 12 | Combat (client side, PhysicalHandler) | **fix** | Unfinished by design, so this is **foundation only**:<br>• stun and cooldown checks that are set up but never read<br>• stacked listeners multiplying hits and combo counts<br>• small leaks<br>Finishing the combo chain and the block-break "feel" is design work for later. | H6, L11 |
| 13 | Royal Dagger auto-equip | **remove** | Bryan: test code. The weapon system itself (WeaponHandler) stays. | L7 |
| 14 | Effects (status markers) | **fix** | The marker system works. It needs safer handling when markers vanish mid-hit, and should hook up before early markers are added. | M18 |
| 15 | Health and block regen | **fix** | Growing taller never adds health (wrong branch name); the regen tiers don't change the rate; block bar refill takes about 12.5 minutes. | M11, L8 |
| 16 | Regions and music | **fix** | Works. Needed: music fades (they cut instantly), `CutDown` targets the wrong child, one-song playlists spin forever, and Bryan's "volume feels finicky". | L21 |
| 17 | Footsteps | **fix** | Needed: server rate limit on the Footstep remote, a connection that piles up on every step, a nil-raycast error, and small Animate hook bugs. | M7, L10 |
| 18 | Hunger | **keep (question)** | The HUD shows hunger, but the drain script is switched off and would leak if switched on. **Open question 2.** | L17 |
| 19 | HUD | **fix** | The `game.Loaded` waits don't actually wait. Otherwise fine. | L9 |
| 20 | Character menu (M) | **keep** | Works. The cut-off line is caused by runaway age (fixed by #5). The inventory lookup is latent until inventory is built. The black preview diamond is noted for later. | P3, L13 |
| 21 | Backpack / hotbar | **keep** | Customized Roblox backpack; works. | none |
| 22 | NPCs (training dummies) | **fix** | Needed:<br>• punches hit the player's weapon and stall the server<br>• the Target dummy chases too far<br>• it never restarts after losing its target | P2, M19 |
| 23 | Dev commands | **fix** | The permission check is correct. Needed: offline edits go to the wrong DataStore, confirmations don't show in chat, a duplicate parse call. | L1 |
| 24 | Collisions | **keep** | Works. One unreachable branch, trivial. | L18 |
| 25 | Ocean | **rewrite** | Bryan's direction: replace the 766 per-part scripts with **one client-side script** that animates every ocean part. That also removes the lag and connection growth. | M17 |
| 26 | Code hygiene (whole game) | **fix** | One sweep: remove debug prints, swap deprecated `spawn`/`wait`/`delay`/`:connect`, add `local` to accidental globals, drop unused requires. Style stays Bryan's. | L20, D1, D2, D4 |

## Remove list (dead code and leftovers from the previous game)

Nothing here is deleted until Bryan approves each line. The **?** lines are ones where intent is unclear; each is an open question.

| # | What | Call | Why |
|---|---|---|---|
| R1 | `RS/Modules/Combat/LightCombat`, `BasicSwordCombat` | **remove** | Old server-side combat; nothing uses them; they require a module that doesn't exist |
| R2 | `RS/Modules/DashHandler` | **remove** | Required but never called; wrong asset path. The dash lives in InteractionsHandler |
| R3 | `RS/Modules/AssetID` | **remove** | Never called; uses a proxy site that's been shut down |
| R4 | `SSS/Datastore/StatManipulation` | **remove** | Disabled; broken require; body fully commented out |
| R5 | Desert Lair Tunnel code in `RegionHandlerPart1` | **remove** | Bryan: the tunnel doesn't exist (D5) |
| R6 | `RF/Tools/.../UniversalToolBar/LocalScript` | **remove** | Empty stub |
| R7 | `RF.Objects.MissionWagon.Cradle.Seat.Script` (Studio-only) | **remove** | Never runs; nothing uses the wagon or its "Driver" value |
| R8 | Empty scripts: `Workspace.Qarzin.QarzinEconomy`, `MaterialService.Tool.LocalScript` (Studio-only) | **remove** | Empty. (The misplaced Tool in MaterialService is a question for Bryan) |
| R9 | `RS/Modules/RubbleHandler`, `RS/Modules/CameraShaker` | **remove?** | Unused now; could be for future magic or impact effects. **Open question 3** |
| R10 | `RS/Modules/LevelHandler` | **remove?** | Unused; reads stats that don't exist (`Depravity`, `LovedByRukh`). The design says rank comes from Magoi, and this has hero/villain rewards. **Open question 3** |
| R11 | Unused remotes: the combat/misc ones (`AutoSave`, `Wipe`, `ItemEquip`, `MissionInteraction`, `MissionFinisher`, `SpawnTeleport`, `RegionEntered`, `RegionLeft`, `DeathHandlerPart3`, `CombatMusic*`, `FollowUp`, `RaceSkill`, `Carry`, `SandStormSound`, `Party`, `ClientCommunication`, `Holding`, `GameLoaded`, `GetDamageFunc`, `CombatPress`, `Drop`, `Announcer`, `Cam`, `CameraShake`, `CombatString`, `Gripped`, `BlockBroken`) | **remove?** | Nothing uses them. `GenderSelected` is **kept** for #4. **Open question 3** |
| R12 | `SpellRemotes` folder and `BorgActivation` | **remove?** | Magic isn't built yet. These could be placeholders for it. **Open question 3** |

## Open questions (asked one at a time)

1. **Saving layout:** give each save script its own key (smallest change), or merge them into one save handler with one key (cleaner, a bit more work)?
2. **Hunger:** should hunger drain in this version? If so, fix and switch on the drain script (#18); if not, hide it from the HUD.
3. **Magic and rank leftovers** (R9–R12): remove them, or keep them as placeholders for the magic and rank systems you plan?
4. **Aging speed:** is 5 minutes per year still right? And at what age should old-age death start?

## Suggested milestone order (after approval)

1. **Save and security:** #1, #2, #3, and the server checks in #9, #10 and #11 (both criticals first)
2. **Character:** #4, #5, #15
3. **Combat and NPCs:** #11, #12, #13, #14, #22
4. **Economy and missions:** #7, #8, #9
5. **World and audio:** #16, #17, #25
6. **Cleanup:** #19, #23, #26, and the approved removals

# Roadmap: where the restore stands, and what comes next (updated 2026-10-03, for Bryan)

Written so a fresh session can pick up without the conversation. Read with `docs/TASKS.md` (the board) and `docs/WHEN-HOME.md` (Bryan's short checklist).

## 1. The goal, restated
Bryan's intention: **restore his game to full working order** first ("fix up the house from the owner's picture of it"), then grow it. TRIAGE.md was the complete inventory of what the old game had (29 systems plus parks and removals). Below is where each one stands.

## 2. Restoration scorecard (TRIAGE # -> what happened)

| Old system | Status | Where |
|---|---|---|
| 1 Saving | rebuilt | M1, DataService, schema v4 |
| 2 Join flow and spawn | rebuilt | M1, PlayerService |
| 3 Creation and appearance | rebuilt | M2, CharacterService, CreationController |
| 4 Aging, visible aging, death | rebuilt + new | M2, AgeService, LifeService, afterlife scene (Bryan tunes the scene) |
| 5 Items and clothing codes | kept, moved | M5B, ItemService |
| 6 Currency | rebuilt | M5A (bands, exact-coin pay). Money changer = Bank, later. Supply and demand deferred by Bryan |
| 7 Qarzin clothes shop | rebuilt | M5B, ShopService (Bryan deletes the Studio stocker) |
| 8 Delivery missions | rebuilt | M5C, MissionService + the intercepted mark |
| 9 Movement and speed | rebuilt | M3, MovementService |
| 10, 11 Combat server and client | rebuilt, then **shelved** | M3 and M3B. Bryan (2026-10-03): combat is erased and redesigned from scratch after M12; until then it only runs, nothing is tuned |
| 12 Royal Dagger auto-equip | removed | M3 (the dagger is now a fighting style, bought later) |
| 13 Status effects | rebuilt | M3, StatusService |
| 14 Health and block regen | rebuilt | M2/M3, HealthService |
| 15 Regions and music | rebuilt | M6, RegionController + MusicController |
| 16 Footsteps | rebuilt | M6, FootstepController (local) |
| 17 HUD | look kept, scripts rebuilt | M4, HudController (hunger parked) |
| 18 Character menu | look kept, script rebuilt | M2, MenuController |
| 19 Backpack / hotbar | kept as is | still the old `BackpackGUI.client.luau`; it works |
| 20 Training dummies | rebuilt | M3B, NpcService with behaviour trees, seven trainers |
| 21 Dev commands | rebuilt | M1, DevService (server-checked) |
| 22 Collisions | moved | M6, CollisionService |
| 23 Ocean | rebuilt | M6, OceanController (the old wave scripts are gone; it stays off until `Config.World.Ocean.Enabled` is set true) |
| 24 Code hygiene | ongoing | every rebuild |
| 25 Rank, Rukh, epithets | new, done | M4, RankService |
| 26 Bounty Hunting | new, not started | M8 in the old numbering (below: M9) |
| 27 Day/night and city lights | new, done | M6 (Bryan tags the lights) |
| 28 Weapons and gear for sale | new, not started | M9 in the old numbering (below: M10) |
| 29 Debug and testing tools | new, done | M1 (test saves, self-tests, dev panel) |
| K1-K3 parked (hunger, magic, LevelHandler) | parked by Bryan | `ServerStorage/Parked` |
| R1-R9 removals | done except the Studio-only ones | R7, R8 and the Studio stocker are on Bryan's FOLLOWUPS |

**Verdict: restoration complete, pending the M7 close-out.** Every system the old game had is rebuilt, kept, or deliberately shelved (combat). Nothing from the original inventory is missing. What is left is cleanup and verification, not features:

1. **Old scripts still running:** `InputHandler.client.luau` and `BackpackGUI.client.luau` (to fold into controllers), plus the `Effects` and `IntFold` value folders and the `SpeedHandler` shim that exist only for them and for Animate.
2. **Scripts inside binary `.rbxm` GUIs:** `Gender.Decisions`, `MenuMechanics`, the DeliveryFrame X-button LocalScript. They never run now; strip them in Studio and re-sync.
3. **Bryan's Studio-side jobs:** delete the clothes stocker, the old dummy scripts, the ServerStorage previous-game folder, R7/R8; tag city lights; the afterlife scene, heartbeat and sound levels.
4. **Verification:** Bryan's re-runs of M5B, M5C and M6, and the two open bugs (BUG-58 dash fling, the silent-footstep root cause).

## 3. Milestones, renumbered (draft notes for Bryan)

| # | Milestone | Notes | Size |
|---|---|---|---|
| M6 | World | **Done 2026-09-29.** Regions, music, day/night, city-light tag, footsteps, ocean, collisions, bridge removal. | done |
| **M7** | **Restoration close-out** | The list in section 2: fold the last old scripts into the new controllers (`InputHandler`, `BackpackGUI`), retire the `Effects`/`IntFold` folders, strip the rbxm scripts, fix what Bryan's playtests turn up, one full regression pass of PLAYTEST.md. Ends with a written "restore complete" gate. Combat is excluded: it is shelved. | 1 server task, 1 client task, bug rounds |
| M8 | Talking NPCs and tutorial | Dialogue system as data (lines, choices, a portrait frame in Bryan's UI style), the alley teacher who runs the combat tutorial and grants `Meta.Unlocks.Combat` (then `Config.Combat.UnlockedByDefault` goes false), a few flavour NPCs in Qarzin (merchant, guard) with idle animations. Talking NPCs are the delivery vehicle for lore and for every later mission type. | 2 tasks |
| M9 | Bounty Hunting | The bounty board in each city (Bryan places `BountyBoard` models), crimes raise `Bounty` (interception already does), the wanted list, tracking a wanted player, knocking out and "turning in" at a board for Copper, Magoi and Gold Rukh, rank gate at Adventurer. Escort and other mission types after. | 2 tasks |
| M10 | Weapons and gear | The Rathole blacksmith (Bryan places it), weapons as items with a fighting style (the Dagger already exists; add one more, such as a Sword), simple gear stats, buying with coin, the old rarity idea back as data. Needs M8's dialogue for the smith. | 2 tasks |
| M11 | Bank and world economy | The Bank (money changer with a fee, the only place coins convert), then the deferred 5D supply-and-demand model once two shops exist (three candidate models to choose from). | 1-2 tasks |
| M12 | Legacy | What survives a death: today only account-wide unlocks. Add a small inheritance (a keepsake item or a coin fraction), a "lives lived" record on the menu, and a leaderboard or hall of past names in Qarzin. This is the first step toward the parked families feature. | 2 tasks |
| after M12 | Combat redesign | Combat is erased and rebuilt from the top (Bryan, 2026-10-03), with the hit-checking, styles and trainers rethought together. The old scenarios stay in PLAYTEST.md for it. | own milestone |
| later | Parked features | Magic (the 8 types, Borg, Magoi Blast), other races and their ladders, kingdoms, families, hunger, parties, jail, djinn. Each is its own milestone when Bryan wants it. | |

## 4. The gameplay loop (draft for the conversation after M7)

**One session (30 to 60 minutes):**
1. Arrive in Qarzin. The clock and the music tell you when it is; your purse and rank tell you where you stand.
2. Take a delivery from the board. Choose the route by risk and pay (modifiers, the intercepted mark, your streak).
3. On the road: other players may hunt you (interception) or you may hunt them. Combat decides it.
4. Get paid in Copper, earn Magoi and a Rukh deed. Spend at the clothes stand, later the smith and the Bank.
5. Rank up, pick an epithet, and get a new option: bounty hunting at Adventurer, better weapons with coin.

**One life (about a day of play at 30 minutes a year):**
Street Rat at 13 -> deliveries and choices push you Gold or Black -> your epithets tell the story of the choices -> from 60 each birthday may be the last -> the return to the Rukh -> a fresh character, with the account's unlocks and (M12) a legacy.

**What the loop is missing today, and which milestone supplies it:**
- A reason to keep earning after clothes: weapons and gear (M10), the Bank (M11).
- A reason to fight other than mission interception: bounties, with a moral choice attached (M9).
- Someone to tell you all this in the world: talking NPCs and the tutorial (M8).
- A reason to care about death: legacy (M12).
- More of the world built: only Qarzin exists; the other six cities are markers. Building them is Studio art work at Bryan's pace; the mission and region systems already take new cities from data.

**Open questions for that conversation (one at a time):** how long a life should feel in sessions, not hours; whether interception should ever be "allowed" (a lawful bounty) versus always a crime; what a player keeps across lives.

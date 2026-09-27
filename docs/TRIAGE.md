# TRIAGE

**Status: REVISED DRAFT (2026-09-26), waiting for Bryan's approval.** This follows Bryan's new rule ("build it right, keep the look") and the approved DESIGN.md. Once approved, it becomes the Phase 5 milestones in TASKS.md.

**Calls:**

| Call | Meaning |
|---|---|
| **Rebuild** | Rewrite on the new foundation (see DESIGN.md §5). It keeps what the system was meant to do and all its art, UI, animations, sounds and text, and it fixes its AUDIT findings along the way. Approving a Rebuild line also approves deleting the old scripts it replaces. |
| **Keep** | Leave as it is (it may move to the new folder layout). |
| **New** | Doesn't exist yet; comes from DESIGN.md. |
| **Park** | Move to `ServerStorage/Parked`. It never runs or reaches players, and stays for later. |
| **Remove** | Delete it. |

Save data is debug-only and will be wiped. Much of the old code is left over from the previous game.

## Systems

| # | System | Call | What happens | Findings / source |
|---|---|---|---|---|
| 1 | Saving | **Rebuild** | One data service with one key and a versioned table. Session lock, retries, saves at shutdown, a bad-load guard, cleanup when players leave. The save layout covers rank/Magoi, Rukh tallies, epithet, bounty and age, and leaves room for family and magic. The debug data is wiped. | C1, H1, H2, M20, L19 · Bryan: one key |
| 2 | Join flow and spawn | **Rebuild** | One ordered join pipeline on the server (load save → build character → place at Qarzin spawn → ready), with no one-time signals to miss. No 30-second kick while in character creation. | H3, P1, M9, L4 |
| 3 | Character creation and appearance | **Rebuild** | Same faces, skins, hair, FalseHead and starter rags. The gender/skin picker becomes a client screen plus one checked remote. Names match gender; skin templates fixed; one shared collision group. | H4, L2, L3, P4, M8, L6 |
| 4 | Aging, visible aging and death | **Rebuild** + **New** | Keep the growth-spurt maths (AgeHandler is good). 30 min per year while online (shorter for testing); offline aging at 2 years per real day that stops at 59. Visible aging from adulthood (grey hair, wrinkles). From 60, a rising chance of death at each online birthday, then the **return-to-the-Rukh** scene, then a fresh character. | M10, L5 · DESIGN §3 |
| 5 | Items and clothing codes | **Keep** (extend) | Item codes and equipping work. They move into the new layout and get extended with weapons and gear. | · DESIGN §3 |
| 6 | Currency and market | **Rebuild** + **New** | One fixed conversion rate, a **money changer**, prices that move with supply and demand, an "already owned" check that includes colour, messages for every coin. | M15, M22 · DESIGN §3 |
| 7 | Qarzin clothes shop | **Rebuild** | Moves out of Workspace into synced code. Hover highlight only for the player hovering. Every rack sells its own pants. Colours are white/tan/black by rarity. | L12 |
| 8 | Delivery missions | **Rebuild** | Same missions, cities, modifiers, lore and interception. The server checks city and route, there are no endless loops, no money printing, and no crash cases. Route history and city personality drive modifiers, and there's a real success streak. It grants **Magoi**; interception adds **Black Rukh** and a **bounty**. | H7, H8, H9, M12, M13, M14, M21, L14, L15 |
| 9 | Movement and speed | **Rebuild** | One speed-modifier system for players and NPCs. Dash works without a first punch; server cooldowns; low-health slow applies immediately and restores fully. | H10, M4, M6, D2 |
| 10 | Combat (server) | **Rebuild** | The server decides every hit: range, cooldown, attacker state, blocking and parry windows, block HP cap, and hitting a weapon or pack finds the character. No leaks on respawn. | C2, H5, M1, M2, M3/P2, M5 |
| 11 | Combat (client) | **Rebuild** | Keeps your animations and feel. Input sends intentions only, with stun and cooldown respected and no stacked listeners. Finishing the combo chain and the block-break feel are tuned with Bryan during this milestone. | H6, L11 · Bryan: combat unfinished |
| 12 | Royal Dagger auto-equip | **Remove** | Test code. Weapons are bought instead (#6). | L7 · Bryan |
| 13 | Status effects (Hit, Stun, Knocked, …) | **Rebuild** | One status service; safe when markers vanish mid-hit. | M18 |
| 14 | Health and block regen | **Rebuild** | Folded into the combat and status services. Height adds health; regen tiers really change the rate; the block bar refills at a sane speed. | M11, L8 |
| 15 | Regions and music | **Rebuild** | Keeps all music, playlists and the city banner. Region detection by position instead of touch; working fades; volume consistent across tracks. | L21 · Bryan: volume finicky |
| 16 | Footsteps | **Rebuild** | Played on each client locally (sounds and sand prints), so there's no per-step remote. | M7, L10 |
| 17 | HUD | **Keep** look, **Rebuild** scripts | Health and block bars keep their look. The hunger bar is parked. | L9 · Bryan: hunger parked |
| 18 | Character menu (M) | **Keep** look, **Rebuild** script | Shows rank, epithet and Rukh alignment. Age and height display correctly. | P3, L13 · DESIGN §3a |
| 19 | Backpack / hotbar | **Keep** | Works. | |
| 20 | Training dummies (NPCs) | **Rebuild** | Moves into synced code. Punches find the player, the chase gives up at range, and they restart after losing a target. | P2, M19 |
| 21 | Dev commands | **Rebuild** | On the new data service. Keeps the UserId permission check; offline edits reach the real save; confirmations show in chat. Adds testing commands (set age, rank, Rukh, bounty). | L1 |
| 22 | Collisions | **Keep** | Moves into the new layout. | L18 |
| 23 | Ocean | **Rebuild** | **One client-side script** animates every ocean part. The 766 wave scripts are deleted. | M17 · Bryan |
| 24 | Code hygiene | covered | The rebuild drops the deprecated APIs, globals, debug prints and unused requires. | L20, D1, D2, D4 |
| 25 | Rank, Rukh alignment and epithets | **New** | Magoi → rank ladder; Gold/Black tallies → alignment; choose 1 of 3 epithets at each rank-up; Rukh flutter effect. | DESIGN §3a |
| 26 | Bounty Hunting | **New** | Crimes put a bounty on you. A **bounty board** in the cities lists the wanted. Knocking out a wanted player and turning them in pays coin and Magoi and adds Gold Rukh. Unlocks at Adventurer. | DESIGN §3 |
| 27 | Day/night and city lights | **New** | Lighting cycle; city lamps, torches and fires light at dusk and go out at dawn. | DESIGN §3 · Bryan |
| 28 | Weapons and gear for sale | **New** | The Rathole blacksmith and gear with real stats, bought with coin. | DESIGN §3 |

## Park (to `ServerStorage/Parked`)

| # | What | Why |
|---|---|---|
| K1 | Hunger: `Fear&Hunger` script and the HUD hunger bar | Bryan: unfinished, not in this version |
| K2 | Magic leftovers: `SpellRemotes`, `BorgActivation`, `RubbleHandler`, `CameraShaker` | Bryan: magic comes back later; keep out of the way |
| K3 | `LevelHandler` (old hero/villain Magoi rewards) | Reference for rank and Rukh; replaced by #25 |

## Remove

| # | What | Why |
|---|---|---|
| R1 | `LightCombat`, `BasicSwordCombat` | Old combat; unused; broken require |
| R2 | `DashHandler` | Never called; wrong path |
| R3 | `AssetID` | Never called; dead proxy site |
| R4 | `StatManipulation` | Disabled; broken; fully commented out |
| R5 | Desert Lair Tunnel code | Bryan: the tunnel doesn't exist |
| R6 | `UniversalToolBar` LocalScript stub | Empty |
| R7 | MissionWagon seat script (Studio-only) | Never runs |
| R8 | Empty scripts: `Workspace.Qarzin.QarzinEconomy`, `MaterialService.Tool.LocalScript` | Empty (the misplaced Tool itself is left alone) |
| R9 | Unused non-magic remotes (full list in AUDIT D3 and SYSTEMS "Not in use") | Nothing uses them; the new foundation declares only the remotes it needs |

## Milestones (Phase 5)

Each milestone ends with a playtest and Bryan's approval before the next starts.

1. **Foundation:** the new code layout, data service (#1), remote layer, join pipeline (#2), dev commands (#21), data wipe, and the parks and removals.
2. **A life:** character creation (#3), aging, visible aging and death (#4), health (#14), menu (#18).
3. **Combat:** movement (#9), status (#13), server and client combat (#10, #11), training dummies (#20), dagger removal (#12).
4. **Status and Rukh:** rank, alignment and epithets (#25), HUD (#17).
5. **Economy and missions:** currency and money changer (#6), clothes shop (#7), weapons and gear (#28), delivery (#8), Bounty Hunting (#26).
6. **World:** day/night and city lights (#27), regions and music (#15), footsteps (#16), ocean (#23), collisions (#22).

## Bryan's decisions so far

- **Saving:** one handler, one key.
- **Hunger:** parked; its HUD bar comes off.
- **Magic and rank leftovers:** parked, not deleted.
- **Old age:** starts at 60, with a rising death chance and visible aging. Death means a fresh start; family comes later.
- **Style:** build it right, keep the look (CLAUDE.md).
- **Design:** see DESIGN.md (scope, Bounty Hunting, rank/Rukh/epithets, 30 min/year, offline aging, day/night).

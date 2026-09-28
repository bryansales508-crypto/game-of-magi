# Milestone 5: Economy and missions (draft for Bryan's approval)

Scope from the approved TRIAGE: currency and market (#6), the Qarzin clothes shop (#7), delivery missions (#8), Bounty Hunting (#26), weapons and gear for sale (#28). This is the biggest milestone. Everything keeps your look: the delivery board and quest tracker GUIs, the city lore text, the mannequins and racks, the coin purse, the flavour lines the character says when a purchase fails.

## Decisions to approve (each one is a line you can change)

1. **One conversion rate:** 1 Gold = 100 Silver = 10,000 Copper (the bank's rate; the old pricing half disagreed). Prices are stored in copper internally and shown as mixed coins.
2. **Money changer:** a prompt at a part named `MoneyChanger` in each city (you place the part; the code finds it by name). Change up or down at a 5% fee. Every coin action gives a message.
3. **Supply and demand, per server:** each city keeps stock levels per goods type (clothing, weapons, cargo). A delivery restocks the destination (prices there drop a little); an intercepted delivery raises prices at the destination. Stock drifts back to normal over time. Kept in memory per server for now, not in the DataStore (one live server; a world save comes later if needed).
4. **Clothes shop rebuilt in synced code:** the Studio-only ClothingSpawn script is replaced by a `ShopService` that stocks the same hat table, mannequins, racks and cloak stands from a data file (which rack sells what, rarity -> white / tan / black). Prompts are server-side; the hover highlight is client-only (only you see it); every rack sells its own pants; "already owned" includes colour; a full hat slot refuses before charging.
5. **Weapons and gear:** a `Blacksmith` prompt part at Rathole (you place it). Sells the Royal Dagger (the move set already exists in `Combat.luau`) and a second weapon of your choice, plus two gear pieces with one real stat each (a padded vest for max health, a light shawl for block). Bought weapons are equipped through the combat system (`WeaponSet`), so the dagger's 3-hit chain returns as something you buy. Item codes get a `W` (weapon) and `G` (gear) type.
6. **Delivery rebuilt:** same board, same cities, routes, modifiers, lore and interception, in one `MissionService`. The server checks the city against the route (no more accepting any city), one board per player, no per-frame loops, no money printing. Interception moves the package to the interceptor, who must finish the run to be paid; it adds Black Rukh and a bounty. A real success streak and a per-city route history are saved and drive the modifiers with the city's personality. Each delivery grants about 10 Magoi and 1 Gold Rukh.
7. **Bounty Hunting (unlocks at Adventurer):** crimes (intercepting a courier, robbing a knocked courier) put a bounty on you. A `BountyBoard` prompt part in each city lists the wanted on this server with their bounty. Knock out a wanted player and press E on them to turn them in: you get the bounty in coin, 25 to 50 Magoi scaled by the bounty, and 2 Gold Rukh; their bounty clears. No jail (parked). The board is visible to everyone; turning in needs Adventurer rank.
8. **Save changes (schema v3):** `Progress.DeliveryStreak`, `Progress.Routes` (deliveries per city), `Gear.Weapons` (owned codes), `Gear.EquippedWeapon`, `Gear.Equipment` (owned gear codes). Written up in SYSTEMS.md section 1 with the migration.

## Tasks

| ID | Task | Owner |
|---|---|---|
| M5-01 | `Shared/Data/Economy.luau` (rate, fee, base prices, elasticity, per-city goods) + `EconomyService` (wallet ops on the save, money changer, city stock and prices, `TryBuy`, coin messages, `Currency` attributes that drive the coin purse instead of the old bridge line) | server-builder |
| M5-02 | `Shared/Data/Shop.luau` + `Shared/Data/Weapons.luau` + `ShopService` (stocks the Qarzin stand and the Rathole blacksmith from data, server prompts, purchase through EconomyService, equips through ItemService/CombatService); `ItemHandler` ported to a strict `ItemService` with the new `W`/`G` codes | server-builder |
| M5-03 | `Shared/Data/Cities.luau` (routes, personality; lore text stays in your GUI frames and is read from them) + `MissionService` (board, modifiers, package, timers, interception, payout, Magoi and Rukh, streak and history) + schema v3 | server-builder (Opus review) |
| M5-04 | `BountyService` (crimes, bounty board listing, turn-in, rank gate) | server-builder (Opus review) |
| M5-05 | Client: `ShopController` (hover highlight, purchase feedback, the flavour line in chat), `MoneyChangerController` (small UI in the menu style), currency HUD driven by attributes | client-builder |
| M5-06 | Client: `MissionController` (the same DeliveryFrame, city panels, start button, quest tracker, modifier pop-outs, timers), `BountyController` (board UI, turn-in prompt feedback) | client-builder |
| M5-07 | PLAYTEST.md M5 scenarios; Bryan plays the shops and a delivery loop; the agent runs cheat checks (buy without coins, wrong city, fake turn-in) | Bryan + lead + playtester |

**Order:** server M5-01 -> 02 -> 03 -> 04 in one session; client M5-05 -> 06 in one session; contracts fixed in the prompts.

**Removed when done (approved TRIAGE):** `MISC/MarketHandler.luau`, `MISC/MissionHandler/init.server.luau` (its city Frames move under `ReplicatedFirst/GUI/MissionGUI/Cities/` as art), `RS/Modules/MissionDeliniation.luau`, `RS/Modules/RewardHandler.luau`, `Character/ItemHandler.luau`, the `Delivery` and `ForcedChat` old remotes, the `SpeedHandler` shim. Studio-only: `Workspace.Qarzin.ClothesStand.ClothingSpawn` (you delete it; follow-ups).

**Bridge:** after M5 the only old readers of `Stats`/`OnCharacter` are the region and footstep scripts, which M6 rebuilds; the legacy bridge is deleted in M6.

**Needs from Bryan (Studio, whenever):** place parts named `MoneyChanger` (one per city), `BountyBoard` (one per city) and `Blacksmith` (Rathole). Plain parts are fine; the code adds the prompts. Tell me the second weapon and the two gear pieces you want, or accept the defaults above.

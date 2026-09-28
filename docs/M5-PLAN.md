# Milestone 5: Economy and missions, in phases (draft 2, 2026-09-29, for Bryan's approval)

Bryan's direction: break it into phases, get each right before the next. Keep everything nearly the same apart from integrating with the new code. The money changer is pushed to a later **Bank** milestone. Each phase ends with Bryan's playtest and his OK.

## Decisions so far (Bryan, 2026-09-29)

- **Coins:** 1 Gold = 100 Silver = 10,000 Copper (Bryan confirmed 2026-09-29).
- **No mixed coins, whole numbers only, in bands (Bryan, 2026-09-29):** 1 to 100 Copper shows as Copper; 101 to 200 is 1 Silver; 201 to 300 is 2 Silver (Silver = ceil(copper / 100) - 1); the same from Silver into Gold: 10,001 to 20,000 Copper is 1 Gold. No decimals anywhere.
- **Paying:** NO automatic change. A price is in one coin and you pay with that coin; if you hold the wrong coins the purchase fails with the old flavour line, and the Bank (later milestone) is the only place to exchange. Rewards stay Copper for now (Bryan, 2026-09-29); Silver and Gold come only from the dev `.coins` command until the Bank milestone.
- **Money changer:** out; Bank milestone later.
- **Coin sound:** the `CoinReward` sound plays on ANY coin change (Bryan, 2026-09-29), owned by the client purse controller from 5A on.
- **Clothes shop:** its own phase. Keep the stock, racks, mannequins, hat table and cloak stands as they are; integrate with the new save and combat code; fix the hover highlight (only the hovering player sees it) and the colour bug (owning a black shirt must not block buying the white one). "Each rack sells the same pants" is expected today: only one pants design exists. The shop data gets a pants pool so Bryan can add designs later and racks pick from it.

## Phases

### Phase 5A: Currency
- `Shared/Data/Economy.luau`: the coin ratios, the rounding rule, the display rule.
- `EconomyService`: the wallet on the save (`Economy.Copper/Silver/Gold` as today), `CanAfford`, `Pay` with automatic change-making, `Give`, `Currency` attributes for the purse HUD (replaces the legacy bridge writing the purse text), a message for every coin action (the old "say it in chat" flavour lines stay for shop failures).
- Client: the coin purse HUD driven by attributes; nothing else.
- Dev: `.coins` already exists; add `.price <copper>` to print how a copper amount displays.
- Playtest: rounding table, buying with automatic change, purse display.

### Phase 5B: Clothing shop
- Approved 2026-09-29. Rarity colours: White, Tan, Black (Bryan: tan and gold are the same colour; "Tan" is the name).
- `ShopService` + `Shared/Data/Shop.luau`: the Qarzin stand stocked from data exactly as the Studio-only script does now (hat table, mannequins, cloak stands, the same random pools and rarity colours), prompts server-side, purchase through `EconomyService.Pay`, wear through `ItemService` (the old `ItemHandler` ported to strict; item codes unchanged), the hat-slot check before charging, colour-aware ownership.
- Client `ShopController`: hover highlight for the hovering player only; purchase feedback; the flavour line in chat.
- The Studio-only `ClothingSpawn` script is deleted by Bryan after the phase passes.
- Playtest: buy a hat, a shirt, a cloak; colours; full hat slots; the highlight only for you; nothing paid twice.

### Phase 5C: Delivery missions (draft for approval, 2026-09-29)

**What exists today.** Clicking a `*Delivery` part in `Workspace.MAP.MISSION` opens the delivery board (`RF.GUI.MissionGUI.DeliveryFrame`) listing the cities on that city's trade route. Each destination rolls 0 to 3 modifiers (`TimeCrunch`, `CourierLoop`, `HighlyValuable`, `HeavyCargo`, `VIP`, `FragilePackage`, `CleartheRoute`), weighted by how much the route has been used and how safe it is. The board closes when you walk 20 studs away. Starting straps a package to your back; reaching the destination within 10 studs pays Copper based on your level, the server population, your past deliveries and the modifiers. Being knocked out mid-run hands your reward to the attacker. Seven cities: Qarzin, Sahraqin, Illegal Port, Ain Jamala, Saleh, Rathole, Jaddaty's Hut.

**Known bugs it fixes** (AUDIT): the server accepts any city the client names (H7); interception can create money and crash (H8); every board click leaves a per-frame loop running for the session and listeners pile up (H9, M14); route history and city personality never actually shape the modifiers, and Clear the Route errors (M12); heavy-cargo slow only clears on success (M13); the "consecutive success" bonus resets on rejoin and is not a streak (M21); the quest panel hides even with quests and the pay preview leaves out modifiers (L14); the reward math can divide by zero (L15); the route table names two cities that don't exist.

**What 5C builds (same missions, same look):**
1. `Shared/Data/Cities.luau`: the seven cities, their trade routes (the broken names fixed to real ones), each city's personality and safety, the modifier table (names, weights, effects, pay multipliers) moved out of the three copies in the old code. Lore text stays in your GUI frames and is read from them.
2. `MissionService` (server): one board per player, opened from the `*Delivery` part prompt; the server only accepts a destination that is on that board's route; modifiers rolled server-side from route history, city personality and safety; the package strapped on; timers for `TimeCrunch`; `HeavyCargo` slow through MovementService and removed on any end; `CourierLoop` return point; `FragilePackage` fails on a hit taken; arrival within 10 studs of the destination pays Copper (the old formula ported, division-by-zero fixed, rank instead of the dead level), plus about 10 Magoi and 1 Gold Rukh through RankService. **Interception (Bryan, 2026-09-29):** knocking out a courier pays the run's reward to the attacker INSTANTLY (a get-rich-quick scheme for ambushers: camp a route, hit a courier, take the coin); the courier's run fails and pays nothing; the reward is paid exactly once, so no money is created; the interceptor gets 1 Black Rukh and a bounty number on their save (the bounty board comes with the later missions milestone). **Lead decisions during review (2026-09-29, Bryan may change them):** an interception pays only if the courier is at least 100 studs from the run's origin or at least 30 seconds into the run (`Config.Missions.InterceptMinStuds` / `InterceptMinSeconds`); otherwise the run fails with no payout, so two accounts can't farm it at the board. Clear the Route pays its bonus only if the courier actually knocked someone out during the run (the old intent). Modifier chances shown are roll weights, not true percentages. **Courier beacon:** while on a run the courier is highlighted for everyone every so often (`Config.Missions.Beacon = { everySeconds, forSeconds }`, a Highlight visible through walls) so interceptors can find them; if the old MissionHandler already did something like this the builder keeps its timing. A real success streak and per-city route history are saved (schema v4) and feed the modifier weights. No per-frame loops; everything cleaned on leave and respawn. **Bryan (2026-09-29):** a HighlyValuable courier is highlighted PERMANENTLY for the run (no pulse). **Failing a modifier never fails the run:** Time Crunch expiring, a Fragile hit, an uncleared route or a missed VIP condition only drop that modifier's bonus (client shows "Failed." on its pop-out); only leaving, dying, respawning or interception end a run.
3. `MissionController` (client): the same DeliveryFrame, city panels and lore, the start button, the quest tracker, the modifier pop-outs and timers; the pay preview includes modifiers; the quest panel shows only when there is a quest. Board closes at 20 studs as today.
4. Removed: `MISC/MissionHandler/init.server.luau` (its city Frames move under `ReplicatedFirst/GUI/MissionGUI/Cities/` as art), `RS/Modules/MissionDeliniation.luau`, `RS/Modules/RewardHandler.luau`, the old `Delivery`, `QuestGUI`, `Quest2GUI` remotes.
5. Dev: `.mission start <city>`, `.mission finish`, `.mission fail`, `.mission streak <n>`.
6. Playtest (Bryan): a full run, an intercepted run (two players or a Target dummy knockout), each modifier once, the board closing at 20 studs, the streak surviving a rejoin.

**Bryan (2026-09-29):** approved. Routes are placeholders (only Qarzin is built; the other cities are markers), so the data keeps the old route table with the two broken names pointed at real placeholder cities and a comment. The client mission GUI is rebuilt in full, including the modifier view buttons (semi-broken before: stacked listeners, M14) and the pay preview (L14). The city panels and lore text are dumped by the lead into `docs/reference/m5c-studio-dump.md`.

### Phase 5D: Supply and demand: DEFERRED (Bryan, 2026-09-29) until more shops exist

With Bounty Hunting and weapons pushed to later milestones, the only shop today is the Qarzin clothes stand, so a world economy has little to move yet. Two options:
- **Defer 5D** until the blacksmith and a second shop exist (lead's recommendation): 5C still saves the route history that any model will use.
- **Or build model 3 now, minimal:** personal pricing from your own route history: every completed delivery to a city lowers that city's prices for you by a small step (capped), every interception you commit raises them; shown on the prompt. Cheap, no world save, no cross-player effects.
Models 1 (per-server drifting stock) and 2 (persistent world market) stay described below for when more shops exist.


### Later milestone: Weapons and gear (Bryan, 2026-09-29: after several weapon types exist)
- `Blacksmith` part at Rathole; `Shared/Data/Weapons.luau`; real weapon Tools with the `Weapon` attribute so equipping sets the fighting style (M3B already handles it); the Royal Dagger plus a second weapon Bryan names; two gear pieces with one stat each (defaults: padded vest for max health, light shawl for block); item codes `W` and `G`; owned weapons and gear saved (schema v4).
- Playtest: buy the dagger, equip it, fight with it; gear stat shows in `.state`.

### Later milestone: Missions (Bounty Hunting, Carriage Escort and other types; Bryan, 2026-09-29)
- `BountyService`: crimes (intercepting a courier, robbing a knocked courier) add a bounty; `BountyBoard` part in each city lists the wanted on the server; knock out a wanted player and press E to turn them in: the bounty in coin, 25 to 50 Magoi scaled, 2 Gold Rukh; turning in needs Adventurer rank; no jail.
- Client `BountyController`: the board UI in the menu style, the turn-in prompt.
- Playtest: earn a bounty by interception, get hunted, turn someone in.

### Later: Bank milestone
Deliberate exchange between coins (a fee), storage, maybe interest; the money changer lives here.

## Three market models for Phase 5D (Bryan picks one, or none)

1. **Per-server drifting stock (proposed before).** Each city keeps stock per goods type in memory on that server. Deliveries restock the destination and lower its prices a little, interceptions raise them, stock drifts back to normal over time. Simple, no save, resets when the server does. Feels alive in a session; nothing carries across servers.
2. **Persistent world market.** The same stock levels saved in a world DataStore shared by every server, updated with a short cooldown and conflict handling. Prices carry across days and servers, so a route can stay depleted or flush. Truer to "the world moves on", more moving parts, needs a world save and care with multiple servers writing at once.
3. **Personal reputation pricing.** No global economy at all. Each player's route history (already saved for the modifiers) gives them personal discounts at cities they deliver to often and higher prices where they intercepted couriers. Cheapest to build, zero cross-player effects, and it turns your own history into a reason to run routes; but the world itself never changes.

Lead's lean: start with 3 (cheap, uses the route history 5C already saves), and revisit 2 once there are enough players for a shared market to matter.

## Removed when done (approved TRIAGE)
`MISC/MarketHandler.luau` (5A/5B), `MISC/MissionHandler/init.server.luau` and `RS/Modules/MissionDeliniation.luau`, `RS/Modules/RewardHandler.luau` (5C), `Character/ItemHandler.luau` (5B), the `Delivery` and `ForcedChat` old remotes, the `SpeedHandler` shim. Studio-only: `ClothingSpawn` (Bryan, after 5B).

## From Bryan
- The Gold ratio.
- The market model for 5D (or defer 5D).
- Later: the second weapon and gear names (5E), and the Studio parts `Blacksmith` (5E) and `BountyBoard` per city (5F).

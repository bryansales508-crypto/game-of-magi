# Milestone 5: Economy and missions, in phases (draft 2, 2026-09-29, for Bryan's approval)

Bryan's direction: break it into phases, get each right before the next. Keep everything nearly the same apart from integrating with the new code. The money changer is pushed to a later **Bank** milestone. Each phase ends with Bryan's playtest and his OK.

## Decisions so far (Bryan, 2026-09-29)

- **Coins:** 1 Gold = 100 Silver = 10,000 Copper (Bryan confirmed 2026-09-29).
- **No mixed coins, whole numbers only.** A price is shown in the largest coin where the rounded amount is at least 1: 40 Copper stays 40 Copper; 60 Copper rounds to 1 Silver; 103 to 1 Silver; 150 to 2 Silver (round half up); Silver amounts round up into Gold the same way. No decimals anywhere.
- **Paying:** NO automatic change. A price is in one coin and you pay with that coin; if you hold the wrong coins the purchase fails with the old flavour line, and the Bank (later milestone) is the only place to exchange. Rewards stay Copper for now (Bryan, 2026-09-29); Silver and Gold come only from the dev `.coins` command until the Bank milestone.
- **Money changer:** out; Bank milestone later.
- **Clothes shop:** its own phase. Keep the stock, racks, mannequins, hat table and cloak stands as they are; integrate with the new save and combat code; fix the hover highlight (only the hovering player sees it) and the colour bug (owning a black shirt must not block buying the white one). "Each rack sells the same pants" is expected today: only one pants design exists. The shop data gets a pants pool so Bryan can add designs later and racks pick from it.

## Phases

### Phase 5A: Currency
- `Shared/Data/Economy.luau`: the coin ratios, the rounding rule, the display rule.
- `EconomyService`: the wallet on the save (`Economy.Copper/Silver/Gold` as today), `CanAfford`, `Pay` with automatic change-making, `Give`, `Currency` attributes for the purse HUD (replaces the legacy bridge writing the purse text), a message for every coin action (the old "say it in chat" flavour lines stay for shop failures).
- Client: the coin purse HUD driven by attributes; nothing else.
- Dev: `.coins` already exists; add `.price <copper>` to print how a copper amount displays.
- Playtest: rounding table, buying with automatic change, purse display.

### Phase 5B: Clothing shop
- `ShopService` + `Shared/Data/Shop.luau`: the Qarzin stand stocked from data exactly as the Studio-only script does now (hat table, mannequins, cloak stands, the same random pools and rarity colours), prompts server-side, purchase through `EconomyService.Pay`, wear through `ItemService` (the old `ItemHandler` ported to strict; item codes unchanged), the hat-slot check before charging, colour-aware ownership.
- Client `ShopController`: hover highlight for the hovering player only; purchase feedback; the flavour line in chat.
- The Studio-only `ClothingSpawn` script is deleted by Bryan after the phase passes.
- Playtest: buy a hat, a shirt, a cloak; colours; full hat slots; the highlight only for you; nothing paid twice.

### Phase 5C: Delivery missions
- `Shared/Data/Cities.luau` (routes, personality; lore text stays in your GUI frames) + `MissionService`: same missions, modifiers, package, timers, interception and payout, rebuilt: the server checks the city against the route, one board per player, no per-frame loops, no money printing; interception hands the package to the interceptor who must finish the run to be paid, and adds Black Rukh and a bounty on them; a real success streak and per-city route history (saved, schema v4) drive the modifiers with city personality; about 10 Magoi and 1 Gold Rukh per run.
- Client `MissionController`: the same DeliveryFrame, city panels, start button, quest tracker, modifier pop-outs and timers.
- Playtest: a full run, an intercepted run, the board closes when you walk away, the streak.

### Phase 5D: Supply and demand (model chosen in 5D planning; three candidates below)

### Phase 5E: Weapons and gear
- `Blacksmith` part at Rathole; `Shared/Data/Weapons.luau`; real weapon Tools with the `Weapon` attribute so equipping sets the fighting style (M3B already handles it); the Royal Dagger plus a second weapon Bryan names; two gear pieces with one stat each (defaults: padded vest for max health, light shawl for block); item codes `W` and `G`; owned weapons and gear saved (schema v4).
- Playtest: buy the dagger, equip it, fight with it; gear stat shows in `.state`.

### Phase 5F: Bounty Hunting
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

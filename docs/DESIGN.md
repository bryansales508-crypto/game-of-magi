# Game of Magi: design direction

**Status: DRAFT proposal by the lead, 2026-09-26. Bryan edits, approves or rejects each part.** This is the "picture of the finished house". Anything in here only gets built after Bryan approves it.

**Sources used:**
- Bryan's own words in chat
- the Trello board
- the current code (docs/SYSTEMS.md)
- the old game's scripts (`OldGameScripts.rbxm`), used for intent only, not code

## 1. The game in one line

A **human life in the world of Magi**. You're born into the desert at 13 and make your way: missions, money, rank, gear, fights. Then you grow old and die, and your Rukh returns to the flow and you start a new life.

## 2. Core loop

```
take missions → earn coin + Magoi → get stronger (rank, gear, health) → unlock harder missions → …
                         ↑                                                              |
                         └────────────── spend coin in the cities ◄─────────────────────┘
```

Around the loop, the long arc: **age 13 → adulthood → old age (60+) → death → a fresh life.**

## 3. Pillars: what exists today and what's proposed

| Pillar | Today | Proposed for this renovation |
|---|---|---|
| **Character** | Random traits; you pick gender and skin; growth 13–18 | Keep. Add **visible aging** after adulthood (greying hair, wrinkles), per Bryan. |
| **Aging and death** | Ages forever; no death | From **60**, each birthday carries a rising chance of death. Death shows the old game's **return-to-the-Rukh** scene (glowing, walking into the Rukh core), then a **completely fresh character**. Family/lineage comes later. |
| **Progression (rank)** | MaxMagoi exists but never grows; the title is always "THE MERCHANT'S CHILD" | **Missions grant Magoi.** Magoi sets your **rank title**, using the old game's human ladder: *Commoner → Merchant → Lord/Lady → King/Queen* (and *Lowlife* below zero). Rank raises max health (already wired) and **unlocks harder missions and better goods**. |
| **Economy** | Copper, Silver, Gold; one city; fixed prices; cosmetics only | Settle one conversion rate and add a **money changer**. Prices **move with supply and demand**: deliveries restock the destination city, and interception raises prices. Add things worth buying: **weapons** (the Rathole blacksmith from your lore) and **gear with real stats**, alongside the clothes. |
| **Missions** | Delivery (works) | Keep Delivery as the starter tier. Add **one** rank-gated tier from the old game: **Carriage Escort** (defenders vs bandits) or **Bounty Hunting** (turn in wanted players or NPCs). The other comes later. |
| **Combat** | Fist PvP works; the server trusts the client; combo unfinished; test dagger | A **server-authoritative** fist, finishing the combo chain and the block-break feel. Weapons you **buy** use the same system. |
| **Items** | Clothes, hats, cloaks | Keep. Add weapons and gear as items with a simple code, so the old game's rarity and enchantment idea can return with magic. |
| **World** | Qarzin plus 6 cities on trade routes; region music | Keep. One client-side ocean script. **Day/night cycle** from the old game (cheap, adds a lot). |

## 4. Parked (placeholders, don't load, come back later)

Stored in `ServerStorage/Parked`, so they never run or distract:
- **Magic:** the 8 types (Heat, Water, Light, Lightning, Wind, Sound, Strength, Life), incantation words, Borg barrier and hover, Magoi Blast, the Magoi bar with its low-Magoi stages
- **Races other than Human:** Fanalis, Imuchakk, Magician, Magi, and their rank ladders
- **Kingdoms** (Kou, Sindria, Reim) and the Huang currency
- **Families and lineage** (Ren, Saluja, au Andromedus, Jamil) and inheritance on death
- **Hunger and eating**
- **Parties/alliances, jail, djinn and metal vessels, Rukh morality** (Depravity / LovedByRukh)

## 5. Technical foundation (how the house is rebuilt)

- **One data service:** one key and one versioned save table. Session locking so two servers can't fight over a save; retries; a clean way to wipe. The save layout leaves room for family and magic later.
- **The server decides.** Clients send intentions ("swing", "block", "buy", "start mission"). The server checks range, cooldowns, state and money, then acts. Every remote is declared in one place, with validation.
- **Clear layout:** one bootstrap per side that loads modules (services on the server, controllers on the client). No scripts inside GUIs, models or Workspace. All code is text in `src/`.
- **Keep Bryan's aesthetic:** art, UI, animations, sounds, cities, names and lore text.

## 6. Open design questions (answered one at a time)

1. **Scope of this renovation:** foundation + character life + rank + economy + Delivery + one new mission tier. Right size?
2. Which mission tier comes next: Carriage Escort or Bounty Hunting?
3. How much Magoi per mission, and the rank thresholds (the old game used 0 / 500 / 1000 / 1500 / 2000)?
4. Real time per in-game year (the code comment says 5 minutes; 60 years ≈ 4 hours of play)?
5. Day/night: in or out?

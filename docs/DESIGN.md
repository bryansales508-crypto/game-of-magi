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
| **Missions** | Delivery (works) | Keep Delivery as the starter tier. Add **Bounty Hunting** as the rank-gated next tier (Bryan's choice): crimes such as knocking out and robbing a courier put a **bounty** on you. A **bounty board in the cities** shows the wanted, so good (or evil) players can find the crooks and put them down for the reward. Carriage Escort comes later. |
| **Combat** | Fist PvP works; the server trusts the client; combo unfinished; test dagger | A **server-authoritative** fist, finishing the combo chain and the block-break feel. Weapons you **buy** use the same system. |
| **Items** | Clothes, hats, cloaks | Keep. Add weapons and gear as items with a simple code, so the old game's rarity and enchantment idea can return with magic. |
| **World** | Qarzin plus 6 cities on trade routes; region music | Keep. One client-side ocean script. **Day/night cycle** from the old game, **and the cities react to it** (Bryan): lamps, torches and fires light at dusk and go out at dawn. |

## 3a. Rank, Rukh and epithets (approved by Bryan, 2026-09-26)

Rank measures **status**, like Sinbad's rise from a fisherman's son to King of Sindria: a street kid who becomes a King. It's built in two layers.

**Layer 1: Rank (internal status).** It comes from Magoi alone, and the same ladder applies to everyone. A bounty never changes it.

| Magoi | Rank | Unlocks |
|---|---|---|
| 0 | Street Rat | |
| 50 | Wanderer | |
| 100 | Adventurer | Bounty Hunting |
| 250 | Renowned | |
| 400 | Hero | |
| 700 | Legend | |
| 1,000 | King / Queen | (actually founding a kingdom stays parked) |

**Magoi income:** about 10 per Delivery (more with modifiers); 25–50 per bounty turned in, scaled by the bounty.

**Pacing note:** at Bryan's final rate of **30 min per year**, one life (13 → 60+) is about 23.5 h of play, and reaching King/Queen should take most of a life. So the Magoi thresholds above scale **×6** with the income unchanged: 0 / 300 / 600 / 1,500 / 2,400 / 4,200 / 6,000. The table keeps the original ratios, and the exact numbers are data, tuned in playtests.

**Layer 2: Rukh alignment.** From Magi's Rukh morality, this is a mix, not a single scale. Two hidden tallies:
- **Gold Rukh:** good deeds (deliveries, turning in bounties, …)
- **Black Rukh:** bad deeds (robbing couriers, carrying bounties, …)

| Alignment | When |
|---|---|
| **White Rukh** (undecided) | A new life, before you've done enough to be judged |
| **Gold Rukh** | Your deeds lean clearly good |
| **Black Rukh** | Your deeds lean clearly bad |
| **Gold & Black** | Close to the middle: both at once |

The exact thresholds get tuned during the build (starting idea: one side ≥ 65% of all deeds). The rank-up moment shows a Rukh flutter in your alignment's colour; the old game already had this effect.

**Epithets (what the world calls you).** At each rank-up the player **chooses 1 of 3** epithets, drawn from the bank for their rank and **current alignment**. Street Rat epithets are your **origin**, chosen at birth while you're still White Rukh. The menu shows the epithet in place of the old fixed "THE MERCHANT'S CHILD", and later it can go on name tags or a leaderboard.

| Rank | Gold Rukh | Gold & Black | Black Rukh |
|---|---|---|---|
| **Street Rat** (origin, White Rukh) | The Merchant's Child · The Exiled Prince/Princess · The Unwanted · The Fisherman's Son/Daughter · The Sand-Born · The Orphan of Qarzin | (same bank at birth) | (same bank at birth) |
| **Wanderer** | The Wayfarer · The Dune Walker · The Far-Traveled · The Lost Star | The Grey Wanderer · The Masked · The Dusk Walker · The Coin-Flip | The Road Thief · The Dust Jackal · The Drifting Blade · The Vagrant |
| **Adventurer** | The Bold · The Treasure Seeker · The Caravan's Shield · The Sword of the Sands | The Sellsword · The Fortune Hunter · The Smuggler · The Double-Edged | The Caravan Raider · The Hired Knife · The Vulture · The Bandit |
| **Renowned** | The Wise · The Generous · The Silver-Tongued · The Pride of the South | The Enigma · The Shadow Broker · The Silver Serpent · The Two-Faced | The Impaler · The Merciless · The Scourge of the Roads · The Cruel |
| **Hero** | The Lionheart · The Shield of the Desert · The Liberator · The Unbowed | The Reluctant Hero · The Twilight Blade · The Dark Champion · The Scarred | The Butcher · The Slaver · The Black Viper · The Tyrant-in-Waiting |
| **Legend** | The Voyager of Seven Seas · The Undying · The Star of the South · The Unbroken | The Eclipse · The Sandstorm · The Storm of the South · The Unreadable | The Harbinger · The Desert's Nightmare · The Fallen Star · The Plague of the Sands |
| **King / Queen** | The Just · The Beloved · The Great · The Conqueror | The King/Queen of Two Rukh · The Iron-Handed · The Pragmatic · The Unyielding | The Tyrant · The Usurper · The Bloody · The Terrible |

The banks are just data. Bryan can add, rename or cut epithets at any time.

## 4. Parked (placeholders, don't load, come back later)

Stored in `ServerStorage/Parked`, so they never run or distract:
- **Magic:** the 8 types (Heat, Water, Light, Lightning, Wind, Sound, Strength, Life), incantation words, Borg barrier and hover, Magoi Blast, the Magoi bar with its low-Magoi stages
- **Races other than Human:** Fanalis, Imuchakk, Magician, Magi, and their rank ladders
- **Kingdoms** (Kou, Sindria, Reim) and the Huang currency
- **Families and lineage** (Ren, Saluja, au Andromedus, Jamil) and inheritance on death
- **Hunger and eating**
- **Parties/alliances, jail, djinn and metal vessels.** (Rukh morality is no longer parked: its light version is in 3a.)

## 5. Technical foundation (how the house is rebuilt)

- **One data service:** one key and one versioned save table. Session locking so two servers can't fight over a save; retries; a clean way to wipe. The save layout leaves room for family and magic later.
- **The server decides.** Clients send intentions ("swing", "block", "buy", "start mission"). The server checks range, cooldowns, state and money, then acts. Every remote is declared in one place, with validation.
- **Clear layout:** one bootstrap per side that loads modules (services on the server, controllers on the client). No scripts inside GUIs, models or Workspace. All code is text in `src/`.
- **Keep Bryan's aesthetic:** art, UI, animations, sounds, cities, names and lore text.

## 6. Open design questions (answered one at a time)

1. **Scope of this renovation:** foundation + character life + rank + economy + Delivery + one new mission tier. Right size? **Bryan: yes, this scope is right (2026-09-26).**
2. Which mission tier comes next: Carriage Escort or Bounty Hunting? **Bryan: Bounty Hunting, with a place where players can find the wanted crooks and put them down.**
3. How much Magoi per mission, and the rank thresholds? **Bryan: approved; see section 3a (ladder reworked into status titles with Rukh epithets).**
4. Real time per in-game year? **Bryan changed this to 30 minutes per year** (debug builds use a shorter value). Aging and progression should both be slow. A life of 13 → 60 is about **23.5 h of play**, so the rank thresholds in 3a scale up to match (see the note there).
5. Day/night: in or out? **Bryan: in, with the cities reacting (lights and fires at night).**

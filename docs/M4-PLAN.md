# Milestone 4: Status and Rukh (plan for Bryan's approval)

Scope from the approved TRIAGE: rank, Rukh alignment and epithets (#25, new) and the HUD (#17). Most of #17 is already done: the health and block bars were rebuilt in M2-04 and the hunger bar is parked. The rank ladder, alignment rule and epithet banks exist as data since M2-06, and the menu already shows rank, epithet and alignment. What is new here is the **moment**: earning a rank, choosing an epithet, and the Rukh flutter. Magoi and deeds are granted by missions in M5; until then the dev commands drive it.

## What the player will notice

- At birth (right after the creation screen) you choose your **origin**: 1 of 3 Street Rat epithets (The Merchant's Child, The Sand-Born, ...). It shows on the menu card in place of the old fixed title.
- When your Magoi crosses a rank threshold (Street Rat -> Wanderer -> Adventurer -> ...), the **Rukh flutters around you** in your alignment's colour (white before you're judged, gold, black, or both), a short card announces the new rank, and you **choose 1 of 3 epithets** drawn from that rank's bank for your current alignment. The choice is saved; if you leave before choosing, it waits for you next time.
- When your deeds tip you from one alignment to another (Gold, Black, Gold & Black), the flutter plays in the new colour and the menu updates.
- Rank keeps raising max health (already wired) and, from M5 on, gates missions and goods.

## Tasks

| ID | Task | Owner | Notes |
|---|---|---|---|
| M4-01 | **RankService** (server). Watches each player's `Progress` (Magoi, GoldRukh, BlackRukh): computes rank and alignment from the shared data; detects rank-ups and alignment changes; on a rank-up stores three epithet choices in the save (`Progress.PendingEpithet = {rank, choices}`) and fires `RankUp {title, choices, alignment}` to the client; `ChooseEpithet(index)` (validated 1-3, only while a choice is pending) sets `Progress.Epithet`; the origin choice at birth reuses the same flow with the Street Rat bank. `AlignmentChanged {alignment}` event. Public API for M5: `AddMagoi(player, amount, reason)`, `AddDeed(player, "Gold" or "Black", amount)`. Takes over the `Rank`/`Epithet`/`Alignment` attributes from HealthService's loop. **First real save migration:** schema v2 adds `Progress.PendingEpithet` (Migrations[2]; SYSTEMS.md section 1 updated). Dev: `.magoi`, `.rukh` already exist; add `.rankup` (force the next threshold) and `.epithet clear`. | server-builder | Sonnet review (data-driven, small) plus a lead check of the migration |
| M4-02 | **RankController + the Rukh flutter** (client). On `RankUp`: the flutter (the Rukh particle emitters from `ReplicatedFirst.VFX.RukhEffects` around the character for a few seconds: `Rukh1-3` for Gold, `DepravityRukh1-3` for Black, both for Gold & Black, `SpecialRukh1-3` for White; Bryan can remap in a small table), then a card in the menu style (Merriweather italic, gold text on the dark card image) with the new rank title and three epithet buttons; sends `ChooseEpithet(index)`. On `AlignmentChanged`: the flutter only. Origin choice at birth: the same card, titled for the origin. Numbers (flutter seconds, emitter counts) in `Config.Rukh`. | client-builder | Sonnet review |
| M4-03 | PLAYTEST.md M4 scenarios and the playtest: Bryan plays the moments (`.magoi 300`, `.rukh 8 1`, rejoin with a pending choice); the agent checks the remote (choose out of range, choose with nothing pending, choose twice). | Bryan + lead + playtester | |

**Order:** M4-01 and M4-02 in parallel (contracts below), then the playtest.

**Contracts:**
- Server -> client: `RankUp {title: string, rankIndex: number, alignment: string, choices: {string, string, string}, origin: boolean}`, `AlignmentChanged {alignment: string}`.
- Client -> server: `ChooseEpithet(index: number 1-3)` (rate 3 per 10 s). Rejected unless a choice is pending; the server uses its stored choices, never a string from the client.
- Player attributes (server): `Rank` (title), `RankIndex`, `Epithet`, `Alignment` (label), `EpithetPending` (bool).
- `Config.Rukh = { FlutterSeconds = 4, CardSeconds = 0 (stays until chosen), Emitters = { White = {...}, Gold = {...}, Black = {...}, GoldBlack = {...} } }`.

**Save format change:** schema v2, `Progress.PendingEpithet: {rank: number, choices: {string}}?` (nil when nothing is pending). Migration fills nothing (nil is the default). Written up in SYSTEMS.md section 1.

**Not in this milestone:** name tags or a leaderboard showing the epithet (later), Magoi from missions (M5).

**Reminder of your open follow-ups** (`docs/FOLLOWUPS.md`): combat feel, heartbeat sound, afterlife cutscene, viewport framing, NPC animations, NPC type attribute, Studio-only script deletions.

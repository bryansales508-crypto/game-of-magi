# M9 plan: Bounty Hunting, the jail, and carrying the knocked out (approved by Bryan 2026-10-03)

> **Bryan's decisions (2026-10-03):** approved as written with two changes. (1) The old jail was time-based; the sentence scales with the bounty, as proposed in section 1.8. (2) **No bounty for knocking someone out** - it could be farmed. In this pass the only crime is intercepting a courier (already live); other crimes come with later systems. Lead defaults for the remaining questions, vetoable: no struggling free while carried; jailing someone with no bounty is refused ("they're not wanted").

Bryan's direction (2026-10-03): M8 (talking NPCs and the tutorial) is shelved until the new combat exists; M9 comes next and grows to three parts: bounties (TRIAGE #26, DESIGN section 3), the **jail** from the old game, and **picking up a knocked-out player** so a hunter can knock out someone with a bounty, carry them to the jail, and have them imprisoned. Nothing below is built until Bryan approves it. Numbers are proposals and go in `Config.Bounty` / `Shared/Data/Bounty.luau`.

## 1. The loop, in plain words

1. **Crimes raise your bounty.** Interception already adds to `Bounty` (M5C). No bounty for knocking people out (Bryan: farmable); later systems add their own crimes. `Bounty` is a number on the save, visible as a player attribute; `.bounty <n> [player]` sets it for testing.
2. **The wanted list.** A `BountyBoard` model per city (Bryan places them, like the delivery boards). Click it: a list of everyone online with a bounty above the posting threshold, their bounty, their last known city (from RegionController's current region, reported by the server every so often, not live tracking). Rank gate: you need **Adventurer** to take a bounty; anyone can read the board.
3. **Take a bounty.** Pick a name: you get a quest-line entry and a tracker that points at their last known city (not at the player). While you hold it, you are not a criminal for knocking them out.
4. **Knock them out.** Combat as it runs today (shelved design, but knockout works). A knocked-out player lies ragdolled for `Combat.Knockout.getUpSeconds`.
5. **Pick them up.** Walk up to a knocked-out player and hold E: they are welded over your shoulder, you walk at `Carry.speedMult`, cannot attack, block, dash or run, and drop them with E again (or when you are knocked out, die, or leave). The carried player stays knocked out while carried and for `Carry.graceSeconds` after being dropped, so a drop isn't a free escape. They see a "You are being carried" state and a dimmed screen, and can do nothing. Anyone knocked out can be carried; only the wanted can be jailed.
6. **Jail them.** Each city with a jail has a `Jail` model with a `JailDrop` part at the door and a `JailSpawn` inside (Bryan places them; the old game had `JailSpawners`). Carry a wanted player to the drop part and press E: they are released from your shoulder inside the cell, their `Bounty` is cleared, you are paid.
7. **The reward:** Copper equal to the bounty (banded by the currency rules), Magoi (DESIGN: 25 to 50, scaled by the bounty), and Gold Rukh. Interception's intercepted-mark rules are untouched.
8. **Serving time.** The prisoner sits in the cell for `Jail.secondsPerBountyPoint x bounty`, clamped to `Jail.minSeconds`..`Jail.maxSeconds`, with a countdown on their screen. The cell has no door they can open; the time is on the save (`Progress.JailUntil`, a server timestamp), so logging out doesn't skip it: rejoin mid-sentence and you spawn in the cell with the remaining time. When it ends, the door teleports them to the city spawn with the bounty at 0. Dying in jail respawns in the cell (sentence continues).
9. **Escape and bail:** none in this pass (see open questions).

## 2. Rules the server guarantees

- The client only ever sends: open board, take bounty by name, drop bounty, pick-up/drop/jail intentions (E), nothing else. The server checks: the target is knocked out, within `Carry.reach`, not already carried, not the carrier; the carrier is not knocked, stunned, carrying, or in jail; the jail drop is within reach; the carried player's bounty is above the posting threshold.
- Payment and Rukh go through EconomyService and RankService (the same paths interception uses), once per imprisonment.
- A carrier who is knocked out or leaves drops the carried player where they stand; the carried player is never left welded to nothing.
- `Bounty`, `JailUntil`, `Wanted` (the current target) live on the save (schema bump, migration for old saves), and the matching player attributes are republished on `DataService.Replaced` like the purse.

## 3. Proposed numbers

| Knob | Proposal | Why |
|---|---|---|
| Crime: intercept a courier | existing | the only crime in this pass (Bryan: no bounty for knockouts, farmable) |
| Posting threshold | 20 | Below it you're a nuisance, not wanted |
| Rank gate to take a bounty | Adventurer (100 Magoi) | DESIGN table |
| Carry speed | 0.6 of walk, no run/dash | Carrying someone is slow and risky |
| Carry grace after drop | 4 s | Dropping isn't an escape |
| Jail: seconds per bounty point | 6 | Bounty 30 = 3 minutes |
| Jail min / max | 60 s / 600 s | Never trivial, never a session-killer |
| Reward Magoi | 25 + bounty / 4, max 50 | DESIGN range |
| Reward Rukh | +1 Gold per imprisonment | TRIAGE #26 |

## 4. Studio pieces Bryan places

- `BountyBoard` model per city (a part to click; the GUI is built from data like the delivery board).
- `Jail` model per city that has one: `JailDrop` part (door, where the hunter presses E) and `JailSpawn` part (inside). Until built, a placeholder like the delivery drop-offs (`Workspace.MissionPlaceholders`).
- Which cities have a jail is data (`Cities.luau`); a city without one sends hunters to the nearest.

## 5. Tasks (after approval)

| ID | Owner | Scope |
|---|---|---|
| M9-01 | server-builder | `BountyService`: crimes, posting, the wanted list payload, take/drop, last-known-city, reward through Economy/Rank; save schema bump; self-tests |
| M9-02 | server-builder | `CarryService` + `JailService`: pick up / drop / jail with every check in section 2; `Carried`, `Carrying`, `Jailed` statuses in StatusService; MovementService hooks; jail timers that survive rejoin; placeholders |
| M9-03 | client-builder | Bounty board GUI (Bryan's board look), quest-line entry and tracker; carry/jail E prompts; the carried and jailed screens with the countdown |
| M9-04 | reviews (Sonnet; Opus for M9-02 since it touches saves and the knockout authority) | |
| M9-05 | Bryan | playtest scenarios in PLAYTEST.md |

## 6. Open questions (one at a time)

1. **How did the old jail work?** Its scripts (`BountyAndJail`, `JailHandler`, `JailSpawners`) were in the previous-game folder we just deleted from Studio, so the rules above are my guess. Was the sentence time-based, bounty-based, or until someone paid? Was there bail or an escape?
2. Should a carried player be able to struggle free (mash a key to shorten the carry)?
3. Does a knocked-out player with NO bounty get anything when jailed (my proposal: the drop is refused with "they're not wanted")?

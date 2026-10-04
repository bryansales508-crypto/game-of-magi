# M9 plan: Bounty Hunting, the jail, and carrying the knocked out (approved by Bryan 2026-10-03)

> **Bryan's decisions (2026-10-03):** approved as written with two changes. (1) The old jail was time-based; the sentence scales with the bounty, as proposed in section 1.8. (2) **No bounty for knocking someone out** - it could be farmed. In this pass the only crime is intercepting a courier (already live); other crimes come with later systems. Lead defaults for the remaining questions, vetoable: no struggling free while carried; jailing someone with no bounty is refused ("they're not wanted"). (3) **A hunter who dies loses the poster** and has to take it from the board again (Bryan, 2026-10-03); a knockout keeps it.

Bryan's direction (2026-10-03): M8 (talking NPCs and the tutorial) is shelved until the new combat exists; M9 comes next and grows to three parts: bounties (TRIAGE #26, DESIGN section 3), the **jail** from the old game, and **picking up a knocked-out player** so a hunter can knock out someone with a bounty, carry them to the jail, and have them imprisoned. Nothing below is built until Bryan approves it. Numbers are proposals and go in `Config.Bounty` / `Shared/Data/Bounty.luau`.

## 1. The loop, in plain words

1. **Crimes raise your bounty.** Interception already adds to `Bounty` (M5C). No bounty for knocking people out (Bryan: farmable); later systems add their own crimes. `Bounty` is a number on the save, visible as a player attribute; `.bounty <n> [player]` sets it for testing.
2. **The board is a real board, not a GUI** (Bryan, 2026-10-03). Bryan places a wooden `BountyBoard` in Qarzin for now (other cities later). The server pins **posters** on it, one per wanted online player: name, bounty, last known city, sorted by bounty, capped at 8, refreshed as the list changes. Anyone can read them; taking one needs **Adventurer**.
3. **The bounty is a tool.** Click a poster: you get a `Bounty: <name>` tool in your hotbar (one at a time). Equip it and a tracker (the delivery one, reused) points at the target's **last known location**, the spot they stood when you took the poster. Reach that spot and it updates to where they are now; so you follow a trail of snapshots, not a live dot. When you come within range of the target (about 80 studs), the tracker fades away and the target gets a **red highlight** for you alone, so the fight isn't cluttered. Lose them for a few seconds and the tracker comes back at the point you last saw them. Unequip the tool and nothing shows; destroy it (or the target stops being wanted, or leaves) and the bounty is dropped. While you hold a bounty you are not a criminal for knocking that target out.
4. **Knock them out.** Combat as it runs today (shelved design, but knockout works). A knocked-out player lies ragdolled for `Combat.Knockout.getUpSeconds`.
5. **Pick them up.** Walk up to a knocked-out player and hold E: they are welded over your shoulder, you walk at `Carry.speedMult`, cannot attack, block, dash or run, and drop them with E again (or when you are knocked out, die, or leave). The carried player stays knocked out while carried and for `Carry.graceSeconds` after being dropped, so a drop isn't a free escape. They see a "You are being carried" state and a dimmed screen, and can do nothing. Anyone knocked out can be carried; only the wanted can be jailed.
6. **Jail them.** Bryan built the jail under `QuestBuilding` on the map (2026-10-03): a large cell, a spawn inside it, and a drop-off outside. The server uses his parts by name (exact paths in SYSTEMS.md once inspected); a city without a jail sends hunters to Qarzin's. **The drop-off glows** (a Highlight the hunter alone sees) only while the hunter holds the poster tool for the person on their shoulder; delivering needs both, so you can't jail someone else's bounty. Drop them on the drop-off: the criminal is teleported into the cell, their `Bounty` is cleared, you are paid. In the cell they can only walk: no jump, run, dash, attack, block or missions. Containment is server-side (teleported back if they leave the cell bounds, jump power 0) with the cell's own walls as the physical barrier; the client adds nothing a cheater could remove.
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

- `BountyBoard` model: a wooden board with a front-facing Part the server pins posters on (Qarzin first; other cities later). Until it exists, the server places a placeholder board like the delivery drop-offs.
- `Jail` model per city that has one: `JailDrop` part (door, where the hunter presses E) and `JailSpawn` part (inside). Until built, a placeholder like the delivery drop-offs (`Workspace.MissionPlaceholders`).
- Which cities have a jail is data (`Cities.luau`); a city without one sends hunters to the nearest.

## 5. Tasks (after approval)

| ID | Owner | Scope |
|---|---|---|
| M9-01 | server-builder | `BountyService`: crimes, posting, the wanted list payload, take/drop, last-known-city, reward through Economy/Rank; save schema bump; self-tests |
| M9-02 | server-builder | `CarryService` + `JailService`: pick up / drop / jail with every check in section 2; `Carried`, `Carrying`, `Jailed` statuses in StatusService; MovementService hooks; jail timers that survive rejoin; placeholders |
| M9-03 | client-builder | No board GUI (the posters are server-built on the board). Client: tell the server when the bounty tool is equipped; show the delivery tracker at `lastKnown` while equipped; on `revealed` hide the tracker and put a red Highlight on the target for the hunter only; carry/jail E prompts; the carried and jailed screens with the countdown |
| M9-04-S | server-builder | `GripService` (section 7): statuses, timing, interrupts, the kill through LifeService, the Black-Rukh reward path in BountyService, dummies grip after a knockout (NpcService Target tree); poster portraits (section 8) in BountyService |
| M9-04-C | client-builder | Grip prompt/key on a knocked player, code-posed grip placeholder for gripper and victim, the gripped screen with the choke progress, interrupt feedback; poster portrait camera framing if the client has to help |
| Reviews | Sonnet; Opus for M9-02 and M9-04-S (saves, knockout and death authority) | |
| Playtest | Bryan | PLAYTEST.md M9 A-H plus the grip scenarios |

## 7. Gripping (Bryan, 2026-10-03, added to M9)

From the old game: **grip** a knocked-out player to kill them. You crouch over them and choke them for `Grip.seconds` (4); if you are interrupted before it ends (any hit lands on you, you are knocked out, you move away, you release the key, or they get up) the grip breaks and they live. If it finishes they **die** (an ordinary death: costs a life, respawn as usual; last life runs the Rukh scene). Rules:
- **Reward:** if the victim is wanted AND you hold their poster, you collect the bounty reward exactly as a jailing would (Copper, Magoi), but the Rukh is **Black**, not Gold, and every grip, bounty or not, adds Black Rukh (`Grip.blackRukh`, 1). No bounty on the gripper (Bryan's rule: knockouts and kills don't add bounty this pass).
- **Dummies grip too:** an NPC that knocks you out walks up and grips you; interrupt it the same way (a landed hit on it, or it gets knocked). Trainers don't (they reset you).
- **Who can be gripped:** any knocked-out player, carried or not (gripping a carried player is refused: put them down first). Jailed players can't grip or be gripped.
- **Animation:** Bryan makes the real grip animation later. Until then the client poses it in code: gripper kneeling over the victim, hands at the neck, victim flat; a `Config.Bounty.Grip.Animations` slot takes the asset ids when they exist.
- **Server authority:** the grip is a server state (`Gripping`/`Gripped` statuses); the client sends start/stop only; progress and the kill are server-timed; the interrupt hooks are CombatService's landed-hit path and StatusService.

## 8. Posters show the face

A poster shows **who you're looking for**, not just a name: a ViewportFrame on the poster with a clone of the wanted player's current character (skin, face, hat, clothes) framed like a wanted-poster portrait, with name and bounty under it. The server clones the character into the poster when it's pinned and refreshes the clone when the player's look changes (respawn, new clothes).

## 6. Open questions (one at a time)

1. **How did the old jail work?** Its scripts (`BountyAndJail`, `JailHandler`, `JailSpawners`) were in the previous-game folder we just deleted from Studio, so the rules above are my guess. Was the sentence time-based, bounty-based, or until someone paid? Was there bail or an escape?
2. Should a carried player be able to struggle free (mash a key to shorten the carry)?
3. Does a knocked-out player with NO bounty get anything when jailed (my proposal: the drop is refused with "they're not wanted")?

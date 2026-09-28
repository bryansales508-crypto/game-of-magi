# Milestone 3B: combat stance, unlock, and training dummies (plan for Bryan's approval)

Follows the fighting-style framework (M3-FIX4). Bryan's direction, 2026-09-28: players don't start with combat; they earn it in a tutorial (talking NPCs come later, after the planned milestones). Combat is entered with a key; only then do clicks attack. Weapons: equip the tool, then the key or a click enters combat with that weapon's style. Stance animations so others can see who is in combat (placeholders until Bryan makes them). A set of training dummies, each with one habit, in an order that teaches the rock-paper-scissors loop; a dev command spawns them so everything can be tested now.

## 1. Combat stance (basis for all future combat)

- **Key:** `C` toggles combat (Bryan can change it in `Config.Combat.StanceKey`). Entering requires: combat unlocked, alive, not knocked or in a scene. Leaving is instant. Knockout leaves combat automatically.
- **Server-owned:** the client sends `SetStance(on)`; the server validates and sets the character attribute `InCombat`. `AttackStart` is rejected unless `InCombat` is true, so clicks outside the stance are nothing, on the server as well as on the client.
- **Weapons:** the style comes from the equipped tool (server-side: a `Weapon` tag or attribute on the Tool, mapped to a style name; the fist is the style when no weapon tool is equipped). Pressing the key or clicking with a weapon tool equipped enters combat with that style and the click becomes the first hit. Unequipping the weapon in combat drops you to Fist. Until the shop (M5) hands out real tools, `.weapon Fist|Dagger` keeps working as the dev shortcut and the dagger stays a visual.
- **Stance animations:** one looping idle per style, `Config.Combat.StanceAnimations = { Fist = "", Dagger = "" }` (empty = none; Bryan fills the ids). Played on the character while `InCombat`, on every client (attribute-driven), so others see who is ready to fight. A small stance indicator over the head is not needed; the animation is the tell.
- **HUD:** nothing new; the block bar already exists. Optional later: dim the block bar outside the stance.

## 2. Unlock

- Save field `Meta.Unlocks = { Combat = false }` (schema v3; in `Meta` so it survives death: once a player completes the tutorial, every future life starts with fist combat; a wipe makes a new player again; migration fills `Combat = true` for existing saves). Bryan 2026-09-28: per player for ever, repeatable later, no menu indicator needed. The tutorial sets it later; for now `.unlock combat [player]` and `.lock combat [player]`.
- `Config.Combat.UnlockedByDefault = true` until the tutorial exists (new lives start unlocked in Studio and live); Bryan flips it to false when the teacher NPC ships. Locked players can't enter the stance; the client shows a short "You don't know how to fight yet" line in the menu font.

## 3. Training dummies (each is an NPC style of its own, behavior tree + config, Fist style)

Spawned with `.dummy spawn <name>` at the caller's position facing them; `.dummy clear` removes them all; `.dummy list` shows the roster. Each has a name over the head and full health; they reset (get up, refill) after a knockout. They only fight the player who spawned them or the nearest player within 12 studs. In teaching order:

| # | Dummy | Habit | What it teaches |
|---|---|---|---|
| 1 | **Straight Sam** | Throws light-heavy straight, never cancels, on a fixed rhythm | Blocking, then the parry timing (parry his light, punish) |
| 2 | **Turtle Tariq** | Always blocks, never attacks, never parries | Heavies drain and break block; punish the break |
| 3 | **Jabbing Jamal** | Interrupts: jabs the moment your heavy wind-up starts | Cancel the heavy into block and parry his jab (the bait) |
| 4 | **Parry Pete** | Blocks and always parries your first light | Cancel to make the parry whiff, then land the delayed hit |
| 5 | **Feinting Mohammed** | Only feints: light, cancel the heavy, re-jab (Fist style, super telegraphed) | Don't bite on the heavy; read the cancel highlight and punish the re-jab |
| 6 | **Dashing Dalila** | Dashes out of every heavy wind-up | Spacing and the follow-up after a landed light |
| 7 | **Sparring Sinbad** | Picks throw / cancel / parry / dash with tunable weights | The whole loop; the final exam |

Weights, rhythms and reaction delays live in `Config.Npc.Trainers`, so Bryan tunes each one. Every dummy's reaction has a small delay (`reactionSeconds`) so they are beatable and readable. The teacher NPC and dialogue come with the talking-NPC milestone; until then these are dev-spawned only.

## 4. Testing (M3B playtest)

Bryan runs one scenario per dummy (spawn, do the taught answer, confirm the log and the feel). The agent runs only the cheat checks: `SetStance` while locked or knocked, `AttackStart` outside the stance, style claims from the client (must be impossible: the style is server-derived).

## Tasks

| ID | Task | Owner |
|---|---|---|
| M3B-01 | Server: stance (`SetStance` remote, `InCombat` attribute, attack gating), tool-to-style mapping, unlock flag + schema v3 + dev commands, stance animation attribute | server-builder (Opus review: gating is security) |
| M3B-02 | Server: the seven trainer trees + `Config.Npc.Trainers` + `.dummy spawn/clear/list`, name billboards, reset after knockout | server-builder |
| M3B-03 | Client: `C` key stance toggle, clicks only in stance, weapon-click enters combat, stance idle animation per style (placeholders), locked message | client-builder |
| M3B-04 | PLAYTEST.md M3B scenarios (one per dummy) and the playtest | Bryan + lead + playtester |

**Later (new milestone after M6):** talking NPCs and the tutorial: the alley teacher, dialogue, the dummies introduced one by one, the unlock at the end.

**Reminder of your open follow-ups:** combat feel, rank and Rukh tweaks, heartbeat sound, afterlife cutscene, viewport framing, NPC animations, NPC type attribute, Studio-only script deletions, and now: stance animations and marker names per style.

## 6. Lives (Bryan, 2026-09-28)

A character has 4 lives (`Config.Life.LivesPerCharacter`). Every death from any cause except a heart attack costs one life and the character simply respawns, no scene. The death that takes the last life plays the return-to-the-Rukh scene and wipes to a completely new character with 4 lives. A fatal heart attack ignores lives and always wipes. Knockouts are not deaths. The combat unlock is account-wide (`Meta.Unlocks.Combat`), so the new character keeps it. `Meta.Lives` stays the incarnation count; the new field is `Character.LivesLeft`. Dev: `.lives <n>`, `.kill`.

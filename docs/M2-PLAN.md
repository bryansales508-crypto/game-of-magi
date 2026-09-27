# Milestone 2: A life (plan for Bryan's approval)

Scope from the approved TRIAGE: character creation (#3), aging with visible aging and death (#4), health (#14), the character menu (#18). Everything below keeps Bryan's look: the same faces, skins, hair, FalseHead, starter rags, the Gender screen, the menu card, the HUD bars, and the old game's return-to-the-Rukh scene.

## What the player will notice

- Character creation works the same (Masculine/Feminine, skin) but is now a client screen with one server-checked remote. Names match the chosen gender. Skin colours match what was picked.
- You age at **30 real minutes per year** while playing (Studio: 60 seconds, and the `.timescale` command speeds it up). Away from the game you age **2 years per real day**, never past 59.
- From about 45 your hair greys in gradually. From **60**, every birthday you are online for rolls a rising chance of death.
- Death plays the **return-to-the-Rukh** scene (the glowing character walking into the Rukh), then you start a **completely fresh life**: new random face, hair and name, age 13, 20 copper, starter rags. Lives are counted on the save.
- Max health grows with height (finally) and with rank. Health and block regen tiers actually change the rate; the block bar refills at a sane speed.
- The M menu shows your name, kingdom, age and height as before, plus your **rank title**, **epithet** and **Rukh alignment** in place of the fixed "THE MERCHANT'S CHILD". The clipped stat line and the black character preview are fixed.

## Tasks

| ID | Task | Owner | Replaces (deleted when done) |
|---|---|---|---|
| M2-01 | **CharacterService** (server): builds the look from the save exactly like `AppearanceController` did (skin by tone and kingdom, FalseHead and face decals, hair colour, hitbox, sounds, starter rags, hats and clothes), with the audit fixes: one shared collision group (M8), skin template names checked (P4), magician eye colours reachable (L2), `ToolGrip` wired or dropped (L6). Creation: a `CreateCharacter(gender, skin)` remote, validated 1-2 / 1-3 on the server, that also rolls the gender-matched first name (L3). `FaceControl` and the custom `Animations` swap become part of it. | server-builder | `Character/AppearanceController/*` (script only; the template rbxm children move under the service), `Animations.server.luau`, the Studio-only `Gender.Decisions` script (disabled at runtime, Bryan deletes it in Studio) |
| M2-02 | **AgeService** (server): the aging loop on the new save, with `AgeHandler` growth maths and `HeightHandler` kept (ported to strict; hair scale fix L5). Config: `Aging.SecondsPerYear` (1800 live, 60 Studio) times `.timescale`; offline aging 2 years/day capped at 59; birthday resize; **visible aging** (hair greys from 45 to 70; wrinkles only if a face decal exists, otherwise noted as an art task); **death roll** from 60 with a rising chance table in Config; `Meta.Lives`. Fires `Died` for the scene, then `SaveSchema.NewLife` and a respawn. | server-builder | `Character/AgeController.server.luau`; `AgeHandler`/`HeightHandler` move under `Server/` |
| M2-03 | **HealthService** (server): max health = base + height bonus + rank bonus; regen tiers (idle, combat, knocked) with real rates (L8, M11); block value and its refill; exposes what M3 combat needs (`TakeDamage`, `SetTier`). Player attributes (`Health`, `MaxHealth`, `Block`, `Age`, `Rank`, `Epithet`, `Alignment`) are the cheap replication path the client reads. | server-builder | `StarterCharacterScripts/Health.server.luau`, `BlockHealthRegen.server.luau` |
| M2-04 | **Client: creation, menu, HUD** controllers using the existing rbxm GUIs (same look): `CreationController` (the Gender screen, sends the remote), `MenuController` (M key; name, kingdom, age, height, rank, epithet, alignment; live ViewportFrame preview instead of the black diamond; stat line fits), `HudController` (health and block bars from attributes). | client-builder | `StarterGui/HUD/HealthHandler.client.luau`, `BlockHandler.client.luau`, the Studio-only `MenuMechanics` script (disabled at runtime, Bryan deletes it in Studio) |
| M2-05 | **Client: return-to-the-Rukh scene** (`RukhController`): the old `WipeHandlerPart2` scene rebuilt (camera, frozen input, golden neon body, walk into the Rukh), triggered by the server's `Died` event, ending with the fresh spawn. The old `AfterLife` model is **gone from the place** (checked 2026-09-27), so this task builds a simple stand-in from the old script: golden neon body, frozen input, scriptable camera, a walk into a Rukh particle core; Bryan restores the real art later. | client-builder | old `DeathHandlerPart1/2`, `WipeHandlerPart1/2` (reference only, already not in the game) |
| M2-06 | **Shared data**: `Shared/Data/Ranks.luau` (the Magoi ladder and titles from DESIGN 3a, pure `rankFor(magoi)`), `Shared/Data/Epithets.luau` (the banks), `Shared/Data/Alignment.luau` (`alignmentFor(gold, black)`, White/Gold/Black/Gold&Black). Data only; the rank-up flow itself is M4. | server-builder (first, small) | nothing |
| M2-07 | Playtest scenarios for M2 and the M2 playtest | lead + playtester | |

**Order:** M2-06 → M2-01 → M2-02 → M2-03 in one server session; M2-04 → M2-05 in one client session, starting once M2-01's remote and attribute names are fixed in the prompt (they are, below). Reviews: Opus for M2-01 and M2-02 (creation and death touch the save), Sonnet for the rest.

**Contracts** (so both sides build in parallel):
- Remote `CreateCharacter` (client → server, `gender: number 1-2`, `skin: number 1-3`, rate 3/10s). Server replies through attribute `Gender` becoming non-zero.
- Player attributes set by the server: `Age`, `MaxHealth`, `Health`, `Block`, `MaxBlock`, `Rank` (title string), `Epithet`, `Alignment`, `Kingdom`, `HeightStuds`, `Lives`.
- Remote `Died` (server → client, `cause: string`): the client plays the scene, then fires `RukhSceneDone` (client → server, no args, rate 2/60s); the server respawns the fresh life on that, or after a 30 s timeout.

**Legacy bridge:** stays. After M2 it still feeds `Stats`/`OnCharacter` Values for the market, missions, items and combat until M3–M5 rebuild them.

**Save format changes (SYSTEMS.md §1 gets updated):** none to the schema. `Meta.Lives` increments on death. `Age.TimePassed` is now the last online tick, used for offline aging.

**Studio-only removals for Bryan after M2 passes:** the `Decisions` Script inside `ReplicatedFirst.GUI.Gender` and the `MenuMechanics` LocalScript inside `MenuGUI` (both disabled by the new controllers at runtime until then).

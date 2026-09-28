# Milestone 6: World, in phases (draft 1, 2026-09-29, for Bryan's approval)

What M6 covers (TASKS.md, from the approved TRIAGE): day/night and city lights (#27, **new**), regions and music (#15, **rebuild**), footsteps (#16, **rebuild**), the ocean (#23, **rebuild**), collisions (#22, **keep**, moved into the new layout), and the end of the **legacy bridge** (the old `player.Stats` / `player.OnCharacter` Value folders), since the region and footstep scripts are its last readers.

Everything here is built on the read-only Studio survey in `docs/reference/m6-studio-dump.md` (2026-09-29) plus the old code in `src/`.

## What the survey found (plain language)

- **Regions.** Only seven invisible region parts exist: four `OceanREGION`, two `QarzinREGION`, one `SakuraIslandREGION`. The old client script also handled Badlands, Qishan City, Endless Desert, Bandit Camp, Gourge, Sultan Chest, Desert Lair Tunnel, Rain, Slept and Low Health. None of those parts exist any more: previous-game leftovers (AUDIT D5). The rebuild is data-driven so you add a region by dropping a new `<Name>REGION` part in `Workspace.Regions` and one line of data.
- **Music.** All 62 sounds live in `ReplicatedFirst.SFX`. Today the server clones every OST into every character's Torso on spawn, and the client plays from those clones: a full copy of the soundtrack per player, per life. Two OSTs have no asset (Lullaby, WandFlick). Your "volume feels finicky" note: playlist tracks are tweened to 0.05 while looped singles go to 0.5, and the fade-out wait is inverted so music cuts instead of fading (AUDIT L21).
- **Day/night.** The only day/night driver is `ServerStorage.Folder.Day/Night Cycle`, and scripts in ServerStorage never run, so the live game is frozen at 13:30. The sky, sun and moon are Roblox defaults; the warm look comes from the Atmosphere (orange, density 0.25), ColorCorrection tint and Bloom. That look is kept as the daytime palette.
- **City lights.** Essentially unbuilt: six blue PointLights in two Qarzin models and six Neon parts in the whole map. No fires, torches, lamps or braziers exist. The system ships with a tag; placing the lights is your Studio work (see 6B).
- **Ocean.** 256 folders, 1,279 anchored parts, 766 server scripts, each with its own per-frame Heartbeat connection. Half of them (the `OceanWaves` copies) have a copy-paste bug and only ever move up once. Net effect on screen today: the `MovingPart` tiles bob 2 studs over 15 s up, 3 s hold, 15 s down; the wave decals fade in and out over 10 s each way with a 10 s pause. That timing is what the new script keeps.
- **Collisions.** `MapCollisionGroup` and `ClothingRackGroup` are set by a startup script that scans the whole map; the player-limb group is already one shared group in `CharacterService` (AUDIT M8 was fixed in M2). Two leftover group names (`RebornNoMoreCollisionGroup-HRT`, with and without the hyphen) sit on 18 parts from the previous game.

## Decisions proposed (Bryan approves, vetoes or changes each)

1. **Region detection and music are client-only.** No server, no remotes, no `RegionInfo` folder. Music is presentation; nothing on the server needs to know which region you are in. Detection is a position test every 0.25 s against the region parts' boxes (no `Touched`), so walking through walls or teleporting can never get you stuck in the wrong music (AUDIT M16 class of bug).
2. **One soundtrack, no per-player copies.** The client plays straight from `ReplicatedFirst.SFX.OSTs`. `CharacterService` stops cloning OSTs into every Torso. Step sounds also stop being cloned (6C).
3. **Music volume is one number.** `Config.World.Music.Volume` (default 0.5, the value most of your tracks were authored at), ambient loops keep their own per-track volume in data (Rain 0.2, Ocean 0.6 as today), crossfade 1 s, shuffle without repeating the last track, and a one-track playlist just loops.
4. **Day/night is a shared clock, computed on each client.** The server sets two attributes on `Workspace` once (`DayStart` = server time the day began, `DayLength` = seconds per in-game day). Every client derives `Lighting.ClockTime` from `GetServerTimeNow()` each frame, so all players see the same time, late joiners are in sync, and no replication traffic exists. Proposed default: **the old game's timing**, found in that ServerStorage script: 10 real minutes of daylight (06:00 to 18:00) and 6 real minutes of night (18:00 to 06:00), a 16-minute day. Your call on the length.
5. **The night palette is data.** Daytime keeps today's exact Atmosphere, ColorCorrection and Bloom values (from the survey). `Shared/Data/DayNight.luau` holds the dusk, night and dawn values for Atmosphere colour/decay/density, ColorCorrection tint, Brightness and OutdoorAmbient; the client tweens between them. You tune the night look in one file (TINKER.md entry).
6. **City lights react by tag.** Any part tagged `CityLight` (CollectionService, set in Studio's Tag Editor) turns on at dusk and off at dawn: its `PointLight`/`SpotLight`/`SurfaceLight` children get `Enabled`, its `Fire`/`ParticleEmitter` children too, and if the part itself is Neon it swaps to `SmoothPlastic` by day and back at night. All of that runs on the client (each player's own lights), with a 2 s tween on brightness. Placing lamps, torches and fires is Studio art work you do; the six existing bulbs are a first test.
7. **Footsteps are client-only.** The sound and the sand or mud print are made on the stepping player's own client, so no remote and no server work per step (TRIAGE #16). Other players do not see your footprints. If you want shared prints later, it is a small server addition.
8. **The ocean is one client script.** It drives every `MovingPart` and `OceanWaves` tile and every wave decal from one Heartbeat with `BulkMoveTo`, with the timing above, amplitude and periods in Config. The 766 Studio scripts must be deleted by you first (a one-line command-bar snippet in TINKER.md), because while they run the server keeps overwriting the tile positions. Until you delete them the new script stays off (`Config.World.Ocean.Enabled = false`).
9. **Collisions become a service.** `CollisionService` registers the groups and assigns map parts at Init, fixes L9 and L18, and leaves `CharacterService`'s player group as is. The two `RebornNoMore...` names are left alone (they do nothing) and listed for you to clean in Studio if you like.
10. **The legacy bridge goes.** Once 6A and 6C land, nothing reads `player.Stats`, `player.OnCharacter` or `player.Loaded`; `LegacyBridge` and those folders are deleted in 6E. The `IntFold` movement bridge is separate and stays until its own readers go (see "Not in M6").

## Phases

### Phase 6A: Regions and music (client)
- `Shared/Data/Regions.luau`: per region key (`Qarzin`, `SakuraIsland`, `Ocean`, plus the old keys kept as commented examples): playlist track names, ambient loop name and volume, banner title and subtitle ("Q A R Z I N", "The Merchant's Playground"), and a `priority` so a city inside an ocean region wins the music while the ocean ambient keeps playing underneath.
- `Client/Controllers/RegionController`: reads `Workspace.Regions` (all descendants named `*REGION`), tests the root part's position against each box every 0.25 s, fires local `Entered`/`Left`; respawn-safe.
- `Client/Controllers/MusicController`: the playlist player (shuffle, crossfade, ambient layer, volumes from data and Config), the city banner from the `MsgHold[CITY]` template with the same bounce-in / drop-out animation, and `Config.World.Music`.
- Server: `CharacterService` stops cloning `OSTs` into the Torso (one small edit; the `SoundsFolder` goes).
- Removed: `SCS/Scripts/RegionHandlerPart1.client.luau`, `SSS/MISC/RegionHandlerPart2.server.luau`, `RS/Modules/SoundController.luau`.
- Dev: `.region` (prints the regions you are in), `.music <track>|stop`.
- Fixes: L21, M16, D5.

### Phase 6B: Day/night and city lights
- `Shared/Data/DayNight.luau`: day length, night hours, the four palettes (day = today's values verbatim, dusk, night, dawn), light tween time.
- `Server/Services/WorldClockService`: sets `Workspace` attributes `DayStart`/`DayLength` at start; dev `.time <0-24>` (shifts `DayStart` so everyone jumps together), `.time speed <x>`, `.time pause`.
- `Client/Controllers/LightingController`: `Lighting.ClockTime` from the shared clock each frame; palette tweens at the transitions; `CityLight` tag handling with a 2 s fade; a tagged part added later (Streaming or Studio) is picked up through `GetInstanceAddedSignal`.
- Studio (you): delete `ServerStorage.Folder.Day/Night Cycle`; tag the six Qarzin bulbs `CityLight` to test; then place lamps, torches and fires at your pace (FOLLOWUPS entry).
- Fixes: nothing broken; DESIGN §3 "cities react to the day".

### Phase 6C: Footsteps (client)
- `Client/Controllers/FootstepController`: Roblox's `Animate` keeps its step timing but fires a client-side BindableEvent instead of the old remote; the controller picks the sound by `Humanoid.FloorMaterial` (no raycast for the sound), volume by the `Running` character attribute, and skips the sound while the character has the `MutedStep` marker; sand and mud prints by one local raycast per step, fading out as today (ColorMath stays for the darkening).
- Sounds play from `ReplicatedFirst.SFX.Steps` directly; `CharacterService` stops cloning them.
- Removed: `Server/Services/FootstepService.luau`, the `MiscRemotes.Footstep` remote, `Animate`'s remote lines (Animate itself stays; it is Roblox's script with your hooks).
- Fixes: M7, L10.

### Phase 6D: Ocean (client)
- `Client/Controllers/OceanController`: collects the tiles and decals once, drives them from one Heartbeat with `BulkMoveTo` (511 tiles) and a transparency curve for 255 decals; `Config.World.Ocean` = `Enabled`, `Amplitude` (2), `RiseSeconds` (15), `HoldSeconds` (3), `DecalFadeSeconds` (10), `DecalPauseSeconds` (10). Only tiles within `CullDistance` of the camera are moved (the map is huge and the tiles are 2,048 studs wide, so the default is generous).
- Studio (you): run the TINKER.md snippet that deletes every Script under `Workspace.MAP.OCEAN` (766 scripts), then set `Enabled = true`.
- Fixes: M17.

### Phase 6E: Collisions and the end of the legacy bridge (server)
- `Server/Services/CollisionService`: registers `MapCollisionGroup` and `ClothingRackGroup` at Init, assigns map parts (all BaseParts under `Workspace.MAP`, Unions included, `Areas` excluded if it ever exists) and rack parts, and exposes `AssignMapPart(part)` for anything spawned later. `ShopService` and `CharacterService` keep their own group writes.
- Removed: `SSS/Interactions/CollisionsHandler.server.luau`, `Server/Services/LegacyBridge.luau` and the `player.Stats` / `player.OnCharacter` / `player.Loaded` mirrors, the `SSS/Character/AgeHandler.luau` and `HeightHandler.luau` shims (their last reader was the Studio-only clothes stocker, which 5B replaced).
- Guard: a self-test greps nothing at runtime, but the review confirms no file under `src/` still references `Stats`, `OnCharacter`, `Loaded`, `SoundsFolder` or `RegionInfo`.
- Fixes: L9, L18; closes the M2 bridge.

### Playtest (Bryan, after each phase merges)
- 6A: walk into Qarzin: the banner bounces in, a Qarzin track fades in; leave: it fades out over 1 s; stand at the shore: the ocean ambient layers under the city music; a rejoin mid-region starts the right music; `.music stop`.
- 6B: `.time 18.5` and watch dusk arrive for everyone in the server; the tagged bulbs light up; `.time 5.5` for dawn; a late joiner sees the same clock; night is dark but readable (tune `DayNight.luau`).
- 6C: steps sound different on stone, dirt and sand; running is louder; prints appear on sand and mud and fade; no Output spam; `.state` shows no per-step server work.
- 6D: after deleting the scripts and enabling, tiles bob and decals breathe with the old timing; the server's script count under OCEAN is 0; frame rate at the shore is steady.
- 6E: clothes racks still let you walk through them; the map still collides; no `Stats`/`OnCharacter` folders under your Player; the self-test passes.

### Not in M6 (so nothing gets lost)
- `Services/EffectsService.server.luau` (creates `character.Effects`, server ragdoll, the `MutedStep`/input-lock markers) and `SCS/Scripts/InputHandler.client.luau` are M3 leftovers still in use; they and the `IntFold` movement bridge get their own cleanup task when the last readers go (proposed as the first task of M7).
- The 18 parts on the `RebornNoMore...` collision groups: Studio-only cleanup, harmless.
- The two empty OSTs (Lullaby, WandFlick) and the loud combat sounds (SwordClangSound1 at 3.0, the BattleCries at 5.0): your asset tuning, listed in FOLLOWUPS.
- `ServerStorage.Folder` holds about twenty previous-game scripts (party, jail and bounty, carriage and escort, spells, leaderboard, the old death and currency handlers). None run there. They are a reference for M8 (bounties, escort) and otherwise yours to delete in Studio; nothing in M6 touches them.

## Order and cost
6A and 6C are pure client work and can run in parallel with 6B (server clock + client lighting) and 6E (server). 6D waits for your Studio deletion. Two cloud builders at a time, Sonnet reviews except 6E (Opus, since it deletes the bridge and touches every player's collision). Estimated four build sessions and three reviews of cloud credit; the lead's local work is merges and docs only.

**One question for Bryan:** how long should an in-game day be, and which hours count as night? (Proposed: the old 16-minute day, 10 minutes of light and 6 of dark. Say "keep" or give two numbers.)

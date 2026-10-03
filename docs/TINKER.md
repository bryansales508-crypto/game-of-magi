# Tinkering guide

Where each knob lives and what it does. Every file here syncs through Rojo; after editing, restart Play. Numbers live in data files, not in the logic. `Config` means `src/ReplicatedStorage/Shared/Config.luau`, `Data/` means `src/ReplicatedStorage/Shared/Data/`. `Config` is frozen at load, so runtime changes go through a dev command.

## Debug and saves
- `Config.Debug.Enabled`: on in Studio; makes every player a dev. `LogLevel`: how chatty Output is. `TimeScale`: speeds aging and the day clock (use `.timescale` at runtime).
- `Config.Debug.FreshSave`: `true` gives a blank save every Studio run. `SaveScope`: `Studio` or `Live` (never change by hand).
- `Config.Debug.DeathRolls`: whether birthdays can kill. Off in Studio; `.mortal on|off` flips it live.
- `Config.Dev.Admins`: UserIds that count as devs on a live server.
- `Config.Data.SchemaVersion`: bump only with a migration in `Shared/SaveSchema.luau`. Starting values for a new character (coins 20 Copper, age 13) are in `SaveSchema.Template`.

## Aging and lives
- `Config.Aging.SecondsPerYear` (1800 live, 60 Studio): one in-game year of real time.
- `OfflineYearsPerDay` (2), `OfflineAgeCap` (59), `AdultAge` (18): offline aging and when growth stops.
- `GreyStart` / `GreyEnd` (45 / 70): hair greying range.
- `DeathStart` (60) and `DeathChance`: from when each birthday is a heart attack, and the odds it is fatal at each age.
- `SceneTimeout`, `Tick`: how long the server waits for the Rukh scene, and how often the aging loop runs.
- `Config.Life.LivesPerCharacter` (4), `RespawnDelay` (3 s): lives per character and the pause before a respawn.
- Heartbeat sound: `Config.Sfx.Heartbeat` (asset id). Pulse timing: `Config.Scene` (`BeatGap`, `PairGap`, `NonFatalCycles`, `FatalCycles`, `FatalSlowFactor`, `MessageSeconds`).
- Afterlife scene: your model `ReplicatedFirst.AfterLife` (the code reads only `AfterlifeCamera`, `AfterlifeSpawnBlock`, optional `AfterlifeCore`); pacing in `Config.Scene` (`WalkSeconds`, `FadeSeconds`, `CoreDistance`).

## Health
- `Config.Health.Base`, `HeightBonus`, `RankBonus` (per rank): max health.
- `RegenPerSecond` (Idle / Combat / Knocked), `Tick`, `CombatTierSeconds`: health regeneration.
- `MaxBlock`, `BlockRegenPerSecond`: the block meter.

## Movement and combat (combat is shelved; numbers kept for the redesign)
- `Data/Combat.luau`: `Run` (speed multiplier, walk is 16), `Dash` (cooldown, distance, duration, wall sweep), `Block` (parry window, break stun), `Knockout` (get-up time, health on get-up), `Knockback` (every N hits taken), and every style's chain (damage, range, timing windows, stun, block drain, bleed).
- `Config.Combat.ComboSpeed` per style: the one speed knob; windows in `Combat.luau` are authored in animation seconds and retimed from it.
- `Config.Combat.Chain` (`HitGap`, `ClickTimeout`, `Recovery`, `DropRecovery`, `WatchdogMargin`) and `HitTolerance`: pacing and network slack.
- `Config.Combat.Markers` / `LogMarkers`: animation event names per style; with logging on, one swing prints each event and its time.
- `Config.Combat.StanceKey` (C), `StanceAnimations`, `ComboAnimations`, `MoveAnimations`, `DashTrail`: keys, animation ids and dash lines.
- `Config.Combat.UnlockedByDefault`: `true` unlocks combat for everyone until the tutorial exists.
- `Config.Character.Animations`: your walk, run, jump, fall and idle ids (players and NPCs).

## NPCs and trainers
- `Config.Npc`: `TickSeconds`, `ChaseRadius`, `GiveUpRadius`, `AttackRange`, `AttackCooldown`, `ContinueDelay`, `WanderRadius`, `MaxHealth` per type, `Animations` (Walk/Run/Flinch fallback ids).
- `Config.Npc.Trainers.<Key>`: per-trainer `reactionSeconds`, `rhythmSeconds`, `engageRadius`, Sinbad's `weights`. `TrainerOrder` is the list order.
- A model under `Workspace.NPC` with attribute `NpcType` = `Target` chases and punches; `Dummy` only flinches.
- New trainer: add its `Config.Npc.Trainers` entry and `TrainerOrder` key, write its decide function in `Server/Services/NpcService/Trees.luau`, add it to `TRAINER_DECIDERS`.

## Rank, Rukh and epithets
- `Data/Ranks.luau`: the Magoi thresholds and rank titles.
- `Data/Epithets.luau`: the epithet banks per rank and alignment (gendered entries).
- `Data/Alignment.luau`: `MinDeeds` (5) before you are judged, `Lean` (0.65) share to count as Gold or Black.
- `Config.Rukh`: `FlutterSeconds`, `EmitRate`, `Emitters` (which `ReplicatedFirst.VFX.RukhEffects` emitters play per alignment).
- The look of the flutter and the card: `Client/Controllers/RankController/init.luau`.

## Money and shop
- `Data/Economy.luau`: coin ratios (1 / 100 / 10,000) and the banded display rule.
- `Data/Shop.luau`: stand model names, `StandardColors` and `VarietyColors` (weights, price multipliers), the price formula, `StockDelaySeconds`, `HoldDuration`.
- Flavour lines when you can't pay: top of `Server/Services/EconomyService.luau`.

## Delivery missions
- `Config.Missions`: `OpenStuds` / `BoardCloseStuds` (board range), `ArriveStuds`, `TimeCrunchSeconds`, `HeavyCargoSpeedMult`, `HeavyCargoPackScale`, `MagoiPerDelivery`, `Tick`.
- Interception: `InterceptMinStuds`, `InterceptMinSeconds` (anti-farming), `InterceptedDecay`, `InterceptedFloor` (the intercepted mark).
- Beacon: `Config.Missions.Beacon` (`everySeconds` 45, `forSeconds` 3). `PlaceholderDeliveryPoints`: drop-offs for unbuilt cities. `PlayerActiveThreshold`, `SafeRouteThreshold`: modifier odds inputs.
- `Data/Cities.luau`: each city (name, colour, lore, safety, population, image), and every modifier (chance, pay multiplier, text).
- Wording of the "Merchants doubt you..." line: `INTERCEPTED_NOTICE_FORMAT` in `Client/Controllers/MissionController/init.luau`.

## World
- `Config.World.DayNight`: `DaySeconds` (600), `NightSeconds` (360), `DawnHour`, `DuskHour`, `TransitionSeconds`, `LightFadeSeconds`, `Tag` (`CityLight`), `DayMaterial`. Day must stay longer than night.
- `Data/DayNight.luau`: the four looks (Day, Dusk, Night, Dawn): sky, ambient, atmosphere, colour tint, bloom.
- City lights: tag a part or whole model `CityLight` in Studio's Tag Editor. Lights, fires and particles under it run at night; Neon goes matte by day. A torch is a model with a flame part and a separate light part; tag the model.
- `Data/Regions.luau`: per region `priority`, `playlist` (track names in `RF.SFX.OSTs`), `ambient` loop, `banner`. A region is a part named `<Key>REGION` under `Workspace.Regions`; several parts can share a key.
- `Config.World.Music`: `Volume`, `CrossfadeSeconds`, `RegionPollSeconds`.
- `Config.World.Footsteps`: `WalkVolume`, `RunVolume`, `PrintSeconds`, `PrintRayStuds`, `FallbackStrideStuds`, `RunStepSeconds`, `Debug` (logs every step to find silent ones).
- `Config.World.Sfx.Dash`: name of the dash sound under `RF.SFX.CombatSounds`.
- `Config.World.Ocean`: `Enabled` (off by default), `Amplitude`, `RiseSeconds`, `HoldSeconds`, decal fade values, `CullDistance`.
- Menu preview framing: `Client/Controllers/MenuController/init.luau`, the preview camera block (search "FIX BUG-21").

## Effects and sounds (Studio)
- Particles and VFX live in `ReplicatedFirst.VFX`; code that clones them: `MissionService` (Highly Valuable sparkles), `EffectsController` (hits, dash lines).
- Sounds live in `ReplicatedFirst.SFX`. Levels to check: `SFX.OSTs.Lullaby` and `SFX.Magic.WandFlick` have no SoundId; `SwordClangSound1` is 3.0 and both BattleCry sounds 5.0 (the rest are 0.1 to 0.5).

## Dev commands
Type in chat (leading `.`) or the backquote panel; `.cmd` lists them live. F8 shows a live status overlay.
- State and saves: `.state [player]`, `.watch on|off`, `.save`, `.fresh`.
- Money: `.coins <c> [s] [g]`, `.coins+`, `.price <copper>`, `.pay <coin> <amount>`.
- Progress: `.age <n>`, `.age+ <n>`, `.birthday`, `.heart [fatal]`, `.mortal on|off`, `.lives <n>`, `.kill`, `.magoi <n>`, `.magoi+ <n>`, `.rukh <gold> <black>`, `.rankup`, `.epithet clear|<text>`, `.bounty <n>`.
- Health: `.hp <n>`, `.tier <Idle|Combat|Knocked>`.
- Travel and world: `.tp <city>`, `.cities`, `.time [0-24|speed <x>|pause|resume]`, `.timescale <n>`, `.region`, `.music stop|play|next|volume <0-1>`, `.lights on|off|auto`, `.shop restock|list`.
- Missions: `.mission start <city>`, `finish`, `fail`, `streak <n>`, `mark [n]`, `intercept`, `log on|off`.
- Combat and NPCs: `.combat log on|off`, `.weapon <Fist|Dagger>`, `.style`, `.knock`, `.stun <s>`, `.lock combat`, `.unlock combat`, `.npc list|reset|type <name> <Dummy|Target>`, `.dummy spawn <Key>|clear|list`.

## Reading the logs
Every script logs `[Tag] message` through `Shared/Log.luau`; `[WARN]` lines are rejected or dropped actions, red lines are bugs. `[SelfTest] PASS (n checks)` at server start means the rules still hold.

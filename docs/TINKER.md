# Tinkering guide

Where each knob lives and what it does. Almost every number is in `src/ReplicatedStorage/Shared/Config.luau` (called **Config** below) or in a data file under `src/ReplicatedStorage/Shared/Data/` (**Data/**). Edit, let Rojo sync, restart Play. In Studio everyone is a dev; type `.cmd` in chat for the live command list.

Server services live in `ServerScriptService/Server/Services/`, client controllers in `StarterPlayer/StarterPlayerScripts/Client/Controllers/`. The server decides everything that matters; clients only send intentions.

## Debug and saves
- `Config.Debug.Enabled`: dev commands and the dev panel are on (Studio only; live uses `Config.Dev.Admins` user ids).
- `Config.Debug.FreshSave`: true starts every Studio join with a brand-new save.
- `Config.Debug.TimeScale`: speeds up aging and the day clock for tests (1 = real time).
- `Config.Debug.DeathRolls`: whether birthdays can kill; off in Studio so `.age` never ends a test character (`.mortal on|off` flips it live).
- `Config.Data.SchemaVersion`: bump together with a new migration in `Shared/SaveSchema.luau`.

## Movement
- `MovementService.luau` top: `WALK_SPEED = 16`.
- `Data/Combat.luau` `Combat.Run.speedMult`: run speed is walk times this (1.75).
- `Combat.Dash`: `cooldown`, `distance`, `duration`, and the wall check (`castRadius`, `wallMargin`, `minDistance`).
- Dash distance shrinks with low health and with Heavy Cargo (same multiplier that slows walking), so a hurt or loaded courier dashes shorter.
- Low health slows you: `MovementService.LowHealthMult` runs from full speed down to half (running) or a quarter (walking) at 0 health.
- `Config.Missions.HeavyCargoSpeedMult`: speed while carrying Heavy Cargo.
- `Config.Character.Animations`: idle, walk, run, jump and fall animation ids for players and NPCs.

## Health
- `Config.Health.Base`, `HeightBonus` (per stud of height), `RankBonus` (one entry per rank, Street Rat first): max health.
- `Config.Health.RegenPerSecond`: health regained per second in the `Idle`, `Combat` and `Knocked` tiers; `CombatTierSeconds` is how long after a hit you stay in `Combat`.
- `Config.Health.MaxBlock`, `BlockRegenPerSecond`: the block bar.
- There are no overhead health bars; the HUD bar is the only one.

## Aging and lives
- `Config.Aging.SecondsPerYear`: real seconds per game year (60 in Studio, 1800 live).
- `OfflineYearsPerDay`, `OfflineAgeCap`: years gained per real day away, and the age offline time cannot pass.
- `AdultAge`, `GreyStart`, `GreyEnd`: when growth stops and when hair greys.
- `DeathStart` and the `DeathChance` table: from that age every birthday has a heart-attack moment; the table is age to odds of it being fatal.
- `SceneTimeout`: how long the server waits for the return-to-the-Rukh scene before starting the new life anyway.
- `Config.Life.LivesPerCharacter`: deaths (falls, drowning) before a brand-new character. `RespawnDelay`: pause before respawning with lives left.
- `Config.Scene`: pacing of the heartbeat pulses and the afterlife walk (`BeatGap`, `PairGap`, `NonFatalCycles`, `FatalCycles`, `FatalSlowFactor`, `WalkSeconds`, `FadeSeconds`). `Config.Sfx.Heartbeat` is the sound id.
- The scene's look lives in `RukhController` and the `ReplicatedFirst.AfterLife` model (`AfterlifeCamera`, `AfterlifeSpawnBlock`, optional `AfterlifeCore`).

## Rank and Rukh
- `Data/Ranks.luau`: the seven rank titles and the Magoi each one needs.
- `Data/Epithets.luau`: the epithet choices per rank and alignment.
- `Data/Alignment.luau`: `MinDeeds` before you are judged, `Lean` (share of deeds a side needs to count).
- `Config.Rukh`: the flutter's `FlutterSeconds`, `EmitRate` and which particle emitters each alignment uses.

## Currency
- `Data/Economy.luau`: 1 Gold = 100 Silver = 10,000 Copper; `toPrice` picks the coin a price shows in (one whole coin, no change). All rewards pay Copper.
- A fresh character starts with 20 Copper (`SaveSchema.luau`).

## Shop (Qarzin clothes stand)
- `Data/Shop.luau`: `ClothingBaseCopper` is the base price; `TypeMult` scales it per item type (hat, cloak, shirt, pants).
- `StandardColors` and `VarietyColors`: colour names, rarity `weight` and `priceMult`.
- `HoldDuration`: seconds you hold the prompt to buy. `StockDelaySeconds`: delay before the stand is stocked at server start.
- `PantsDisplayName`: the fixed name every pants prompt shows.
- Clothing pools come from `ReplicatedFirst.Assets`.

## Missions
- `Data/Cities.luau`: the seven cities (name, colour, lore, personality, `safety`), `Routes` (which cities each can send you to), and the modifier table (weight `chance`, `payMultiplier`, text).
- `Config.Missions.MagoiPerDelivery`: Magoi per completed delivery.
- `OpenStuds`, `BoardCloseStuds`: how close you must be to open the board and how far before it closes. `ArriveStuds`: how close counts as arrived.
- `PlayerActiveThreshold`, `SafeRouteThreshold`: when the Active-route and Safe-route modifiers apply.
- `TimeCrunchSeconds`, `HeavyCargoPackScale`: the Time Crunch timer and the size of the Heavy Cargo package.
- `InterceptMinStuds`, `InterceptMinSeconds`: how far out a courier must be before knocking them out pays.
- `InterceptedDecay`, `InterceptedFloor`: each interception halves that player's offers, never below a tenth.
- Beacon: `Config.Missions.Beacon.everySeconds` (45) is the gap between pulses, `forSeconds` (3) how long each lasts; the client fades it in and out. Highly Valuable keeps the package glowing the whole run.
- Placeholder drop-offs: a city with no `<Key>Delivery` part uses its `<Key>REGION` part, or the point in `PlaceholderDeliveryPoints`. A city with neither refuses runs. The tracker points at the real drop-off when it exists.
- `Tick`: how often arrival, expiry and the beacon are checked.

## Bounty hunting
- `Config.Bounty.PostingThreshold` (20): the bounty at which a player is wanted (postered, huntable). `RankGateIndex` (3 = Adventurer): the rank needed to take one.
- `MaxPosters` (8): posters on the board, highest bounty first. `CityRefreshSeconds` (20): how often a wanted player's last known city is re-read.
- `Tracking.TickSeconds` (1), `ReachStuds` (25), `RevealStuds` (80), `LoseSeconds` (6): how the equipped bounty Tool follows the target (see SYSTEMS.md section 17).
- `Reward`: `MagoiBase` 25 + bounty / `MagoiDivisor` 4, capped at `MagoiCap` 50; `GoldRukhDeeds` 1. Copper paid equals the bounty.
- The board: a Part named `BoardName` (QuestBoard, or `BoardAltName` BountyBoard) with a Decal named `FrontDecalName` (frontface); posters go on the decal's face, sized `Poster.Width` x `Height` (shrunk to fit). No board = a placeholder in `Workspace.BountyPlaceholders` at Qarzin.

## Carrying and the jail
- `Config.Bounty.Carry`: `ReachStuds` (6) how close to pick someone up; `SpeedMult` (0.6) the carrier's walk speed; `GraceSeconds` (4) how long the dropped stay down; `Offset` and `TiltDegrees` where the body rides on the shoulder (tune in Studio); `RefreshSeconds` how often the knockout is renewed; `DropDistance` how far in front a drop lands.
- `Config.Bounty.Jail`: `JailFolderName`, `DropoffName`, `CellFolderName`, `SpawnName` the names the server looks for (rename here if Bryan renames the parts); `BoundsMargin` (2) grows the cell box; `ReachStuds` (8) from the dropoff zone; `SecondsPerBountyPoint` (6), `MinSeconds` (60), `MaxSeconds` (600): the sentence; `TickSeconds` (1): how often prisoners are checked; `PlaceholderOffset`: where the stand-in cell goes when no real jail exists.
- `Data/Cities.luau` `hasJail`: which city gets a placeholder jail (Qarzin).
- Commands: `.jail <seconds> [player]`, `.jail release [player]`, `.carry drop`. To test: knock a player out (`.knock`), stand within 6 studs and send `CarryPickUp` (client prompt comes in M9-03), then `.carry drop`.

## World
- Music: `Data/Regions.luau` (per region `priority`, `playlist`, `ambient`, `banner`); `Config.World.Music` has `Volume`, `CrossfadeSeconds`, `RegionPollSeconds`. A region is a part named `<Key>REGION` under `Workspace.Regions`. The music panel and `.music` change the track and volume for you only.
- Day and night: `Config.World.DayNight` (`DaySeconds`, `NightSeconds`, `DawnHour`, `DuskHour`, `TransitionSeconds`, `LightFadeSeconds`); the four looks are in `Data/DayNight.luau`. Tag a lamp part or model `CityLight` and it lights only at night (`Tag`, `DayMaterial`).
- Footsteps (`Config.World.Footsteps`): `WalkVolume`, `RunVolume`, sand/mud print `PrintSeconds`, `FallbackStrideStuds` (a step every N studs if the animation markers do not fire), `RunStepSeconds`, `Debug` (logs every step).
- `Config.World.Sfx.Dash`: the dash whoosh sound, under `ReplicatedFirst.SFX.CombatSounds`.
- Ocean: `Config.World.Ocean.Enabled` stays false until the old wave scripts under `Workspace.MAP.OCEAN` are deleted; then `Amplitude`, `RiseSeconds`, `HoldSeconds` and the decal timings shape the waves.

## Combat (shelved; kept for the redesign)
Combat is shelved and will be redesigned from the top. Its numbers stay where they are: `Config.Combat` (chain pacing, animation ids, markers, speeds), `Config.Npc` (training dummies), and `Data/Combat.luau` (damage, block, parry, knockout, fighting styles).

## Dev commands
Server commands (`DevService`, checked on the server; `.cmd` lists them):
- State and saves: `.state`, `.watch on|off`, `.save`, `.fresh` (wipes the save; the coin purse refreshes), `.timescale <n>`, `.mortal on|off`.
- Life: `.age`, `.age+`, `.birthday`, `.heart [fatal]`, `.lives <n>`, `.kill`.
- Rank: `.magoi`, `.magoi+`, `.rukh <gold> <black>`, `.rankup`, `.epithet <text>` or `.epithet clear`.
- Money and shop: `.coins`, `.coins+`, `.price <copper>`, `.pay <coin> <amount>`, `.shop restock|list`.
- Health: `.hp <n>`, `.tier Idle|Combat|Knocked`.
- Travel: `.tp <city>` (a city's spawn, else its drop-off or region), `.cities`.
- Bounty: `.bounty <n> [player]`, `.bounty list`, `.bounty take <player>`, `.bounty drop`, `.bounty clear [player]`.
- Missions: `.mission start <city>|finish|fail|streak <n>|mark [n]|intercept|log on|off`.
- World: `.time [0-24 | speed <x> | pause | resume]`.
- Combat (shelved): `.combat log on|off`, `.knock`, `.stun <s>`, `.weapon Fist|Dagger`, `.style`, `.unlock combat`, `.lock combat`, `.npc list|reset|type`, `.dummy spawn <name>|clear|list`.

Local commands (`DevController`, run on your own client, typed in chat or the dev panel):
- `.region`: lists the regions you are in.
- `.music`: now playing; `.music next`, `.music stop`, `.music play`, `.music volume <0-1>`, `.music <track name>`.
- `.lights on|off|auto`: force the city lights.

Keys: F8 shows the state overlay, the backquote key opens the dev panel.

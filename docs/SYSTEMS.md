# SYSTEMS

The map of Game of Magi as it runs today. Written for Bryan: plain language first, then files, remotes and data. Server code is `src/ServerScriptService/Server/` (one `Main.server.luau` that loads every module in `Services/`), client code is `src/StarterPlayer/StarterPlayerScripts/Client/` (one `Main.client.luau` that loads every module in `Controllers/`), shared code and data is `src/ReplicatedStorage/Shared/`. Every service and controller has `Init()` (set up, never yields) then `Start()` (may yield). Names below are shortened: `SSS` = ServerScriptService, `RS` = ReplicatedStorage, `RF` = ReplicatedFirst.

Rules that hold everywhere: the server decides everything that matters and validates every remote; the client only sends intentions and draws what the server says. All remotes are declared once in `Shared/Remotes.luau` (name, argument types, per-player rate limit) and live in `ReplicatedStorage.Net`. Logging goes through `Shared/Log.luau` (`[Tag] message`).

---

## 1. Join and saves

**What it does.** Each player has one save, loaded when they join and written when they leave or the server shuts down. Two servers can never hold the same save at once. A join runs in a fixed order: save loads, character is built, character is placed at the Qarzin spawn, player is marked ready, and the loading screen lifts. If the save can't load the player is kicked with a "rejoin in a moment" message.

**Files.** `SSS/Server/Services/DataService.luau` (the save), `Packages/ProfileStore.luau` (vendored save library, unchanged), `RS/Shared/SaveSchema.luau` (the save's shape and upgrades), `SSS/Server/Services/PlayerService.luau` (join order), `Client/Controllers/LoadController` (loading screen, art in `LoadScreen.rbxm`), `Services/NetService.luau` (creates the `Net` remote folder, `DebugPing`).

**Depends on.** `Config`, `Log`, `Remotes`. Everything that reads a save uses `DataService.Get/WaitFor`.

**Save.** DataStore name `Config.Data.StoreName` (`GameOfMagi_v1`). Key: `<SaveScope>_<UserId>`, where the scope is `Studio` in Studio and `Live` on a real server, so playtests never touch live saves. `Config.Debug.FreshSave = true` gives a blank save every run (Studio only). Schema version **4** (`Config.Data.SchemaVersion`):

```
Version
Character = { FirstName, Gender (0 = not chosen), Race (2 = Human), Kingdom, SkinTone (0 = not chosen),
              HairColor {R,G,B}, EyeColor, FaceBase, MouthShape, Height (10 = not rolled),
              GrowthProfile, LivesLeft }
Age       = { Years, TimePassed (os.time of last aging tick), ProgToAge (seconds toward next birthday) }
Progress  = { Magoi, GoldRukh, BlackRukh, Epithet, PendingEpithet? = { rank, choices {3} },
              DeliveryStreak, Routes = { [cityKey] = deliveries }, Intercepted (stacks) }
Bounty
Economy   = { Copper (starts 20), Silver, Gold }
Gear      = { Shirt, Pants, Hats {3 slots}, Inventory {item codes} }
Family, Magic = {}  (reserved)
Meta      = { Created, LastSeen, Lives (how many characters this player has had), Unlocks = { Combat } }
```
Upgrades: `SaveSchema.Migrations[N]` turns version N-1 into N (v2 and v4 add fields only; v3 sets `Unlocks.Combat = true` and a full `LivesLeft` for older saves). Missing fields are filled from the template first. Any change to this shape is written here and bumps the version.

**API.** `DataService.Get(player)`, `.WaitFor(player, timeout)`, `.IsLoaded`, `.Wipe(player)` (blank save, clears unlocks), `.NewLife(player)` (new character, keeps `Meta.Lives`, `Meta.Created`, `Meta.Unlocks`), `.Save(player)`, `.OnReleasing(handler)`, and `.Replaced` (fires after a wipe or new life so other services re-publish). `PlayerService.IsReady/WaitForReady/GetState`.

**Attributes.** Player `JoinState`: `Loading` -> `Loaded` -> `Ready`, back to `Loading` on every respawn. The loading screen waits for `Loaded`, fades, then fires `ClientReady`.

**Remotes.** `ClientReady` (client -> server, no args), `DebugPing` (string up to 50 characters).

---

## 2. Character creation and appearance

**What it does.** A brand-new life sees the creation screen (your `Gender` GUI): pick Masculine or Feminine and a skin tone, then Enter. The server checks the pick, rolls a first name matching the gender, and builds the body. On every spawn the server rebuilds the look from the save: strips the default avatar, applies skin, the FalseHead face, hair colour, a shared collision group, the combat hitbox, sounds and particles, the saved (or a starter) outfit, hats, and your run/walk/jump/idle/fall animations. A live face reacts to chat (mouth), blinks, and looks hurt when hit.

**Files.** `Services/CharacterService/init.luau` (+ `FaceControl/`, skin templates `Black/Brown/Tan/LightTan/White.rbxm`, `FalseHead.rbxm`, `NormMeshie.rbxm`), `Client/Controllers/CreationController`, `RF/Assets/init.luau` (names, face bases, clothing ids; the data tables the builder reads).

**Depends on.** Saving, Aging (hair grey, height), Items (outfit), `RF.Assets`, `Config.Character.Animations`.

**Remote.** `CreateCharacter(gender 1|2, skin 1|2|3)` (client -> server). Only honoured while `Character.Gender == 0`.

**Attributes (Player).** `Gender`, `SkinTone`, `Kingdom`, `FirstName`, `HeightStuds`, `Lives`, `Age`. The creation screen closes when `Gender` becomes non-zero. Character values `AppearenceLoaded` (BoolValue) and the `Effects` folder still exist because `Animate` and the FaceControl module wait on them (see section 17).

**Also.** `CharacterService.HideOverheadDisplay` hides Roblox's default name and health bar on players. `StatShim` hands the old `RF.Assets` helpers the stat values they expect.

---

## 3. Aging, death and lives

**What it does.** One shared loop banks real seconds into each player's age; `Config.Aging.SecondsPerYear` (1800 live, 60 in Studio) makes a birthday. Birthdays resize the body up to adulthood (18) and grey the hair between 45 and 70. Time offline ages you 2 years per day, capped at 59, and never kills. From age 60 every online birthday is a heart attack: a heartbeat and red pulse that passes, or, by a rising chance (5% at 60 to 100% at 100), a fatal one. A fatal heart attack plays the return-to-the-Rukh scene and starts a brand-new character.

**Lives per character.** A character has `Config.Life.LivesPerCharacter` (4) lives. Any real death (falling, the void, drowning; a combat knockout is not a death) costs one and respawns the same character after `RespawnDelay` (3 s). Losing the last one plays the same Rukh scene (cause `lastLife`, no heartbeat) and wipes to a new character. A fatal heart attack wipes regardless of lives left. `Players.RespawnTime` is pushed out to an hour so only our code respawns players.

**Files.** `Services/AgeService/init.luau` (loop, birthdays, death sequence), `AgeService/AgeHandler.luau` (growth maths), `AgeService/HeightHandler.luau` (body resizing), `Services/LifeService.luau` (lives, `HandleDeath`), `Client/Controllers/RukhController` (pulses and the scene).

**Depends on.** Saving, Character, Health (max HP follows height), Dev (time scale, mortal toggle).

**Remotes.** `HeartAttack(age, fatal)` and `Died({cause = "lastLife"})` (server -> client); `RukhSceneDone` (client -> server; the server also starts the new life after `Config.Aging.SceneTimeout`).

**Attributes (Player).** `Age`, `Lives`, `LivesLeft`, `Dying`.

**Dev.** `.age`, `.age+`, `.birthday`, `.heart [fatal]`, `.mortal on|off`, `.lives <n>`, `.kill`, `.timescale`.

**Scene.** Your model `RF.AfterLife` is used if present (code only reads `AfterlifeCamera`, `AfterlifeSpawnBlock`, optional `AfterlifeCore`); otherwise a stand-in plays. Input is fully disabled during the scene. Timings: `Config.Scene`.

---

## 4. Health and status

**Health.** `HealthService` sets max health = `Config.Health.Base + HeightBonus x height + RankBonus[rank]`, regenerates it by tier (`Idle` 2/s, `Combat` 0, `Knocked` 1; the Combat tier lasts `CombatTierSeconds` after any hit), and owns the block meter (`MaxBlock` 100, refills 10/s, paused while blocking). Players and NPCs use the same path. It also ticks Bleed (1 HP floor).

**Status.** `StatusService` is the one owner of statuses on any combatant (player or NPC): `Hit, Stun, Knocked, Ragdoll, Block, BlockBroken, TrueStun, LightStun, Recovery, Bleed`. `Apply(character, status, duration?, data?)`, `Remove`, `Has`, `Get`, `Changed` signal. Each status mirrors to a character attribute and, for the original four, to the old `character.Effects` value markers that Animate/FaceControl/FootstepController still read.

**Attributes.** Player (for the HUD and menu): `Health`, `MaxHealth`, `Block`, `MaxBlock`, `RegenTier`. Character: `Stunned`, `Knocked`, `Blocking`, `TrueStunned`, `LightStunned`, `Recovering`, `BlockBroken`, `Bleed` (stack count).

**Files.** `Services/HealthService.luau`, `Services/StatusService.luau`, `Client/Controllers/HudController` (health and block bars, rebuilt on every respawn because the HUD GUI resets).

**Dev.** `.hp <n>`, `.tier <Idle|Combat|Knocked>`, `.stun`, `.knock`.

---

## 5. Movement

**What it does.** `MovementService` is the only thing that writes `WalkSpeed`. Each character has a stack of named multipliers (`Run`, `Block`, `Stun`, `TrueStun`, `Knocked`, `Hit`, `LowHealth`, `HeavyCargo`); the smallest wins and 0 freezes. Walk is 16, run is 28 (double-tap W). Low health slows walk, run and dash immediately. Dash (Q + direction) is a server-checked burst with a cooldown, swept against walls so nobody is flung through them, shortened by every movement modifier and the weapon's `dashCooldownMult`; it is refused mid-swing.

**Files.** `Services/MovementService.luau`, `RS/Modules/SpeedHandler.luau` (a thin shim kept for old callers). Numbers: `Shared/Data/Combat.luau` (`Run`, `Dash`).

**Remotes.** `Run(boolean)`, `Dash(x, z)` (each -1..1, character-relative), both client -> server intentions. Results broadcast through `CombatEvent` (`Run`, `Dash`).

**Attributes.** Character `SpeedMult`, `Running`, `NextDashAt`. A leftover `character.IntFold` folder (one child per modifier, `Running?`) is still filled for HealthService, Animate and the HUD (section 17).

---

## 6. Combat (shelved)

Combat is **shelved for a from-scratch redesign** after M12 (Bryan, 2026-10-03). Do not tune or extend it; log bugs and fix only what breaks something outside combat. What runs today, in one paragraph: press `C` for the stance (locked until `Meta.Unlocks.Combat`, currently granted to everyone by `Config.Combat.UnlockedByDefault`), click to start an animation-driven Fist or Dagger chain (one click per hit, an infinite loop of lights), `F` blocks and parries, right-click cancels, Q dashes; every hit is checked by `CombatService` against timing windows from `Shared/Data/Combat.luau`, a landed hit light-stuns and interrupts the target, the sixth hit taken knocks back, health 0 is a knockout (ragdoll, blind, get-up after a few seconds), Dagger bleeds. Seven trainer dummies fight back with behaviour trees (section 8).

**Files.** Server: `Services/CombatService.luau` (the core), `RagdollService.luau`, `RS/Shared/Data/Combat.luau` (numbers), `RS/Shared/Config.luau` `Config.Combat` (pacing, animation ids, marker names). Client: `Controllers/CombatController/` (+ `SwingTrack.luau`), `EffectsController` (sounds, particles, knockout screen, dash lines). `RS/Modules/Ragdoll/` builds the joints. `RF/ShapecastHitbox` and `RF/Tools` are art and library assets.

**Remotes.** Client -> server: `AttackStart`, `AttackHit(index)`, `AttackContinue(index)`, `AttackCancel`, `Block(bool)`, `SetStance(bool)`, plus `Run`, `Dash`. Server -> client: `CombatEvent(kind, data)` for `Swing, SwingContinue, Hit, Miss, Blocked, Parried, BlockBroken, Knocked, Recovered, KnockedBack, Bleed, AttackCancelled, AttackEnded, Run, Dash`.

**Attributes (character).** `InCombat`, `WeaponSet`, `Attacking`, `CurrentHitIndex`, `NextAttackAt`, `HitCount`, `ComboStep`, `CombatUnlocked`.

**Dev.** `.combat log on|off`, `.weapon <Fist|Dagger>`, `.style`, `.knock`, `.stun`, `.lock combat`, `.unlock combat`.

---

## 7. NPCs and trainers

**What it does.** `NpcService` finds models under `Workspace.NPC` (or tagged `NPC`), registers each exactly like a player (status, movement, health, combat) and ticks their behaviour tree on one shared loop. Types: `Dummy` (flinches only) and `Target` (chases within `ChaseRadius` 30, gives up past 40, punches within 4). Seven trainers (`StraightSam, TurtleTariq, JabbingJamal, ParryPete, FeintingMohammed, DashingDalila, SparringSinbad`) are spawned on demand by dev command and each teaches one habit. Knocked-out trainers reset to full health. A client-side `NpcAnimController` gives every tagged NPC the player's animation set from the server's own state.

**Files.** `Services/NpcService/init.luau`, `AiController.luau`, `Trees.luau`, `RS/Shared/BehaviorTree.luau`, `Client/Controllers/NpcAnimController`. Numbers: `Config.Npc`.

**Dev.** `.npc list|reset|type <name> Dummy|Target`, `.dummy spawn <Key> [player]`, `.dummy clear`, `.dummy list`.

---

## 8. Ragdoll

`RagdollService` builds ragdoll joints (via `RS/Modules/Ragdoll`) when `Knocked` starts on any combatant and removes them when it ends. For players the owning client's `EffectsController` flips the Humanoid state; for NPCs the server does. It also creates the `character.Effects` folder that StatusService, FaceControl and the client wait for, and writes the `Ragdoll` status for the dazed face.

---

## 9. Rank, alignment, Rukh and epithets

**What it does.** Magoi sets your rank (Street Rat 0, Wanderer 300, Adventurer 600, Renowned 1500, Hero 2400, Legend 4200, King/Queen 6000). Gold and Black Rukh deeds set your alignment: under 5 deeds you are White; at 65% of deeds one way you are Gold or Black; otherwise Gold & Black. At birth and at every rank-up you pick one of three epithets from a bank for your rank and alignment; the pick becomes your title in the menu. A pending choice is saved and the card returns after a rejoin. The Rukh flutters around you in the alignment colour on a rank-up and on every Rukh gain that changes alignment.

**Files.** `Services/RankService.luau`, `RS/Shared/Data/Ranks.luau`, `Epithets.luau`, `Alignment.luau`, `Client/Controllers/RankController` (flutter and card), `RF.VFX.RukhEffects` (emitters, art).

**API.** `RankService.AddMagoi(player, amount, reason)`, `.AddDeed(player, "Gold"|"Black", amount)`, `.GetRank`, `.GetAlignment`. Every change to Magoi or Rukh goes through these.

**Remotes.** `RankUp({title, rankIndex, alignment, choices, origin})` and `AlignmentChanged({alignment})` (server -> client); `ChooseEpithet(1..3)` (client -> server, the server only trusts the index).

**Attributes (Player).** `Rank`, `RankIndex`, `Epithet`, `Alignment`, `EpithetPending`.

**Dev.** `.magoi`, `.magoi+`, `.rukh <gold> <black>`, `.rankup`, `.epithet clear|<text>`, `.bounty`.

---

## 10. HUD and menu

**HUD.** `StarterGui.HUD` (your art) shows the health and block bars; `HudController` fills them from the player attributes in section 4. **Menu.** `M` opens the character card cloned from `RF.GUI.UIGUI.MenuGUI`: name, title (epithet, else rank), a stat line (kingdom, age, height), a second line (alignment, life number), a live mirror preview of your character in the diamond, and the apparel frames. `MenuController` reads only player attributes. **Backpack and hotbar** are still your original `StarterPlayerScripts/BackpackGUI.client.luau` (slated to fold into a controller). **Hunger** is parked (section 18).

**Files.** `Client/Controllers/HudController`, `MenuController`; art in `StarterGui/HUD/HudFrame.rbxm` and `RF/GUI/UIGUI/*.rbxm`.

---

## 11. Currency

**What it does.** Three coins: 1 Gold = 100 Silver = 10,000 Copper. A price shows as one whole coin, banded: 100 Copper or less is Copper, 101-10,000 is Silver (rounded up), above that Gold. Paying is **exact coin only**: Silver can only pay a Silver price. A refused purchase makes your character say "I need more money" or "I need to convert" (exchanging is the Bank's job, later). Rewards are paid in Copper. A coin sound plays on every purse change after the first paint.

**Files.** `Services/EconomyService.luau`, `RS/Shared/Data/Economy.luau` (ratios and the banding rule), `Client/Controllers/CurrencyController` (purse GUI, coin messages in chat).

**API.** `EconomyService.Get/CanAfford/Pay/Give/GiveCopperValue`.

**Remote.** `CoinMessage(text)` (server -> client). **Attributes (Player).** `Copper`, `Silver`, `Gold`, republished after `.fresh`, a wipe or a new life.

**Dev.** `.coins`, `.coins+`, `.price <copper>`, `.pay <coin> <amount>`.

---

## 12. Items and the clothes shop

**Items.** `ItemService` handles wearables: an item code is `type|name|r,g,b` (S shirt, P pants, H hat, C cloak). `Equip` recolours and resizes to the body; `Owns` checks item and colour; `Wear` equips and writes `Gear.Shirt/Pants/Hats` (max 3 hats).

**Shop.** `ShopService` stocks the Qarzin clothes stand (`Workspace.Qarzin.ClothesStand`) five seconds after the server starts, from `Shared/Data/Shop.luau` (colours with weights and price multipliers; price = ceil(80 x type x colour)). Prompts show the whole-coin price; every refusal (can't afford, hats full, already own that colour) happens before charging; a purchase pays through EconomyService and wears through ItemService. `ShopController` highlights only the rack you hover, for you alone, and shows one E prompt at a time (empty racks are skipped; a fallback covers gamepad and touch).

**Files.** `Services/ItemService.luau`, `Services/ShopService.luau`, `Client/Controllers/ShopController`, `RS/Shared/Data/Shop.luau`, clothing art in `RF/Assets/*.rbxm`.

**Dev.** `.shop restock|list`. The old Studio script `Workspace.Qarzin.ClothesStand.ClothingSpawn` is disabled at startup and slated for deletion in Studio.

---

## 13. Delivery missions

**What it does.** Press E at a city's `*Delivery` part to open that city's board: the other cities on the route, each with lore, a pay preview and rolled modifiers. Start a run and the package straps on, a tracker points at the drop-off, and a beacon highlights you through walls for 3 s every 45 s. Reach the destination within `ArriveStuds` to be paid in Copper, earn Magoi (10) and a Gold Rukh, and add to your streak. Modifiers: Time Crunch (3 min), Courier Loop (return leg), Highly Valuable (the package glows for the whole run), Heavy Cargo (slower, bigger pack), Very Important Noble, Fragile Package, Clear the Route. Failing a modifier only drops its bonus; only leaving, dying, respawning or interception end a run. Bonuses add (1.2 and 1.3 give 1.5).

**Interception.** If another player knocks a courier out at least `InterceptMinStuds` (100) or `InterceptMinSeconds` (30) into the run, the courier's run fails and the interceptor is paid the run's reward once, plus Black Rukh and bounty. Each interception adds an "intercepted mark" stack to the courier: their board offers halve per stack (floor 10%); an interceptor of a marked courier gets the reduced pay and no Black Rukh; one completed delivery clears the mark.

**Pay.** `floor(1 + 10/rankIndex + players x 1.25 + streak x 1.25)` x combined modifiers x offer multiplier. Modifier odds come from the player's own route history and each city's `safety`.

**Cities.** Saleh, Ain Jamala, Qarzin, Sahraqin, Illegal Port, Rathole, Jaddaty's Hut (`Shared/Data/Cities.luau`). Only Qarzin is built; an unbuilt city gets a magenta placeholder drop-off at its region centre (`Workspace.MissionPlaceholders`).

**Files.** `Services/MissionService.luau`, `RS/Shared/Data/Cities.luau`, `Client/Controllers/MissionController` (board, tracker, pop-outs, beacon), art in `RF/GUI/MissionGUI/*.rbxm`.

**Remotes.** `MissionOpenBoard(cityKey)`, `MissionStart(cityKey)`, `MissionExit()` (client -> server; city keys are validated against the list and the board the server opened). `MissionBoard({city, destinations = {{key, name, color {r,g,b}, lore, image, pay, modifiers}}, intercepted, offerMultiplier})` or nil to close; `MissionUpdate({state, destination, destinationPosition {x,y,z}, modifiers, failed, pay, returnPosition?, timerEnds?})` (server -> client).

**Attributes.** Player `OnMission`, `MissionDestination`, `MissionStreak`, `Bounty`; character `CourierBeacon`.

**Dev.** `.mission start <city>|finish|fail|streak <n>|mark [n]|intercept|log on|off`.

---

## 14. World: regions, music, day and night, footsteps, collisions, ocean

- **Regions and music.** A region is an invisible part named `<Key>REGION` under `Workspace.Regions` (Qarzin, SakuraIsland, Ocean are defined in `Shared/Data/Regions.luau`). `RegionController` tests your position against the boxes on your own client every 0.25 s. `MusicController` plays the winning region's playlist, shuffled, crossfading; adds an ambient layer; shows the city banner; and draws a bottom-left panel (track name, play/stop, volume).
- **Day and night.** `WorldClockService` publishes `DayStart`, `DayLength`, `DayPaused` on `Workspace`; every client's `LightingController` derives the same hour from them (10 min day, 6 min night). Parts or models tagged `CityLight` light at dusk and go dark at dawn. Palettes: `Shared/Data/DayNight.luau`.
- **Footsteps.** Local to each player. `FootstepController` hears Animate's `FootstepEvent`, plays a step sound by floor material from `RF.SFX.Steps`, and leaves a fading print on sand and mud; run steps follow the run animation. `StarterPlayerScripts/RbxCharacterSounds.client.luau` replaces Roblox's sound script without the default Running sound. A dash plays `SFX.CombatSounds.QuickDash`.
- **Collisions.** `CollisionService` puts every part under `Workspace.MAP` in the map collision group and every `ClothingRack` part in a group players walk through.
- **Ocean.** `OceanController` bobs the tiles under `Workspace.MAP.OCEAN` from one client loop; it is off until `Config.World.Ocean.Enabled = true`.

**Files.** `Client/Controllers/RegionController, MusicController, LightingController, FootstepController, OceanController`, `Services/WorldClockService.luau`, `Services/CollisionService.luau`. **Dev.** `.time`, `.region`, `.music`, `.lights`.

---

## 15. Dev commands and self-tests

**Who is a dev.** In Studio everyone is. Live, only `Config.Dev.Admins` (UserId 27938432). The server checks every command; a non-dev gets one warning and nothing happens. Commands run from chat (start with `.`), from the backquote (`` ` ``) panel, or the F8 overlay (live status). A chat command the server doesn't know is forwarded to your own client (`DevLocalCommand`) so `.region/.music/.lights` work from chat.

**Commands.** `.cmd` lists them. By group: state (`.state`, `.watch`, `.save`, `.fresh`), economy (`.coins`, `.coins+`, `.price`, `.pay`), progress (`.age`, `.age+`, `.birthday`, `.heart`, `.mortal`, `.lives`, `.kill`, `.magoi`, `.magoi+`, `.rukh`, `.rankup`, `.epithet`, `.bounty`), world (`.tp <city>`, `.cities`, `.time`, `.timescale`, `.region`, `.music`, `.lights`, `.shop`), missions (`.mission ...`), combat and NPCs (section 6 and 7). `.tp <city>` uses the city's spawn part, else its drop-off, else its region centre.

**Self-tests.** `SelfTestService` runs in Studio at server start and logs one `[SelfTest] PASS (n checks)` or FAIL line; it covers validation, remotes, save migrations, ranks, economy, missions, status, movement and combat rules. `scripts/check.sh` runs the style and type checks.

**Files.** `Services/DevService.luau`, `SelfTestService.luau`, `Client/Controllers/DevController`. **Remotes.** `DevCommand(line)` (client -> server); `DevReply`, `DevState`, `DevLocalCommand` (server -> client).

---

## 16. Remotes (all declared in `Shared/Remotes.luau`)

| Remote | Direction | Payload |
|---|---|---|
| `DebugPing` | C->S | string (max 50) |
| `ClientReady` | C->S | none |
| `DevCommand` | C->S | string (max 200) |
| `DevReply`, `DevState`, `DevLocalCommand` | S->C | text, state table, command text |
| `CreateCharacter` | C->S | gender 1-2, skin 1-3 |
| `HeartAttack` | S->C | age, fatal |
| `Died` | S->C | `{cause}` |
| `RukhSceneDone` | C->S | none |
| `Run`, `Dash` | C->S | boolean; x, z (-1..1) |
| `SetStance`, `Block` | C->S | boolean |
| `AttackStart`, `AttackCancel` | C->S | none |
| `AttackHit`, `AttackContinue` | C->S | hit index (integer >= 1) |
| `CombatEvent` | S->C | kind string, data table |
| `RankUp`, `AlignmentChanged` | S->C | tables (section 9) |
| `ChooseEpithet` | C->S | 1-3 |
| `CoinMessage` | S->C | string (max 100) |
| `MissionOpenBoard`, `MissionStart` | C->S | city key (validated) |
| `MissionExit` | C->S | none |
| `MissionBoard`, `MissionUpdate` | S->C | tables (section 13) |

Every call is rate-limited per player and argument-checked before its handler runs; bad calls are dropped with one `[Remotes]` warning per window plus a summary. Server -> client remotes ignore any client call.

---

## 17. Old scripts still running

These are your original scripts or shims that still run and are slated to fold into the new controllers (M7 close-out):
- `StarterCharacterScripts/Scripts/InputHandler.client.luau`: input freeze actions and the old forced-chat hook. Waits on `AppearenceLoaded` and `Effects`.
- `StarterPlayerScripts/BackpackGUI.client.luau`: the backpack and hotbar.
- `StarterCharacterScripts/Animate/`: your animate script (waits on `AppearenceLoaded`; fires `FootstepEvent`; reads `IntFold`).
- `character.IntFold` and `character.Effects` value folders, kept by MovementService and StatusService for the scripts above.
- `RS/Modules/SpeedHandler.luau` shim.

## 18. Parked (not running)

`ServerStorage/Parked`: `Hunger` (`Fear&Hunger` server script, `HungerHandler` client), `Magic` (camera shaker, rubble handler, spell remotes), `Rank/LevelHandler`. Bring each back as its own milestone when Bryan wants it. Parked is synced for safekeeping; nothing requires it.

---

## Attribute reference

The server publishes state as attributes; clients only read them.

| On | Attributes | Set by |
|---|---|---|
| Player | `JoinState` | PlayerService |
| Player | `Gender`, `SkinTone`, `Kingdom`, `FirstName`, `HeightStuds`, `Lives`, `Age` | CharacterService, AgeService |
| Player | `LivesLeft`, `Dying` | LifeService, AgeService |
| Player | `Health`, `MaxHealth`, `Block`, `MaxBlock`, `RegenTier` | HealthService |
| Player | `Rank`, `RankIndex`, `Epithet`, `Alignment`, `EpithetPending` | RankService |
| Player | `Copper`, `Silver`, `Gold` | EconomyService |
| Player | `OnMission`, `MissionDestination`, `MissionStreak`, `Bounty` | MissionService |
| Character | `Stunned`, `Knocked`, `Blocking`, `TrueStunned`, `LightStunned`, `Recovering`, `BlockBroken`, `Bleed` | StatusService |
| Character | `SpeedMult`, `Running`, `NextDashAt` | MovementService |
| Character | `InCombat`, `WeaponSet`, `Attacking`, `CurrentHitIndex`, `NextAttackAt`, `HitCount`, `ComboStep`, `CombatUnlocked` | CombatService |
| Character | `CourierBeacon` | MissionService |
| Workspace | `DayStart`, `DayLength`, `DayPaused` | WorldClockService |

---

## Rojo layout (`default.project.json`)

Rojo covers only code and the art that travels with it: `ReplicatedFirst` (`Assets`, `GUI`, `ShapecastHitbox`, `Tools`), `ReplicatedStorage`, `ServerScriptService`, `ServerStorage/Parked`, `StarterGui/HUD`, `StarterPlayer/StarterCharacterScripts`, `StarterPlayer/StarterPlayerScripts`. Workspace is never synced. Art in GUIs and models is binary `.rbxm`; read and edit those in Studio.

## Not synced (lives only in the place file, edited in Studio)

| Path | Class | What it does |
|---|---|---|
| `Workspace.Qarzin.ClothesStand.ClothingSpawn` | Script | Old shop stocker; disabled by `ShopService` at startup. Delete in Studio. |
| `Workspace.NPC.DUMMY.NPCFetch` and `Health` (x2) | Script | Old dummy AI and regen. Superseded by NpcService; delete in Studio. |
| `Workspace` models, `Regions`, `MAP`, spawns, `NPC`, `Qarzin` | art | Everything the services look up by name (`MAP.Spawns.QarzinSpawn`, `Regions.<Key>REGION`, `*Delivery` parts, `ClothesStand`). |

## Synced, but inside binary `.rbxm` files

| Script | File | Status |
|---|---|---|
| `RF.GUI.Gender.Decisions` (Script) | `RF/GUI/Gender.rbxm` | disabled by `CreationController` at runtime; strip in Studio |
| `RF.GUI.UIGUI.MenuGUI...MenuMechanics` (LocalScript) | `RF/GUI/UIGUI/MenuGUI.rbxm` | destroyed by `MenuController` at runtime; strip in Studio |
| `RF.GUI.MissionGUI.DeliveryFrame...XButtonFrame.TextButton.LocalScript` | `RF/GUI/MissionGUI/DeliveryFrame.rbxm` | dead (old remote); strip in Studio |

---

## How systems connect

Arrows mean "needs".

```
Join (PlayerService)         -> Saving (DataService), Character, LoadController (ClientReady)
Saving (DataService)         -> ProfileStore, SaveSchema, Config
Character (CharacterService) -> Saving, Aging (hair, height), Items, RF.Assets, FaceControl
Aging (AgeService)           -> Saving, Dev (time scale), Health, LifeService, RukhController
Lives (LifeService)          -> Saving, Aging (death sequence), PlayerService
Health (HealthService)       -> Saving, Rank (rank bonus), Status (Bleed), Dev
Status (StatusService)       -> PlayerService (auto-register), Effects/IntFold bridge
Movement (MovementService)   -> Status, Health, Combat data (Run, Dash numbers)
Combat (CombatService)       -> Status, Movement, Health, NPCs (shared entry points), Combat data  [shelved]
Ragdoll (RagdollService)     -> Status, RS/Modules/Ragdoll
NPCs (NpcService)            -> Status, Movement, Health, Combat, BehaviorTree
Rank (RankService)           -> Saving, Ranks/Epithets/Alignment data; RankController (client)
Currency (EconomyService)    -> Saving, Economy data; CurrencyController (client)
Items (ItemService)          -> Saving, RF.Assets
Shop (ShopService)           -> Economy, Items, Collisions, Shop data; ShopController (client)
Missions (MissionService)    -> Economy, Rank, Movement, Status, Combat (hit events), Cities data, Saving; MissionController (client)
World clock                  -> WorldClockService -> LightingController -> DayNight data, CityLight tag
Regions and music (client)   -> RegionController -> MusicController -> Regions data, RF.SFX.OSTs
Footsteps (client)           -> Animate -> FootstepController -> RF.SFX.Steps
Collisions                   -> CollisionService -> Workspace.MAP, clothing racks
HUD and menu (client)        -> Health, Rank, Aging attributes
Dev tools                    -> every service (Register), Saving; DevController (client)
```

Central pieces nearly everything depends on: `DataService`, `Remotes`, `Config`, and `StatusService` (combat state for players and NPCs alike).

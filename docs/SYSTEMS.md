# SYSTEMS

What every part of Game of Magi does today, as read from the code in Phase 2. Nothing here has been changed. Anything marked **⚠** is something I noticed while reading. Those go to the Phase 3 audit for a proper look; they are not decisions.

Paths are shortened: `SSS` = ServerScriptService, `RS` = ReplicatedStorage, `RF` = ReplicatedFirst, `SCS` = StarterPlayer.StarterCharacterScripts.

---

## 1. Saving and loading (DataStore) — rebuilt M1-03

**What it does now.** One `DataService` (`SSS/Server/Services/DataService.luau`) owns one save per player, on top of the vendored **ProfileStore** library (`SSS/Server/Packages/ProfileStore.luau`, MadStudio/loleris, Apache 2.0, unchanged). ProfileStore session-locks each save (so two servers can never load and save the same profile at once), retries loading, and saves on leave and on server shutdown (it binds to `game:BindToClose` itself).

**Store and key.** Store name `Config.Data.StoreName` (`"GameOfMagi_v1"`, a new store — the old `"GameOfMagi_v0.01am"` data is not read by the new code). Key: `Config.Debug.SaveScope .. "_" .. userId`, where `SaveScope` is `"Studio"` in Studio and `"Live"` in a published server — so play tests in Studio can never touch or corrupt a live save. `Config.Debug.FreshSave` (Studio only) forces every session onto `ProfileStore.Mock` instead: nothing persists, and every run starts from a brand-new template. DataService also falls back to `.Mock` on its own, for the rest of that server's life, if the very first real `StartSessionAsync` call throws (DataStore API unavailable, e.g. testing offline).

**Schema (v1)**, defined in `RS/Shared/SaveSchema.luau` as `SaveSchema.Template`, deep-copied per profile by ProfileStore:
```
Version   number                            -- schema version; SaveSchema.Migrate walks old saves up to Config.Data.SchemaVersion

Character = { FirstName, Gender, Race, Kingdom, SkinTone, HairColor {R,G,B},
              EyeColor, FaceBase, MouthShape, Height, GrowthProfile }   -- same fields/meanings as the old Stats shape below
Age       = { Years, TimePassed, ProgToAge }   -- TimePassed set to os.time() on first load
Progress  = { Magoi, GoldRukh, BlackRukh, Epithet }   -- DESIGN.md section 3a
Bounty    number
Economy   = { Copper, Silver, Gold }
Gear      = { Shirt, Pants, Hats {3 slots}, Inventory {item code list} }
Family    table   -- reserved, empty
Magic     table   -- reserved, empty
Meta      = { Created, LastSeen, Lives }
```
Missing keys on an existing save are filled in by `Profile:Reconcile()` before `SaveSchema.Migrate` runs, so a migration can assume its own version's shape already exists.

**Public API** (`RS/Shared` types, `SSS/Server/Services/DataService.luau`): `DataService.Get(player)`, `.WaitFor(player, timeout?)`, `.IsLoaded(player)`, `.Loaded` (fires once the save and the legacy bridge are both ready), `.Wipe(player)` (resets to a fresh template in place, for the M1-05 dev "fresh save" command), `.Save(player)` (manual save, for dev use), `.NewLife(player)` (M2-02: like `Wipe`, but keeps `Meta.Lives` — incremented — and `Meta.Created`; used by `AgeService`'s old-age death).

**If loading fails or the player leaves mid-load:** the player is kicked with "Your save couldn't be loaded. Please rejoin in a moment." A session stolen by another server, or the DataStore going down mid-session, kicks the player the same way (ProfileStore's `OnSessionEnd`).

**The legacy bridge** (`SSS/Server/Services/LegacyBridge.luau`, **temporary** — deleted once M2–M6 stop needing it). Old scripts (M2 onward, not yet rebuilt) still read and write `player.Stats` and `player.OnCharacter` directly, so on load DataService builds those exact folders and Value objects from the real save, and mirrors changes both ways:

| Old Value | Mirrors | Direction |
|---|---|---|
| `Stats.Race`, `.Kingdom`, `.EyeColor`, `.FaceBase`, `.MouthShape`, `.SkinTone`, `.HairColor`, `.FirstName`, `.GrowthProfile`, `.Height` | `Character.*` (same names) | two-way |
| `Stats.Gender` | `Character.Gender` | two-way |
| `Stats.Age` | `Age.Years` | two-way |
| `Stats.TimePassed`, `.ProgToAge` | `Age.TimePassed`, `.ProgToAge` | two-way |
| `Stats.MaxMagoi` | `Progress.Magoi` | one-way (data → Value); nothing currently active writes it back (the only old writer, `LevelHandler`, is parked) |
| `Stats.Hunger` | fixed at `5` | one-way (parked, TRIAGE K1) |
| `OnCharacter.Clothes.Clothing_Shirt/Pants` | `Gear.Shirt`/`Pants` | two-way |
| `OnCharacter.Currency.Copper/Silver/Gold` | `Economy.*` | two-way |
| `OnCharacter.Hats.HatSpot1..3` | `Gear.Hats[1..3]` | two-way |
| `OnCharacter.Inventory.Row1` | `Gear.Inventory`, `;`-joined | two-way |
| `OnCharacter.Inventory.Row2` | fixed at `""` | one-way (nothing ever wrote it) |
| `OnCharacter.Position` | fixed at `(0,0,0)` | inert — created (like the old code did) but never read from or written to the save; new spawns always go to Qarzin — see section 2 |
| `player.LoadedOC`, then `player.Loaded` | — | set once, in that order, after the folders above are populated |

**Also mirrored, one-way (data → old GUI/sound), not part of the table above:** the coin purse HUD (`PlayerGui.Currency.Bank.CoinPurse.Copper/Silver/Gold.Text`) is set from `Economy.*` on load and on every change, and the `CoinReward` sound plays on every change — exactly what the old `OnCharacterStore2` did, since nothing else updates that display now.

**Depends on:** `RS/Shared/Config`, `RS/Shared/Log`, `RS/Shared/SaveSchema`, `SSS/Server/Packages/ProfileStore`.
**Depended on by:** every old script that reads `player.Stats` / `player.OnCharacter` / `player.Loaded` / `player.LoadedOC` (unchanged, via the bridge), and every M1-04+ system that will call `DataService.Get`/`WaitFor` directly instead.

**Removed:** the old `SSS/Datastore/` folder (`MainStore2/init.server.luau`, `MainStore2/OnCharacterStore2.server.luau`, `CurrentStore.txt`) — TRIAGE #1, approved. **Not removed** (out of this task's scope): `SSS/DevCommandHandler.luau` (M1-05) still opens two DataStores directly by name (`"Mainstore2"`, `"OnCharacterStore2"` — note these don't even match the old `CurrentStore` value, so that code path looks already-dead); M1-05 should point it at `DataService` instead.

---

## 2. Join flow (loading screen → spawn) — rebuilt M1-04

**What it does now.** One `PlayerService` (`SSS/Server/Services/PlayerService.luau`) coordinates the whole join, on the server, through a single Player attribute instead of the old one-shot remote race (AUDIT H3/P1/M9: the old flow could hang, or spawn ~326 studs from Qarzin, if the `MainScreen` fire was ever missed).

**The state:** a string attribute on the Player, **`JoinState`**, one of `"Loading"`, `"Loaded"`, `"Ready"`. It's set again to `"Loading"` on every respawn, not just the first spawn. Because it's an attribute (not a one-time event), anything can just read the current value or watch `GetAttributeChangedSignal("JoinState")` — there's no window where a script that starts waiting late misses the signal.

1. **PlayerAdded** (and any player already in the game when the server starts, including one whose character already auto-spawned before PlayerService's listeners connected): `JoinState = "Loading"`.
2. **CharacterAdded** (every spawn, including respawns): `JoinState = "Loading"` again. PlayerService waits for `HumanoidRootPart` (10s timeout, logs an error and gives up placing the character if it never appears — it does **not** hang or kick), then immediately pivots the whole character to `Workspace.MAP.Spawns.QarzinSpawn`, raised half the spawn part's own height plus a margin so it doesn't clip regardless of the part's size. A saved position isn't used yet (AUDIT L4) — every spawn goes to Qarzin, same as today. Once the character is placed and the save is loaded (`DataService.WaitFor`; if the save never loads, DataService has already kicked the player and PlayerService has nothing further to do), `JoinState = "Loaded"`.
3. **CharacterRemoving** (fires just before the *next* CharacterAdded, on death or a dev `.fresh`): `JoinState = "Loading"` immediately, so nothing can read a stale `"Ready"`/`"Loaded"` left over from the life that just ended — a real risk since Roblox doesn't guarantee the order server scripts hear CharacterRemoving vs. CharacterAdded.
4. **The client says it's done:** the client's loading screen fires the new remote **`ClientReady`** (`Net.ClientReady`, event, no arguments, rate-limited to 3 per 10s) once it's finished showing/fading. PlayerService ignores this unless `JoinState` is currently `"Loaded"` (so a stray or repeated fire can't skip ahead), and unless the character is still there. When accepted: `JoinState = "Ready"`, and `PlayerService.Ready` fires with the player and character — this is the signal later systems (M2+) should wait on instead of `MainScreen`.
5. **Stuck loading:** if a character is still `"Loading"` 120 seconds after it spawned, PlayerService logs one warning and keeps waiting. It never kicks — the old 30-second kick during character creation (`Protection.server.luau`) was itself a bug (H3) and is gone by design.
6. **Leaving mid-load:** every wait loop in PlayerService re-checks `player.Parent` on each iteration and exits if the player is gone, so quitting during any stage never leaves a thread running (AUDIT M9).

**Public API:** `PlayerService.GetState(player)`, `.IsReady(player)`, `.WaitForReady(player, timeout?)` (returns the character once `JoinState == "Ready"`, or `nil` on timeout/leave), `.Ready` (fires `(player, character)`). `IsReady`/`WaitForReady` check that the "Ready" state still belongs to the player's *current* character (not one from a life that just ended), on top of the `JoinState` attribute itself.

**The old scripts, bridged.** Character creation itself isn't rebuilt until M2, so `AppearanceController` still runs the same appearance-building code it always did — it just waits on `JoinState == "Ready"` now instead of the `MainScreen` remote (checks the current attribute first, then `GetAttributeChangedSignal`, so it can't miss a fast transition). It still sets `character.AppearenceLoaded = true` at the end, so every other old script that waits on `AppearenceLoaded` (`EffectsService`, `InteractionsDesign`, `RegionHandlerPart2`, the HUD, `Health`, `Animate`, footsteps, and more) keeps working unchanged.

**Removed:** `LocationHandler.server.luau` (PlayerService now places the character — TRIAGE #2) and `Protection.server.luau` (the 30s kick; by design, gone). **Not removed** (out of this task's scope): the old client `SCS/Scripts/Load/init.client.luau` still fires `MiscRemotes.MainScreen` — M1-04C replaces it with a `LoadController` that fires `ClientReady` instead, same look.

**Remotes:** `Net.ClientReady` (client → server, no arguments, 3 per 10s). The old `MiscRemotes.MainScreen` still exists (untouched) but nothing on the server listens to it anymore.

---

## 3. Character creation and appearance — rebuilt M2-01

**What it does.** `CharacterService` runs on `PlayerService.Ready` (after the join pipeline and `DataService` load are both done). If the save's `Character.Gender` is still 0 (a brand-new life), it waits for the `CreateCharacter` remote before building anything; the client shows the Gender/skin screen itself whenever it sees the `Gender` attribute at 0 (M2-04 owns that screen; the old Studio-only `RF.GUI.Gender.Decisions` server script — AUDIT H4 — is never shown by the server anymore). Once a gender exists, it strips the default Roblox avatar and rebuilds the same look the old `AppearanceController` did: skin tone (by `SkinTone` + `Kingdom`, template picked **by name**), a `FalseHead` with face decals (face base, eyes, mouth, eyebrows from `RF.Assets`), hair recoloured to `HairColor`, a combat hitbox part, one shared collision group, sounds/particles/footstep sounds/music copied onto the torso, the saved shirt/pants and hats (or a fresh random starter rag outfit for a new life), and the custom run/walk/jump/idle/fall animations (old `SSS/Animations.server.luau`, now folded in). `AppearenceLoaded` (same name/spelling) is still set on the character at the end, since most other scripts (old and new) wait on it. First height/growth-profile rolling and resizing are **not** done here; they stay with `AgeController`/`AgeHandler` until M2-02 moves them into `AgeService`.

`FaceControl` (`CharacterService/FaceControl`) is now a plain module the service calls once per character instead of a script cloned into the FalseHead; same behaviour and timings — mouth flaps while the player chats, random blinking, "hurt"/"knocked out" faces on `Hit`/`Ragdoll` effects.

**Remote:** `CreateCharacter` (client → server, `gender: 1|2`, `skin: 1|2|3`, rate 3/10s). Ignored unless the save's `Character.Gender == 0`. Stores `Gender`/`SkinTone`, rolls a **gender-matched** first name from `Assets.FirstNames.sindria.male`/`.female` (AUDIT L3 — the old roll always used the male list, before gender was even chosen), and refreshes the legacy `Stats` mirror. The client sees it worked once the `Gender` attribute goes non-zero.

**Player attributes kept current:** `Gender`, `SkinTone`, `Kingdom`, `FirstName`, `HeightStuds` (`Character.Height` × a nominal 5-stud default rig height — display only, not HeightHandler's own scale), `Lives`, `Age` (AgeService also keeps this current on every birthday; see section 4).

Applied (not saved) hair colour lerps toward grey from `Config.Aging.GreyStart` to `GreyEnd` (`AgeService.GreyFactor`) — visible aging, section 4. No wrinkle decal exists yet (`-- ART TASK (Bryan)` comment in `applyHairColor`).

**Audit fixes carried in:**
- **H4** — the gender/skin picker is a client screen plus one server-validated remote, not a server script reading GUI clicks.
- **L2** (`RF/Assets/init.luau`, `eyecolor`) — the magician eye-colour branch used `Race ~= 4 or Race ~= 5`, which is always true, so it could never run; fixed to `Race == 4 or Race == 5`. Race is fixed to Human (2) for the rest of this renovation (DESIGN.md section 4), so this branch is currently unreachable in play either way — the fix is correctness, not a live change.
- **L3** — first name now rolls from the gender the player actually chose, not the male list rolled before gender exists (`SaveSchema.NewLife`'s roll is a placeholder `CreateCharacter` always overwrites).
- **L6** — the `ToolGrip` Motor6D never had a `Part0`, so it never moved anything. Wired (`Part0 = Torso`, its own parent) rather than deleted: the not-yet-rebuilt `PhysicalHandler.client.luau` still reaches for `Torso.ToolGrip.Part1`.
- **M8** — one collision group (`PlayerLimbs`), registered once at `CharacterService:Init()`, instead of one per player per spawn that was never removed (Roblox caps collision groups at 32).
- **P4** — the skin template is now picked strictly **by name** (1 Black, 2 Brown, 3 White, with the same Kingdom overrides as before). Whether each `.rbxm` template's own colours actually match its name is still unverified (binary asset, no Studio access from this build) — **playtester: please eyeball SkinTone 1/2/3 in each kingdom and report any mismatch.**

**Files:**
- `SSS/Server/Services/CharacterService/` (`init.luau` the service; `Black`/`Brown`/`White`/`Tan`/`LightTan`/`FalseHead`/`NormMeshie` template assets as before; `FaceControl/` a nested module + its two `WateryEyes`/`TalkCount` Value templates).
- `RF/Assets/init.luau`: unchanged data module (face decal tables, first/last names, clothing/outfit/hat/cloak lists, item-code lookup), except the L2 fix above.
- `SSS/Character/ItemHandler.luau`, `AgeHandler.luau`, `HeightHandler.luau`: unchanged, still required by `CharacterService` (`ItemHandler`) and by `AgeController` until M2-02.

**Removed (TRIAGE #3):** `SSS/Character/AppearanceController/init.server.luau`, `SSS/Character/AppearanceController/FaceControl/init.server.luau`, `SSS/Animations.server.luau`.

**Depends on:** `DataService`, `PlayerService.Ready`, `LegacyBridge` (refreshes `Stats`/`OnCharacter` after writing `Gender`/`SkinTone`/`FirstName`/`Gear` directly to the save), `ItemHandler`, `RF.Assets`, `RF.SFX`, `RF.VFX`, `RF.MISC.HitBox` (none of the last three are synced by Rojo — Studio-only asset folders).
**Depended on by:** nearly every character script still waits on `AppearenceLoaded` (unchanged name); the legacy bridge keeps `Stats.Gender`/`Stats.SkinTone` mirrored for anything not yet rebuilt.

---

## 4. Aging, visible aging and death — rebuilt M2-02

**What it does.** `AgeService` runs one shared server loop (`Config.Aging.Tick`, 10s) for every loaded player instead of one thread per player. Each tick it banks real elapsed seconds — times `DevService.GetTimeScale()` — into `Age.ProgToAge`, and turns each `Config.Aging.SecondsPerYear` (60s in Studio, 1800s live — DESIGN's 30 min/year) into a birthday. On a birthday: `Age.Years += 1`, the body is resized (height/build follow the per-life S-curve growth profile, hats/cloaks removed and re-equipped to fit — same as before), and the `Age` attribute updates immediately. Resizing also happens on every spawn (not just birthdays), once `AppearenceLoaded` is true (waits for `CharacterService` to finish first, same ordering the old `AgeController` used).

**Offline aging (DESIGN.md section 3).** On `DataService.Loaded` (once per session), `AgeService.OfflineAgingYears` ages the player up to `Config.Aging.OfflineYearsPerDay` (2) per real day away, capped at `Config.Aging.OfflineAgeCap` (59) — **never fatal**. `Age.TimePassed` (the last aging tick, real `os.time()`) is what this and the online loop both measure from.

**Visible aging.** Applied hair colour (not the saved `HairColor`) lerps toward grey from `Config.Aging.GreyStart` (45) to `GreyEnd` (70) — `AgeService.GreyFactor(age)`, applied by `CharacterService.applyHairColor` on every build. No wrinkle decal exists in `RF.Assets` yet (flagged `-- ART TASK (Bryan)` in that function).

**Death (DESIGN.md section 3a "Aging and death"; Bryan's heart-attack styling in `docs/M2-PLAN.md`).** From `Config.Aging.DeathStart` (60), every online birthday fires the `HeartAttack` remote (`age`, `fatal`) — the client (M2-05) always shows a short heartbeat/red-pulse moment, heavier and lasting if `fatal`. `fatal` is rolled from `Config.Aging.DeathChance`, linearly interpolated between its `{age, chance}` points (`AgeService.DeathChance`). A fatal roll sets the `Dying` attribute, freezes the humanoid (`WalkSpeed`/`JumpPower`/`JumpHeight` 0), and waits for the client's `RukhSceneDone` remote (or `Config.Aging.SceneTimeout`, 30s, also time-scaled) before starting a **completely fresh life**: `DataService.NewLife` (like `Wipe`, but keeps `Meta.Lives` — incremented — and `Meta.Created`), a fresh growth-profile roll, then `Player:LoadCharacter()`.

**Growth profile format (versioned, unchanged):** `"v1|startHeight|adultHeight|spurtAge|fatEnd"`, rolled once per life (`AgeService`'s `rollFirstGrowth`, moved here from the old `AppearanceController`) and stored in `Character.GrowthProfile`. `AgeHandler.unpack` rejects anything that isn't `v1`; `resizeCharacter` re-rolls if the profile is ever missing/invalid (same defensive fallback the old `sizeCharacter` had).

**Audit fixes:** **M10** (runaway age, no old-age death) — this section is the fix: age is now bounded (offline capped at 59) and old-age death is built. **L5** (`HeightHandler.resize`) — hair accessory parts used to scale by the full body ratio like a torso part; they now follow the head's (smaller, `HEAD_RESPONSE`-scaled) ratio instead, so hair doesn't stretch.

**Dev commands (section 16):** `.birthday [player]`, `.heart [fatal] [player]`.

**Files:** `SSS/Server/Services/AgeService/` (`init.luau` the service; `AgeHandler.luau` growth maths and the profile format, ported to `--!strict`, same numbers; `HeightHandler.luau` resizes body parts, joints, attachments and accessories — also holds the per-cloak fit offsets — ported to `--!strict` with the L5 fix).
**Removed (TRIAGE #4):** `SSS/Character/AgeController.server.luau`.
**Repointed:** `SSS/Character/ItemHandler.luau` and `SSS/MISC/MissionHandler/init.server.luau` required the old `Character.HeightHandler`/`Character.AgeHandler` paths; both now require the new `Server.Services.AgeService.HeightHandler`/`.AgeHandler`.
**Depends on:** `DataService` (`Age`, `Character.Height`/`GrowthProfile`, `NewLife`), `PlayerService.Ready`, `LegacyBridge`, `DevService.GetTimeScale`, `ItemHandler`, `Gear.Hats`.
**Depended on by:** `CharacterService` (spawn build waits for `AgeService`'s first growth roll to have already happened via `DataService.Loaded`; `applyHairColor` calls `GreyFactor`), Items, Health (Height adds max health, M2-03).

---

## 5. Items, clothing and hats

**What it does.** Every wearable is stored as a short **item code** string: `"type|name|r,g,b"`.
- Types: `S` shirt, `P` pants, `H` hat, `C` cloak.
- `name` matches an entry in `RF.Assets.outfits.desertBasic` (clothing) or a child of `RF.Assets` (hats and cloaks).
- `r,g,b` is 0–255.

`ItemHandler.equip(code, character)` puts the item on, recolors it, and resizes it to the character's current body.

**Files:** `SSS/Character/ItemHandler.luau`.
**Saved in:** `OnCharacter.Clothes.Clothing_Shirt/Clothing_Pants`, `OnCharacter.Hats.HatSpot1..3`.
**Depends on:** `RF.Assets`, `HeightHandler`, `AgeHandler`.
**Depended on by:** Appearance, AgeController, MarketHandler, the Qarzin clothes shop (section 6).

---

## 6. Market and currency

**What it does.** `MarketHandler` is a module that prices goods from a city's supply and demand, and handles "can this player buy this?". It checks money, whether the player needs to convert coins, whether their hat slots are full, and whether they're already wearing the item. If the purchase goes through it takes the coins. On failure it makes the player "say" a flavor line in chat through the `ForcedChat` remote. Only one city (Qarzin) and four resource types are defined. The data lives in the module, so it is not saved.

**Coins:** Copper, Silver, Gold, saved in `OnCharacter.Currency`. **⚠** The two halves of the module disagree on what a Gold coin is worth. Pricing treats 1 Gold as 100 Silver = 100,000 Copper; the bank total treats it as 10,000 Copper.

**The Qarzin clothes shop** (`Workspace.Qarzin.ClothesStand.ClothingSpawn`, Studio-only). Five seconds after the server starts, it stocks the shop once, with no restocking:
- random hats on the hat table, in White, Gold or Black
- random shirts, with pants, on the 9 mannequins
- a cloak on every cloak stand

Each item has an "E" prompt, and its price comes from `MarketHandler.GetPrice("Qarzin", "Clothing", ...)`. On purchase it builds an item code and calls `GetPlayerEcon`. If that says "yes", it puts the item on and writes the code into `OnCharacter.Clothes` or the first empty `OnCharacter.Hats` slot. Hovering a mannequin highlights it. **⚠** The hover changes what every player sees, not just the one hovering; every rack sells the same pants; and a hat bought with all 3 slots full is paid for but not saved.

**Files:** `SSS/MISC/MarketHandler.luau`, `Workspace.Qarzin.ClothesStand.ClothingSpawn` (Studio-only).
**Remotes:** `MiscRemotes.ForcedChat` (server → client, one string; the client posts it to chat in `InputHandler`).

---

## 7. Delivery missions

**What it does.** Clicking a `*Delivery` part in `Workspace.MAP.MISSION` opens a delivery board (`RF.GUI.MissionGUI.DeliveryFrame`) listing the cities on that city's trade route. Each destination gets 0–3 random **modifiers** (`TimeCrunch`, `CourierLoop`, `HighlyValuable`, `HeavyCargo`, `VIP`, `FragilePackage`, `CleartheRoute`), weighted by how much the route has been used and how safe it is. The board closes if you walk more than 20 studs away. Starting a mission straps a package to your back. Reaching the destination (within 10 studs) pays Copper based on your level, server population, your number of past deliveries, and the modifiers. If someone knocks you out mid-delivery, they get your reward and it's taken from you.

**Cities:** Qarzin, Sahraqin, Illegal Port, Ain Jamala, Saleh, Rathole, Jaddaty's Hut. **⚠** The trade-route table refers to `"JADDATYSHUT"` and `"CITYF"`, which don't exist, so those entries are empty. The server also accepts any city name the client sends, even one not on the route.

**Files:**
- Server: `SSS/MISC/MissionHandler/init.server.luau`. Its 7 city Frames, with their LocalScripts, are the route buttons (Studio-only, `.rbxm`).
- Shared/client: `RS/Modules/MissionDeliniation.luau`. It builds the city description panel, the start button, the quest tracker and the modifier pop-outs, and fires `Delivery` "MissionStart".
- `RS/Modules/RewardHandler.luau`: reward math and payout.
- The 7 city button LocalScripts (Studio-only) are one line each: `MissionDeliniation.DeliveryProtocol(player, button, "<City>")`. They only run once MissionHandler copies them into the player's delivery board.
- `RF.GUI.MissionGUI.DeliveryFrame…LocalScript`: the board's close (X) button. It fires `Delivery("Exit")` (Studio-only).

**Remotes:**
- `ImportantRemotes.Delivery` (client → server): `("MissionStart", cityName)` or `("Exit")`.
- `MiscRemotes.QuestGUI` (server → client): modifier name.
- `MiscRemotes.Quest2GUI` (server → client): the return-point part for Courier Loop.

**Player/character values it creates:**
- `player.CityMods.<city>.<modifier>`
- `player.SuccessRate` (made by Appearance)
- `player.TimerQuestMod`
- `character.Effects.Reading` / `OnMission` (with `RewardAmount`)
- `character.Pack`

**Depends on:** RewardHandler, SpeedHandler, the Effects system, OnCharacter currency, Stats (`MaxMagoi`, `Race`).

---

## 8. Movement and speed

**What it does.** Walk speed is 16 and run speed 28. The race- and height-based speeds are commented out. Double-tapping W runs, which zooms the camera out and plays the run animation. Anything that changes speed (running, blocking, dashing, being hit, heavy cargo, parried, stunned) adds a named child to `character.IntFold.MovementSpeed`. The server recomputes WalkSpeed from the smallest multiplier present, and `0` means frozen. Low health also slows you, down to half run speed and a quarter walk speed.

**Files:**
- `RS/Modules/SpeedHandler.luau`: add or remove a speed modifier.
- `SSS/Interactions/InteractionsDesign.server.luau`: creates `IntFold`, recomputes speed, and has a separate copy of the logic for NPCs.
- `SSS/Interactions/InteractionsHandler.server.luau`: the `Running` and `Dash` remotes.
- `SCS/Scripts/PhysicalHandler.client.luau`: run and dash input.

**Remotes (client → server):**
- `Running(bool)`
- `CombatRemotes.Dash("Dash" | "Release" | "RunningHit")`

---

## 9. Combat

**What it does.** Client-driven melee.

**Client** (`PhysicalHandler`):
- **M1:** a click plays a swing animation. At the animation's `Hit` marker, the client runs a shapecast hitbox from the fist or dagger and tells the server what it hit. Fist has a 2-hit combo; Royal Dagger has 3.
- **F:** holds block. The first 0.25 s of a block is a parry window.
- **Q + a direction key:** dashes.
- **Right-click or jump during a swing:** cancels it.

**Server:**
- `InteractionsHandler` receives `CombatRemotes.Hit(nil, partHit)` and calls `DamageHandler.damage` with a fixed packet: 5 damage, knockback, a brief slow, 1 s stun.
- `DamageHandler` applies the effects:
  - adds `Stun` and `Hit` markers
  - slows the target and knocks them back; every 5th hit knocks back 10× harder
  - takes health
  - at 0 health, instead of dying, the target is **Knocked**: health is set to 1, and the name of the attacker is stored under the Knocked marker
  - blocking from the front routes to `InteractionsDesign` via the `GetDamage` bindable. That drains "block HP" (35), breaks the block at 0 (3 s TrueStun), or on a parry stuns the attacker and plays the parry effects.
- `EffectsService` reacts to markers in `character.Effects`:
  - `Knocked` → ragdoll, blind screen and input freeze
  - `Hit` → sound and particles
  - `BlockBroken` → TrueStun
- `HealthService` (rebuilt M2-03, TRIAGE #14 — see its own write-up below) sets max health and regenerates health/block; it also still counts `Knocked` down while health is above 10% and removes it at 0 (how you get back up), moved over from the old `Health` script.

**Weapon:** 10 seconds after every spawn, the server equips the **Royal Dagger** on everyone (`WeaponHandler.equip`, called from InteractionsDesign).

**Files:**
- Client: `SCS/Scripts/PhysicalHandler.client.luau`
- Server: `SSS/Interactions/InteractionsHandler.server.luau`, `SSS/Interactions/InteractionsDesign.server.luau`, `SSS/Services/DamageHandler.luau`, `SSS/Services/EffectsService.server.luau`, `SSS/Server/Services/HealthService.luau` (M2-03, see below; replaces the old `SCS/Health.server.luau` and `SCS/BlockHealthRegen.server.luau`)
- Shared modules: `RS/Modules/Combat/WeaponHandler.luau`, `RS/Modules/Ragdoll`
- `RF/ShapecastHitbox` (third-party, TeamSwordphin v0.2.5)

**Remotes:**
- `CombatRemotes.Hit` (client → server): `("Highlight")` to flash your cancel highlight, or `(nil, partHit)` for a hit.
- `Blocking(bool)` (client → server)
- `RagdollEvent(bool)`, `Remotes.Hit()`, `CombatRemotes.Parry()` (server → client, for animations and screen effects)
- `GetDamage` (server bindable)

**⚠** The server takes the client's word for what was hit, with no distance or cooldown check, so a modified client could hit anyone on the map.

**Health and block — rebuilt M2-03 (TRIAGE #14).** `HealthService` sets `Humanoid.MaxHealth = Config.Health.Base + Config.Health.HeightBonus × Character.Height + Config.Health.RankBonus[rankIndex]` (DESIGN.md section 3a "Rank raises max health"; `rankIndex` from `Shared/Data/Ranks.rankFor`), on `PlayerService.Ready` and again once `AppearenceLoaded` is true (so a height AgeService only finishes resizing after Ready still lands correctly). A character already at full health when `MaxHealth` changes is topped up to the new full; otherwise current health is left alone. One shared loop (`Config.Health.Tick`, 1s) regenerates health by `Config.Health.RegenPerSecond[tier]` (`Idle`/`Combat`/`Knocked`, set via `HealthService.SetTier`) and refills `Block` by `Config.Health.BlockRegenPerSecond` while not blocking, up to `Config.Health.MaxBlock` — flat per-second rates, so the tiers actually change the rate now (**FIX L8**: the old scripts' regen scaled with their own wait interval, so the tier variable never mattered). The same loop also refreshes the `Rank`/`Epithet`/`Alignment` attributes from `Progress` every tick (simplest correct option; no separate change signal). The old `Knocked`-revival countdown (decrement once a second while health is above `Config.Health.KnockedReviveThreshold`, destroy at 0 — how a knocked-out player gets back up) moved over unchanged; `DamageHandler` still creates that marker and still damages the Humanoid directly, both untouched until M3.

**FIX M11:** the old `Health.server.luau` had `HealthDetermine("Height", ...)` as its own branch, but `Height.Changed` called `HealthDetermine("MaxHealth", ...)` instead, so growing taller never added health. The new formula always recomputes `MaxHealth` from scratch instead of tracking deltas, so there's no branch to wire to the wrong name.

**Numbers changed from the old scripts:** the old max-health formula was race-branched (`50 + 100 + 10×Height` for Race 1, `50 + MaxMagoi/2 + 3×Height` for Race 2, ...) — since Race is fixed to Human for this renovation and Magoi now drives *rank* (DESIGN.md section 3a) rather than health directly, the Magoi/2 term is replaced by `Config.Health.RankBonus[rankIndex]` (`{0, 10, 20, 35, 50, 70, 100}`, one entry per rank). `Base` (50) and `HeightBonus` (3, Race 2's old multiplier) are kept. Health regen's old `Rate = 1/250` (times whatever the tier's wait interval happened to be, which is the L8 bug) is replaced by flat `Config.Health.RegenPerSecond = {Idle=2, Combat=0, Knocked=1}` health/second. Block's old `Rate = 1/750` (≈12.5 minutes to refill) is replaced by flat `Config.Health.BlockRegenPerSecond = 10`.

**API for M3 combat:** `HealthService.TakeDamage(player, amount, source?)`, `.SetTier(player, tier)`, `.SpendBlock(player, amount): boolean`, `.IsBlocking(player)` / `.SetBlocking(player, bool)`. None of these are wired to the current combat scripts yet — that's M3's job.

**⚠ Known gap until M3:** the old `IntFold.BlockInt`/`MaxBlockHpInt` Values (created by `InteractionsDesign.server.luau`'s character setup, read by the not-yet-removed `StarterGui/HUD/BlockHandler.client.luau`) are **not** bridged to the new `Block`/`MaxBlock` attributes — `HealthService`'s block state is a clean, independent system, and the old combat block-break logic still writes `IntFold.BlockInt` directly. Since `BlockHealthRegen.server.luau` is removed, nothing regenerates `IntFold.BlockInt` any more; the old block HP bar will read as frozen until M3 rewires combat to `HealthService`, or M2-04 finishes removing `BlockHandler.client.luau` (already on the M2 plan's removal list).

**Dev commands (section 16):** `.hp <n> [player]`, `.tier <Idle|Combat|Knocked> [player]`.

**Files:** `SSS/Server/Services/HealthService.luau`.
**Removed (TRIAGE #14):** `SCS/Health.server.luau`, `SCS/BlockHealthRegen.server.luau`.
**Depends on:** `DataService` (`Character.Height`, `Progress.Magoi`/`GoldRukh`/`BlackRukh`/`Epithet`, `Character.Gender`), `PlayerService.Ready`, `Shared/Data/Ranks`, `Shared/Data/Alignment`, `DevService.Register`/`.ResolvePlayer`.
**Depended on by:** the HUD (`Health`/`MaxHealth`/`Block`/`MaxBlock`/`RegenTier` attributes, plus `Humanoid.Health`/`MaxHealth` directly) and the menu (`Rank`/`Epithet`/`Alignment` attributes); M3 combat will call the API above.

**Not in use:** `RS/Modules/Combat/LightCombat.luau` and `BasicSwordCombat.luau` are an older server-side combat design. Nothing requires them, and they would error if something did: they require `SSS.Services.DamageService`, which doesn't exist.

---

## 10. Effects (status markers)

**What it does.** A shared convention rather than one script. Status is shown by putting a named Value in `character.Effects`, and other scripts react when it's added or removed.

| Marker | Added by | Effect |
|---|---|---|
| `Hit` | DamageHandler | stagger animation, hit sound and particle, hurt face; cancels your swing or block |
| `Stun` | DamageHandler, parry | blocks attacking |
| `Knocked` | DamageHandler | ragdoll, blind screen, input freeze; removed by Health regen |
| `Ragdoll` | EffectsService | physics ragdoll, knocked-out face |
| `Block` | Blocking remote | blocking; value 1 = parry window |
| `BlockBroken` | InteractionsDesign | adds `TrueStun` for 3 s |
| `TrueStun` | EffectsService | speed 0, no jumping |
| `BigFreezeInput` / `FreezeInput` / `ActionFreezeInput` | EffectsService | client input lock (`InputHandler`) |
| `Reading`, `OnMission` | MissionHandler | mission state |
| `MutedStep`, `Hungry`, `CombatTagged`, `FireBurn`, `Bleed` | checked for, but nothing creates them now, except `Hungry`, which only the disabled Fear&Hunger script creates |

**Files:** `SSS/Services/EffectsService.server.luau`, `SCS/Scripts/InputHandler.client.luau` (input freezes, and posting ForcedChat lines to chat).

---

## 11. Regions, music and announcements

**What it does.** The map has invisible parts whose names contain `REGION` (under `Workspace.Regions`). The server watches the character's root part touching them and keeps a list in `character.RegionInfo`. The client reacts: it starts a region's music playlist (Qarzin, Qishan City, Badlands, Sakura Island), plays ambient loops (Rain, Ocean), shows a "Q A R Z I N — The Merchant's Playground" banner, and darkens lighting in `DesertLairTunnel`. It fades music out when you leave.

**Files:** `SSS/MISC/RegionHandlerPart2.server.luau`, `SCS/Scripts/RegionHandlerPart1.client.luau`, `RS/Modules/SoundController.luau`.
**⚠** The server-side region list uses `Touched` and `TouchEnded`, and the client changes Lighting without ever restoring it (the restore code is commented out).

---

## 12. Footsteps

**What it does.** The run animation and `Animate` fire `MiscRemotes.Footstep("Right" | "Left" | "Jump")` on each step. The server plays a step sound that matches the floor material (stone, dirt, wood) and leaves fading footprint blocks on sand and mud.
**Files:** `SSS/Interactions/InteractionsHandler.server.luau`, `SCS/Animate/init.client.luau` (Roblox's Animate with footstep hooks added), `SCS/Scripts/PhysicalHandler.client.luau`, `RS/Modules/ColorMath.luau` (third-party color math, used to darken footprints).

---

## 13. Hunger

**What it does.** `Stats.Hunger` (0–5, saved) is drawn as 5 pips on the HUD (`StarterGui/HUD/HungerHandler`). The script that makes hunger go down, `SSS/Character/Fear&Hunger`, is **disabled**, so hunger currently never changes.

---

## 14. HUD, menu and backpack

- `StarterGui/HUD` holds the **health bar** (`HealthHandler`), **block bar** (`BlockHandler`) and **hunger** (`HungerHandler`). Other ScreenGuis in StarterGui (`Currency`, `QuestLine`, `Announcer`) are filled in by server and client scripts; they aren't synced.
- **Coin purse:** the OnCharacter save script writes coin counts straight into `PlayerGui.Currency.Bank.CoinPurse`.
- **M key** opens and closes the character menu (`RF.GUI.UIGUI.MenuGUI`; its script `MenuMechanics` is Studio-only). The menu shows your name, kingdom (Midlander, Easterner, Westerner), age ("THE 13TH YEAR SINCE BIRTH"), and height in feet and inches. The title is always "THE MERCHANT'S CHILD". The Apparel tab shows inventory tokens from `OnCharacter.Inventory.Row1`. **⚠** Only one item code (`"1AA"` = FeatherHat) is known to the lookup, so any other item there would error.
- **Backpack/hotbar:** `StarterPlayerScripts/BackpackGUI.client.luau` is a customized copy of Roblox's backpack script (10 slots, drag and drop, inventory panel).

---

## 15. NPCs

**What it does.** Two training dummies at `Workspace.NPC.DUMMY` chase a target with pathfinding within 40 studs and give up beyond that. InteractionsDesign and EffectsService give NPCs the same speed and effects handling as players.
**Files:** `RS/Modules/NPController.luau`, plus `Workspace.NPC.DUMMY.NPCFetch` and `Health` (Studio-only).

The two `NPCFetch` copies have the same code but different settings. `npcType = "Dummy"` only plays walk and run animations and flinches when hit. `npcType = "Target"` also wanders, chases the nearest player within 30 studs (using NPController), and punches within 4 studs through `DamageHandler.damage` (3 damage). `Health` is Roblox's stock regen script. **⚠** Once the Target dummy loses its target or gets knocked out, it never starts again.

---

## 16. Dev commands — rebuilt M1-05

**What it does now.** One `DevService` (`SSS/Server/Services/DevService.luau`) owns every dev command. Commands arrive two ways — typed in chat (`Player.Chatted`, same leading-`.` style as before) or from the M1-05C dev panel over the new `DevCommand` remote — and both go through the same `DevService.Run`, so there's exactly one place permission and parsing happen. Another service can add its own commands via `DevService.Register`/`.ResolvePlayer` (M2-02's `.birthday`/`.heart` from `AgeService`, M2-03's `.hp`/`.tier` from `HealthService`) instead of `DevService` requiring that service back, since Roblox errors on a cyclic `ModuleScript` require.

**Permission.** A player is a dev if their UserId is in `Config.Dev.Admins` (`27938432`, Bryan — the same UserId the old handler checked), **or** `Config.Debug.Enabled` is true (Studio: everyone testing there is a dev). Checked on the server before anything else runs. A non-dev gets no reply at all (so they can't tell a real command from an unknown one) and one `Log:Warn` per player per minute, not per command.

**Commands** (all start with `.`; `[player]` defaults to the caller and matches by display name or username prefix, case-insensitive — ambiguous replies with the candidates):

| Command | Effect |
|---|---|
| `.cmd` | lists every command with one-line help |
| `.state [player]` | sends a state snapshot to the caller over `DevState` and logs the same snapshot as a readable block in Output |
| `.watch on\|off` | streams `DevState` to the caller every second |
| `.coins <copper> [silver] [gold] [player]`, `.coins+ ...` | set or add currency |
| `.age <years> [player]`, `.age+ <n>` | set or add to `Age.Years` |
| `.magoi <n> [player]`, `.magoi+ <n>` | set or add to `Progress.Magoi` |
| `.rukh <gold> <black> [player]` | sets both Rukh tallies |
| `.bounty <n> [player]` | sets `Bounty` |
| `.epithet <text> [player]` | sets `Progress.Epithet` (quote multi-word text) |
| `.tp <city>` | teleports the caller's character to a spawn point (matches `Workspace.MAP.Spawns` children case-insensitively, with or without the `Spawn` suffix — `.tp qarzin` finds `QarzinSpawn`) |
| `.cities` | lists the spawn points that exist |
| `.timescale <n>` | sets a runtime time scale (`DevService.GetTimeScale()` / `.TimeScaleChanged`); later milestones (aging, day/night) should read it from here instead of the frozen `Config.Debug.TimeScale` |
| `.fresh [player]` | `DataService.Wipe`, then reloads the character (kick-free) |
| `.save [player]` | saves now |
| `.birthday [player]` | forces one birthday tick right now (`AgeService.ForceBirthday`) |
| `.heart [fatal] [player]` | fires a heart attack right now (`AgeService.ForceHeartAttack`); put `fatal` first to make it lethal |
| `.hp <n> [player]` | sets current health (`HealthService`) |
| `.tier <Idle\|Combat\|Knocked> [player]` | sets the regen tier (`HealthService.SetTier`) |

Every stat-editing command writes through the `DataService` table and calls `LegacyBridge.Refresh` so the old Value folders (and the coin purse HUD, for currency) pick it up immediately — never the Values directly. Every reply goes out over `DevReply` and is also logged with `Log:Info`.

**The state snapshot** (`DevState`, also what `.watch` streams every second), a flat table in a fixed key order: `name, userId, joinState, age, magoi, rank, goldRukh, blackRukh, epithet, bounty, copper, silver, gold, walkSpeed, health, maxHealth, position {x,y,z}, saveScope, freshSave, timeScale, sessionSeconds`. A system that isn't built yet (rank, until M4) sends `"n/a"`.

**Remotes:** `Net.DevCommand` (client → server, one string, 5/s), `Net.DevReply` (server → client, one string), `Net.DevState` (server → client, one table).

**Removed:** `SSS/DevCommandHandler.luau` and `SSS/DevCommandChatListener.server.luau` (TRIAGE #21) — the old offline path wrote to DataStores named `"Mainstore2"`/`"OnCharacterStore2"`, which never matched the real save name, so offline edits never worked; the new tools only ever write through `DataService`.

---

## 17. Collisions

`SSS/Interactions/CollisionsHandler` puts all map parts (except `Areas`) in `MapCollisionGroup`, and clothing racks in `ClothingRackGroup`. Appearance gives each player their own limb group that doesn't collide with clothing racks.

---

## 18. Ocean (Workspace, not synced)

766 server Scripts under `Workspace.MAP.OCEAN`, three per ocean tile, animate the waves: parts bob 2 studs over 15 s, and wave decals fade in and out over 10 s. **⚠** The `OceanWaves` copies move up and then "down" to the same spot, so they stop after one bob. Every copy adds more event connections each cycle, so the cost keeps growing the longer a server runs.

---

## Not in use (dead or unfinished code)

These are here so you know they exist. Nothing is being removed; that would be a Triage decision.

| What | Why it looks unused |
|---|---|
| `RS/Modules/Combat/LightCombat`, `BasicSwordCombat` | nothing requires them; they require a module that doesn't exist |
| `RS/Modules/LevelHandler` | nothing requires it; it reads `Depravity` and `LovedByRukh`, which aren't in Stats |
| `RS/Modules/RubbleHandler`, `RS/Modules/CameraShaker` (third-party) | nothing in `src/` requires them |
| `RS/Modules/DashHandler` | required by EffectsService but never called; it also looks in the wrong place (`RS.VFX` instead of `RF.VFX`) |
| `RS/Modules/AssetID` | required but never called; it uses a proxy site that has been shut down |
| `SSS/Datastore/StatManipulation` | disabled; broken require |
| `SSS/Character/Fear&Hunger` | disabled (hunger drain) |
| `RF/Tools/.../UniversalToolBar/LocalScript` | empty event handlers |
| **Remotes with no code using them in `src/`:** `AutoSave`, `Wipe`, `ItemEquip`, `MissionInteraction`, `MissionFinisher`, all of `SpellRemotes` (MagoiBlast, BorgHover/BorgHoverU, Wand, Sound/Water/Light/Plant/Heat/Strength/WindMagic), `BorgActivation`, `SpawnTeleport`, `RegionEntered`, `RegionLeft`, `GenderSelected`, `DeathHandlerPart3`, `CombatMusic`, `CombatMusicClientFires`, `CombatMusicFunc`, `FollowUp`, `RaceSkill`, `Carry`, `SandStormSound`, `Party`, `ClientCommunication`, `Holding`, `GameLoaded`, `GetDamageFunc`, `CombatPress` (looked up, never used) | I checked the Studio-only scripts too: none of them use these. |

---

## Not synced

These scripts live inside models or asset folders that Rojo does not sync, so they stay only in the place file and are edited in Studio.

Only scripts that actually run and do something are listed. Left off: empty scripts, disabled scripts, notes-only scripts, and LocalScripts in Workspace, which never run there. Also left off: `RF.Objects.MissionWagon.Cradle.Seat.Script`. It was read in Phase 2; it only records who sits in the wagon seat, but server scripts don't run in ReplicatedFirst and nothing ever places the wagon in the world, so it never runs.

| Path | Class | What it does |
|---|---|---|
| `Workspace.Qarzin.ClothesStand.ClothingSpawn` | Script | Clothing and hat shop in Qarzin. Requires MarketHandler, ItemHandler, HeightHandler, AgeHandler and Assets. |
| `Workspace.NPC.DUMMY.NPCFetch` (×2) | Script | NPC AI. Uses NPController and DamageHandler. |
| `Workspace.NPC.DUMMY.Health` (×2) | Script | Health regen for the NPC dummies (stock Roblox script) |
| `Workspace.MAP.OCEAN.Folder.MovingPart.Waves` (×256) | Script | Ocean wave motion, one script per part |
| `Workspace.MAP.OCEAN.Folder.OceanWaves.Waves` (×255) | Script | Ocean wave motion, one script per part |
| `Workspace.MAP.OCEAN.Folder.OceanWaves.Decal.DecalWaves` (×255) | Script | Ocean decal animation, one script per part |

## Synced, but inside binary `.rbxm` files

These scripts sit inside GUI frames, which Rojo saves as binary `.rbxm` files. They are in `src/`, but they can't be read or edited as text there. Read and edit them in Studio.

| Script | File |
|---|---|
| `ServerScriptService.MISC.MissionHandler.SALEH.TextButton.Saleh` (LocalScript) | `src/ServerScriptService/MISC/MissionHandler/SALEH.rbxm` |
| `ServerScriptService.MISC.MissionHandler.AIN JAMALA.TextButton.AinJamala` (LocalScript) | `src/ServerScriptService/MISC/MissionHandler/AIN JAMALA.rbxm` |
| `ServerScriptService.MISC.MissionHandler.QARZIN.TextButton.Qarzin` (LocalScript) | `src/ServerScriptService/MISC/MissionHandler/QARZIN.rbxm` |
| `ServerScriptService.MISC.MissionHandler.SAHRAQIN.TextButton.Sahraqin` (LocalScript) | `src/ServerScriptService/MISC/MissionHandler/SAHRAQIN.rbxm` |
| `ServerScriptService.MISC.MissionHandler.ILLEGAL PORT.TextButton.IllegalPort` (LocalScript) | `src/ServerScriptService/MISC/MissionHandler/ILLEGAL PORT.rbxm` |
| `ServerScriptService.MISC.MissionHandler.RATHOLE.TextButton.Rathole` (LocalScript) | `src/ServerScriptService/MISC/MissionHandler/RATHOLE.rbxm` |
| `ServerScriptService.MISC.MissionHandler.JADDATYS HUT.TextButton.JaddatysHut` (LocalScript) | `src/ServerScriptService/MISC/MissionHandler/JADDATYS HUT.rbxm` |
| `ReplicatedFirst.GUI.Gender.Decisions` (Script) | `src/ReplicatedFirst/GUI/Gender.rbxm` |
| `ReplicatedFirst.GUI.UIGUI.MenuGUI.MasterFrame.MenuGUIFrame.MenuMechanics` (LocalScript) | `src/ReplicatedFirst/GUI/UIGUI/MenuGUI.rbxm` |
| `ReplicatedFirst.GUI.MissionGUI.DeliveryFrame.OutsideFrame.XButtonFrame.TextButton.LocalScript` (LocalScript) | `src/ReplicatedFirst/GUI/MissionGUI/DeliveryFrame.rbxm` |

---

## How the systems connect

Arrows mean "needs". For example, "Appearance → Saving" means Appearance needs Saving.

```
Saving (Stats + OnCharacter)      → RF.Assets
Join flow (Load screen)           → MainScreen remote → Appearance, Location
Appearance                        → Saving, Aging, Items, RF.Assets, Gender picker
Location (spawn)                  → Saving, Join flow, Appearance
Aging                             → Saving, Items, HeightHandler
Items (ItemHandler)               → RF.Assets, HeightHandler, AgeHandler
Market (MarketHandler)            → Items, Saving (currency, hats), ForcedChat → InputHandler
Qarzin clothes shop (Workspace)   → Market, Items, Aging, RF.Assets
Delivery missions                 → RewardHandler, SpeedHandler, Effects, Saving (currency, stats)
  city buttons / X button (client) → MissionDeliniation → Delivery remote → MissionHandler
Movement & speed                  → SpeedHandler, IntFold (from InteractionsDesign)
Combat (client PhysicalHandler)   → ShapecastHitbox, Hit/Blocking/Dash remotes → InteractionsHandler
Combat (server)                   → DamageHandler → SpeedHandler, GetDamage → InteractionsDesign
                                  → Effects → EffectsService → Ragdoll, InputHandler (freezes)
Health / BlockHealthRegen         → Saving (Stats), Effects, IntFold
Weapon                            → WeaponHandler ← InteractionsDesign (auto-equips Royal Dagger)
Regions & music                   → RegionHandlerPart2 (server) → RegionInfo → RegionHandlerPart1 → SoundController
Footsteps                         → Animate / PhysicalHandler → Footstep remote → InteractionsHandler → ColorMath
HUD                               → Humanoid, IntFold, Saving (Hunger)
Menu                              → Saving, RF.Assets
NPCs (Workspace)                  → NPController, DamageHandler, Effects, speed handling
Dev commands                      → Saving (live Values, or the DataStore directly for offline players)
Collisions                        → Workspace.MAP, clothing racks; Appearance adds player groups
```

The central pieces nearly everything depends on:
- the two save scripts (`player.Stats`, `player.OnCharacter`, `player.Loaded`)
- `AppearanceController` (`character.AppearenceLoaded`)
- the `character.Effects` and `character.IntFold` folders

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

**Public API** (`RS/Shared` types, `SSS/Server/Services/DataService.luau`): `DataService.Get(player)`, `.WaitFor(player, timeout?)`, `.IsLoaded(player)`, `.Loaded` (fires once the save and the legacy bridge are both ready), `.Wipe(player)` (resets to a fresh template in place, for the M1-05 dev "fresh save" command), `.Save(player)` (manual save, for dev use).

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

1. **PlayerAdded** (and any player already in the game when the server starts): `JoinState = "Loading"`, then the server waits for that player's save to finish loading (`DataService.WaitFor`). If the save never loads, DataService has already kicked the player (section 1) and PlayerService has nothing further to do.
2. **CharacterAdded** (every spawn, including respawns): `JoinState = "Loading"` again. PlayerService waits for `HumanoidRootPart` (10s timeout, logs an error and gives up placing the character if it never appears — it does **not** hang or kick), then immediately pivots the whole character to `Workspace.MAP.Spawns.QarzinSpawn`, raised 3 studs so it doesn't clip into the spawn part. A saved position isn't used yet (AUDIT L4) — every spawn goes to Qarzin, same as today. Once the character is placed and the save is loaded, `JoinState = "Loaded"`.
3. **The client says it's done:** the client's loading screen fires the new remote **`ClientReady`** (`Net.ClientReady`, event, no arguments, rate-limited to 3 per 10s) once it's finished showing/fading. PlayerService ignores this unless `JoinState` is currently `"Loaded"` (so a stray or repeated fire can't skip ahead). When accepted: `JoinState = "Ready"`, and `PlayerService.Ready` fires with the player and character — this is the signal later systems (M2+) should wait on instead of `MainScreen`.
4. **Stuck loading:** if a character is still `"Loading"` 120 seconds after it spawned, PlayerService logs one warning and keeps waiting. It never kicks — the old 30-second kick during character creation (`Protection.server.luau`) was itself a bug (H3) and is gone by design.
5. **Leaving mid-load:** every wait loop in PlayerService re-checks `player.Parent` on each iteration and exits if the player is gone, so quitting during any stage never leaves a thread running (AUDIT M9).

**Public API:** `PlayerService.GetState(player)`, `.IsReady(player)`, `.WaitForReady(player, timeout?)` (returns the character once `JoinState == "Ready"`, or `nil` on timeout/leave), `.Ready` (fires `(player, character)`).

**The old scripts, bridged.** Character creation itself isn't rebuilt until M2, so `AppearanceController` still runs the same appearance-building code it always did — it just waits on `JoinState == "Ready"` now instead of the `MainScreen` remote (checks the current attribute first, then `GetAttributeChangedSignal`, so it can't miss a fast transition). It still sets `character.AppearenceLoaded = true` at the end, so every other old script that waits on `AppearenceLoaded` (`EffectsService`, `InteractionsDesign`, `RegionHandlerPart2`, the HUD, `Health`, `Animate`, footsteps, and more) keeps working unchanged.

**Removed:** `LocationHandler.server.luau` (PlayerService now places the character — TRIAGE #2) and `Protection.server.luau` (the 30s kick; by design, gone). **Not removed** (out of this task's scope): the old client `SCS/Scripts/Load/init.client.luau` still fires `MiscRemotes.MainScreen` — M1-04C replaces it with a `LoadController` that fires `ClientReady` instead, same look.

**Remotes:** `Net.ClientReady` (client → server, no arguments, 3 per 10s). The old `MiscRemotes.MainScreen` still exists (untouched) but nothing on the server listens to it anymore.

---

## 3. Character creation and appearance

**What it does.** Every spawn, the server strips the Roblox avatar down and rebuilds it from saved stats: skin tone (by `SkinTone` + `Kingdom`), a "FalseHead" with face decals (face base, eyes, mouth, eyebrows from `RF.Assets`), hair recolored to `HairColor`, a combat hitbox part, collision groups, sounds, particles, footstep sounds and music tracks copied onto the torso. It then puts on the saved shirt and pants, giving new players a random ragged starter outfit. If `Gender` is 0, it shows the gender picker GUI (`RF.GUI.Gender`) and waits until a gender is chosen. It also rolls the first height/growth profile (section 4).

`FaceControl` (a copy is placed in each character's FalseHead) animates the face: mouth flaps while the player chats, random blinking, and "hurt" or "knocked out" faces when `Hit` or `Ragdoll` effects appear.

`SSS/Animations` swaps in custom run, walk, jump, idle and fall animations on the character's `Animate` script.

**Files:**
- `SSS/Character/AppearanceController/init.server.luau`. Its children `Black`, `Brown`, `White`, `Tan`, `LightTan` (BodyColors), `FalseHead`, `NormMeshie` and `FaceControl` are templates.
- `SSS/Character/AppearanceController/FaceControl/init.server.luau`
- `SSS/Animations.server.luau`
- `RF/Assets/init.luau`: the big data module. Face decal tables, first and last names, clothing and outfit lists, hat and cloak lists, and item-code lookup. Its 34 children are the actual Accessory models for hats and cloaks.
- Gender picker: `RF.GUI.Gender.Decisions` (inside `Gender.rbxm`, Studio-only). A **server** Script in the picker GUI: you choose Masculine/Feminine and a skin box (Black, Brown, White), then Enter. It sets `Stats.Gender` (1 male, 2 female) and `Stats.SkinTone` (1 Black, 2 Brown, 3 White). **⚠** Normally a server script can't see a player's GUI clicks, so this may never finish for a new player. Phase 3 will test it.

**Depends on:** Saving (Stats, OnCharacter), `ItemHandler`, `AgeHandler`, `HeightHandler`, `RF.Assets`, `RF.SFX`, `RF.VFX`, `RF.MISC.HitBox`, `MainScreen` remote.
**Depended on by:** nearly every character script waits on `AppearenceLoaded`.

---

## 4. Aging and growth

**What it does.** Characters start at 13 and age with real time. Every 10 seconds the server banks elapsed seconds into `ProgToAge` and turns each `SECONDS_PER_YEAR` into a birthday. That constant is **30 seconds** right now, marked `--debug`; the comment says it's meant to be 5 minutes. Growth stops changing at 18. On a birthday (or a fresh spawn) the body is resized: height follows a per-player S-curve growth spurt, and build goes from skinny at 13 toward a random adult build. Hats and cloaks are removed and re-put-on so they fit the new size.

**Growth profile format (versioned):** `"v1|startHeight|adultHeight|spurtAge|fatEnd"`, rolled once and stored in `Stats.GrowthProfile`. `AgeHandler.unpack` rejects anything that isn't `v1`, and the controller re-rolls if the profile is invalid.

**Files:** `SSS/Character/AgeController.server.luau` (the loop), `SSS/Character/AgeHandler.luau` (growth math and the profile format), `SSS/Character/HeightHandler.luau` (resizes body parts, joints, attachments and accessories; also holds the per-cloak fit offsets).
**Depends on:** Stats (`Age`, `Height`, `GrowthProfile`, `TimePassed`, `ProgToAge`), `ItemHandler`, `OnCharacter.Hats`.
**Depended on by:** Appearance, Items, MissionHandler (requires HeightHandler; the resize calls are commented out), Health (Height adds max health).

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
- `SCS/Health` (a server Script inside the character) sets max health from race, MaxMagoi and height, and regenerates health. It also counts `Knocked` down while health is above 10% and removes it at 0, which is how you get back up.
- `SCS/BlockHealthRegen` regenerates block HP.

**Weapon:** 10 seconds after every spawn, the server equips the **Royal Dagger** on everyone (`WeaponHandler.equip`, called from InteractionsDesign).

**Files:**
- Client: `SCS/Scripts/PhysicalHandler.client.luau`
- Server: `SSS/Interactions/InteractionsHandler.server.luau`, `SSS/Interactions/InteractionsDesign.server.luau`, `SSS/Services/DamageHandler.luau`, `SSS/Services/EffectsService.server.luau`
- Character scripts: `SCS/Health.server.luau`, `SCS/BlockHealthRegen.server.luau`
- Shared modules: `RS/Modules/Combat/WeaponHandler.luau`, `RS/Modules/Ragdoll`
- `RF/ShapecastHitbox` (third-party, TeamSwordphin v0.2.5)

**Remotes:**
- `CombatRemotes.Hit` (client → server): `("Highlight")` to flash your cancel highlight, or `(nil, partHit)` for a hit.
- `Blocking(bool)` (client → server)
- `RagdollEvent(bool)`, `Remotes.Hit()`, `CombatRemotes.Parry()` (server → client, for animations and screen effects)
- `GetDamage` (server bindable)

**⚠** The server takes the client's word for what was hit, with no distance or cooldown check, so a modified client could hit anyone on the map.

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

**What it does now.** One `DevService` (`SSS/Server/Services/DevService.luau`) owns every dev command. Commands arrive two ways — typed in chat (`Player.Chatted`, same leading-`.` style as before) or from the M1-05C dev panel over the new `DevCommand` remote — and both go through the same `DevService.Run`, so there's exactly one place permission and parsing happen.

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

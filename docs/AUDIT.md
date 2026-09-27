# AUDIT

Phase 3 diagnosis of Game of Magi. **Nothing has been changed**; this is a list of problems for the Triage decisions.

**Sources:**
- A full read-only code review of every script in `src/`. Studio-only scripts were reviewed from the SYSTEMS.md summaries.
- A playtest of the published place (the section at the end).

Per Bryan's direction, systems are judged by what they were **meant** to do (code comments, the Trello board, DESIGN.md) as well as by what they do now. Where the design notes say how something should work, the finding says so under **Meant to**.

**Severity:**
- **critical**: loses player data, or lets a cheater break the game for others
- **high**: a main feature is broken or exploitable
- **medium**: a real bug or leak with limited reach
- **low**: small bugs, tidy-ups, latent problems

IDs start with the severity letter: C, H, M, L, and D for dead or duplicate code. Paths are relative to `src/`. `SSS` = ServerScriptService, `RS` = ReplicatedStorage, `RF` = ReplicatedFirst, `SCS` = StarterPlayer/StarterCharacterScripts.

## Summary

| Severity | Count | Main themes |
|---|---|---|
| Critical | 2 | Saves overwrite each other; the server trusts client hits |
| Playtest | 4 (1 high, 1 medium, 2 low) | NPC punches hit the dagger and stall; the spawn point is missed; menu and skin visuals |
| High | 10 | Save safety; join flow and gender picker; block/parry exploits; delivery exploits and leaks; dash |
| Medium | 21 | Combat rules, speed, leaks, delivery details, market maths, lighting, ocean lag, NPC AI, save retries |
| Low | 21 | Small logic bugs, tuning that doesn't work, debug prints, latent bugs |
| Dead/deprecated | 4 groups | Old APIs, unused code, unused remotes, accidental globals |

---

## Critical

### C1: Saves overwrite each other
- **System:** Saving
- **Where:** `SSS/Datastore/MainStore2/init.server.luau:129,133,148`; `SSS/Datastore/MainStore2/OnCharacterStore2.server.luau:93,97,107-110`
- **What's wrong:** Both save scripts use the same DataStore (`CurrentStore.Value`) and the same key (`UserId`), but each saves only its own table (`SetAsync`, or an `UpdateAsync` that ignores the old value). The last save replaces the whole record. On the next load, the missing half looks like a brand-new player, so it gets re-rolled with defaults. Both 60-second save loops also hit the same key at nearly the same moment, which Roblox throttles.
- **Plain:** Your stats and your money erase each other. Rejoining can turn your character back into a fresh 13-year-old with a new name and face, or roll your coins back.

### C2: The server believes whatever the client says it hit
- **System:** Combat
- **Where:** `SSS/Interactions/InteractionsHandler.server.luau:223-252`; `SSS/Services/DamageHandler.luau:13-125`
- **What's wrong:** The `CombatRemotes.Hit(nil, partHit)` handler checks none of the following:
  - distance
  - cooldown
  - type, or nil (`nil` errors at line 244)
  - the attacker's state: it accepts hits while the attacker is Knocked, Stunned or blocking
  - self-hits: a self-hit makes a zero-length direction, so a NaN velocity goes into the BodyVelocity

  Knocking someone out also hands over their delivery reward (H8).
- **Plain:** A cheater can hit anyone, anywhere on the map, as fast as they like, even while they're knocked out. They can rob every courier.
- **Fix direction:** The server checks range to the target, applies a swing cooldown, and refuses hits from a stunned, knocked or blocking attacker.

---

## High

### H1: "Don't save bad data" only protects half the save
- **System:** Saving
- **Where:** `OnCharacterStore2.server.luau:95-103, 225-233`; `MainStore2/init.server.luau:229-235`
- **What's wrong:**
  - If OnCharacter fails to load, it only warns, then carries on with an empty table plus defaults and saves that.
  - It never checks the `BadData` marker, so when Stats kicks a player for a failed load, OnCharacter still writes on the way out (which, through C1, wipes Stats).
  - The Stats 60-second loop doesn't check `BadData` either.
- **Plain:** If Roblox's save service hiccups when someone joins, their whole save can be replaced with a starter character.

### H2: OnCharacter never forgets players who leave
- **System:** Saving
- **Where:** `OnCharacterStore2.server.luau:225-233`
- **What's wrong:** On PlayerRemoving, `ingameData[player]` and `dirtyData[player]` are never cleared. That's a memory leak. It also means BindToClose saves every player who was *ever* on the server, overwriting newer progress they made on other servers.
- **Plain:** When an old server shuts down, it can roll back the money of players who already left and kept playing somewhere else.

### H3: Join flow can hang, and the 30-second kick includes time spent choosing a gender
- **System:** Join flow
- **Where:** `SSS/Character/AppearanceController/init.server.luau:69-80, 109-123, 312`; `SSS/Character/Protection.server.luau:4-9`; `SCS/Scripts/Load/init.client.luau:45-49`
- **What's wrong:** The server only starts listening for `MainScreen` after both saves have loaded. The client fires it once, about 3 seconds after loading. If the save loads slower than that, the signal is missed and the player waits forever. Separately, `AppearenceLoaded` is set only after the gender picker finishes, and Protection kicks at 30 seconds.
- **Plain:** A slow save load, or a new player who takes more than about 30 seconds on the gender and skin screen, gets kicked with "Appearence isn't loading".

### H4: Gender picker may not work at all
- **System:** Character creation
- **Where:** Studio-only: `RF.GUI.Gender.Decisions`
- **What's wrong:** It's a **server** Script listening to GUI button clicks, and server scripts don't receive a player's GUI clicks. If it never finishes, AppearanceController (lines 115-123) waits forever and H3 kicks the player. The unused `GenderSelected` remote suggests a remote was the plan. If the choice goes through a remote, the server must check Gender is 1–2 and SkinTone is 1–3.
- **Plain:** New players may not get past character creation. **Bryan (2026-09-26):** it works, to his memory. If the playtest confirms that, this drops to a low "fragile pattern" note. _Playtest result: see the Playtest section._
- **Meant to:** Let the player pick gender and skin tone. Skin then adapts to cultural origin.

### H5: Blocking can be abused for endless parries and immunity
- **System:** Combat
- **Where:** `InteractionsHandler.server.luau:329-347`; `SSS/Interactions/InteractionsDesign.server.luau:54-77`
- **What's wrong:**
  - Every `Blocking(true)` makes a new `Block` marker with a fresh 0.25-second parry window. There's no cooldown and no limit on duplicate markers.
  - Blocking is accepted while block-broken, stunned or knocked.
  - While `BlockBroken` exists, the block-damage handler does nothing, so the defender takes no damage.
  - A nil character errors.
- **Plain:** A cheater can parry every hit, or be unhittable right after their block breaks.
- **Meant to:** A parry needs F timed at guard-up. A broken block leaves you stunned and open.

### H6: Attacks ignore stun and cooldowns, and fast clicking multiplies hits
- **System:** Combat
- **Where:** `SCS/Scripts/PhysicalHandler.client.luau:403-496` (the unused checks are at 280-291 and 344-347)
- **What's wrong:**
  - The M1 handler never reads `m1db`, `cancelCheck` or the stun counter `checkLength1`.
  - Each click adds another `Hit` marker listener, so several clicks in one combo step fire the Hit remote several times.
  - Right-click cancel has no cooldown.
  - A parry only slows the attacker; it doesn't disable them.
- **Plain:** Being stunned doesn't stop you swinging, and clicking fast makes one punch land two or three times.
- **Meant to:** Cancel has a cooldown that depends on timing. A parry "disables the opponent temporarily".

### H7: Delivery accepts any city from the client
- **System:** Delivery missions
- **Where:** `SSS/MISC/MissionHandler/init.server.luau:387-437, 470-491`
- **What's wrong:** `city` is not type-checked and not checked against the board's route.
  - An unknown city makes `Mods` nil and errors at line 432. By then the pack is on and `OnMission` exists, so the player is stuck "on a mission" and can't open boards.
  - Naming the current board's own city pays out straight away (line 478).
- **Plain:** A cheater can finish deliveries without travelling. A bad request can leave someone unable to take deliveries until they respawn.

### H8: Intercepting a courier can create money and can crash
- **System:** Delivery missions
- **Where:** `MissionHandler/init.server.luau:495-514`; `RS/Modules/RewardHandler.luau:120-122`
- **What's wrong:**
  - The knocker is paid the carried reward, and the victim's Copper is reduced with no floor, so it can go negative. Two accounts can farm this back and forth.
  - Line 501 `CarriedReward /= 2` divides an Instance, which errors whenever HighlyValuable is active.
  - If the knocker is an NPC or has left the game, `missionsuccess(nil, …)` errors.
  - In every error case the pack and `OnMission` are never removed.
- **Plain:** Two players can farm money off each other, and some interceptions leave the package stuck on your back.
- **Meant to:** "Players can intercept others for payment."

### H9: Delivery leaves loops running forever and piles up connections
- **System:** Delivery missions
- **Where:**
  - `MissionHandler/init.server.luau:359-370`: `while gooey ~= nil` is always true, because a destroyed object isn't nil. Every board click starts a server loop that runs every frame for the rest of the session.
  - `MissionHandler/init.server.luau:264-273` (TimeCrunch) and `321-328` (HighlyValuable): same problem.
  - `RS/Modules/MissionDeliniation.luau:209-240`: the client adds a new connection every frame during a delivery.
- **Plain:** Every board opened leaves something running on the server forever, and every delivery adds lag on the player's own computer. Long servers slow down.

### H10: Dash probably doesn't work until you've attacked, and diagonals never work
- **System:** Movement
- **Where:** `PhysicalHandler.client.luau:652`, `601`, `633-651`, `133-141`
- **What's wrong:** Dash requires the attack animation's `Speed == 0`. A newly loaded animation has Speed 1, so after spawning, and again 10 seconds later when the dagger is equipped, Q does nothing until you've swung. Diagonals: keys are combined in the order A, S, D, W, which gives names like "DW" and "AW". No animation has those names (the diagonal animations are commented out).
- **Plain:** Dash does nothing until you've punched once (**confirmed by Bryan**). W+D and W+A fail because the code builds animation names that don't exist.
- **Meant to:** Q plus a direction dashes; cardinal directions only are fine for now.

---

## Medium

| ID | System | Where | What's wrong | Plain |
|---|---|---|---|---|
| M1 | Combat | `DamageHandler.luau:91-107` | The "would this knock them out" check runs before the block check; slow, knockback and the Hit marker also go through a block | Blocking is meant to make you immune, but a weak blocker still gets knocked out |
| M2 | Combat | `InteractionsDesign.server.luau:89-94` | Parry computes `posecheck` but compares `poseCheck`, so the cap never applies | A parry can overfill your block bar |
| M3 | Combat | `InteractionsHandler.server.luau:244-249`; `DamageHandler.luau:21` | "Nearest Model" is the backpack or weapon if that's what was hit; the server then waits forever for `Effects` on it | Punching someone's package or weapon does nothing and leaves a stuck thread. **Raised to high by the playtest: see P2** |
| M4 | Movement | `InteractionsHandler.server.luau:207-220, 350-401`; `InteractionsDesign.server.luau:152-154` | Dash has no server cooldown and adds +30 speed each time (it stacks); `Running` writes any value into a BoolValue | A cheater can stack dashes for huge speed or flood the server with trail effects |
| M5 | Combat / Movement | `InteractionsDesign.server.luau:50-113, 247-270` | Every spawn adds another `GetDamage` listener and never removes it; the low-health speed loop never ends | Each respawn leaves code running that never stops |
| M6 | Movement | `InteractionsDesign.server.luau:247-266` | The low-health slowdown updates the base speeds but never re-applies WalkSpeed | Being hurt doesn't slow you until you start or stop running |
| M7 | Footsteps | `InteractionsHandler.server.luau:24-205` (52, 116) | Footstep remote has no rate limit; a new sound connection every step; operator precedence lets a nil raycast result error | Footprints can be spammed to lag the server |
| M8 | Appearance | `AppearanceController/init.server.luau:236-246` | One collision group per player, never removed; Roblox allows 32, and failures are hidden by `pcall` | On long servers, later players bump into clothing racks |
| M9 | Join flow | `AppearanceController:80, 115-123`; `LocationHandler.server.luau:35`; `MainStore2/init.server.luau:220` | Wait loops never check whether the player left | Quitting during loading or the gender picker leaves a loop running forever |
| M10 | Aging | `SSS/Character/AgeController.server.luau:8, 61-63` | Offline aging is **intended** (Bryan). What's missing is death from old age: age grows forever, and nothing happens past 18 except that growth stops | **Meant to:** characters keep aging offline and eventually die of old age. The death part was never built |
| M11 | Health | `SCS/Health.server.luau:93` (vs 46) | `Height.Changed` calls the `"MaxHealth"` branch, but the branch is named `"Height"` | Growing taller never adds health, though it's meant to |
| M12 | Delivery | `MissionHandler/init.server.luau:64-77, 133-134, 333`; `MissionDeliniation.luau:27-70` | `timesRun` and `successRate` are never updated, so VIP and CleartheRoute can't roll; city Personality is only used for display; CleartheRoute would error (`IntFold.GripInt` doesn't exist) | Cities' history and personality don't shape modifiers yet |
| M13 | Delivery | `MissionHandler/init.server.luau:301, 455, 495-514` | Heavy Cargo slow is only removed on success | Get intercepted with heavy cargo and you stay slow until you respawn |
| M14 | Delivery (client) | `MissionDeliniation.luau:98-114` | Each city click adds another Start-button listener | Looking at two cities, then Start, can point your tracker at the wrong city |
| M15 | Market | `SSS/MISC/MarketHandler.luau:73-78, 97, 103, 148` | Gold is worth 100,000 Copper in pricing but 10,000 in the bank total; bank (Copper) is compared to a price in Silver or Gold units; only Copper has a "convert" message; no way to convert coins exists | The game can't agree what a gold coin is worth, and "convert your money" has no way to do it |
| M16 | Regions | `SCS/Scripts/RegionHandlerPart1.client.luau:105-120` (restore commented out at 153-166) | Tunnel lighting is never restored | Enter the Desert Lair Tunnel and the world stays dark until you rejoin |
| M17 | Ocean | Studio-only: `Workspace.MAP.OCEAN.*` | 766 server scripts tween parts (network traffic to everyone), and connections grow every cycle | The ocean likely causes steady lag that worsens over time. One client-side script would do |
| M18 | Effects | `SSS/Services/EffectsService.server.luau:62, 125, 171` | Reads `Block.Value` after Block may be gone; destroys a possibly-nil Ragdoll; hooks connect only after `RegionInfo` exists, so early markers are missed | Hit sounds and knockouts can sometimes error or be skipped |
| M19 | NPCs | `RS/Modules/NPController.luau:148, 155-156, 164-187` | `comp()` runs before `con1`/`con2` exist (nil `Disconnect`); `failureProtection` never resets; `wayp[2]` is used unchecked | The Target dummy gives up for good after one bad chase |
| M20 | Saving | `MainStore2/init.server.luau:146-154, 246-252`; `OnCharacterStore2.server.luau:105-117, 229-233` | No retries, no session lock; shutdown saves players one at a time | A briefly busy save service loses saves; at shutdown with many players, some aren't saved |
| M21 | Delivery | `AppearanceController:342-344`; `RewardHandler.luau:78-87` | A new `SuccessRate` folder every spawn; the count isn't saved and isn't a streak (only a gank resets it) | The "consecutive success" bonus resets on rejoin and doesn't track streaks |

---

## Low

| ID | System | Where | What's wrong / Plain |
|---|---|---|---|
| L1 | Dev commands | `SSS/DevCommandHandler.luau:6-7, 186`; `DevCommandChatListener.server.luau:26-28, 86-88` | **The server-side permission check is correct.** But offline edits go to the wrong DataStore names; confirmations use a client-only chat call, so they only `print`; `parseCommand` is called twice |
| L2 | Appearance | `RF/Assets/init.luau:67` | `Race ~= 4 or Race ~= 5` is always true, so magician eye colours can never appear |
| L3 | Appearance | `MainStore2/init.server.luau:102-105` | The first name comes from the male list before gender is chosen, so female characters get male names |
| L4 | Location | `LocationHandler.server.luau:20-24, 39` | Position is never saved; if it were, `CFrame.new(Pos)` would error on the Instance (latent) |
| L5 | Aging | `HeightHandler.luau:144-175` | Hair parts are scaled like the body (full ratio) while the head scales 30%; hair may look stretched after birthdays (check visually) |
| L6 | Appearance | `AppearanceController:346-353` | The `ToolGrip` Motor6D never gets a `Part0`, so it does nothing |
| L7 | Combat | `InteractionsDesign.server.luau:272-273` | Everyone is given the Royal Dagger 10 s after spawning, replacing Fist, which the design calls the core combat. Looks like test code |
| L8 | Health / Block | `BlockHealthRegen.server.luau:44-45`; `Health.server.luau:151-152` | Regen scales with the wait time, so the Regen tiers (combat, knocked) don't change the rate; pose takes about 12.5 minutes to refill |
| L9 | Various | `CollisionsHandler:1`, `HUD/HealthHandler:1`, `HUD/BlockHandler:1`, `HUD/HungerHandler:1` | `until game.Loaded` doesn't wait (it's an event); meant to be `game:IsLoaded()` |
| L10 | Footsteps | `SCS/Animate/init.client.luau:283, 291, 299` | `("jump" or "fall")` is always "jump"; walk plays even while running; `IntFold` may not exist yet |
| L11 | Combat (client) | `PhysicalHandler.client.luau:478, 656, 726-731, 753` | Connections added every combo, dash and parry, never removed; the stagger "no repeat" doesn't work; many globals |
| L12 | Market | Studio-only: `Workspace.Qarzin.ClothesStand.ClothingSpawn`; `MarketHandler.luau:106-137` | The mannequin hover shows for everyone; every rack sells the same pants; you can't buy another colour of a shirt you're wearing; colours are White/Gold/Black, but the design says white/**tan**/black; supply and demand never change. The earlier "hat paid for but not saved" note looks wrong: MarketHandler refuses and doesn't charge when slots are full (the playtest checks this) |
| L13 | Menu | `RF/Assets/init.luau:1134-1141` | The item lookup only knows `"1AA"`; latent, since nothing fills inventory rows yet |
| L14 | Delivery (client) | `MissionDeliniation.luau:109, 234` | The quest panel check is always true, so the panel hides even with quests; the pay preview leaves out modifiers |
| L15 | Delivery | `RewardHandler.luau:59-62, 102` | Race 5 (Magi) has no level thresholds, which errors; level 0 makes `10/0`, an infinite reward |
| L16 | Combat | `RS/Modules/Ragdoll/init.luau:131-139` | Extra no-collide constraints are added on every knockout and never removed |
| L17 | Hunger | `SSS/Character/Fear&Hunger.server.luau:14` | (Disabled) `while chara do` never ends; it would leak if switched back on |
| L18 | Collisions | `CollisionsHandler.server.luau:14` | Unreachable Union branch (a Union is already a BasePart) |
| L19 | Saving | `OnCharacterStore2.server.luau:76-84, 198-202` | A coin change with no character errors before the save flag is set; the coin sound also plays when spending |
| L20 | Various | `InteractionsHandler:231,246,248,251`; `OnCharacterStore2:217`; `Load:2`; `PhysicalHandler:474` | Debug prints left in |
| L21 | Music | `RS/Modules/SoundController.luau:66-69, 85, 209-212` | Fade-out wait is inverted (music cuts instantly); `CutDown` looks for a child literally named "Name"; a one-song playlist spins forever |

---

## Dead, duplicate and deprecated code

| ID | What |
|---|---|
| D1 | **Deprecated APIs.** `spawn`: FaceControl, Fear&Hunger, Protection, InteractionsDesign, MissionHandler, Health, NPController. `wait`: Health, BlockHealthRegen, Load. `delay`: FaceControl, SoundController. Lowercase `:connect`: InteractionsHandler, FaceControl, MissionHandler, MissionDeliniation, NPController, PhysicalHandler. `Instance.new(class, parent)`: AppearanceController, ItemHandler. |
| D2 | **Unused or duplicate code.** Unused requires in MainStore2, OnCharacterStore2, AppearanceController, EffectsService, InteractionsDesign, PhysicalHandler, MissionDeliniation and MissionHandler. The Modifiers table is copied 3 times (MissionHandler, RewardHandler, MissionDeliniation). The speed recompute is pasted 4 times in InteractionsDesign. Unused modules are listed in SYSTEMS.md under "Not in use". |
| D3 | **Unused remotes.** The ~35 listed in SYSTEMS.md, plus `MiscRemotes.Drop`, `Announcer`, `Cam`, `CameraShake`, `CombatRemotes.CombatString`, `Gripped`, `BlockBroken`. |
| D5 | **Leftovers from the previous game (Bryan).** The Desert Lair Tunnel region code in `SCS/Scripts/RegionHandlerPart1.client.luau:105-120, 153-166` (was M16). The tunnel doesn't exist anymore. |
| D4 | **Accidental globals.** `PlyStats`, `CharaStats`, `DesertCities`, `forcedChatsMsgs`, `spawnfold`, `spawnlocations`, `HUD`, and PhysicalHandler's combat state. |

---

## Playtest (published place)

**How it was run:**
- Place: the published Game of Magi place (it shows in Studio as "TEST", placeId 136695893030663).
- Two play-solo sessions, 2026-09-26. The run was stopped early at Bryan's request to save usage.
- The test ran as Bryan's own account (UserId 27938432), so it used his debug save. That save now has a Feather in HatSpot1 and 904 Copper. Bryan says this data can be wiped.

### Results by system

| System | Result | Notes |
|---|---|---|
| Join / saving | **Works** | Both saves loaded, no kicks. Custom face, hair, rags, HUD and coin purse all appeared. |
| Spawn location | **Bug (new, P1)** | Spawned about 326 studs from `QarzinSpawn` even though the saved position was empty. See P1. |
| Gender picker | Not reached | The existing save already has a gender. Needs a fresh save; Bryan remembers it working. |
| Aging | Works, but see M10 | Age counts up at 30 s/year. The saved age is **300,379**, because offline time at the debug rate adds about 104 days' worth of years. The menu shows "THE 300379TH YEAR SINCE BIRTH". |
| Run / dash | Inconclusive | No errors. Bryan confirmed dash only works after the first punch (H10). |
| M1 combat | Works, with bugs | Hits land on the dummy. **Confirms H6:** the first combo counted 1→6 on a 3-hit dagger, because listeners stack. |
| Block | Works | `Effects.Block` appears when F is held. No errors. |
| Knockout and recovery | **Works** | Knocked at 1 HP → ragdoll, blind screen, input frozen → back up in about 20 s. |
| Low-health slow | Partly works | WalkSpeed dropped to about 10 when hurt, but stayed at 15.38 instead of 16 once health was full again (adds to M6). |
| NPC combat | **Broken (P2)** | Confirms and raises M3. See P2. |
| NPC chase range | **Bug** | The Target dummy chased about 400 studs, far past its 30–40 stud give-up range (adds to M19). |
| Menu (M) | Works | Name, kingdom, age and height show. The stat line is cut off at both edges, and the character-view diamond is solid black (P3). |
| Market (hat) | **Works** | The Feather cost 96 Copper and was equipped and saved. Buying it again gave "Don't I have this already..." with no charge. |
| Delivery, regions, dev commands, ocean idle, shirt purchase | Not tested | Stopped early. |

### New findings from the playtest

| ID | Severity | System | Where | What's wrong | Plain |
|---|---|---|---|---|---|
| P1 | medium | Join flow / Location | `SSS/Character/LocationHandler.server.luau:15-39` | With an empty saved position, the player should be moved to `QarzinSpawn`, but spawned about 326 studs away. Most likely the teleport never ran because LocationHandler missed the one-time `MainScreen` signal (the same race as H3) and is still waiting. | New players don't start at the Qarzin spawn point, and a leftover server thread waits forever |
| P2 | **high** | NPCs / Combat | Studio-only `Workspace.NPC.DUMMY.NPCFetch:329,339`; `SSS/Services/DamageHandler.luau:21`; same pattern at `InteractionsHandler.server.luau:245,249` | Confirms M3 in practice. When the dummy's punch hits the player's **Royal Dagger**, the "nearest Model" is the dagger, and `DamageHandler` waits forever for `Effects` on it. That was 150+ stuck threads and warnings in a few minutes. Since everyone carries the dagger (L7), most NPC punches do nothing. | The training dummy's punches mostly don't land, and each miss leaves a stuck thread on the server |
| P3 | low | Menu | Studio-only `RF.GUI.UIGUI.MenuGUI` | The stat line is cut off on both sides; the character-view diamond is solid black | The menu's info line doesn't fit, and the character preview is blank |
| P4 | low | Appearance | `SSS/Character/AppearanceController/*.rbxm` | With SkinTone 2 (Brown), the character's BodyColors is named "Black". The skin templates may be named or coloured wrong. | The skin colour may not match what was picked (check visually) |

### Findings confirmed in practice
- **C1:** `KeyThrottled` / "request rate exceeds the allowed maximum for the key" at shutdown. Both save scripts hit the same key.
- **H6:** stacked combo listeners.
- **H10:** dash needs a first punch (Bryan).
- **M3 → P2**
- **M10:** runaway age.
- **M19:** the dummy doesn't give up.
- **L20:** debug prints on every hit, swing, join and autosave. That includes a full dump of the DUMMY and the whole save table every 60 s.

### Output errors and warnings seen

| Message | Where | Count |
|---|---|---|
| `Infinite yield possible on 'Workspace.Characters.iiBry.Royal Dagger:WaitForChild("Effects")'` | DamageHandler:21 ← NPCFetch:329 | 150+ |
| `DataStore request was added to queue… Key = 27938432` | save scripts | 3 |
| `DataStoreService: KeyThrottled… API: SetAsync, Data Store: GameOfMagi_v0.01am` | save scripts at shutdown | 1 |
| `502: API Services rejected request… Error code: 8… request rate exceeds the allowed maximum for the key` | save scripts at shutdown | 1 |

Earlier output already in the console (not from these sessions) showed "You must publish this place to the web to access DataStore" and an "Appearence isn't loading" kick. That's what happens when the local copy is played. It's why the playtest moved to the published place.

### Confirmed by Bryan (2026-09-26)

**Background:** Game of Magi is a remake of an earlier game. Many scripts, remotes and regions are left over from that previous version and aren't part of the new design.

| Topic | Bryan's answer | Effect on findings |
|---|---|---|
| Customization | No errors | Fine |
| Aging | Ages, no resize after 18. Resize not needed past that | Fine (M10 still stands for the runaway age and missing old-age death) |
| Knockout | Screen lightens after about 20 s, up about 2 s later | Works |
| Blocking at low health | Doesn't get knocked | M1 not seen in play (the dummy mostly hits the dagger, P2). The code path still exists, so it drops to **low** |
| Hat with 3 slots full | "Not enough room" line, no charge | L12 "paid but not saved": **not a bug** |
| Different shirt | Can buy | Works (same shirt in a different colour still untested) |
| Delivery | Delivered and got paid | Works end to end |
| Desert Lair Tunnel | Doesn't exist; left over from the previous game | M16 becomes **dead code** (D5) |
| PvP | Block, parry and block-break all work. **Block-break "feels a little funky"** | Works; feel note for combat |
| Courier interception | Took the courier's money | Works as designed (the H8 exploit and crash cases still stand) |
| Mannequin hover for everyone | **Not intended** | L12 hover confirmed as a bug |
| Royal Dagger on everyone | **Test code** | L7: test code |
| Combat (combo chain etc.) | **Not finished** | Combat is work in progress; H6 and similar are "unfinished", not regressions |
| Menu line cut off | Because the age number is huge | P3 is caused by M10 (runaway age), not the layout |

### Still unconfirmed
- The gender picker on a fresh save (Bryan remembers it working)
- Dash and run in the open
- Regions and music
- Dev commands in play
- Ocean lag over time
- Buying the same shirt in a different colour

---

## Housekeeping

An untracked `game-of-magi/` folder inside the project is an older nested copy with its own `.git`, `CLAUDE.md` and place file. It isn't part of the game and it's easy to confuse with the real project. Nothing has been done with it.

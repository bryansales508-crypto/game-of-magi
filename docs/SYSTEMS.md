# SYSTEMS

What every part of Game of Magi does today, as read from the code in Phase 2. Nothing here has been changed. Anything marked **⚠** is something I noticed while reading. Those go to the Phase 3 audit for a proper look; they are not decisions.

Paths are shortened: `SSS` = ServerScriptService, `RS` = ReplicatedStorage, `RF` = ReplicatedFirst, `SCS` = StarterPlayer.StarterCharacterScripts.

---

## 1. Saving and loading (DataStore) — rebuilt M1-03

**What it does now.** One `DataService` (`SSS/Server/Services/DataService.luau`) owns one save per player, on top of the vendored **ProfileStore** library (`SSS/Server/Packages/ProfileStore.luau`, MadStudio/loleris, Apache 2.0, unchanged). ProfileStore session-locks each save (so two servers can never load and save the same profile at once), retries loading, and saves on leave and on server shutdown (it binds to `game:BindToClose` itself).

**Store and key.** Store name `Config.Data.StoreName` (`"GameOfMagi_v1"`, a new store — the old `"GameOfMagi_v0.01am"` data is not read by the new code). Key: `Config.Debug.SaveScope .. "_" .. userId`, where `SaveScope` is `"Studio"` in Studio and `"Live"` in a published server — so play tests in Studio can never touch or corrupt a live save. `Config.Debug.FreshSave` (Studio only) forces every session onto `ProfileStore.Mock` instead: nothing persists, and every run starts from a brand-new template. DataService also falls back to `.Mock` on its own, for the rest of that server's life, if the very first real `StartSessionAsync` call throws (DataStore API unavailable, e.g. testing offline).

**Schema (v3)**, defined in `RS/Shared/SaveSchema.luau` as `SaveSchema.Template`, deep-copied per profile by ProfileStore:
```
Version   number                            -- schema version; SaveSchema.Migrate walks old saves up to Config.Data.SchemaVersion

Character = { FirstName, Gender, Race, Kingdom, SkinTone, HairColor {R,G,B},
              EyeColor, FaceBase, MouthShape, Height, GrowthProfile }   -- same fields/meanings as the old Stats shape below
Age       = { Years, TimePassed, ProgToAge }   -- TimePassed set to os.time() on first load
Progress  = { Magoi, GoldRukh, BlackRukh, Epithet,
              PendingEpithet? = { rank, choices {3 strings} } }   -- DESIGN.md section 3a; PendingEpithet added in v2 (M4-01), see section 19
Bounty    number
Economy   = { Copper, Silver, Gold }
Gear      = { Shirt, Pants, Hats {3 slots}, Inventory {item code list} }
Family    table   -- reserved, empty
Magic     table   -- reserved, empty
Meta      = { Created, LastSeen, Lives, Unlocks = { Combat } }   -- Unlocks.Combat added in v3 (M3B-01), see section 9
```
Missing keys on an existing save are filled in by `Profile:Reconcile()` before `SaveSchema.Migrate` runs, so a migration can assume its own version's shape already exists.

**Migrations.** `SaveSchema.Migrations[N]` is a function that turns a save at version `N-1` into version `N`; `Migrate` walks a save up from its own `Version` to `Config.Data.SchemaVersion` one step at a time. `Migrations[2]` (M4-01, the first real one) is an intentional no-op: v2 only adds `Progress.PendingEpithet`, an optional field, so a v1 save missing the key entirely already reads the same as `nil` — there's nothing to backfill, but the entry exists (rather than being left out) so the version bump always walks through a real migration function. `Migrations[3]` (M3B-01, Bryan 2026-09-28) sets `Meta.Unlocks.Combat = true` for every existing save: an existing save already had full combat access before v3 ever existed, and gaining a flag for something it could already do shouldn't take that away — only a save that's genuinely new as of v3 starts at the template's own `false` (has to actually earn it). `Meta`, not `Progress` — the unlock is meant to be per-player forever, not per-life; see section 9 and `DataService.NewLife`/`.Wipe` below.

**Public API** (`RS/Shared` types, `SSS/Server/Services/DataService.luau`): `DataService.Get(player)`, `.WaitFor(player, timeout?)`, `.IsLoaded(player)`, `.Loaded` (fires once the save and the legacy bridge are both ready), `.ResetToTemplate(data)` (M3B-01: the shared reset step `Wipe`/`NewLife` both build on — replaces `data` in place with a fresh, migrated template; data-only, no Player involved, so self-tests can exercise it directly), `.Wipe(player)` (resets to a fresh template in place, for the M1-05 dev "fresh save" command — a wipe is a brand-new player, so `Meta.Unlocks.Combat` resets to `false` along with everything else), `.Save(player)` (manual save, for dev use), `.NewLife(player)` (M2-02: like `Wipe`, but keeps `Meta.Lives` — incremented —, `Meta.Created`, and (M3B-01) `Meta.Unlocks.Combat`, since the combat unlock is per-player forever, not per-life; used by `AgeService`'s old-age death).

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

**What it does.** `CharacterService` runs on `PlayerService.Ready` (after the join pipeline and `DataService` load are both done). Every attribute below is set immediately, even before a gender exists (**F1**: a brand-new player's `Gender` attribute must actually read `0`, not stay unset, or M2-04's `CreationController` never opens the creation screen it's waiting to show). If the save's `Character.Gender` is still 0 (a brand-new life, or right after a death — `DataService.NewLife` resets `Gender` too), it then waits for the `CreateCharacter` remote before building anything; the client shows the Gender/skin screen itself whenever it sees the `Gender` attribute at 0 (M2-04 owns that screen; the old Studio-only `RF.GUI.Gender.Decisions` server script — AUDIT H4 — is never shown by the server anymore). Once a gender exists, it rolls the first growth profile if this is a new life (**F2**: `Character.Height == 10`, the "not rolled yet" sentinel — `AgeHandler.start(age, race, gender)`, ported from the old AppearanceController's "first time height" block, which needs gender for its 0.9x female growth factor; `AgeService` no longer rolls this eagerly on load, since that ran before gender was known and always took the male curve — its `resizeCharacter` fallback still catches a missing profile defensively). Then it strips the default Roblox avatar and rebuilds the same look the old `AppearanceController` did: skin tone (by `SkinTone` + `Kingdom`, template picked **by name**), a `FalseHead` with face decals (face base, eyes, mouth, eyebrows from `RF.Assets`, read through `CharacterService.StatShim` — **BUG-10**: this used to omit `HairColor`, which `Assets.eyebrow` reads as a Color3 to tint the eyebrow; missing it crashed `buildFalseHead` on every single build, which aborted the rest of `buildCharacter` before `AppearenceLoaded` was ever set — naked character, grey hair, and every old script waiting on that flag hanging forever. `StatShim` now covers every key `RF/Assets` actually reads, self-tested against the real `Assets` functions, and each face-decal call is its own `pcall` so a future bad read only drops that one decal instead of the whole build), hair recoloured to `HairColor`, a combat hitbox part, one shared collision group, sounds/particles/footstep sounds/music copied onto the torso (resolved once at `Start()`, not per spawn, by searching `RF.SFX`/`RF.VFX` **recursively** by name — **BUG-19**: the old lookup only checked immediate children, but the real assets sit in subfolders like `VFX.HitEffects`/`VFX.MiscEffects`, `SFX.UISounds`, per `docs/reference/m2-studio-dump.md` section 3, so nothing was ever found: no combat/coin sounds, and `InteractionsHandler` hung forever waiting on the `Cancel` Highlight it never got; a missing name now warns once at boot instead of once per spawn), the saved shirt/pants and hats (or a fresh random starter rag outfit for a new life), a `player.SuccessRate` Folder if it doesn't already exist (**F4**: created once per player, not once per spawn like the old script — `RewardHandler`/`MissionHandler` index it directly and error without it), and the custom run/walk/jump/idle/fall animations (old `SSS/Animations.server.luau`, now folded in; stops any already-playing tracks after the id swap, **F9**, so a stale track can't keep playing). `AppearenceLoaded` (same name/spelling) is still set on the character at the end, since most other scripts (old and new) wait on it. Resizing to the growth profile still happens in `AgeService`, on spawn and on birthdays (section 4).

`FaceControl` (`CharacterService/FaceControl`) is now a plain module the service calls once per character (off its own thread, **F3**, only after `AppearenceLoaded` flips true — `EffectsService` doesn't create `character.Effects` any earlier, so starting it sooner used to stall every spawn for its old fixed 10s wait) instead of a script cloned into the FalseHead; same behaviour and timings — mouth flaps while the player chats, random blinking, "hurt"/"knocked out" faces on `Hit`/`Ragdoll` effects. Its `player.Chatted` and `Effects` connections are now tracked and disconnected together on `character.Destroying` (**F5**), instead of piling up across respawns; its `WateryEyes`/`TalkCount` Values are cloned from the templates moved alongside it rather than built fresh (**F10**).

**Remote:** `CreateCharacter` (client → server, `gender: 1|2`, `skin: 1|2|3`, rate 3/10s). Ignored unless the save's `Character.Gender == 0`. Stores `Gender`/`SkinTone`, rolls a **gender-matched** first name from `Assets.FirstNames.sindria.male`/`.female` (AUDIT L3 — the old roll always used the male list, before gender was even chosen), and refreshes the legacy `Stats` mirror. The client sees it worked once the `Gender` attribute goes non-zero.

**Player attributes kept current:** `Gender`, `SkinTone`, `Kingdom`, `FirstName`, `HeightStuds` (`Character.Height` × a nominal 5-stud default rig height — display only, not HeightHandler's own scale), `Lives`, `Age` (AgeService also keeps this current on every birthday; see section 4).

Applied (not saved) hair colour lerps toward grey from `Config.Aging.GreyStart` to `GreyEnd` — `AgeService.ApplyHairColor` (REVIEW-M2-02 R3: the one shared implementation, called from here on every build **and** from `AgeService.onBirthday`, so hair actually greys in on the birthday it's due rather than only the next respawn) — visible aging, section 4. No wrinkle decal exists yet (`-- ART TASK (Bryan)` comment where it's called).

**Audit fixes carried in:**
- **H4** — the gender/skin picker is a client screen plus one server-validated remote, not a server script reading GUI clicks.
- **L2** (`RF/Assets/init.luau`, `eyecolor`) — the magician eye-colour branch used `Race ~= 4 or Race ~= 5`, which is always true, so it could never run; fixed to `Race == 4 or Race == 5`. Race is fixed to Human (2) for the rest of this renovation (DESIGN.md section 4), so this branch is currently unreachable in play either way — the fix is correctness, not a live change.
- **L3** — first name now rolls from the gender the player actually chose, not the male list rolled before gender exists (`SaveSchema.NewLife`'s roll is a placeholder `CreateCharacter` always overwrites).
- **L6** — the `ToolGrip` Motor6D never had a `Part0`, so it never moved anything. Wired (`Part0 = Torso`, its own parent) rather than deleted: the not-yet-rebuilt `PhysicalHandler.client.luau` still reaches for `Torso.ToolGrip.Part1`.
- **M8** — one collision group (`PlayerLimbs`), registered once at `CharacterService:Init()` (**F6**: along with `ClothingRackGroup` too, if it isn't already — `CollisionsHandler` normally only registers that one later, after the map loads, which used to make the very first `SetCollidable` call fail silently inside a `pcall`; that call runs with no `pcall` now) instead of one per player per spawn that was never removed (Roblox caps collision groups at 32).
- **P4** — the skin template is now picked strictly **by name** (1 Black, 2 Brown, 3 White, with the same Kingdom overrides as before). REVIEW-M2-01 read each `.rbxm` template's actual `BodyColors` and confirmed all five match their name, darkest to lightest: Black (75,54,36), Tan (98,70,47), Brown (158,112,76), LightTan (206,157,116), White (255,203,161).

**Also fixed in review (REVIEW-M2-01):** **F7** a second `CreateCharacter` while `Gender ~= 0` now logs a throttled warning (30s cooldown per player) instead of nothing. **F8** the wait for `CreateCharacter` also gives up if this character is replaced by a respawn, not only if the player leaves. **F11** a stale comment claimed the Kingdom overrides "lighten" the skin; Kingdom 1's White→LightTan actually swaps to a more tan colour (wording only, no behaviour change).

**Files:**
- `SSS/Server/Services/CharacterService/` (`init.luau` the service; `Black`/`Brown`/`White`/`Tan`/`LightTan`/`FalseHead`/`NormMeshie` template assets as before; `FaceControl/` a nested module + its two `WateryEyes`/`TalkCount` Value templates, now actually used — F10).
- `RF/Assets/init.luau`: unchanged data module (face decal tables, first/last names, clothing/outfit/hat/cloak lists, item-code lookup), except the L2 fix above.
- `SSS/Character/ItemHandler.luau`: unchanged, still required by `CharacterService`. `AgeHandler.luau`/`HeightHandler.luau` moved under `AgeService` in M2-02 (section 4); `CharacterService` requires `AgeService.AgeHandler` directly for the F2 roll and `AgeService.ApplyHairColor` for hair colour (R3).

**Removed (TRIAGE #3):** `SSS/Character/AppearanceController/init.server.luau`, `SSS/Character/AppearanceController/FaceControl/init.server.luau`, `SSS/Animations.server.luau`.

**Depends on:** `DataService`, `PlayerService.Ready`, `LegacyBridge` (refreshes `Stats`/`OnCharacter` after writing `Gender`/`SkinTone`/`FirstName`/`Gear`/`GrowthProfile`/`Height` directly to the save), `ItemHandler`, `AgeService` (`AgeHandler` for the first growth roll, `ApplyHairColor` for hair colour), `RF.Assets`, `RF.SFX`, `RF.VFX`, `RF.MISC.HitBox` (none of the last three are synced by Rojo — Studio-only asset folders).
**Depended on by:** nearly every character script still waits on `AppearenceLoaded` (unchanged name); the legacy bridge keeps `Stats.Gender`/`Stats.SkinTone` mirrored for anything not yet rebuilt; `RewardHandler`/`MissionHandler` need `player.SuccessRate`; `AgeService`'s own spawn-resize waits for `AppearenceLoaded` before resizing/re-fitting hats.

---

## 4. Aging, visible aging and death — rebuilt M2-02

**What it does.** `AgeService` runs one shared server loop (`Config.Aging.Tick`, 10s) for every loaded player instead of one thread per player. Each tick it banks real elapsed seconds — times `DevService.GetTimeScale()` — into `Age.ProgToAge`, and turns each `Config.Aging.SecondsPerYear` (60s in Studio, 1800s live — DESIGN's 30 min/year) into a birthday. On a birthday: `Age.Years += 1`, the body is resized (height/build follow the per-life S-curve growth profile, hats/cloaks removed and re-equipped to fit — same as before), and the `Age` attribute updates immediately. Resizing also happens on every spawn (not just birthdays), once `AppearenceLoaded` is true (waits for `CharacterService` to finish first, same ordering the old `AgeController` used).

**Offline aging (DESIGN.md section 3).** On `DataService.Loaded` (once per session), `AgeService.OfflineAgingYears` ages the player up to `Config.Aging.OfflineYearsPerDay` (2) per real day away, capped at `Config.Aging.OfflineAgeCap` (59) — **never fatal**. `Age.TimePassed` (the last aging tick, real `os.time()`) is what this and the online loop both measure from. Fractional leftover days are dropped, not carried over (REVIEW-M2-02 R6, intended: banking them into `ProgToAge` would count them at the much faster *online* rate instead).

**Visible aging.** Applied hair colour (not the saved `HairColor`) lerps toward grey from `Config.Aging.GreyStart` (45) to `GreyEnd` (70) — `AgeService.ApplyHairColor`, called from both `CharacterService`'s build and every birthday (**R3**: it used to only apply on a respawn, so hair didn't actually grey in on the birthday it was due). No wrinkle decal exists in `RF.Assets` yet (flagged `-- ART TASK (Bryan)` where it's called).

**Death (DESIGN.md section 3a "Aging and death"; Bryan's heart-attack styling in `docs/M2-PLAN.md`).** From `Config.Aging.DeathStart` (60), every online birthday fires the `HeartAttack` remote (`age`, `fatal`) — the client (M2-05) always shows a short heartbeat/red-pulse moment, heavier and lasting if `fatal`. `fatal` is rolled from `Config.Aging.DeathChance`, linearly interpolated between its `{age, chance}` points (`AgeService.DeathChance`) — but only if `DevService.IsMortal()` is true (**BUG-20**, Bryan's design: off by default in Studio via `Config.Debug.DeathRolls`, always on live; `.mortal on|off` flips the runtime override, same pattern as `.timescale`); with mortality off, the roll is skipped entirely (not rolled-then-discarded), so `.age`/`.birthday` and natural aging can never kill a test character, but the non-fatal heartbeat/pulse still plays every birthday from `DeathStart`. `.heart fatal` bypasses mortality — it sets `fatal` directly, never through this roll. A fatal roll sets the `Dying` attribute and freezes the humanoid (`WalkSpeed`/`JumpPower`/`JumpHeight` 0; **R10**: a character that spawns mid-scene, e.g. from a reset, is frozen the same way). `DataService.NewLife` (like `Wipe`, but keeps `Meta.Lives` — incremented — and `Meta.Created`) then runs **immediately**, before the scene wait (**R2**: running it only after used to let a player who left during the wait keep their old 60+ life instead — the save is now always the fresh life no matter when they come back). The service then waits for the client's `RukhSceneDone` remote (or `Config.Aging.SceneTimeout`, a flat 30s — **R7**: not time-scaled, since the client's scene takes about the same wall-clock time regardless of aging speed) before calling `Player:LoadCharacter()` and marking the player active again (**R1**: this used to never happen, so a fresh life stopped aging entirely until the player rejoined). `AgeService.ForceBirthday`/`ForceHeartAttack` (and `onBirthday` itself) now refuse while `Dying` (**R4**), so a repeated or badly-timed `.heart fatal` can't start a second death sequence — both return `(boolean, reason?)` (**BUG-08**), so the dev command can say *why* ("already dying") instead of the same generic message a missing save gets.

**Client (`RukhController`, M2-05/M2-FIX-C).** Plays the heart-attack pulse and, on a fatal one, the return-to-the-Rukh scene, entirely off `HeartAttack`'s own `fatal` argument (not the `Dying` attribute, which is informational). A heartbeat is "lub-dub" (two quick beats, then a pause) per Bryan's BUG-16 note: non-fatal is `Config.Aging.DeathStart`-onward short, `Config.Scene.NonFatalCycles` cycles that fully clear between beats; fatal is `Config.Scene.FatalCycles` cycles that deepen in colour and never fully clear, each cycle's `Config.Scene.BeatGap`/`PairGap` stretched again by `Config.Scene.FatalSlowFactor` (compounding, so it visibly slows down), ending near-black with "Your heart gave out." for `Config.Scene.MessageSeconds`. Every timing (`BeatGap`, `PairGap`, `NonFatalCycles`, `FatalCycles`, `FatalSlowFactor`, `MessageSeconds`, `WalkSeconds`, `FadeSeconds`, `CoreDistance`) lives in `Config.Scene`, for Bryan to tune directly; `Config.Sfx.Heartbeat` is the sound (placeholder asset, marked for him to swap).

The scene itself (input frozen, camera scriptable, the character turned golden-neon, a walk toward a core over `Config.Scene.WalkSeconds` with a `Config.Scene.FadeSeconds` white fade at the end, then `RukhSceneDone`) is Bryan's to art-direct in his own `ReplicatedFirst.AfterLife` model — the controller reads exactly three of its children and otherwise never touches it:
- `AfterlifeCamera` (BasePart) — the scene's camera is set to its `CFrame` (and `CameraSubject`, matching the old `WipeHandlerPart2`).
- `AfterlifeSpawnBlock` (BasePart) — the character's `HumanoidRootPart.CFrame` is moved here (client-side only; the server respawns for real).
- `AfterlifeCore` (BasePart, optional) — if present, the character walks toward its `Position`; if the model has no `AfterlifeCore`, or `ReplicatedFirst.AfterLife` doesn't exist at all, the controller builds a plain stand-in marker (`Config.Scene.CoreDistance` studs ahead of the spawn point, or of the character if there's no model either) instead of assuming anything about Bryan's art.
If `ReplicatedFirst.AfterLife` is missing entirely, the scene falls back to keeping the current world in view (camera 12 studs in front of the character, looking back) rather than failing.

**Growth profile format (versioned, unchanged):** `"v1|startHeight|adultHeight|spurtAge|fatEnd"`, rolled once per life and stored in `Character.GrowthProfile`. The actual first roll lives in `CharacterService` now (REVIEW-M2-01 F2), once gender is known — `AgeHandler.start` needs it for the 0.9x female growth factor, and rolling any earlier (this service used to do it on `DataService.Loaded`, before a new player has chosen a gender) always took the male curve. `AgeService.rollFirstGrowth` still exists and is still used by `resizeCharacter`'s own fallback if a profile is ever missing/invalid (same defensive fallback the old `sizeCharacter` had), and after `DataService.NewLife` a death also goes through `CharacterService`'s roll again, since `NewLife` resets `Character.Gender` to 0 too. `AgeHandler.unpack` rejects anything that isn't `v1`.

**Audit fixes:** **M10** (runaway age, no old-age death) — this section is the fix: age is now bounded (offline capped at 59) and old-age death is built. **L5** (`HeightHandler.resize`) — hair accessory parts, their `AccessoryWeld` joint and any attachments inside the hair Handle used to scale by the full body ratio like a torso part; they now all follow the head's (smaller, `HEAD_RESPONSE`-scaled) ratio instead (**R8** completed the joint/attachment half; the parts themselves were already fixed), so hair doesn't stretch or sit offset on a tall/short adult. **R9**: the `Mesh` child scale check now accepts any `DataModelMesh` (`BlockMesh`, `FileMesh`, `CylinderMesh`, not only `SpecialMesh`), matching what the old code scaled.

**Dev commands (section 16):** `.birthday [player]`, `.heart [fatal] [player]`.

**Files:** `SSS/Server/Services/AgeService/` (`init.luau` the service; `AgeHandler.luau` growth maths and the profile format, ported to `--!strict`, same numbers; `HeightHandler.luau` resizes body parts, joints, attachments and accessories — also holds the per-cloak fit offsets — ported to `--!strict` with the L5 fix).
**Removed (TRIAGE #4):** `SSS/Character/AgeController.server.luau`.
**Repointed:** `SSS/Character/ItemHandler.luau` and `SSS/MISC/MissionHandler/init.server.luau` required the old `Character.HeightHandler`/`Character.AgeHandler` paths; both now require the new `Server.Services.AgeService.HeightHandler`/`.AgeHandler`. **BUG-11/BUG-18:** the Studio-only `Workspace.Qarzin.ClothesStand.ClothingSpawn` (a live place script, not synced into `src/`, so it can't be repointed the same way) requires **both** old paths directly (`ClothingSpawn:5` the old `HeightHandler`, `:8` the old `AgeHandler`) and errored every time it tried to stock the shop. `SSS/Character/HeightHandler.luau` and `SSS/Character/AgeHandler.luau` are now one-line compatibility shims (`return require(...AgeService.HeightHandler/.AgeHandler)`) at those old paths — the self-test confirms each shim resolves to the exact same module table as the new path (Lua's require cache, not a copy). Delete both once M5 rebuilds the clothes shop.
**Depends on:** `DataService` (`Age`, `Character.Height`/`GrowthProfile`, `NewLife`), `PlayerService.Ready`, `LegacyBridge`, `DevService.GetTimeScale`/`.OnAgeChanged`, `ItemHandler`, `Gear.Hats`.
**Depended on by:** `CharacterService` (requires `AgeHandler` directly for its own first growth roll, and `GreyFactor` for hair colour), Items, Health (Height adds max health, M2-03).

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

## 8. Movement and speed — rebuilt M3-02 (TRIAGE #9, fixes AUDIT H10/M4/M5/M6/D2)

**What it does.** `MovementService` is now the one owner of `Humanoid.WalkSpeed`, keyed by the combatant's **character Model**, never by Player (NPCs move exactly like players; M3-04's `NpcService` registers them the same way `PlayerService.Ready` registers players).

**Speed stack.** `SetModifier(character, name, mult)` / `ClearModifier(character, name)` keep a named-multiplier table per combatant. The effective multiplier is the **smallest active one** (`0` freezes, matching the old "smallest wins" idea) — with none active, `1.0`. WalkSpeed is written **immediately** on every change (AUDIT M6: the old code updated its base speeds but only re-applied WalkSpeed when something else happened to touch it). Base walk is 16; running is `Combat.Run.speedMult × 16` (28, unchanged) — `Run` isn't folded into the same min-pool as everything else, because it picks which *baseline* (16 or 28) the stack multiplies, not a multiplier of that baseline itself: "half of run speed" and "a quarter of walk speed" (see Low health below) are two different final speeds for the same kind of low multiplier, which a single flat `min()` can't express. Named modifiers other systems use: `Run`, `Block`, `Stun`, `TrueStun`, `Knocked`, `Hit`, `LowHealth`, `HeavyCargo` (missions, via the bridge below).

**Style (M3-FIX4-S).** `SetStyle(character, styleName)` reads the fighting style's own `speedMult`/`dashCooldownMult` traits (`Shared/Data/Combat.luau`'s `Combat.Style`, section 9) and applies them — but NOT through the modifier stack above: a style can be a genuine speed *boost* (the Royal Dagger's `1.10`), and the stack's "smallest active modifier wins" is a debuff rule, not something a boost should ever have to beat. Instead it multiplies the walk/run baseline directly, the same way `Run` already picks 16 vs. 28 before the stack applies, and separately scales `Combat.Dash.cooldown`. `CombatService.Register`/`.SetWeapon` call this; unset (or an unknown style name), it's `1.0`/`1.0` — Fist's own numbers, so nothing changes for the common case.

**Run.** `Run(true)` is ignored while `Stun`/`TrueStun`/`Knocked`/`Block` is active (checked against `StatusService.Has`); the server also clears `Run` itself the instant one of those statuses turns on (subscribed via `StatusService.Changed`), so a client can't keep running through a stun by just not sending `Run(false)`.

**Dash.** A server cooldown (`Combat.Dash.cooldown × the equipped style's own dashCooldownMult`, AUDIT M4 — old code had none and let dashes stack); rejected while `Stun`/`TrueStun`/`Knocked`/`Recovery` (M3-FIX4-S: a punished feint can't dash either; not `Block`: dashing out of a block is fine). No first-punch requirement (**fixes H10** — the old client gated Dash on an attack animation's `Speed` reaching 0) and no cardinal-only restriction (**fixes H10's diagonal half**: the old code built animation names like `"DW"` that never existed; the server just takes any non-zero `(x, z)` in the character's own local space, normalises it itself, and pushes a `LinearVelocity` for `Combat.Dash.distance` studs over `Combat.Dash.duration` seconds along that world direction). Sets the `NextDashAt` attribute (`workspace:GetServerTimeNow()`-based, for a client cooldown UI) and emits `CombatEvent("Dash", {character, x, z})`.

**Low health.** Subscribed directly to the combatant's own `Humanoid.HealthChanged`/`MaxHealth` changes (not `HealthService`'s Player attributes — those are just a mirror of the same Humanoid, and reading the Humanoid directly works for NPCs too, which have no Player). Below full health, a `LowHealth` modifier is applied and kept current: down to half of run speed or a quarter of walk speed at 0 health (old SYSTEMS 8 numbers, `MovementService.LowHealthMult`), scaling linearly with the health ratio in between; at full health it's removed entirely, not just decayed to 1.0.

**Bridge (kept until M5/M6 per the M3 plan).** `character.IntFold.MovementSpeed` keeps one child per active modifier (old code and `PhysicalHandler.client.luau`'s attack-cancel-on-dash both watch `ChildAdded`/`ChildRemoved` there by name), and `IntFold["Running?"]` mirrors the run flag (M3-03's `FootstepService` reads it verbatim for step-sound volume). Unlike `StatusService`'s `Effects` folder, `MovementService` creates `IntFold`/`IntFold.MovementSpeed`/`IntFold["Running?"]` itself if they're missing — `InteractionsDesign.server.luau` used to, and M3-03 deletes that file. `RS/Modules/SpeedHandler.luau` (the old add/remove-a-modifier module) is now a compatibility **shim**: its two remaining real callers, `MissionHandler`'s heavy-cargo slow and `EffectsService.server.luau`'s TrueStun freeze, keep calling it exactly as before, and it forwards into `MovementService.SetModifier`/`ClearModifier`. `Running.model.json` and `CombatRemotes/Dash.model.json` (the old remotes) are deleted — approved TRIAGE #9; `InteractionsHandler.server.luau`'s own `Running`/`Dash` handlers (and its footstep code, which M3-03 moves into `FootstepService`) go with M3-03's deletions, not this one.

**Remotes (client → server, declared in `Shared/Remotes.luau`):** `Run(on: boolean)` (4/s), `Dash(x: number, z: number)` (2/s, each clamped to `[-1, 1]`; the server normalises the resulting vector). **Server → client:** `CombatEvent(kind: string, data: table)` — `Run`/`Dash` kinds from this service, more kinds from M3-03's `CombatService`.

**Attributes:** `SpeedMult` (number, the current effective multiplier), `Running` (bool), `NextDashAt` (server clock).

**Files:** `Server/Services/MovementService.luau`, `Shared/Remotes.luau` (Run/Dash/CombatEvent added), `Modules/SpeedHandler.luau` (now a shim, see above).
**Depends on:** `PlayerService.Ready`/`Players.PlayerRemoving` (player registration), `StatusService` (gates Run/Dash, clears Run on a status), `Shared/Data/Combat` (Run/Dash numbers).
**Depended on by:** `MissionHandler` (heavy cargo, via the `SpeedHandler` shim), `EffectsService.server.luau` (TrueStun, via the same shim), `PhysicalHandler.client.luau`'s dash-cancel (via the `IntFold.MovementSpeed` bridge), M3-03's `CombatService`/`FootstepService`, M3-04's `NpcService`.
**Update (M3-02 review fix):** `Interactions/InteractionsDesign.server.luau` and `Interactions/InteractionsHandler.server.luau` are now both deleted (M3-03) — confirmed no other script creates `IntFold`/`IntFold.MovementSpeed` (`MovementService.luau` is the only remaining creator) or writes `Humanoid.WalkSpeed` for a combatant. Two unrelated, pre-existing scripts still set `WalkSpeed` directly for their own one-shot purposes — `AgeService`'s death-sequence freeze and the client-side `RukhController`'s afterlife-scene lock — but only during a death/afterlife cutscene that ends in the character being destroyed and respawned, not a competing continuous movement system; flagged as a known, low-risk pre-M3 interaction, not touched here. Also fixed: the transient `Dash` bridge child (below) is now routed through `SetModifier`/`ClearModifier` properly, so it actually clears itself after the dash instead of lingering forever (REVIEW-M3-02 #3).

---

## 9. Combat — rebuilt M3-03 (TRIAGE #10, fixes AUDIT C2/H5/H6/M1/M2/M3-P2)

**What it does.** `CombatService` is the server-authoritative combat core, keyed by the combatant's **character Model**, never by Player — NPCs attack and block through the exact same `CombatService.Attack`/`SetBlocking` entry points a Player's remote calls use. The client only ever sends an intention (or, for a hit, a timing report); the server decides everything (**fixes C2**, "the server believes whatever the client says it hit").

**M3B-01 (Bryan, 2026-09-28) added the combat stance: combat is earned, not automatic.** A character attribute, **`InCombat`** (bool), gates `AttackStart`/`AttackCancel`/`Block` — none of the three ever do anything while it's false — but not `Dash`/`Run`, which stay available regardless. The client → server remote **`SetStance(on: boolean)`** (4/s) is the only way to change it: `SetStance(false)` always succeeds (leaving the stance is never blocked by anything). `SetStance(true)` succeeds only if the owning Player's **`CombatUnlocked`** attribute is true, the character is alive, and it's clear of `Knocked`/`TrueStun`/`Recovery` and the Player isn't `Dying` (`AgeService`'s death scene) — otherwise it's silently rejected, same as any other invalid remote call. **NPCs are always `InCombat`** (`NpcService.setupNpc` sets it right after `CombatService.Register`, once, never toggled) — the stance only exists to gate a *player's* click. **`CombatUnlocked`** is computed as `Meta.Unlocks.Combat or Config.Combat.UnlockedByDefault` (section 1's schema v3, section 19) — `Config.Combat.UnlockedByDefault = true` today, so every player can fight regardless of their own save, until Bryan flips it false once the tutorial (a later milestone) exists to actually grant `Meta.Unlocks.Combat` via `CombatService.SetUnlocked(player, true)`. Being account-wide (`Meta`, not `Progress`), an earned unlock survives every future character `DataService.NewLife` creates (a dev `.wipe` still clears it — section 1). `Config.Combat.StanceKey` (`Enum.KeyCode.C`) and `Config.Combat.StanceAnimations` (`{Fist = "", Dagger = ""}`, one looping idle per style, `""` = none) are client-only — the server never reads either, it just validates `SetStance` and the `InCombat` attribute it produces (M3B-03, the client counterpart, reads both).

**Tool → style (M3B-01).** The equipped style still lives in the `WeaponSet` character attribute, but as of M3B-01 it's driven by whichever weapon **Tool** (if any) is a child of the character: a Tool carrying a string attribute `Weapon = "<style name>"` (e.g. `"Dagger"`) equipping into the character calls `CombatService.SetWeapon(character, weaponName)`; unequipping any weapon Tool always drops the style back to `"Fist"` outright (not whatever it was before — there's nothing to track back to and the design doesn't ask for it). `CombatService.Register` connects `Character.ChildAdded`/`.ChildRemoved` for this, and also scans any Tool already equipped at registration time (covers a respawn with a weapon already in hand). Unequipping while `InCombat` cancels any attack in progress outright, the same as any other `SetWeapon` call mid-swing (a chain index from the old style might not exist in the new one). The `.weapon [style] [player]` dev command (section 16) still works as a manual override, but the next real equip/unequip always wins over it, same as a real one would.

**M3-FIX4-S (Bryan, 2026-09-28) built a fighting-style framework on top of M3-FIX3-S's animation-driven hit sequence.** Every weapon is a `Combat.Style` (`Shared/Data/Combat.luau`) — a `displayName`, traits, and an ordered `chain` of `Combat.ChainHit`s, each `Light` or `Heavy`. One click plays one swing animation; the animation carries a wind-up marker and a hit marker per chain hit, and the client fires one `AttackHit(index)` report per hit marker, in order. The server never trusts *what* the report says it hit (C2 stays fixed either way) — only that a marker played — and re-derives the target with its own hit-check. The rock-paper-scissors this is built for, the basis for every future weapon: **Light** is fast, can't be interrupted, deals small damage with no knockback of its own, and puts a landed target in `LightStun` (can't block/parry, but *can* still attack or dash); **Heavy** is slow with a big, readable wind-up, big damage and big block drain, but is interruptible — while it's a combatant's own next unlanded hit, *any* hit landing on them cancels their attack; **Parry** beats both, unchanged. `Combat.Styles.Fist` (2 hits: Jab, Heavy) and `.Dagger` (3 hits: Stab, Slash, Lunge, plus a `bleed` trait) are the two styles today; see the long comment above `Combat.Styles.Fist` for the exact timing rules and the intended cancel-to-bait loop.

**AttackStart()** (client → server, 4/s): rejected outside the combat stance (M3B-01: `InCombat` must be true — never gates an NPC, which is always `InCombat`), if dead, `Stun`/`TrueStun`/`Knocked`/`Block`/`Recovery` is active, an attack is already in progress, or before the `NextAttackAt` attribute (**fixes H6**: stun and cooldowns are enforced, each click can only ever start one attack). On success: `Attacking` is set true, the attacker's `HumanoidRootPart` position is remembered (the anti-teleport baseline), a `Swing` event fires (`{character, style, hitCount}`), and a **watchdog** is scheduled — if the client never reports the final chain hit by `chain[#chain].hitWindow.max + Config.Combat.HitTolerance + style.timeout` (a desynced/dropped client), the attack just ends silently and the normal `recovery` cooldown starts, no event.

**AttackHit(index)** (client → server, 8/s): only accepted if an attack is in progress, `index` is exactly the next chain hit owed (an out-of-order, duplicate, or skipped-ahead index is dropped, no state change, logged only with `.combat log on`), the elapsed time since `Swing` falls inside that hit's `hitWindow` — plus or minus `Config.Combat.HitTolerance` on both ends, absorbing round-trip and animation-marker jitter — and the attacker hasn't moved further than a legitimate combatant could have in that time (`runSpeed × elapsed + Combat.Dash.distance`, the same anti-teleport check as before). Once accepted, the hit-check runs (see below) whether or not it finds a target — a whiffed hit still counts as thrown. After the LAST chain hit is accepted, `Attacking` clears and `NextAttackAt = now + style.recovery`.

**AttackCancel()** (client → server, 4/s): rejected outside the combat stance (same `InCombat` gate as `AttackStart`), otherwise honoured whenever the NEXT unlanded chain hit's own `cancelUntil` (seconds since `Swing`, ± tolerance) hasn't passed yet — per-hit now, not a single swing-level window, so a cancel can still land after an earlier hit in the same chain already did, as long as the *next* one's own cancel point hasn't passed. Fires `AttackCancelled {character, reason = "cancelled"}` and always costs nothing (`NextAttackAt = now`). What happens next depends on the style's `cancelInto` trait: **`"Any"`** (Fist) — the attacker is free to block/attack/dash immediately, full stop; **`"Jab"`** (Dagger) — the server immediately starts `chain[1]` (always a Light) as a brand-new attack flagged `feint = true`. If that feint hit lands **Blocked** (not Parried), the attacker eats `style.feintRecoverySeconds` of a new `Recovery` status (can't attack/block/dash) for overcommitting the bait; if it lands clean, nothing special happens. This is the intended read-and-punish loop: Player 1 swings, the enemy reads it and clicks to interrupt back; Player 1 cancels before their own next hit's cancel point to bait that click, then (Fist) re-swings immediately or (Dagger) is thrown straight into a jab that punishes a panicked block.

**Interrupts.** `AttackCancelled {character, reason = "interrupted"}` fires, and `NextAttackAt = now + <the cut-short hit's own stun>` (getting hit mid-swing costs more than a clean cancel), from three places: (1) `CombatService.ApplyHit` interrupts the TARGET's own in-progress attack the moment a hit lands on them **while their own next unlanded hit is a Heavy** — a Light "cannot be interrupted," whatever kind of hit just landed on it; a parry/block returns before this and never interrupts either way; (2) `Stun`, `TrueStun` or `Knocked` turns on for any reason at all — a real hit, a dev command, anything — via the same `StatusService.Changed` subscriber that already owns Block cleanup (this is what actually interrupts a Heavy that lands: every Heavy's own `stun` is nonzero, every Light's is 0); (3) the combatant dies or unregisters (no event, just torn down).

**The hit-check itself** (unchanged in shape from M3-03, just called per chain hit now): a single generous sphere centred half the hit's `range` in front of the attacker's `HumanoidRootPart` (`Workspace:GetPartBoundsInRadius`) — a simple, well-supported stand-in for a forward capsule swing that doesn't depend on the third-party `ShapecastHitbox` module's (unverified) server-side behavior. Among every candidate the sphere finds, only a **registered combatant**, roughly in front of the attacker's own facing, and with a **clear line of sight** counts; the **closest** one wins. A hit part resolves up to the nearest ancestor Model with a Humanoid (**fixes M3/P2**). `range`/`radius` per chain hit aren't part of Bryan's own design shorthand — added here since the hit-check needs them, carried over from the old Fist/Dagger numbers.

**Applying a hit.** A target already `Knocked` takes no further hit (wait for `Recovered` first). Otherwise, if the target is `Block`ing and facing the attacker: a parry (the `Block` status's `value == 1` window) is resolved **before the block meter is ever touched**, stuns the attacker for half `Block.breakStun` (**fixes H5**'s cooldown so the next hit can't be parried for free), and beats a Light and a Heavy alike. A block that isn't a parry drains `hit.blockDrain` (M3-FIX4-S: per chain hit now — a Heavy costs far more than a Light — not the old flat `Combat.Block.drainPerHit`, which is gone). **A blocker takes no damage, stun, slow or knockback while the block holds, full stop (fixes M1)**, and neither a parry nor a block ever interrupts the target's own in-progress attack. If the block breaks: `TrueStun`/`BlockBroken` apply for `Block.breakStun`. A hit from behind bypasses (and ends) the block. Otherwise, once past the knockout check (health floored at 1, never 0, same as before — **fixes C2**): `HealthService.TakeDamage` applies `hit.damage`; a landed **Heavy** applies the `Hit` stagger (`Stagger.hitStun`, M3-FIX4-S: Heavy-only now); `hit.stun > 0` applies a full `Stun` (every Heavy; no Light does); `hit.lightStun > 0` applies `LightStun` (every Light; no Heavy does — can't block/parry, but can still attack/dash); `hit.bleedStacks > 0` (only Dagger hits) stacks `Bleed`, capped at the style's own `maxStacks`, refreshing (not extending) its duration; and the landed hit registers against the count-based knockback (below). **No per-hit knockback impulse any more** — see Knockback. A `Hit` CombatEvent (`{attacker, target, hitIndex, kind, feint}`) fires either way. Every hit dealt or taken also marks both fighters' `HealthService` regen tier `"Combat"` (falling back to `"Idle"` after `Config.Health.CombatTierSeconds`).

**Knockback by count (M3-FIX4-S, replaces the old per-hit impulse).** The `HitCount` attribute is +1 on every landed hit a combatant takes, from any source. On the `Combat.Knockback.everyHits`th (6th) hit, one impulse (`Combat.Knockback.impulse`, away from whoever landed that hit) fires, `CombatEvent KnockedBack {target}` broadcasts, and the count resets to 0. The count also resets on its own after `Combat.Knockback.resetAfterSeconds` (3s) without a further hit (a delayed check captures its own "last hit at" timestamp, so a stale check from an earlier hit can't reset a count a newer hit has since moved past), and on knockout.

**Bleed (M3-FIX4-S, Dagger only today).** `StatusService`'s `Bleed` status carries `data = {stacks, config}` (`config` is the causing style's own `bleed` trait table, riding along in the status data so `HealthService`'s tick doesn't need to know which style caused it). `HealthService`'s shared regen loop (`Config.Health.Tick`) also ticks Bleed: `config.damagePerStackPerSecond × stacks × Tick` damage, **floored at 1 HP** — bleed never knocks out by itself, so `Humanoid.Died` never fires from it alone. The `Bleed` attribute mirrors the current stack count (0 when inactive) — the one status attribute that isn't a plain boolean (`StatusService.mirrorAttribute`'s own special case).

**NPCs** call `CombatService.Attack(character)` (unchanged entry point/signature) — it runs `AttackStart` then schedules `AttackHit(index)` itself, internally, at the midpoint of each chain hit's `hitWindow`, so an NPC's hits go through the **identical** validation (and can be interrupted the same way) a player's client-reported hits do — no separate NPC-only combat path.

**Block.** `Block(on: boolean)` (client → server, 4/s): **starting** a block is also rejected outside the combat stance (M3B-01: `InCombat` must be true) — but releasing one (`on = false`) is exempt from that gate, deliberately, so a player who leaves the stance (or gets `Dying`-frozen) mid-block is never stuck holding it with no way to ever call this with `on = false` again. Starting is also rejected while `Stun`/`TrueStun`/`Knocked`/`BlockBroken`/`LightStun`/`Recovery` is active (M3-FIX4-S added the last two — a light-stunned or recovering combatant can't block or parry), already blocking, or while an attack (any of its chain hits) is still in progress (`Attacking`). One place, `CombatService`'s own `StatusService.Changed` subscriber, owns everything that happens when `Block` turns on or off **no matter which code path caused it**: the `Combat.Block.blockSpeedMult` `MovementService` modifier and `HealthService.SetBlocking` both follow the status. That same subscriber also removes `Block` outright the instant `Stun`/`TrueStun`/`Knocked`/`LightStun` turns on (**fixes M3**; `LightStun` ends an active block/parry too — rule 1's "blocks Block and parry"), interrupts any in-progress attack on `Stun`/`TrueStun`/`Knocked` (see Interrupts above), and applies `Stun`/`TrueStun`/`Knocked`/`Hit`'s own `MovementService` modifiers (0 for the first three, 0.5 for `Hit`; `LightStun`/`Recovery` don't slow movement).

**Knockout and recovery.** `StatusService.Apply(target, "Knocked", Combat.Knockout.getUpSeconds, {by = attackerName})`, and `HitCount` resets to 0; ragdoll comes from `EffectsService` reacting to the bridged `Knocked` marker, unchanged (see below). Recovery (however `Knocked` ends) sets health to `Combat.Knockout.healthOnGetUp × MaxHealth` and fires `Recovered`.

**Weapon/style:** everyone starts `"Fist"` (the `WeaponSet` attribute, now a style name, not just a weapon label). `.weapon <Fist|Dagger> [player]` (dev, section 16) or `CombatService.SetWeapon(character, styleName)` changes it, ending any in-progress attack outright (a chain index from the old style might not even exist in the new one) and re-applying `MovementService.SetStyle`. The old 10-second auto-equipped Royal Dagger was already removed in M1; bought weapons (M5) will call `SetWeapon` the same way.

**Files:**
- Server: `Server/Services/CombatService.luau`, `Server/Services/FootstepService.luau` (see below).
- Shared: `Shared/Data/Combat.luau` (M3-01; M3-FIX3-S changed `Moves.Fist`/`Moves.Dagger` to one `Combat.Swing` of `Combat.Punch`es; **M3-FIX4-S replaced that with `Combat.Styles`** — each a `Combat.Style` with a `chain` of `Combat.ChainHit`s, plus `Combat.Knockback`; `Combat.Block.drainPerHit` is gone, replaced by per-hit `blockDrain`), `Shared/Config.luau` (`Config.Health.CombatTierSeconds`; `Config.Combat.HitTolerance`; M3-FIX4-C added `Config.Combat.Markers`/`.LogMarkers`/`.CancelFlashSeconds`/`.WindupSpeed`, client-only), `Shared/Remotes.luau` (`AttackStart`/`AttackHit`/`AttackCancel`; `Block` unchanged).
- Kept, trimmed to only what the client `EffectsController` does **not** already do: `Services/EffectsService.server.luau` now just creates `character.Effects` and runs the actual server-side ragdoll physics on `Knocked` (un-ragdolling on `Recovered` isn't separate code — it's the same marker chain run backwards). Also: `Modules/Ragdoll`, `RF/ShapecastHitbox` (unused by the new hit-check, not removed - other systems may still reference it).

**Remotes:** `AttackStart()` (4/s), `AttackHit(index: integer >= 1)` (8/s), `AttackCancel()` (4/s), `Block(on: boolean)` (4/s), `SetStance(on: boolean)` (M3B-01, 4/s) — declared in `Shared/Remotes.luau`. Server → client: `CombatEvent(kind, data)` with kinds `Swing {character, style, hitCount}`, `Hit {attacker, target, hitIndex, kind, feint}`, `AttackCancelled {character, reason: "cancelled" | "interrupted"}`, `Bleed {target, stacks}`, `KnockedBack {target}`, `Blocked`, `Parried`, `BlockBroken`, `Knocked`, `Recovered` (plus M3-02's `Run`/`Dash`). Character attributes: `Attacking` (bool), `HitCount` (M3-FIX4-S), `ComboStep` (kept for compatibility, stays 1 - there's no combo chain to advance), `NextAttackAt`, `WeaponSet` (a style name now, driven by the equipped weapon Tool as of M3B-01), `InCombat` (M3B-01, bool), plus `Blocking`/`Stunned`/`Knocked`/`TrueStunned`/`LightStunned`/`Recovering`/`Bleed` from `StatusService`. Player attribute: `CombatUnlocked` (M3B-01, bool; section 19-style pattern - refreshed on `DataService.Loaded` and by `CombatService.SetUnlocked`).

**Dev commands (section 16):** `.combat log on|off` (logs every `AttackStart`/`AttackHit`/`AttackCancel`/interrupt decision with its elapsed time), `.knock [player]`, `.stun <s> [player]`, `.weapon <Fist|Dagger> [player]` (M3-FIX4-S: sets the fighting style), `.style [player]` (prints the equipped style's chain and traits), `.unlock combat [player]` / `.lock combat [player]` (M3B-01: `CombatService.SetUnlocked`, flips `Meta.Unlocks.Combat` and refreshes `CombatUnlocked`).

**Removed (approved TRIAGE #10/#13):** `Interactions/InteractionsHandler.server.luau`, `Interactions/InteractionsDesign.server.luau`, `Services/DamageHandler.luau`, `Modules/Combat/WeaponHandler.luau` (unused since M1's dagger-autoequip removal), the remote model files `Blocking`, `CombatRemotes/Hit`, `CombatRemotes/Parry`, `GetDamage` (all only ever read by the deleted files or by the old `PhysicalHandler.client.luau`, since replaced by `Client/Controllers/CombatController`). **Kept, not removed:** the top-level `Hit` and `RagdollEvent` remote model files — `EffectsService.server.luau` still fires `RagdollEvent` directly for ragdoll sync; nothing server-side uses the top-level `Hit` remote any more, but it's left in place in case old missions/regions still reference it.

**Footsteps (section 12) moved into `FootstepService.luau`** unchanged (same sounds, same sand/mud footprints, same `MiscRemotes.Footstep` remote) since the combat file it used to live inside is gone; see section 12.

**Health and block — rebuilt M2-03 (TRIAGE #14).** `HealthService` sets `Humanoid.MaxHealth = Config.Health.Base + Config.Health.HeightBonus × Character.Height + Config.Health.RankBonus[rankIndex]` (DESIGN.md section 3a "Rank raises max health"; `rankIndex` from `Shared/Data/Ranks.rankFor`) via `setupCharacter`, called on `PlayerService.Ready`, again once `AppearenceLoaded` is true, and then **every tick of the shared loop below** (REVIEW-M2-03: `AgeService.resizeCharacter` changes `Character.Height` in place on a birthday, with no respawn to re-fire `Ready`, so without the per-tick recompute a live height/rank change wouldn't reach `MaxHealth` until the player's next death or rejoin — the same M11 bug this service exists to fix, just moved). A character already at full health when `MaxHealth` changes is topped up to the new full; otherwise current health is left alone. One shared loop (`Config.Health.Tick`, 1s) regenerates health by `Config.Health.RegenPerSecond[tier]` (`Idle`/`Combat`/`Knocked`, set via `HealthService.SetTier`) and refills `Block` by `Config.Health.BlockRegenPerSecond` while not blocking, up to `Config.Health.MaxBlock` — flat per-second rates, so the tiers actually change the rate now (**FIX L8**: the old scripts' regen scaled with their own wait interval, so the tier variable never mattered). **M3-FIX4-S:** the same loop also ticks `Bleed` (see section 9) - `StatusService.Get(character, "Bleed")`'s `data.config.damagePerStackPerSecond × data.stacks × Tick` damage, floored at 1 HP so it never knocks out on its own. **M4-01:** the `Rank`/`Epithet`/`Alignment` attributes moved out to `RankService` (section 19), which refreshes them itself on every `Progress` change instead of this loop refreshing them every tick — one writer. The old `Knocked`-revival countdown (decrement once a second while health is above a threshold, destroy at 0) that moved over unchanged in M2-03 is **gone as of M3-03** (REVIEW-M3-03 L6): `CombatService`/`StatusService` are the sole authority on when a knockout ends now (`Combat.Knockout.getUpSeconds`, `Recovered`), and an independent second timer here was a real conflict, not just a documented overlap — `Config.Health.KnockedReviveThreshold` is removed with it.

**FIX M11:** the old `Health.server.luau` had `HealthDetermine("Height", ...)` as its own branch, but `Height.Changed` called `HealthDetermine("MaxHealth", ...)` instead, so growing taller never added health. The new formula always recomputes `MaxHealth` from scratch instead of tracking deltas, so there's no branch to wire to the wrong name.

**Numbers changed from the old scripts:** the old max-health formula was race-branched (`50 + 100 + 10×Height` for Race 1, `50 + MaxMagoi/2 + 3×Height` for Race 2, ...) — since Race is fixed to Human for this renovation and Magoi now drives *rank* (DESIGN.md section 3a) rather than health directly, the Magoi/2 term is replaced by `Config.Health.RankBonus[rankIndex]` (`{0, 10, 20, 35, 50, 70, 100}`, one entry per rank). `Base` (50) and `HeightBonus` (3, Race 2's old multiplier) are kept. Health regen's old `Rate = 1/250` (times whatever the tier's wait interval happened to be, which is the L8 bug) is replaced by flat `Config.Health.RegenPerSecond = {Idle=2, Combat=0, Knocked=1}` health/second. Block's old `Rate = 1/750` (≈12.5 minutes to refill) is replaced by flat `Config.Health.BlockRegenPerSecond = 10`.

**API used by M3-03/M3-04's CombatService — now a `Combatant` (`Player | Model`), not just a Player (REVIEW-M3-04 H1):** `HealthService.TakeDamage(combatant, amount, source?)`, `.SpendBlock(combatant, amount): boolean`, `.SetTier(combatant, tier)`, `.SetBlocking(combatant, bool)`, `.IsBlocking(combatant)`. `CombatService.healthCombatant(character)` resolves which identity is real for a given character Model (`Players:GetPlayerFromCharacter(character) or character`), so a Player and an NPC are never mixed for the same combatant. `.SetTier` is called on every hit dealt or taken (`"Combat"`, falling back to `"Idle"` after `Config.Health.CombatTierSeconds`) and whenever `Knocked` starts/ends (`"Knocked"`, then back to `"Combat"`/`"Idle"` on recovery) — for an NPC too, not just a Player. `.SetBlocking` follows the `Block` status directly (one `StatusService.Changed` subscriber in `CombatService`, not scattered call sites); `Blocking` itself is still fully `StatusService`'s `Block` status (`Has(character, "Block")`), `HealthService.IsBlocking` is unused by combat (nothing needs the boolean from this side, only the meter).

**Gap closed by M3-03:** the old `IntFold.BlockInt`/`MaxBlockHpInt` Values are still not bridged to the new `Block`/`MaxBlock` attributes (nothing recreates `IntFold.BlockInt` any more — `InteractionsDesign.server.luau`, which used to, is deleted). The old block HP bar (`StarterGui/HUD/BlockHandler.client.luau`) stays frozen until M2-04's removal of that file actually lands, or something ports it to the `Block`/`MaxBlock` attributes.

**NPC registration (REVIEW-M3-04 H1).** `HealthService.Register(character: Model, opts: {maxHealth: number}?)` / `.Unregister(character)` is the parallel entry point `NpcService.setupNpc` calls — same shared state (`active`/`tierState`/`blockingState`/`blockAmount`), same regen loop, same attribute names, just written onto the NPC's own character Model instead of a Player, and `MaxHealth` given directly (`Config.Npc.MaxHealth[npcType]`) instead of computed from height/rank. The Player path (`PlayerService.Ready` → `setupCharacter`) is untouched. Every public function (`TakeDamage`/`SetTier`/`SpendBlock`/`IsBlocking`/`SetBlocking`) takes either — an NPC takes damage, spends its block meter and gets regen'd through the **exact same code**, not a parallel implementation.

**Dev commands (section 16):** `.hp <n> [player]`, `.tier <Idle|Combat|Knocked> [player]`.

**Files:** `SSS/Server/Services/HealthService.luau`.
**Removed (TRIAGE #14):** `SCS/Health.server.luau`, `SCS/BlockHealthRegen.server.luau`.
**Depends on:** `DataService` (`Character.Height`, `Progress.Magoi`), `PlayerService.Ready`, `Shared/Data/Ranks`, `DevService.Register`/`.ResolvePlayer`.
**Depended on by:** the HUD (`Health`/`MaxHealth`/`Block`/`MaxBlock`/`RegenTier` attributes, plus `Humanoid.Health`/`MaxHealth` directly) for a player; an NPC's own character attributes for whatever reads those later. M3-03's `CombatService` calls the API above for both; M3-04's `NpcService` calls `.Register`/`.Unregister`. (The menu's `Rank`/`Epithet`/`Alignment` attributes are M4-01's `RankService` now, section 19.)

**Not in use:** `RS/Modules/Combat/LightCombat.luau` and `BasicSwordCombat.luau` are an older server-side combat design. Nothing requires them, and they would error if something did: they require `SSS.Services.DamageService`, which doesn't exist.

---

## 10. Status effects — rebuilt M3-01 (TRIAGE #13, fixes AUDIT M18)

**What it does.** `StatusService` is now the one owner of every combat status: `Hit`, `Stun`, `Knocked`, `Ragdoll`, `Block`, `BlockBroken`, `TrueStun`, and (M3-FIX4-S) `LightStun`, `Recovery`, `Bleed`. It's keyed by the combatant's **character Model**, never by Player — NPCs are combatants exactly like players (Bryan, 2026-09-27), so nothing in this service may assume a Player exists. A player is registered automatically when `PlayerService.Ready` fires; M3-04's `NpcService` registers NPCs the same way.

**API:**
- `StatusService.Register(character, owner: Player?)` / `.Unregister(character)` — set up or tear down a combatant's status table. Safe to call more than once; `Unregister` on an unregistered or already-gone character is a no-op, never an error (AUDIT M18).
- `StatusService.Apply(character, status, duration?, data?)` — applies a status. With a `duration` (seconds), it auto-expires on one shared loop (0.1 s tick, not a `task.delay` per status: no leaked threads on respawn). Without one, it stays until `Remove` is called explicitly (e.g. `Block`, which CombatService removes on `Block(false)`). Re-applying an already-active status refreshes its duration and `data` (and the bridge marker below) without re-firing `Changed`, since the active/inactive state itself didn't change.
- `StatusService.Remove(character, status)` — clears it early. No-op if it isn't active or the character is already gone.
- `StatusService.Has(character, status): boolean`, `.Get(character, status): StatusInfo?` (`{ expiresAt: number?, duration: number?, data: any? }`).
- `StatusService.Changed` (`RBXScriptSignal`, fires `(character, status, active)`) — only on an actual active/inactive transition, not on a refresh.

**Character attributes** (client-readable, same cheap-replication pattern as `HealthService`'s player attributes): `Stunned` ← `Stun`, `Knocked` ← `Knocked`, `Blocking` ← `Block`, `TrueStunned` ← `TrueStun`, and (M3-FIX4-S) `LightStunned` ← `LightStun`, `Recovering` ← `Recovery`, `Bleed` ← `Bleed`'s own stack count. `Hit` and `BlockBroken` don't get an attribute (nothing client-side reads them directly yet). `Bleed` is the one attribute that isn't a plain boolean - `mirrorAttribute` special-cases it to write `data.stacks` (0 once inactive) instead of `active`, since a stack count is what `CombatService`/the client actually need from it.

**Bridge to the old markers (kept until M3-03/M3-06 replace their readers).** Every `Apply`/`Remove` also creates/destroys the matching Value under `character.Effects`, with the same Name/ClassName/Value semantics the old `DamageHandler`/`InteractionsDesign`/`EffectsService` used, so old readers (missions, regions, and `EffectsService.server.luau`'s own ragdoll/blind-screen/sound/TrueStun reactions, still unmodified and still running) keep working:

| Marker | Class | Value | Notes |
|---|---|---|---|
| `Hit` | StringValue | `data.kind` or `"Fist"` | old code always wrote `"Fist"` regardless of weapon |
| `Stun` | StringValue | (unset) | |
| `Knocked` | IntValue | `math.ceil(duration)` | a child StringValue named after the attacker (`data.by`) if given, same as the old "personKnocker" pattern. `HealthService`'s old independent revive countdown is gone (M3-03, REVIEW-M3-03 L6) — `StatusService`/`CombatService` are the sole authority on when a knockout ends |
| `Ragdoll` | IntValue | (unset) | |
| `Block` | IntValue | `data.value` or `1` | `StatusService` itself flips it 1→0 on the shared loop, `Combat.Block.parryWindow` seconds after Apply — a caller (CombatService, M3-03) never has to re-Apply just to end the parry window (REVIEW-M3-01 L4) |
| `BlockBroken` | IntValue | (unset) | |
| `TrueStun` | StringValue | (unset) | |

`Hit`'s marker is destroyed and recreated on **every** Apply, even while one is already active (REVIEW-M3-01 M1): several old readers (`EffectsService`'s sound/particle, `FaceControl`'s hurt face, `PhysicalHandler`'s stagger, the FragilePackage mission) key off `ChildAdded`, and reusing one instance across a quick second hit (two attackers, a player and an NPC) would go silent after the first.

`StatusService` only owns the markers; it does not ragdoll, blind the screen, or play sounds itself — `EffectsService.server.luau` still reacts to these same markers exactly as before (unchanged this milestone; M3-06 replaces its client-facing half).

**The bridge is two-way (REVIEW-M3-01 M2).** `StatusService` watches `Effects.ChildRemoved`: if a bridged marker disappears and it wasn't StatusService's own doing, it calls `Remove` on that status too, so `Has`/the attribute never go stale relative to the marker some other script just deleted. (As of M3-03, the scripts that used to independently destroy these markers — `HealthService`'s old revive countdown on `Knocked`, `InteractionsDesign`'s parry/block-break paths on `Block` — are gone; `EffectsService`'s trimmed-down `knockedFunc` still destroys its own `Ragdoll` marker when `Knocked` is removed, which is exactly this two-way bridge at work, not a conflict.)

**The Effects folder itself (REVIEW-M3-01 H1).** For a **player** (`owner ~= nil`), `StatusService` only ever *waits* for `EffectsService.server.luau` to create `character.Effects` (which can take several seconds after `PlayerService.Ready` — it waits on `AppearenceLoaded` on its own schedule) and never creates one itself; it gives up only when the character leaves. Creating one early would leave `EffectsService` to add a *second* "Effects" folder later, orphaning whichever one its own ragdoll/sound/`TrueStun` hooks ended up connected to. For an **NPC** (`owner == nil`, nothing else ever creates one), it waits a bounded 5 s and creates the folder itself if it's still missing. Either way this never yields `Register`/`Apply`'s caller — resolution happens in the background, and any status Applied before it resolves is backfilled with its marker once the folder is found or created (`Has`/the client attributes work immediately regardless).

Every active status is also cleared through the real `Remove` (bridge marker destroyed, `Changed` fired) on `Unregister` and on the combatant's `Humanoid.Died`, not left to linger on a dead or deregistered character (REVIEW-M3-01 M3/L1).

**Other markers still handled the old way** (unchanged, not part of this rebuild): `BigFreezeInput`/`FreezeInput`/`ActionFreezeInput` (input locks, `EffectsService` + `InputHandler.client.luau`), `Reading`/`OnMission` (MissionHandler), `MutedStep`/`Hungry`/`CombatTagged`/`FireBurn` (checked for, but nothing creates them except `Hungry` via the disabled Fear&Hunger script). **Not this `Bleed`:** that list's `Bleed` was an old `character.Effects` marker name nothing ever created; M3-FIX4-S's `StatusService` `Bleed` status (above) is a real, new mechanic with no relation to it and no legacy bridge marker of its own.

**Files:** `Shared/Data/Combat.luau` (move sets, block/dash/run/knockout/stagger numbers — data only, no logic), `Server/Services/StatusService.luau`.
**Depends on:** `PlayerService.Ready`/`Players.PlayerRemoving` (player registration only; NPC registration is M3-04's job).
**Depended on by:** M3-02's `MovementService` (subscribes to `Changed` to clear `Run` on a stun/knock), M3-03's `CombatService` (the only service that decides *when* to Apply/Remove a status), `EffectsService.server.luau` (still reacts to the bridge markers, unchanged), M3-FIX4-S's `HealthService` (reads `Bleed`'s stacks/config on its own shared tick).
**Not yet touched this milestone:** `Services/EffectsService.server.luau` and `Services/DamageHandler.luau` (M3-03 replaces both).

---

## 11. Regions, music and announcements

**What it does.** The map has invisible parts whose names contain `REGION` (under `Workspace.Regions`). The server watches the character's root part touching them and keeps a list in `character.RegionInfo`. The client reacts: it starts a region's music playlist (Qarzin, Qishan City, Badlands, Sakura Island), plays ambient loops (Rain, Ocean), shows a "Q A R Z I N — The Merchant's Playground" banner, and darkens lighting in `DesertLairTunnel`. It fades music out when you leave.

**Files:** `SSS/MISC/RegionHandlerPart2.server.luau`, `SCS/Scripts/RegionHandlerPart1.client.luau`, `RS/Modules/SoundController.luau`.
**⚠** The server-side region list uses `Touched` and `TouchEnded`, and the client changes Lighting without ever restoring it (the restore code is commented out).

---

## 12. Footsteps — moved M3-03 (same behavior as the old code)

**What it does.** `Animate` fires `MiscRemotes.Footstep("Right" | "Left" | "Jump")` on each step (still the old, unvalidated remote — TRIAGE #16 rebuilds this properly in M6). The server plays a step sound that matches the floor material (stone, dirt, wood), checking `IntFold["Running?"]` (now maintained by M3-02's `MovementService`) for volume and `character.Effects.MutedStep` to suppress it. Separately, on **every** step call (not only a jump), it raycasts straight down from the Torso and drops a fading footprint block if that specific raycast hits sand or mud — independent of whatever the sound decision above used (REVIEW-M3-03 M6: the first port of this only ever ran that raycast for a jump, matching the outer sound-material check instead of the old code's own inner, unconditional one — footprints on an ordinary grounded step over sand silently stopped appearing).

Moved out of `Interactions/InteractionsHandler.server.luau` into its own `FootstepService.luau` when that file was deleted for M3-03's combat rebuild (TRIAGE #10) — the footstep code was the one piece of that file that still worked and had nothing to do with combat.

**⚠** `PhysicalHandler.client.luau` (which used to fire `MiscRemotes.Footstep` on each step, alongside its now-deleted combat/movement input) has been fully broken since M3-02 removed `Remotes.Running`, its very first top-level lookup — the whole script errors at load, so **no client currently sends footstep events at all**. `FootstepService` itself is unchanged and correct; it just has nothing to react to until M3-05 replaces `PhysicalHandler.client.luau`.

**Files:** `Server/Services/FootstepService.luau`, `SCS/Animate/init.client.luau` (Roblox's Animate with footstep hooks added, unchanged), `Modules/ColorMath.luau` (third-party color math, used to darken footprints, unchanged).
**Removed:** nothing new; the code lived inside `Interactions/InteractionsHandler.server.luau`, deleted by M3-03 as a whole for its combat parts.

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

## 15. NPCs — rebuilt M3-04 (TRIAGE #20, fixes AUDIT M19)

**What it does.** Behavior-tree NPCs (Bryan, 2026-09-27: "Man was bad. Use behavior trees if at all possible. NPCs should be treated like normal players but with obvious AI controllers"), not ported from the old `NPController`/`NPCFetch` design at all — only its numbers (chase/give-up/attack range) carried over. `NpcService` finds NPC models (children of `Workspace.NPC`, or anything tagged `"NPC"` via `CollectionService`) with a `Humanoid`, reads an `NpcType` attribute or StringValue (`"Dummy"` or `"Target"`, defaulting to `"Dummy"`), and registers each one with `HealthService`, `StatusService`, `MovementService` and `CombatService` **exactly the way a player's character does on `PlayerService.Ready`** — an NPC takes damage, blocks, staggers, gets knocked and recovers through the identical code path, keyed by its character Model, never a Player (REVIEW-M3-04 H1: `HealthService.Register(character, {maxHealth})` gives it the same regen loop and `TakeDamage`/`SpendBlock` a Player gets, not a separate NPC-only health implementation).

**`Shared/BehaviorTree.luau`.** A small, generic BT: `Selector` (first non-`Failure` child wins), `Sequence` (first non-`Success` child wins), `Condition(fn)`, `Action(fn)` (the only node a tree author can return `"Running"` from directly), `Inverter`, `Wait(seconds)`, `Cooldown(seconds, child)`. Every factory returns a fresh `Node` (a table holding one `Tick` function) with its own closure state, so `NpcService/Trees.luau`'s `BuildDummy()`/`BuildTarget()` build one tree **per NPC** — a `Cooldown`'s timer never leaks between two NPCs sharing the same tree shape.

**Trees (`NpcService/Trees.luau`):**
- **Dummy** — `Selector( Sequence(IsKnocked, Wait), Sequence(WasHit, Flinch), Idle )`. Matches the old behavior exactly: no chasing, no wandering, just a flinch reaction and standing still otherwise.
- **Target** — `Selector( Sequence(IsKnocked, Wait), Sequence(HasTarget, Selector( Sequence(InReach, Cooldown(AttackCooldown, Attack)), Sequence(TargetWithin(GiveUpRadius), ChaseStep), GiveUp )), AcquireTarget, Wander )`. `Attack` calls `CombatService.Attack(character)` directly (the same entry point `Attack()` uses for a player); `ChaseStep` uses `PathfindingService`, re-planning at most every 2 seconds (a small path cache) and falling back to a direct `Humanoid:MoveTo` if pathing fails; `AcquireTarget` picks the nearest living, non-`Knocked` player within `ChaseRadius`; `GiveUp` clears the target and path state; `Wander` roams a random point within `WanderRadius` of wherever the NPC started. **Fixes AUDIT M19**: giving up never leaves a permanent flag — the very next tick's `AcquireTarget`/`Wander` can pick a new target right away, and losing the character model entirely (below) gets a fresh `AiController` with no memory of the old chase at all, not a start "gave up forever."

**`NpcService/AiController.luau`.** Holds one NPC's blackboard (character, humanoid, root part, npc type, current target, path/waypoint cache, wander goal) and its tree; `Tick()` just runs the tree once. One shared loop in `NpcService` ticks every registered NPC's `AiController` at `Config.Npc.TickSeconds` (0.2 s) — not a thread per NPC, same reasoning as `StatusService`'s own shared expiry loop.

**Respawn.** At setup, each NPC model is cloned once into `ServerStorage.NpcTemplates` (keyed by its own `Name`) before anything else touches it — the dummy's own art is never modified, only read. If the live model is ever destroyed (a mission, a test, `.npc reset`), `NpcService` re-clones the template at the same spot and registers the fresh copy exactly like a new NPC — a clean restart, not a revive of old state.

**Config:** `Config.Npc` in `Shared/Config.luau` — `TickSeconds = 0.2`, `ChaseRadius = 30`, `GiveUpRadius = 40`, `AttackRange = 4`, `AttackCooldown = 1.4`, `WanderRadius = 12`, `MaxHealth = { Dummy = 100, Target = 100 }` (NPCs get health from here, via `HealthService.Register`, not the player rank ladder), `Animations = { Walk = "", Run = "", Flinch = "" }` (asset id fallback, see below).

**⚠ Animations still need Bryan's asset ids.** The old `NPCFetch`/`Health` scripts (Studio-only, already deleted by Bryan, never in this repo) are the only place the walk/run/flinch animation asset IDs ever lived — there's no source to port them from. `Trees.luau`'s `playAnimationIfPresent` tries an `Animation` instance by name (`"Walk"`/`"Run"`/`"Flinch"`) on the NPC model first, then falls back to an asset id in `Config.Npc.Animations = {Walk = "", Run = "", Flinch = ""}` (REVIEW-M3-04 L2, empty by default) — **Bryan/the playtester needs to check in Studio** whether the dummy models already have named Animation instances, and either way, fill in whichever one's missing (an instance on the art, or the id in `Config.Npc.Animations`). Movement, chasing, attacking and reacting to hits all work regardless — this only affects what animation plays while doing it.

**Dev commands (section 16):** `.npc list`, `.npc reset`, `.npc type <name> Dummy|Target`.

**Files:** `Shared/BehaviorTree.luau`, `Server/Services/NpcService/init.luau`, `Server/Services/NpcService/AiController.luau`, `Server/Services/NpcService/Trees.luau`.
**Removed (TRIAGE #20):** `RS/Modules/NPController.luau` (nothing required it once the old Studio-only `NPCFetch`/`Health` scripts that used it were already gone).
**Depends on:** `HealthService.Register`/`.Unregister` (REVIEW-M3-04 H1), `StatusService`, `MovementService`, `CombatService` (all keyed by character Model, NPC-safe by M3-01's own design rule), `Shared/Data/Combat` (the Fist fighting style, via `CombatService`).
**Depended on by:** nothing yet; a future mission/bounty system could read `StatusService.Has(npc, "Knocked")` the same way it would for a player.

---

## 16. Dev commands — rebuilt M1-05

**What it does now.** One `DevService` (`SSS/Server/Services/DevService.luau`) owns every dev command. Commands arrive two ways — typed in chat (`Player.Chatted`, same leading-`.` style as before) or from the M1-05C dev panel over the new `DevCommand` remote — and both go through the same `DevService.Run`, so there's exactly one place permission and parsing happen. Another service can add its own commands via `DevService.Register`/`.ResolvePlayer` (M2-02's `.birthday`/`.heart` from `AgeService`, M2-03's `.hp`/`.tier` from `HealthService`) instead of `DevService` requiring that service back, since Roblox errors on a cyclic `ModuleScript` require. The same reasoning gave `.age`/`.age+` a hook, `DevService.OnAgeChanged(player, data)` (**BUG-15**): `AgeService` and `HealthService` each register one at `Init()` to react to a dev-forced age change immediately, instead of `DevService` requiring either of them. `AgeService`'s hook sets the `Age` attribute itself now too (**BUG-17**: it resized and re-coloured hair but left the attribute stale, so the menu's age line didn't update until the next birthday).

**Permission.** A player is a dev if their UserId is in `Config.Dev.Admins` (`27938432`, Bryan — the same UserId the old handler checked), **or** `Config.Debug.Enabled` is true (Studio: everyone testing there is a dev). Checked on the server before anything else runs. A non-dev gets no reply at all (so they can't tell a real command from an unknown one) and one `Log:Warn` per player per minute, not per command.

**Commands** (all start with `.`; `[player]` defaults to the caller and matches by display name or username prefix, case-insensitive — ambiguous replies with the candidates):

| Command | Effect |
|---|---|
| `.cmd` | lists every command with one-line help |
| `.state [player]` | sends a state snapshot to the caller over `DevState` and logs the same snapshot as a readable block in Output |
| `.watch on\|off` | streams `DevState` to the caller every second |
| `.coins <copper> [silver] [gold] [player]`, `.coins+ ...` | set or add currency |
| `.age <years> [player]`, `.age+ <n>` | set or add to `Age.Years`, then runs every `DevService.OnAgeChanged` hook (**BUG-15**: resize + grey hair via `AgeService`, max health via `HealthService` — these used to only catch up on the next `.birthday`) |
| `.magoi <n> [player]`, `.magoi+ <n>` | set or add to `Progress.Magoi`, through `RankService.AddMagoi` (**M4-01**: re-registered by `RankService`, replacing `DevService`'s own version, so a rank-up fires immediately instead of waiting on a poll) |
| `.rukh <gold> <black> [player]` | sets both Rukh tallies, through `RankService.AddDeed` (**M4-01**, same reasoning as `.magoi`) |
| `.bounty <n> [player]` | sets `Bounty` |
| `.epithet <text> [player]`, `.epithet clear [player]` | sets `Progress.Epithet` (quote multi-word text), or clears both the epithet and any pending choice and re-checks the origin condition (**M4-01**, `RankService`, replacing `DevService`'s own version) |
| `.rankup [player]` | adds exactly enough Magoi to reach the next rank threshold (**M4-01**, `RankService`) |
| `.tp <city>` | teleports the caller's character to a spawn point (matches `Workspace.MAP.Spawns` children case-insensitively, with or without the `Spawn` suffix — `.tp qarzin` finds `QarzinSpawn`) |
| `.cities` | lists the spawn points that exist |
| `.timescale <n>` | sets a runtime time scale (`DevService.GetTimeScale()` / `.TimeScaleChanged`); later milestones (aging, day/night) should read it from here instead of the frozen `Config.Debug.TimeScale` |
| `.mortal on\|off` | toggles whether a birthday can roll a death (`DevService.IsMortal()`, same pattern as `.timescale`; **BUG-20**) |
| `.fresh [player]` | `DataService.Wipe`, then reloads the character (kick-free) |
| `.save [player]` | saves now |
| `.birthday [player]` | forces one birthday tick right now (`AgeService.ForceBirthday`) |
| `.heart [fatal] [player]` | fires a heart attack right now (`AgeService.ForceHeartAttack`); put `fatal` first to make it lethal |
| `.hp <n> [player]` | sets current health (`HealthService`) |
| `.tier <Idle\|Combat\|Knocked> [player]` | sets the regen tier (`HealthService.SetTier`) |
| `.combat log on\|off` | logs every hit decision (swing/hit/blocked/parried/broken/knocked) to Output (`CombatService`) |
| `.knock [player]` | forces a knockout (`StatusService.Apply(..., "Knocked", ...)`) |
| `.stun <s> [player]` | forces a `Stun` for `s` seconds |
| `.npc list` | lists every registered NPC, its type and current health |
| `.npc reset` | destroys every live NPC (each respawns fresh from its `ServerStorage.NpcTemplates` copy) |
| `.npc type <name> Dummy\|Target` | changes an NPC's type at runtime and rebuilds its `AiController` |

Every stat-editing command writes through the `DataService` table and calls `LegacyBridge.Refresh` so the old Value folders (and the coin purse HUD, for currency) pick it up immediately — never the Values directly. Every reply goes out over `DevReply` and is also logged with `Log:Info`.

**The state snapshot** (`DevState`, also what `.watch` streams every second), a flat table in a fixed key order: `name, userId, joinState, age, magoi, rank, goldRukh, blackRukh, epithet, bounty, copper, silver, gold, walkSpeed, health, maxHealth, position {x,y,z}, saveScope, freshSave, timeScale, mortal, sessionSeconds`. **⚠** `rank` still always sends `"n/a"` — `DevService`'s own snapshot code was written before rank existed (M1-05) and hasn't been pointed at `RankService.GetRank` yet; the player's `Rank`/`RankIndex`/`Alignment`/`EpithetPending` attributes (M4-01) are the live source until a follow-up wires this up.

**Remotes:** `Net.DevCommand` (client → server, one string, 5/s), `Net.DevReply` (server → client, one string), `Net.DevState` (server → client, one table).

**Removed:** `SSS/DevCommandHandler.luau` and `SSS/DevCommandChatListener.server.luau` (TRIAGE #21) — the old offline path wrote to DataStores named `"Mainstore2"`/`"OnCharacterStore2"`, which never matched the real save name, so offline edits never worked; the new tools only ever write through `DataService`.

---

## 17. Collisions

`SSS/Interactions/CollisionsHandler` puts all map parts (except `Areas`) in `MapCollisionGroup`, and clothing racks in `ClothingRackGroup`. Appearance gives each player their own limb group that doesn't collide with clothing racks.

---

## 18. Ocean (Workspace, not synced)

766 server Scripts under `Workspace.MAP.OCEAN`, three per ocean tile, animate the waves: parts bob 2 studs over 15 s, and wave decals fade in and out over 10 s. **⚠** The `OceanWaves` copies move up and then "down" to the same spot, so they stop after one bob. Every copy adds more event connections each cycle, so the cost keeps growing the longer a server runs.

---

## 19. Rank, Rukh alignment and epithets — new M4-01

**What it does.** `RankService` (`SSS/Server/Services/RankService.luau`) computes each player's rank and Rukh alignment from `Progress` (`Magoi`, `GoldRukh`, `BlackRukh`) using the pure `Shared/Data/Ranks`/`Alignment`/`Epithets` modules (DESIGN.md section 3a, data since M2-06), owns the `Rank`/`RankIndex`/`Epithet`/`Alignment`/`EpithetPending` player attributes (taken over from `HealthService`'s old per-tick refresh — see section 9), and fires the rank-up, alignment-changed and origin-choice moments for M4-02's client to show.

**No shared polling loop.** Every write to `Progress.Magoi`/`GoldRukh`/`BlackRukh` goes through `RankService.AddMagoi`/`.AddDeed`, which check for a rank/alignment change right where the number actually changes — including the dev `.magoi`/`.magoi+`/`.rukh` commands, which `RankService` re-registers under their existing names (`DevService.Register` is a plain table write keyed by command name — any service can add to it, and re-registering the same name overwrites the previous entry; this is how `RankService` swaps in a version that routes through `AddMagoi`/`AddDeed` without `DevService` needing to require `RankService` back, which Roblox would refuse as a cyclic `ModuleScript` require).

**Rank-up.** `AddMagoi(player, amount, reason)` clamps `Progress.Magoi` at 0 and compares the rank index before and after (`Ranks.rankFor`). A rise (never a fall — a dev removing Magoi just updates the attributes, no card) rolls three distinct epithets for the new rank and the player's *current* alignment (`Epithets.pick3(newTitle, alignmentKey, gender, {currentEpithet})`, excluding the epithet they already have so they're never offered a repeat), stores `Progress.PendingEpithet = {rank, choices}`, sets `EpithetPending = true`, and fires `RankUp {title, rankIndex, alignment, choices, origin = false}`.

**One card at a time (H1 fix, REVIEW-M4-01).** A rank-up never overwrites a choice that's still pending, and never jumps straight to the top rank when a grant crosses several thresholds at once (a real risk once M5's missions can pay out a large lump sum) — `RankService.NextRankToAnnounce(data, oldIndex, newIndex)` is the pure decision `AddMagoi` calls instead of announcing `newIndex` directly: it returns `nil` (nothing announced, attributes still update silently) while `Progress.PendingEpithet ~= nil`, or while `Progress.Epithet == ""` (the origin choice hasn't happened yet — it always comes first), and otherwise only ever `oldIndex + 1`, one rank up from wherever the player last was. The rest of a multi-threshold grant surfaces as each card is answered: `ChooseEpithet`'s handler captures the just-cleared choice's own rank and calls `RankService.NextRankAfterChoice(data, answeredRank)`, which re-reads the player's actual current rank (`Ranks.rankFor(Progress.Magoi)`) and, if it's still higher, announces `answeredRank + 1` — so `.magoi 1500` from Street Rat walks the player through Wanderer, then Adventurer, then Renowned, one `RankUp`/`ChooseEpithet` round-trip at a time, never skipping straight to Renowned.

**Origin at birth.** The Street Rat epithet is chosen once, before a life is judged (White Rukh): `RankService.ShouldOfferOrigin(data, gender)` is true once `Progress.Epithet == ""`, nothing is already pending, and `Gender ~= 0` (character creation done — M2-01's `CharacterService` sets this player attribute). One connection per session on `player:GetAttributeChangedSignal("Gender")` (not a `CharacterService.Created` signal — chosen because the attribute already exists and this avoids touching a file outside this task) does double duty: when `Gender` goes back to 0 (a fresh life — `DataService.NewLife`/`Wipe` already reset `Progress` by the time the new character's attributes are set), it just resyncs the display attributes; when `Gender` goes non-zero, it checks `ShouldOfferOrigin` and, if true, rolls from the Street Rat bank and fires `RankUp {..., rankIndex = 1, origin = true}` the same way a real rank-up does.

**Reconnecting with a choice still pending** (left the game before answering): `RankService:Start()` re-sends the *same stored* `Progress.PendingEpithet.choices` as a `RankUp` (never re-rolled) the moment `DataService.Loaded` fires, so the client shows the same card again. `origin` is inferred as `pending.rank == 1 and Progress.Epithet == ""` — the only way `PendingEpithet.rank` can ever be 1 is the origin flow, since a real rank-up's "before" index is already at least 1 the very first time `AddMagoi` runs.

**Alignment.** `AddDeed(player, "Gold" | "Black", amount)` clamps the given Rukh tally at 0 and compares `Alignment.alignmentFor(GoldRukh, BlackRukh)` before and after. A change that lands on anything but `"White"` fires `AlignmentChanged {alignment}` — landing back on `"White"` never does (that only means dropping below `Alignment.MinDeeds` total deeds, i.e. a dev command lowering the tallies, not a moment worth announcing).

**`ChooseEpithet(index)`:** rejected unless `Progress.PendingEpithet` exists and `index` is an in-range integer 1–3 (the remote's own validator, `Shared/Remotes.luau`, already guarantees the integer/range part; `RankService.ApplyChooseEpithet` re-checks it anyway as the self-tested, Player-free core). On success, `Progress.Epithet` is set from the *stored* choice at that index — never a string the client sends — and `PendingEpithet` is cleared.

**Public API (for M5's missions):** `RankService.AddMagoi(player, amount, reason)`, `.AddDeed(player, kind, amount)`, `.GetRank(player): (index, title)`, `.GetAlignment(player)`. Also `.TitleForIndex(index, gender)` (resolves a stored rank index to its gendered title, e.g. for a `PendingEpithet` resend) and the pure, self-tested core (`ApplyMagoi`, `ApplyDeed`, `ApplyChooseEpithet`, `ShouldOfferOrigin`, `NextRankToAnnounce`, `NextRankAfterChoice`) the Player-facing functions above are thin wrappers around.

**Dev commands (section 16):** `.rankup [player]` (adds exactly enough Magoi to reach the next threshold), `.epithet clear [player]` (new); `.magoi`/`.magoi+`/`.rukh` re-registered to route through `AddMagoi`/`AddDeed` (same usage and reply text as before).

**Remotes** (`Shared/Remotes.luau`): `RankUp` (server → client, `{title: string, rankIndex: number, alignment: string, choices: {string}, origin: boolean}`), `AlignmentChanged` (server → client, `{alignment: string}`), `ChooseEpithet` (client → server, `index: number` integer 1–3, 3/10s).

**Player attributes:** `Rank` (title via `Ranks.titleFor`), `RankIndex`, `Epithet`, `Alignment` (label), `EpithetPending` (bool) — moved here from `HealthService` (section 9), which still owns `Health`/`MaxHealth`/`Block`/`MaxBlock`/`RegenTier` and still reads `Ranks.rankFor` itself for the max-health formula.

**Files:** `SSS/Server/Services/RankService.luau`.
**Depends on:** `DataService` (`Progress.*`, `Character.Gender`, `.Loaded`/`.Get`/`.IsLoaded`), `LegacyBridge.Refresh` (Magoi is one-way bridged to the legacy `Stats.MaxMagoi`, section 1), `DevService.Register`/`.ResolvePlayer`, `Shared/Data/Ranks`/`Alignment`/`Epithets`, `Shared/Remotes`.
**Depended on by:** M4-02's client `RankController` (the remotes and attributes above); M5's missions (`AddMagoi`/`AddDeed`).

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

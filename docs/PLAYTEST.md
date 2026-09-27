# Playtest scenarios

Repeatable checks the playtester runs after each milestone. Every scenario says exactly how to set it up with dev commands, what to look for, and what counts as a pass. The playtester runs on the cheap model: it reads **Output** and the **`.state` dump** first and takes a screenshot only where a scenario says "look".

**Setup for every run:** Studio open on the published place, Rojo connected, then **Play** (F5). In Studio, `Config.Debug.Enabled` is on, the save scope is `Studio`, and everyone counts as a dev. Dev commands are typed in chat (they start with `.`) or in the ` (backquote) dev panel. `.cmd` lists them.

**Result format:** for each scenario: `PASS` / `FAIL` / `BLOCKED`, the Output lines that matter (errors and warnings verbatim), and the `.state` dump where the scenario asks for it. Log every FAIL as a bug in `docs/BUGS.md` (lead does this).

---

## M1 Foundation

### M1-A Server boots clean
- **Setup:** Play. Wait 10 s.
- **Look for in Output:** the self-test line from `[SelfTest]` (must say PASS), `[Net]`, `[Data]`, `[Player]` and `[Dev]` startup lines. No red errors. No raw `print` lines from new code (old scripts may still print).
- **Pass:** self-test PASS, zero errors from anything under `Server/`, `Client/` or `Shared/`.

### M1-B Join pipeline and spawn
- **Setup:** Play as a fresh character (`.fresh` first if not new).
- **Look for:** the loading screen shows, fades once, and the character is standing at the Qarzin spawn (not 300 studs away). In Output, the join states in order: `Loading` → `Loaded` → `Ready`. No "Appearence isn't loading" kick.
- **Then:** `.state` and confirm `joinState = Ready`.
- **Reset the character** (Esc → Reset). The loading screen shows again, and the character is back at the Qarzin spawn.
- **Pass:** both spawns at Qarzin, no kick, no errors, state ends at Ready both times.

### M1-C Slow character creation is not kicked
- **Setup:** `.fresh`, then on the gender and skin screen wait **45 seconds** before choosing.
- **Pass:** no kick, creation finishes, `.state` shows `joinState = Ready`.

### M1-D Save persists across rejoin (Studio scope)
- **Setup:** `.age 40`, `.coins 123 4 5`, `.magoi 250`, `.rukh 3 1`, `.bounty 7`, `.epithet "The Sand-Born"`. Run `.state` and copy the dump. Stop, then Play again.
- **Look for:** `.state` after the rejoin shows the same age, coins, magoi, rukh, bounty and epithet.
- **Pass:** every value matches. (Requires `Config.Debug.FreshSave = false`.)

### M1-E Fresh save switch
- **Setup:** with `Config.Debug.FreshSave = true` (edit `Shared/Config.luau`, Rojo syncs it), Play, `.age 40`, Stop, Play.
- **Pass:** `.state` shows age 13 again. Set FreshSave back to false afterwards.

### M1-F Wipe command
- **Setup:** `.age 40`, `.coins 999`, then `.fresh`.
- **Pass:** `.state` shows age 13, coins 20 copper, a new random first name, the old menu (M key) shows the new name and age, no errors.

### M1-G Legacy bridge keeps old systems alive
- **Setup:** after M1-B, open the menu (M). Buy something at the Qarzin clothes stand if coins allow (`.coins+ 500` first).
- **Look for:** the menu shows name, age and height; the coin purse HUD text changes when coins change (`.coins+ 10` makes it tick up and the coin sound plays); the bought item appears on the character and in `.state` (via the old Values → save).
- **Then:** Stop, Play, and confirm the item and coins survived.
- **Pass:** menu, purse and shop all work through the bridge; nothing about the look changed.

### M1-H Dev permission is checked on the server
- **Setup:** this needs a non-dev; in Studio everyone is a dev, so check the log path instead: run `.state` and confirm the server logs the command under `[Dev]` with the caller's name. Then in `Shared/Config.luau` temporarily set `Debug.Enabled = false` (Rojo syncs), Play, and run `.age 40`.
- **Pass:** with Debug off, nothing changes and Output shows one `[Dev]` warning for the rejected caller. Turn Debug back on afterwards.

### M1-I Remote validation and rate limit
- **Setup:** in the Studio command bar (client side, while playing), run:
  ```lua
  local r = game.ReplicatedStorage.Net.DebugPing
  r:FireServer(string.rep("x", 200))            -- too long
  r:FireServer(5)                                -- wrong type
  for i = 1, 20 do r:FireServer("hi") end        -- over the rate limit
  ```
- **Pass:** Output shows `[Remotes]` warnings naming the player, the remote and the reason (throttled, not one per call), and no errors.

### M1-J Dev panel and overlay
- **Setup:** press F8, then the backquote key (`, left of 1).
- **Look (one screenshot):** the F8 overlay in the top-left lists the snapshot keys in order and updates once a second; the backquote panel in the top-right has the command box, reply log and quick buttons. `.timescale 10` then `.state` shows `timeScale = 10`. `.tp qarzin` moves the character (only QarzinSpawn exists today); `.cities` lists the spawns.
- **Pass:** both toggle cleanly, no input leaks into gameplay while typing, no errors.

### M1-K Leave and rejoin under load (two players)
- **Setup:** Test → Start with 2 players (local server). Both join, one leaves during the loading screen.
- **Pass:** no errors for the leaver, the other player reaches Ready, and the server logs the session end.

---

Before I tested anything, I spawned in completely naked and my hair gray. I had a loaded face. The error read as such. No animations played, and none of the clothes and hats for hat stand loaded.
  12:08:37.345  ReplicatedStorage.Shared.Data.Epithets:83: invalid argument #1 to 'freeze' (table is already frozen)  -  Server - Epithets:83
  12:08:37.345  Stack Begin  -  Studio
  12:08:37.345  Script 'ReplicatedStorage.Shared.Data.Epithets', Line 83  -  Studio - Epithets:83
  12:08:37.345  Stack End  -  Studio
  12:08:37.345  Requested module experienced an error while loading  -  Server - SelfTestService:18
  12:08:37.345  Stack Begin  -  Studio
  12:08:37.345  Script 'ServerScriptService.Server.Services.SelfTestService', Line 18  -  Studio - SelfTestService:18
  12:08:37.345  Stack End  -  Studio
  12:08:37.346  [Server.Main] require(SelfTestService) failed: Requested module experienced an error while loading  -  Server - Main:36
  12:08:37.349  HeightHandler is not a valid member of Folder "ServerScriptService.Character"  -  Server - ClothingSpawn:5
  12:08:37.349  Stack Begin  -  Studio
  12:08:37.349  Script 'Workspace.Qarzin.ClothesStand.ClothingSpawn', Line 5  -  Studio - ClothingSpawn:5
  12:08:37.349  Stack End  -  Studio
  12:08:37.517  [CreationController] ready  -  Client - Log:58
  12:08:37.518  [DevController] dev overlay (F8) and dev panel (backquote `) ready  -  Client - Log:58
  12:08:37.518  [HudController] ready  -  Client - Log:58
  12:08:37.519  [MenuController] ready (M to toggle)  -  Client - Log:58
  12:08:37.519  [RukhController] ready  -  Client - Log:58
  12:08:38.497  [ProfileStore]: Roblox API services available - data will be saved  -  Server - ProfileStore:2115
  12:08:47.617  [DataService] Loaded save for iiBry (scope Studio)  -  Server - Log:58
  12:08:47.621  Infinite yield possible on 'Workspace.iiBry:WaitForChild("AppearenceLoaded")'  -  Studio
  12:08:47.621  Stack Begin  -  Studio
  12:08:47.621  Script 'ServerScriptService.Interactions.InteractionsDesign', Line 11  -  Studio - InteractionsDesign:11
  12:08:47.621  Stack End  -  Studio
  12:08:47.621  Infinite yield possible on 'Workspace.iiBry:WaitForChild("AppearenceLoaded")'  -  Studio
  12:08:47.621  Stack Begin  -  Studio
  12:08:47.621  Script 'ServerScriptService.MISC.RegionHandlerPart2', Line 3  -  Studio - RegionHandlerPart2:3
  12:08:47.621  Stack End  -  Studio
  12:08:47.621  Infinite yield possible on 'Workspace.iiBry:WaitForChild("AppearenceLoaded")'  -  Studio
  12:08:47.621  Stack Begin  -  Studio
  12:08:47.621  Script 'ServerScriptService.Services.EffectsService', Line 159  -  Studio - EffectsService:159
  12:08:47.621  Stack End  -  Studio
  12:08:47.621  Infinite yield possible on 'Workspace.iiBry:WaitForChild("AppearenceLoaded")'  -  Studio
  12:08:47.621  Stack Begin  -  Studio
  12:08:47.621  Script 'Workspace.NPC.DUMMY.NPCFetch', Line 168  -  Studio - NPCFetch:168
  12:08:47.621  Stack End  -  Studio
  12:08:47.683  Infinite yield possible on 'Players.iiBry:WaitForChild("Stats")'  -  Studio
  12:08:47.683  Stack Begin  -  Studio
  12:08:47.683  Script 'ReplicatedFirst.GUI.UIGUI.MenuGUI.MasterFrame.MenuGUIFrame.MenuMechanics', Line 16  -  Studio - MenuMechanics:16
  12:08:47.683  Stack End  -  Studio
  12:08:47.683  Infinite yield possible on 'Workspace.iiBry:WaitForChild("AppearenceLoaded")'  -  Studio
  12:08:47.683  Stack Begin  -  Studio
  12:08:47.683  Script 'Workspace.iiBry.Animate', Line 4  -  Studio - Animate:4
  12:08:47.683  Stack End  -  Studio
  12:08:47.683  Infinite yield possible on 'Workspace.iiBry:WaitForChild("AppearenceLoaded")'  -  Studio
  12:08:47.683  Stack Begin  -  Studio
  12:08:47.683  Script 'Workspace.iiBry.Scripts.RegionHandlerPart1', Line 3  -  Studio - RegionHandlerPart1:3
  12:08:47.683  Stack End  -  Studio
  12:08:47.683  Infinite yield possible on 'Workspace.iiBry:WaitForChild("AppearenceLoaded")'  -  Studio
  12:08:47.683  Stack Begin  -  Studio
  12:08:47.683  Script 'Workspace.iiBry.Scripts.PhysicalHandler', Line 27  -  Studio - PhysicalHandler:27
  12:08:47.683  Stack End  -  Studio
  12:08:47.683  Infinite yield possible on 'Players.iiBry:WaitForChild("Stats")'  -  Studio
  12:08:47.683  Stack Begin  -  Studio
  12:08:47.683  Script 'Players.iiBry.PlayerGui.MenuGUI.MasterFrame.MenuGUIFrame.MenuMechanics', Line 16  -  Studio - MenuMechanics:16
  12:08:47.683  Stack End  -  Studio
  12:08:50.825  ReplicatedFirst.Assets:125: attempt to index nil with 'Value'  -  Server - Assets:125
  12:08:50.825  Stack Begin  -  Studio
  12:08:50.825  Script 'ReplicatedFirst.Assets', Line 125  -  Studio - Assets:125
  12:08:50.825  Script 'ServerScriptService.Server.Services.CharacterService', Line 233 - function buildFalseHead  -  Studio - CharacterService:233
  12:08:50.825  Script 'ServerScriptService.Server.Services.CharacterService', Line 521 - function buildCharacter  -  Studio - CharacterService:521
  12:08:50.825  Stack End  -  Studio

Seemingly when I aged, hair fixed as it regained color, but no clothes.

M2-A; I picked it, I refreshed it seems. Jamilah is feminie name, but my hair is gray and I didn't have any clothes. Same thing for when I was black male. M2-C; I reset, same look, as in no clothes gray hair, same face. When I aged, my hair color went to blonde. When I reset it  went back to the old height before I aged, and white hair. And when I aged, it restored again.
M2-D; Nothing changed when I used age to 13 beside the number in menu. When I birthday'd, my height went to what I would expect to have at 14. Same for the next birthdays. When I did 60, nothing changed. When I birthday'd my height stayed the same and hair was duller color and I saw a pulsating screen. When I aged 69, my hair turned nearly completely white and then pulsating began to slow and got a message saying I had to die. I was then teleported to the afterlife model and respawned to a new character. I think something error'd but I didn't catch the log.

M2-E; Perfectly fine. Worked.
  12:23:18.792  [AgeService] iiBry has a heart attack at age 62 (fatal=false, chance=0.07)  -  Server - Log:58

M2-F;
  12:24:10.041  [DevService] .state iiBry:
  name: iiBry
  userId: 27938432
  joinState: Ready
  age: 62
  magoi: 0
  rank: n/a
  goldRukh: 0
  blackRukh: 0
  epithet: n/a
  bounty: 0
  copper: 20
  silver: 0
  gold: 0
  walkSpeed: 16
  health: 53.47999954223633
  maxHealth: 53.47999954223633
  position: (1944.5, 198.0, -7667.7)
  saveScope: Studio
  freshSave: false
  timeScale: 1
  sessionSeconds: 932  -  Server - Log:58
  12:24:10.041  [DevService] [dev iiBry] .state -> State for iiBry sent  -  Server - Log:58

12:24:10.041  [DevService] [dev iiBry] .state -> State for iiBry sent  -  Server - Log:58
  12:24:18.840  [AgeService] iiBry has a heart attack at age 63 (fatal=false, chance=0.08)  -  Server - Log:58
  12:24:32.188  [DataService] New life for iiBry (life #3)  -  Server - Log:58
  12:24:32.189  [DevService] [dev iiBry] .heart fatal -> Heart attack fired for iiBry (fatal=true)  -  Server - Log:58
  12:24:48.972  ReplicatedFirst.Assets:125: attempt to index nil with 'Value'  -  Server - Assets:125
  12:24:48.972  Stack Begin  -  Studio
  12:24:48.972  Script 'ReplicatedFirst.Assets', Line 125  -  Studio - Assets:125
  12:24:48.972  Script 'ServerScriptService.Server.Services.CharacterService', Line 233 - function buildFalseHead  -  Studio - CharacterService:233
  12:24:48.972  Script 'ServerScriptService.Server.Services.CharacterService', Line 521 - function buildCharacter  -  Studio - CharacterService:521
  12:24:48.972  Stack End  -  Studio

Saw the afterlife, it is the one for my old game. But it is too fast, and I probably need to work on it personally since it is a feel thing versus just brute code.

M2-G; Age was 31. Here is the log.
  12:26:50.336  HeightHandler is not a valid member of Folder "ServerScriptService.Character"  -  Server - ClothingSpawn:5
  12:26:50.336  Stack Begin  -  Studio
  12:26:50.336  Script 'Workspace.Qarzin.ClothesStand.ClothingSpawn', Line 5  -  Studio - ClothingSpawn:5
  12:26:50.336  Stack End  -  Studio
  12:26:50.351  ReplicatedStorage.Shared.Data.Epithets:83: invalid argument #1 to 'freeze' (table is already frozen)  -  Server - Epithets:83
  12:26:50.351  Stack Begin  -  Studio
  12:26:50.351  Script 'ReplicatedStorage.Shared.Data.Epithets', Line 83  -  Studio - Epithets:83
  12:26:50.351  Stack End  -  Studio
  12:26:50.351  Requested module experienced an error while loading  -  Server - SelfTestService:18
  12:26:50.351  Stack Begin  -  Studio
  12:26:50.351  Script 'ServerScriptService.Server.Services.SelfTestService', Line 18  -  Studio - SelfTestService:18
  12:26:50.351  Stack End  -  Studio
  12:26:50.351  [Server.Main] require(SelfTestService) failed: Requested module experienced an error while loading  -  Server - Main:36
  12:26:50.524  [CreationController] ready  -  Client - Log:58
  12:26:50.525  [DevController] dev overlay (F8) and dev panel (backquote `) ready  -  Client - Log:58
  12:26:50.525  [HudController] ready  -  Client - Log:58
  12:26:50.526  [MenuController] ready (M to toggle)  -  Client - Log:58
  12:26:50.526  [RukhController] ready  -  Client - Log:58
  12:26:51.799  [ProfileStore]: Roblox API services available - data will be saved  -  Server - ProfileStore:2115
  12:27:01.192  [DataService] Loaded save for iiBry (scope Studio)  -  Server - Log:58
  12:27:01.196  Infinite yield possible on 'Workspace.iiBry:WaitForChild("AppearenceLoaded")'  -  Studio
  12:27:01.196  Stack Begin  -  Studio
  12:27:01.196  Script 'ServerScriptService.MISC.RegionHandlerPart2', Line 3  -  Studio - RegionHandlerPart2:3
  12:27:01.196  Stack End  -  Studio
  12:27:01.196  Infinite yield possible on 'Workspace.iiBry:WaitForChild("AppearenceLoaded")'  -  Studio
  12:27:01.196  Stack Begin  -  Studio
  12:27:01.196  Script 'ServerScriptService.Services.EffectsService', Line 159  -  Studio - EffectsService:159
  12:27:01.196  Stack End  -  Studio
  12:27:01.196  Infinite yield possible on 'Workspace.iiBry:WaitForChild("AppearenceLoaded")'  -  Studio
  12:27:01.196  Stack Begin  -  Studio
  12:27:01.196  Script 'ServerScriptService.Interactions.InteractionsDesign', Line 11  -  Studio - InteractionsDesign:11
  12:27:01.196  Stack End  -  Studio
  12:27:01.196  Infinite yield possible on 'Workspace.iiBry:WaitForChild("AppearenceLoaded")'  -  Studio
  12:27:01.196  Stack Begin  -  Studio
  12:27:01.196  Script 'Workspace.NPC.DUMMY.NPCFetch', Line 168  -  Studio - NPCFetch:168
  12:27:01.196  Stack End  -  Studio
  12:27:01.378  Infinite yield possible on 'Players.iiBry:WaitForChild("Stats")'  -  Studio
  12:27:01.378  Stack Begin  -  Studio
  12:27:01.378  Script 'ReplicatedFirst.GUI.UIGUI.MenuGUI.MasterFrame.MenuGUIFrame.MenuMechanics', Line 16  -  Studio - MenuMechanics:16
  12:27:01.378  Stack End  -  Studio
  12:27:01.378  Infinite yield possible on 'Workspace.iiBry:WaitForChild("AppearenceLoaded")'  -  Studio
  12:27:01.378  Stack Begin  -  Studio
  12:27:01.378  Script 'Workspace.iiBry.Animate', Line 4  -  Studio - Animate:4
  12:27:01.378  Stack End  -  Studio
  12:27:01.378  Infinite yield possible on 'Workspace.iiBry:WaitForChild("AppearenceLoaded")'  -  Studio
  12:27:01.378  Stack Begin  -  Studio
  12:27:01.378  Script 'Workspace.iiBry.Scripts.RegionHandlerPart1', Line 3  -  Studio - RegionHandlerPart1:3
  12:27:01.378  Stack End  -  Studio
  12:27:01.378  Infinite yield possible on 'Workspace.iiBry:WaitForChild("AppearenceLoaded")'  -  Studio
  12:27:01.378  Stack Begin  -  Studio
  12:27:01.378  Script 'Workspace.iiBry.Scripts.PhysicalHandler', Line 27  -  Studio - PhysicalHandler:27
  12:27:01.378  Stack End  -  Studio
  12:27:01.378  Infinite yield possible on 'Players.iiBry:WaitForChild("Stats")'  -  Studio
  12:27:01.378  Stack Begin  -  Studio
  12:27:01.378  Script 'Players.iiBry.PlayerGui.MenuGUI.MasterFrame.MenuGUIFrame.MenuMechanics', Line 16  -  Studio - MenuMechanics:16
  12:27:01.378  Stack End  -  Studio
  12:27:04.550  ReplicatedFirst.Assets:125: attempt to index nil with 'Value'  -  Server - Assets:125
  12:27:04.550  Stack Begin  -  Studio
  12:27:04.550  Script 'ReplicatedFirst.Assets', Line 125  -  Studio - Assets:125
  12:27:04.550  Script 'ServerScriptService.Server.Services.CharacterService', Line 233 - function buildFalseHead  -  Studio - CharacterService:233
  12:27:04.550  Script 'ServerScriptService.Server.Services.CharacterService', Line 521 - function buildCharacter  -  Studio - CharacterService:521
  12:27:04.550  Stack End  -  Studio

m2-h; in order to get it to work, i couldn't just do age. I had to birthday the character and then the correct health would show and it did increase with height. it also increased with magoi. good to go. block doesn't work so couldn't check with that. And health is much slower when tier is combat, versus idle.

m2-I; title works alongside rukh and magoi. character preview is still black. buttons still make noise, but idk if there are post to do anything else. title reset properly back to adventuerer.


Design notes; I don't like how the afterlife looks. Let me handle that portion, if you can just set it up where I put my own touch, I'll finish it off. Next, the heartbeat doesn't sound quite right. It needs to be BUMPBUMP... BUMPBUMP... Instead it is kind overlayed. I can also handle that if you want. There is obviously some problem with character loading at start. Aging seems to work just fine, and obviously no animations and no interactions can be done from what I can tell due to that error.

## M2 A life

Setup as before. New dev commands used here: `.birthday`, `.heart [fatal]`, `.hp <n>`, `.tier <Idle|Combat|Knocked>`, `.age <n>`, `.magoi <n>`, `.rukh <gold> <black>`, `.epithet <text>`, `.fresh`. Attributes on the Player (`Age`, `Rank`, `Epithet`, `Alignment`, `Health`, `MaxHealth`, `Block`, `Lives`, `Gender`) can be read with `inspect_instance` on `Players.<name>` instead of screenshots.

### M2-A Creation screen through the remote
- **Setup:** `.fresh`. The Gender screen appears (same look: brown background, gold boxes, M/F buttons, three skin boxes, ENTER greyed until both are picked).
- **Do:** pick Feminine and White skin, Enter.
- **Pass:** the screen closes, the character has the White skin and a female first name (`FirstName` attribute), `Gender` attribute = 2, no errors. Repeat with Masculine + Black: `Gender` = 1 and a male name.

### M2-B Server rejects bad creation calls
- **Setup:** after M2-A, with `execute_luau` on the client: `game.ReplicatedStorage.Net.CreateCharacter:FireServer(1, 1)` (Gender already set) and `FireServer(7, 1)`.
- **Pass:** nothing changes (`Gender`, `SkinTone` attributes unchanged); Output shows `[Remotes]` or `[Character]` warnings, no errors.

### M2-C Look unchanged after respawn
- **Setup:** reset the character (`LoadCharacter()` on the server).
- **Look (one screenshot):** same face, skin, hair colour, starter rags, hats as before the reset.
- **Pass:** identical look; `AppearenceLoaded` is true on the new character; no errors.

### M2-D Birthday, growth and grey hair
- **Setup:** `.age 13`, then `.birthday` five times. Then `.age 60`, `.birthday` once; then `.age 69`, `.birthday`.
- **Pass:** `Age` attribute increments; the character grows between 13 and 18 (height changes visible in `.state` `HeightStuds` or the menu); at 61 the hair is clearly greyer than at 18 (screenshot once at 70); no errors on any birthday.

### M2-E Heart attack, non-fatal
- **Setup:** `.heart`.
- **Pass:** a heartbeat sound and a red pulse for about a second, then it passes; the character can move; no message; no errors.

### M2-F Heart attack, fatal, and the return to the Rukh
- **Setup:** `.state` (note `Lives`), then `.heart fatal`.
- **Pass:** heavier beats, the screen darkens, the line "Your heart gave out." shows, then the scene: golden glowing character, frozen input, camera shot, walk into the Rukh core, white fade. Then a fresh spawn at Qarzin: age 13, 20 copper, new name, creation screen shown, `Lives` = old + 1. Camera back to normal, input works. No errors, no stuck camera. If `ReplicatedFirst.AfterLife` exists the scene uses it (say which version played).

### M2-G Offline aging
- **Setup:** `.age 30`, `.save`, Stop. On the server side with `execute_luau` before playing again nothing can be done, so instead: Play, then `.state` and read `Age`; compare to the expected `30 + 2 * (days since last save)`, which is 30 for a same-day rejoin.
- **Pass:** age unchanged on a same-day rejoin; Output shows the `[Age]` offline line with 0 years. (The 2-years-per-day rule is covered by the self-test.)

### M2-H Health from height and rank, regen tiers, block
- **Setup:** `.age 13` then `.state` (MaxHealth A); `.age 30` + `.birthday` (MaxHealth B, higher); `.magoi 1500` (rank Renowned) then `.state` (MaxHealth C, higher). `.hp 10`, `.tier Idle`, wait 5 s, `.state`; `.tier Combat`, `.hp 10`, wait 5 s, `.state`.
- **Pass:** A < B < C; Idle regen raised health by about 10 in 5 s; Combat regen left it at 10; the HUD health bar follows; the block bar refills within ~10 s after blocking (hold F if the old input still works, otherwise skip and say so).

### M2-I Menu shows the new fields
- **Setup:** `.magoi 700`, `.rukh 8 1`, `.epithet "The Dune Walker"`, press M.
- **Look (one screenshot):** the card shows the name, "THE DUNE WALKER" as the title, the stat line unclipped (`MIDLANDER ❖ THE 30TH YEAR SINCE BIRTH ❖ 5'9`), a second line `GOLD RUKH ❖ LIFE n`, and the character preview in the diamond (not black). Apparel button opens and closes the four frames with the sounds.
- **Pass:** all fields right, no clipping, preview visible, no errors. `.epithet ""` then M again: title falls back to the rank title ("ADVENTURER").

### M2-J Two players share one collision group
- **Setup:** Test → 2 players. Both join and finish creation.
- **Pass:** both can walk through clothing racks as before; Output shows the collision group created once; no errors for either player; the second player's creation screen works.

>  m2-a; .age 30 doesn't change the menu text, but yes i spawned in with clothes and age is working
  for the most part.

  12:57:04.345  AgeHandler is not a valid member of Folder "ServerScriptService.Character"  -  Server - ClothingSpawn:8
  12:57:04.345  Stack Begin  -  Studio
  12:57:04.345  Script 'Workspace.Qarzin.ClothesStand.ClothingSpawn', Line 8  -  Studio - ClothingSpawn:8
  12:57:04.345  Stack End  -  Studio
  12:57:04.395  [WARN] [DevService] SelfTestDev tried a dev command without permission  -  Server - Log:60
  12:57:04.396  [SelfTest] PASS (114 checks)  -  Server - Log:58
  12:57:04.564  [CreationController] ready  -  Client - Log:58
  12:57:04.565  [DevController] dev overlay (F8) and dev panel (backquote `) ready  -  Client - Log:58
  12:57:04.565  [HudController] ready  -  Client - Log:58
  12:57:04.566  [MenuController] ready (M to toggle)  -  Client - Log:58
  12:57:04.566  [RukhController] ready  -  Client - Log:58
  12:57:05.539  [ProfileStore]: Roblox API services available - data will be saved  -  Server - ProfileStore:2115
  12:57:15.063  [DataService] Loaded save for iiBry (scope Studio)  -  Server - Log:58
  12:57:15.068  Infinite yield possible on 'Workspace.iiBry:WaitForChild("AppearenceLoaded")'  -  Studio
  12:57:15.068  Stack Begin  -  Studio
  12:57:15.068  Script 'ServerScriptService.Services.EffectsService', Line 159  -  Studio - EffectsService:159
  12:57:15.068  Stack End  -  Studio
  12:57:15.068  Infinite yield possible on 'Workspace.iiBry:WaitForChild("AppearenceLoaded")'  -  Studio
  12:57:15.068  Stack Begin  -  Studio
  12:57:15.068  Script 'ServerScriptService.Interactions.InteractionsDesign', Line 11  -  Studio - InteractionsDesign:11
  12:57:15.068  Stack End  -  Studio
  12:57:15.068  Infinite yield possible on 'Workspace.iiBry:WaitForChild("AppearenceLoaded")'  -  Studio
  12:57:15.068  Stack Begin  -  Studio
  12:57:15.068  Script 'ServerScriptService.MISC.RegionHandlerPart2', Line 3  -  Studio - RegionHandlerPart2:3
  12:57:15.068  Stack End  -  Studio
  12:57:15.068  Infinite yield possible on 'Workspace.iiBry:WaitForChild("AppearenceLoaded")'  -  Studio
  12:57:15.068  Stack Begin  -  Studio
  12:57:15.068  Script 'Workspace.NPC.DUMMY.NPCFetch', Line 168  -  Studio - NPCFetch:168
  12:57:15.068  Stack End  -  Studio
  12:57:15.233  Infinite yield possible on 'Players.iiBry:WaitForChild("Stats")'  -  Studio
  12:57:15.233  Stack Begin  -  Studio
  12:57:15.233  Script 'ReplicatedFirst.GUI.UIGUI.MenuGUI.MasterFrame.MenuGUIFrame.MenuMechanics', Line 16  -  Studio - MenuMechanics:16
  12:57:15.233  Stack End  -  Studio
  12:57:15.233  Infinite yield possible on 'Workspace.iiBry:WaitForChild("AppearenceLoaded")'  -  Studio
  12:57:15.233  Stack Begin  -  Studio
  12:57:15.233  Script 'Workspace.iiBry.Animate', Line 4  -  Studio - Animate:4
  12:57:15.233  Stack End  -  Studio
  12:57:15.233  Infinite yield possible on 'Workspace.iiBry:WaitForChild("AppearenceLoaded")'  -  Studio
  12:57:15.233  Stack Begin  -  Studio
  12:57:15.233  Script 'Workspace.iiBry.Scripts.RegionHandlerPart1', Line 3  -  Studio - RegionHandlerPart1:3
  12:57:15.233  Stack End  -  Studio
  12:57:15.233  Infinite yield possible on 'Workspace.iiBry:WaitForChild("AppearenceLoaded")'  -  Studio
  12:57:15.233  Stack Begin  -  Studio
  12:57:15.233  Script 'Workspace.iiBry.Scripts.PhysicalHandler', Line 27  -  Studio - PhysicalHandler:27
  12:57:15.233  Stack End  -  Studio
  12:57:18.412  [WARN] [CharacterService] missing SFX/VFX asset CoinReward  -  Server - Log:60
  12:57:18.412  [WARN] [CharacterService] missing SFX/VFX asset BlockBroken  -  Server - Log:60
  12:57:18.412  [WARN] [CharacterService] missing SFX/VFX asset Parry  -  Server - Log:60
  12:57:18.412  [WARN] [CharacterService] missing SFX/VFX asset QuickDash  -  Server - Log:60
  12:57:18.412  [WARN] [CharacterService] missing SFX/VFX asset LightHitSound1  -  Server - Log:60
  12:57:18.412  [WARN] [CharacterService] missing SFX/VFX asset MissSound1  -  Server - Log:60
  12:57:18.412  [WARN] [CharacterService] missing SFX/VFX asset LightHitSound2  -  Server - Log:60
  12:57:18.412  [WARN] [CharacterService] missing SFX/VFX asset MissSound2  -  Server - Log:60
  12:57:18.412  [WARN] [CharacterService] missing SFX/VFX asset LightHitSound3  -  Server - Log:60
  12:57:18.412  [WARN] [CharacterService] missing SFX/VFX asset MissSound3  -  Server - Log:60
  12:57:18.412  [WARN] [CharacterService] missing SFX/VFX asset LightHitSoundFin  -  Server - Log:60
  12:57:18.412  [WARN] [CharacterService] missing SFX/VFX asset BlockSound1  -  Server - Log:60
  12:57:18.412  [WARN] [CharacterService] missing SFX/VFX asset BlockSound2  -  Server - Log:60
  12:57:18.412  [WARN] [CharacterService] missing SFX/VFX asset HitParticle  -  Server - Log:60
  12:57:18.412  [WARN] [CharacterService] missing SFX/VFX asset Cancel  -  Server - Log:60
  12:57:18.412  [WARN] [CharacterService] missing SFX/VFX asset BlockParticle  -  Server - Log:60
  12:57:18.412  [WARN] [CharacterService] missing SFX/VFX asset BlockBreakParticle  -  Server - Log:60
  12:57:18.412  [WARN] [CharacterService] missing SFX/VFX asset Confusion  -  Server - Log:60
  12:57:18.412  [WARN] [CharacterService] missing SFX/VFX asset Sparks1  -  Server - Log:60
  12:57:18.412  [WARN] [CharacterService] missing SFX/VFX asset Sparks2  -  Server - Log:60
  12:57:28.944  Infinite yield possible on 'Workspace.Characters.iiBry:WaitForChild("Cancel")'  -  Studio
  12:57:28.944  Stack Begin  -  Studio
  12:57:28.944  Script 'ServerScriptService.Interactions.InteractionsHandler', Line 320  -  Studio - InteractionsHandler:320
  12:57:28.944  Stack End  -  Studio
  12:57:30.045  [DevService] [dev iiBry] .age 30 -> iiBry's age: 23 -> 30  -  Server - Log:58
  12:57:30.795  Infinite yield possible on 'Workspace.Characters.iiBry:WaitForChild("Cancel")'  -  Studio
  12:57:30.795  Stack Begin  -  Studio
  12:57:30.795  Script 'ServerScriptService.Interactions.InteractionsHandler', Line 320  -  Studio - InteractionsHandler:320
  12:57:30.795  Stack End  -  Studio
  12:57:31.911  Infinite yield possible on 'Workspace.Characters.iiBry:WaitForChild("Cancel")'  -  Studio
  12:57:31.911  Stack Begin  -  Studio
  12:57:31.911  Script 'ServerScriptService.Interactions.InteractionsHandler', Line 320  -  Studio - InteractionsHandler:320

m2-c; resets are fine.
m2-d; was able to age and my heart instantly changed as it post to. though i will not that not heartbeat events play on .age only on birthday, which is lowkey fine since we don't want someone instantly dying when dev commands fire. in fact lets set that up that u can age / birthday without worry of the person dying, like lets make it toggleable.
m2-I; it does, but their facing away and its from the side. instead, could we possibly make it like camera, that mirrors the player? ive seen that before in a game. or if it is too hard to implement, we can forget about it as well.
m2-E/F; yeah ill tweak dand look into it later. don't let me forget, and make sure to completely disable character input in the afterlife sequence, there should freeze bind somewhjere in the scripts that can help but if you have ab etter method then use it.

(Bryan's full second-pass notes, given in chat 2026-09-27 13:40:)

m2-a; .age 30 doesn't change the menu text, but yes i spawned in with clothes and age is working for the most part.
Output at boot: `AgeHandler is not a valid member of Folder "ServerScriptService.Character" - ClothingSpawn:8`; `[SelfTest] PASS (114 checks)`; the usual "Infinite yield possible on AppearenceLoaded / Stats" 5 s warnings while the save loads (10 s in Studio); then 20x `[WARN] [CharacterService] missing SFX/VFX asset <CoinReward, BlockBroken, Parry, QuickDash, LightHitSound1-3, MissSound1-3, LightHitSoundFin, BlockSound1-2, HitParticle, Cancel, BlockParticle, BlockBreakParticle, Confusion, Sparks1-2>`; then repeated `Infinite yield possible on 'Workspace.Characters.iiBry:WaitForChild("Cancel")' - InteractionsHandler:320`; `.age 30 -> iiBry's age: 23 -> 30`.

m2-c; resets are fine.
m2-d; was able to age and my heart instantly changed as it post to. though i will not that not heartbeat events play on .age only on birthday, which is lowkey fine since we don't want someone instantly dying when dev commands fire. in fact lets set that up that u can age / birthday without worry of the person dying, like lets make it toggleable.
m2-I; it does, but their facing away and its from the side. instead, could we possibly make it like camera, that mirrors the player? ive seen that before in a game. or if it is too hard to implement, we can forget about it as well.
m2-E/F; yeah ill tweak dand look into it later. don't let me forget, and make sure to completely disable character input in the afterlife sequence, there should freeze bind somewhjere in the scripts that can help but if you have ab etter method then use it.

### M2 playtest 3, final check (Bryan, 2026-09-27 14:47)

Boot: `[SelfTest] PASS (120 checks)`, controllers ready, save loaded; only the usual 5 s "Infinite yield possible on AppearenceLoaded / Stats" warnings from old scripts while the Studio save loads (~10 s), and a `▶ {...}` print from the Studio-only ClothingSpawn:164. No red lines, no missing-asset warnings.
"Clothing stand is stocked. Age works perfectly. Mortal shows false. Mortal on kills. It isn't perfect, but it is good enough for now." Follow-ups Bryan keeps himself: docs/FOLLOWUPS.md (heartbeat sound, afterlife cutscene, viewport).

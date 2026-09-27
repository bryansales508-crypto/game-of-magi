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

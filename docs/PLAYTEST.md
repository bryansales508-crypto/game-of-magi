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
- **Pass:** Output shows `[Net]` warnings naming the player, the remote and the reason (throttled, not one per call), and no errors.

### M1-J Dev panel and overlay
- **Setup:** press F8, then the backquote key (`, left of 1).
- **Look (one screenshot):** the F8 overlay in the top-left lists the snapshot keys in order and updates once a second; the backquote panel in the top-right has the command box, reply log and quick buttons. `.timescale 10` then `.state` shows `timeScale = 10`. `.tp rathole` moves the character; `.cities` lists the spawns.
- **Pass:** both toggle cleanly, no input leaks into gameplay while typing, no errors.

### M1-K Leave and rejoin under load (two players)
- **Setup:** Test → Start with 2 players (local server). Both join, one leaves during the loading screen.
- **Pass:** no errors for the leaver, the other player reaches Ready, and the server logs the session end.

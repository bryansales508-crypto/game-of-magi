# Playtest scenarios

Repeatable checks, one block per milestone. Each scenario has an id, the steps (with dev-command setup) and what counts as a pass.

**Setup for every run:** Studio open on the published place, Rojo connected, then Play (F5). In Studio `Config.Debug.Enabled` is on, the save scope is `Studio`, and everyone is a dev. Dev commands start with `.` in chat or go in the backquote (`` ` ``) panel; `.cmd` lists them; F8 is the live status overlay. Read **Output** and the `.state` dump first; take a screenshot only where a scenario says "look".

---

## M1 Foundation

- **M1-A Server boots clean.** Play, wait 10 s. Output shows `[SelfTest] PASS`, and the `[Net]`, `[Data]`, `[Player]`, `[Dev]` startup lines. Pass: self-test PASS, no red errors from `Server/`, `Client/` or `Shared/`.
- **M1-B Join pipeline and spawn.** `.fresh` if not new, then watch the loading screen. It shows, fades once, and the character stands at the Qarzin spawn; `JoinState` goes `Loading`, `Loaded`, `Ready`. `.state` shows `joinState = Ready`. Reset the character (Esc, Reset): loading screen again, back at the spawn. Pass: both spawns at Qarzin, no kick, state ends at Ready.
- **M1-C Slow creation is not kicked.** `.fresh`, then wait 45 s on the creation screen before choosing. Pass: no kick, creation finishes, `joinState = Ready`.
- **M1-D Save persists.** `.age 40`, `.coins 123 4 5`, `.magoi 250`, `.rukh 3 1`, `.bounty 7`, `.epithet "The Sand-Born"`, `.state`, Stop, Play, `.state`. Pass: every value matches (needs `FreshSave = false`).
- **M1-E Fresh save switch.** Set `Config.Debug.FreshSave = true`, Play, `.age 40`, Stop, Play. Pass: age is 13 again. Set it back to false.
- **M1-F Wipe.** `.age 40`, `.coins 999`, `.fresh`. Pass: age 13, 20 Copper, a new random name, menu (M) shows the new name and age, purse GUI shows 20 too.
- **M1-G Dev permission is server-side.** `.state` logs under `[Dev]` with the caller. Set `Debug.Enabled = false`, Play, `.age 40`. Pass: nothing changes and Output shows one `[Dev]` warning. Turn Debug back on.
- **M1-H Remote validation and rate limit.** In the command bar while playing: `local r = game.ReplicatedStorage.Net.DebugPing; r:FireServer(string.rep("x", 200)); r:FireServer(5); for i = 1, 20 do r:FireServer("hi") end`. Pass: `[Remotes]` warnings name the player, remote and reason (throttled), no errors.
- **M1-I Dev panel and overlay.** F8 overlay (top-left, updates each second) and backquote panel (top-right, command box and reply log). `.timescale 10` then `.state` shows `timeScale = 10`; `.tp qarzin` moves you; `.cities` lists spawns. Pass: both toggle cleanly, no input leaks into gameplay while typing.
- **M1-J Leave under load (two players).** Test, Start with 2 players; one leaves during the loading screen. Pass: no errors for the leaver, the other reaches Ready, the server logs the session end.

## M2 A life

New dev commands: `.birthday`, `.heart [fatal]`, `.hp`, `.tier`, `.age`, `.magoi`, `.rukh`, `.epithet`, `.fresh`. Player attributes (`Age`, `Rank`, `Epithet`, `Alignment`, `Health`, `MaxHealth`, `Block`, `Lives`, `Gender`) can be read with `inspect_instance` on `Players.<name>`.

- **M2-A Creation through the remote.** `.fresh`. The Gender screen appears (brown background, gold boxes, M/F buttons, three skin boxes, ENTER greyed until both picked). Pick Feminine and White, Enter. Pass: screen closes, White skin, a female first name, `Gender` = 2, no errors. Repeat with Masculine and Black: `Gender` = 1, male name.
- **M2-B Server rejects bad creation calls.** After M2-A, on the client: `Net.CreateCharacter:FireServer(1, 1)` and `FireServer(7, 1)`. Pass: nothing changes; `[Remotes]` or `[Character]` warnings, no errors.
- **M2-C Look unchanged after respawn.** Reset the character. Pass: same face, skin, hair, rags and hats; `AppearenceLoaded` true; no errors.
- **M2-D Birthday, growth and grey hair.** `.age 13`, `.birthday` five times, then `.age 60`, `.birthday`, then `.age 69`, `.birthday`. Pass: `Age` rises; the character grows 13 to 18; hair is clearly greyer at 70; the menu age line follows `.age`; no errors.
- **M2-E Heart attack, non-fatal.** `.heart`. Pass: lub-dub heartbeat and red pulse for a couple of seconds, then it passes; you can move; no message.
- **M2-F Heart attack, fatal, return to the Rukh.** Note `Lives` in `.state`, then `.heart fatal`. Pass: slower heavier beats, screen darkens, "Your heart gave out.", then the scene (golden body, frozen input, camera shot, walk into the core, white fade), then a fresh spawn at Qarzin: age 13, 20 Copper, new name, creation screen, `Lives` plus one. Camera and input back to normal.
- **M2-G Offline aging.** `.age 30`, `.save`, Stop, Play, `.state`. Pass: age still 30 on a same-day rejoin; the `[Age]` offline line says 0 years.
- **M2-H Health from height and rank, regen, block.** `.age 13`, `.state` (MaxHealth A); `.age 30`, `.birthday` (B); `.magoi 1500` (C). `.hp 10`, `.tier Idle`, wait 5 s; `.tier Combat`, `.hp 10`, wait 5 s. Pass: A < B < C; Idle regen raises health about 10 in 5 s, Combat leaves it at 10; the HUD bar follows.
- **M2-I Menu fields.** `.magoi 700`, `.rukh 8 1`, `.epithet "The Dune Walker"`, press M. Pass: title "THE DUNE WALKER", unclipped stat line, a second line `GOLD RUKH, LIFE n`, a mirror preview of the character in the diamond (not black); apparel button opens and closes the frames with sounds. `.epithet ""` then M: title falls back to the rank ("ADVENTURER").
- **M2-J Two players share one collision group (two players).** Both finish creation. Pass: both walk through clothing racks; the collision group is created once; no errors.

## M3 Combat (SHELVED: kept for the redesign; do not run until combat is rebuilt)

Dev: `.combat log on|off`, `.knock`, `.stun <s>`, `.npc list|reset|type`, `.hp`, `.tier`.

- **M3-A Fist combo, one click per hit.** `C` into the stance, `.combat log on`. Click at a dummy: jab lands and you freeze on the punch; click again: the cross lands; the next click loops to the jab. Pass: Output shows `AttackHit(1) accepted`, `continues into hit 2`, `AttackHit(2) accepted`. No click for a second: `combo dropped`. Mash after hit 1: hit 2 comes once after the gap. Right-click mid-chain: cancel highlight flashes.
- **M3-B Block, parry, block break.** Hold F against a Target dummy: no damage, block sound. Tap F as a punch lands: parry effect. Keep blocking: the bar drains, breaks, TrueStun, refills. Pass: immune while the block holds.
- **M3-C Dash and run.** Q right after spawning, Q with W+D held, Q again at once (rejected). Double-tap W to run (camera zooms). Pass: `.state` walkSpeed 16 walking and 28 running; a hurt runner is slower, not faster; the dash shortens at low health.
- **M3-D Knockout and getting up.** `.hp 5`, let a dummy hit you; also `.knock` on a dummy. Pass: ragdoll (players and NPCs), blind screen, no input, get up after about 8 s with a quarter health; no death, no stuck camera.
- **M3-E Dummies.** Walk near a Target: it chases within 30 studs, punches within reach, gives up past 40, wanders, returns. Knocked out, it gets up. A Dummy only flinches. Pass: all of it.
- **M3-F Low health slow.** `.hp 10` slows you at once; `.hp 100` restores. Pass: both.
- **M3-G Remote abuse (agent, client command bar).** Spam `Net.AttackStart:FireServer()` 30 times; fire `Net.Dash:FireServer(1e9, 0)`, `(0/0, 1)`, `Net.Block:FireServer(5)`; move 200 studs from a dummy and attack; fire `Dash(0,1)` 10 times in 1 s. Pass: rate-limited or dropped with `[Remotes]` warnings, no hit at range, one dash per cooldown.

## M3B Stance, unlock, trainers, lives (SHELVED except M3B-K)

Dev: `.weapon Fist|Dagger`, `.unlock combat`, `.lock combat`, `.dummy spawn <Key>`, `.dummy clear`, `.dummy list`, `.style`.

- **M3B-A Stance and unlock.** Click without `C`: nothing. `C`: stance idle, clicks swing; `C` again: off. `.lock combat`, `C`: "You don't know how to fight yet."; `.unlock combat` restores. Pass: all four.
- **M3B-B Weapon click.** `.weapon Dagger` (dagger in hand), leave the stance, click. Pass: one click enters the stance and throws the first stab; `.weapon Fist` removes the dagger.
- **M3B-C Straight Sam.** Hold F: his hits are blocked, your meter drains and breaks. Time F just before his first hit: parry, he stuns long enough for your chain.
- **M3B-D Turtle Tariq.** Keep chains going: his block drains and breaks, then your chain lands.
- **M3B-E Jabbing Jamal.** Start a swing: he jabs a beat later and interrupts you. Cancel into F as his jab comes: parry and punish.
- **M3B-F Parry Pete.** A straight hit 1 is parried and stuns you; cancel, wait a beat, then throw: it lands.
- **M3B-G Feinting Mohammed.** Block when his second hit would come (he cancels it); with `.weapon Dagger` a feint stab blocked by Tariq costs you 0.5 s of Recovery.
- **M3B-H Dashing Dalila.** Start a swing: she dashes away; chase and land a hit once her dash is on cooldown.
- **M3B-I Sparring Sinbad.** Fight two minutes. Pass: no errors, `Attacking` never sticks after a swing, knockback on the 6th hit taken, bleed with the dagger.
- **M3B-J Cleanup.** `.dummy clear` removes all, `.dummy list` shows none; a knocked-out dummy gets up at full health; `.knock` on a trainer ragdolls it.
- **M3B-K Lives (runnable now).** `.state` shows `livesLeft: 4`. `.kill`: same character respawns after about 3 s with 3 left, no scene. `.lives 1`, `.kill`: the Rukh scene plays with no heartbeat and the last-life white fade, then a brand-new character with 4 lives, `lives` up by one, combat still unlocked. `.lives 4`, `.age 70`, `.mortal on`, `.heart fatal`: wipes regardless. `.hp 5` knocked out on a dummy: `livesLeft` unchanged.

## M4 Status and Rukh

Dev: `.magoi`, `.magoi+`, `.rukh <gold> <black>`, `.rankup`, `.epithet clear`, `.state`.

- **M4-A Origin at birth.** `.fresh`, finish creation. Pass: white Rukh flutter, a card offering 3 Street Rat epithets; click one or press 1/2/3; the card fades; M shows that title.
- **M4-B Rank-up.** `.magoi 300`. Pass: flutter in your alignment colour, card "A NEW RANK: WANDERER" with 3 epithets; choosing sets the menu title; `.rankup` repeats it for the next rank.
- **M4-C Pending choice survives rejoin.** `.rankup`, do not choose, Stop, Play. Pass: the card returns with the same 3 choices.
- **M4-D Alignment change.** `.rukh 8 1`, `.rukh 1 8`, `.rukh 5 5`. Pass: gold, black, then both flutters; the menu alignment line updates; no card.
- **M4-E Rank down and clear.** `.magoi 0`: Street Rat, no card. `.epithet clear`, `.rankup`: a fresh choice appears.
- **M4-F Remote abuse (agent).** With nothing pending `Net.ChooseEpithet:FireServer(2)` is rejected; with one pending `FireServer(7)` and `FireServer("The Cheat")` are dropped; `FireServer(1)` then `(2)` counts only the first. Pass: `[Rank]` log confirms.

## M5A Currency

Dev: `.coins`, `.coins+`, `.price`, `.pay`, `.state`.

- **M5A-A Rounding table.** `.price 40` "40 Copper", `100` "100 Copper", `101` "1 Silver", `150` "1 Silver", `200` "1 Silver", `201` "2 Silver", `5000` "49 Silver", `10000` "99 Silver", `10001` "1 Gold", `20001` "2 Gold". Pass: every line, never a decimal.
- **M5A-B Exact coin, no change.** `.coins 120 0 0`, `.pay Silver 1`: refused with the "exchange" line, purse unchanged. `.coins 120 1 0`, `.pay Silver 1`: paid. `.pay Copper 40`: 80 left. Pass: purse GUI updates live.
- **M5A-C Rewards stay Copper.** `.coins 0 0 0`, `.coins+ 130`. Pass: Copper rises, Silver stays 0.
- **M5A-D Rejoin.** Set coins, Stop, Play. Pass: same purse, `.state` matches the GUI.
- **M5A-E Coin sound and `.fresh`.** `.coins+ 10` and `.pay Copper 5` each play the coin sound; joining or respawning does not. `.fresh` empties the purse GUI too.

## M5B Clothing shop

Setup: `.coins 500 5 0`, walk to the Qarzin clothes stand.

- **M5B-A Stock and hover.** Hat table, nine mannequins and cloak stands are stocked about 5 s after start, no duplicates, prices whole-coin. Hover each rack: it highlights and shows its E prompt (only the hovered rack). An empty rack does not highlight. Pass: looks like before.
- **M5B-B Buying.** Buy a hat, a shirt (replaces the old one) and a cloak. Pass: item goes on, purse drops by the shown coin, coin sound plays, `.state` and a rejoin keep them.
- **M5B-C Refusals before charging.** No Silver, try a Silver item: refused with the line, purse unchanged. Wear three hats, try a fourth: refused. Same shirt and colour you wear: refused; a different colour: allowed.
- **M5B-D Hover only for you (two players).** The other client does not see your highlight.

## M5C Delivery missions

Dev: `.mission start <city>|finish|fail|streak <n>|mark [n]|intercept`, `.state`, `.tp <city>`, `.dummy spawn StraightSam`.

- **M5C-A The board.** At the Qarzin delivery part press E: the route's cities appear in their colours with modifier chips in their own row; click a city for its lore and pay preview; one description card at a time; Start then points the tracker at the last city clicked. Walk 20 studs away: the board closes.
- **M5C-B A full run.** Start a run: package on your back, tracker at the real drop-off (not the world origin, steady while running), beacon pulses every 45 s. Reach the drop-off: paid in Copper with the coin sound, about 10 Magoi, a Gold Rukh flutter, streak plus one, package gone. Unbuilt cities show a magenta placeholder drop-off. Pass: `.state` confirms; a rejoin keeps the streak.
- **M5C-C Interception pays the ambusher.** Two clients, or `.dummy spawn StraightSam` and let him knock you out mid-run (100 studs or 30 s in). The courier's run fails, pays nothing; the attacker is paid once, gets 1 Black Rukh and bounty and hears the coin sound.
- **M5C-D Each modifier once.** Time Crunch (expiry drops only its bonus, pop-out says "Failed."), Courier Loop (return point), Highly Valuable (the package glows the whole run, not the courier), Heavy Cargo (bigger pack, slower walk, run and dash; restored on any end), Very Important Noble, Fragile Package, Clear the Route. Pass: each behaves and cleans up.
- **M5C-E Bad city.** `.mission start NotACity` is refused; the board offers only route cities.
- **M5C-F Nothing left behind.** Open and close the board ten times, start and fail three runs, `.state`. Pass: no duplicate trackers, no per-frame Output spam.
- **M5C-G The intercepted mark.** Get intercepted once (`.mission intercept`): the board shows "Merchants doubt you" and offers halve; twice: a quarter; never below a tenth. The interceptor of a marked courier gets the reduced pay and no Black Rukh. One completed delivery pays the reduced amount and clears the mark; `.mission mark 0` clears it by hand.

## M6 World

- **M6-A Regions and music.** Walk into Qarzin: the "Q A R Z I N" banner bounces in and out after 5 s; a Qarzin track fades in over 1 s; walking out fades it. Walking in again picks a different track. `.region` lists your regions; `.music next`, `.music stop`, `.music play`, `.music volume 0.3` work from chat. The bottom-left music panel shows the track name, a play/stop button and a volume slider (above the thumbstick on touch). Death and respawn in Qarzin leave no doubled tracks.
- **M6-B Day and night.** `.time` prints the hour; `.time 17.5` brings dusk within a minute for everyone (same hour on a second client); `.time 22` is dark but readable; `.time 5.5` is dawn. With `CityLight` tags placed: lamps light at `.time 18` over 2 s and go out at `.time 6` (Neon goes matte); a tagged torch model switches as one. `.lights on|off|auto` forces it. `.time pause`, `.time speed 10` (a day in about 1.6 min), `.time speed 1`.
- **M6-C Footsteps.** Walk on stone, dirt, sand and carpet: the sound changes with the floor; running is louder and its steps match the run animation (left and right apart); no default Roblox footstep underneath. Sand and mud leave a print that fades in under a second. A dash plays the whoosh. Nobody else hears your steps louder than before.
- **M6-D Ocean.** With `Config.World.Ocean.Enabled = true`: tiles rise 2 studs over 15 s, hold 3 s, fall 15 s; decals breathe over 10 s with a 10 s pause; frame rate at the shore is steady; far tiles stay still. With it false the ocean is still.
- **M6-E Collisions.** You pass through a clothes rack but not a building. Output at server start has one `CollisionService` line with counts and no errors; the self-test passes. No `Stats`, `OnCharacter` or `Loaded` under your Player.

## M7 close-out spot checks

- **M7-A Overhead display.** No name or health bar appears over any player, including when you hit someone.
- **M7-B Package and cargo.** Highly Valuable glows on the package for the whole run; Heavy Cargo draws the pack bigger and shortens walk, run and dash.
- **M7-C Last life.** `.lives 1`, `.kill`: the whole Rukh scene plays to the white fade without the engine respawning you early.
- **M7-D Dash.** A dash in the desert on a slope never flings you (BUG-58 repro: note the place and slope if it does).

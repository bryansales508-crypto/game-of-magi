# Playtest scenarios

Repeatable checks, one block per milestone. Each scenario gives its id, the steps (with dev commands), and the pass condition. Read **Output** and the `.state` dump first; take a screenshot only where a scenario says "look".

**Setup for every run:** Studio open on the published place, Rojo connected, then Play (F5). In Studio `Config.Debug.Enabled` is on, the save scope is `Studio`, and everyone counts as a dev. Dev commands start with `.` in chat or the backquote dev panel; `.cmd` lists them. Report each scenario as PASS / FAIL / BLOCKED with the Output lines that matter.

## M1 Foundation

### M1-A Server boots clean
- Play, wait 10 s. Look in Output for the `[SelfTest]` line and the `[Net]`, `[Data]`, `[Player]`, `[Dev]` startup lines.
- **Pass:** self-test PASS, no errors from `Server/`, `Client/` or `Shared/`, no raw `print` lines.

### M1-B Join pipeline and spawn
- Play as a fresh character (`.fresh` first if needed). The loading screen shows and fades once. `.state` shows `joinState = Ready`. Reset the character (Esc, Reset): the loading screen shows again.
- **Pass:** both spawns land at the Qarzin spawn, join states go Loading, Loaded, Ready, no kick, no errors.

### M1-C Slow character creation is not kicked
- `.fresh`, then wait 45 s on the gender and skin screen before choosing.
- **Pass:** no kick, creation finishes, `joinState = Ready`.

### M1-D Save persists across rejoin
- `.age 40`, `.coins 123 4 5`, `.magoi 250`, `.rukh 3 1`, `.bounty 7`, `.epithet "The Sand-Born"`, `.state`. Stop, Play, `.state`. (Needs `Config.Debug.FreshSave = false`.)
- **Pass:** every value matches.

### M1-F Wipe command
- `.age 40`, `.coins 999`, then `.fresh`.
- **Pass:** `.state` shows age 13, 20 Copper and a new first name; the coin purse HUD shows 20 Copper straight away; the menu (M) shows the new name and age; no errors.

### M1-G Menu, purse and shop agree
- Open the menu (M). `.coins+ 500`, buy something at the Qarzin clothes stand, `.coins+ 10`.
- **Pass:** the menu shows name, age and height; the purse ticks up with the coin sound; the bought item is worn and survives Stop/Play.

### M1-H Dev permission is checked on the server
- Run `.state` and confirm a `[Dev]` log line with your name. Then set `Config.Debug.Enabled = false`, Play, run `.age 40`. Turn Debug back on.
- **Pass:** with Debug off nothing changes and Output shows one `[Dev]` warning for the rejected caller.

### M1-I Remote validation and rate limit
- In the client command bar:
  ```lua
  local r = game.ReplicatedStorage.Net.DebugPing
  r:FireServer(string.rep("x", 200))            -- too long
  r:FireServer(5)                                -- wrong type
  for i = 1, 20 do r:FireServer("hi") end        -- over the rate limit
  ```
- **Pass:** `[Remotes]` warnings naming the player, remote and reason (throttled, not one per call); no errors.

### M1-J Dev panel and overlay
- Press F8, then the backquote key. `.timescale 10` then `.state`; `.tp qarzin`; `.cities`.
- **Pass:** the F8 overlay (top-left) updates once a second; the panel (top-right) has the command box and reply log; `timeScale = 10`; `.tp` moves the character; no input leaks into gameplay while typing.

## M2 A life

Read Player attributes (`Age`, `Rank`, `Epithet`, `Alignment`, `Health`, `MaxHealth`, `Block`, `Lives`, `Gender`) from `Players.<name>` instead of screenshots.

### M2-A Creation screen through the remote
- `.fresh`. Pick Feminine and White skin, Enter. Repeat with Masculine and Black.
- **Pass:** the screen closes; the skin matches; `Gender` is 2 then 1 with a female then male `FirstName`; no errors.

### M2-B Server rejects bad creation calls
- After M2-A, from the client run `Net.CreateCharacter:FireServer(1, 1)` (Gender already set) and `FireServer(7, 1)`.
- **Pass:** `Gender` and `SkinTone` unchanged; `[Remotes]` or `[Character]` warnings, no errors.

### M2-C Look unchanged after respawn
- Reset the character. Look once.
- **Pass:** same face, skin, hair and clothes; `AppearenceLoaded` true; no errors.

### M2-D Birthday, growth and grey hair
- `.age 13`, `.birthday` five times; `.age 60`, `.birthday`; `.age 69`, `.birthday`.
- **Pass:** `Age` increments; height grows between 13 and 18; hair is clearly greyer at 70 than at 18; no errors.

### M2-E Heart attack, non-fatal
- `.heart`.
- **Pass:** heartbeat sound and a red pulse for about a second, you can still move, no errors.

### M2-F Heart attack, fatal, and the return to the Rukh
- `.state` (note `Lives`), then `.heart fatal`.
- **Pass:** heavier beats, the screen darkens, "Your heart gave out." shows, then the golden glowing walk into the Rukh core and a white fade. A fresh spawn follows: age 13, 20 Copper, new name, creation screen, `Lives` up by one, camera and input back to normal.

### M2-G Offline aging
- `.age 30`, `.save`, Stop, Play, `.state`.
- **Pass:** age is still 30 on a same-day rejoin and Output shows the `[Age]` offline line with 0 years.

### M2-H Health from height and rank, regen tiers, block
- `.age 13`, `.state` (A); `.age 30`, `.birthday`, `.state` (B); `.magoi 1500`, `.state` (C). Then `.hp 10`, `.tier Idle`, wait 5 s, `.state`; `.tier Combat`, `.hp 10`, wait 5 s, `.state`.
- **Pass:** MaxHealth A < B < C; Idle regen adds about 10 in 5 s; Combat adds none; the HUD health bar follows; there is no health bar over any head.

### M2-I Menu shows the new fields
- `.magoi 700`, `.rukh 8 1`, `.epithet "The Dune Walker"`, press M. Then `.epithet clear`, press M.
- **Pass:** "THE DUNE WALKER" as the title, the stat line unclipped, a `GOLD RUKH` and `LIFE n` line, the character preview visible (not black), the Apparel button opens and closes its frames; after clearing, the title is the rank title.

### M2-J Two players share one collision group
- Test, 2 players, both finish creation.
- **Pass:** both walk through clothing racks; the collision group is created once; no errors.

### M2-K Lives
- `.state` shows `livesLeft: 4`. `.kill`: same character, `livesLeft: 3`, no scene. `.lives 1`, `.kill`: the afterlife scene (no heartbeat), then a brand-new character with `livesLeft: 4` and the incarnation count up one. `.lives 4`, `.age 70`, `.mortal on`, `.heart fatal`: wipe regardless of lives. `.hp 5` and a knockout leave `livesLeft` unchanged.
- **Pass:** every line, no errors.

## M4 Status and Rukh

### M4-A Origin at birth
- `.fresh`, finish creation.
- **Pass:** a white Rukh flutter; a card offers 3 Street Rat epithets; clicking one (or 1/2/3) fades the card and the menu (M) shows that title.

### M4-B Rank-up
- `.magoi 300`.
- **Pass:** flutter in your alignment colour; card "A NEW RANK: WANDERER" with 3 epithets; choosing sets the menu title; `.state` shows Wanderer. `.rankup` repeats it for the next rank.

### M4-C Pending choice survives a rejoin
- `.rankup`, do not choose, Stop, Play.
- **Pass:** the card returns with the same 3 choices and choosing works.

### M4-D Alignment change
- `.rukh 8 1`, then `.rukh 1 8`, then `.rukh 5 5`.
- **Pass:** a gold, then black, then gold-and-black flutter; the menu alignment line updates each time; no card.

### M4-E Rank down and clear
- `.magoi 0`, then `.epithet clear` and `.rankup`.
- **Pass:** rank returns to Street Rat with no card; the second step offers a fresh choice; no errors.

### M4-F Remote abuse
- With nothing pending: `Net.ChooseEpithet:FireServer(2)`. With a choice pending: `FireServer(7)`, `FireServer("The Cheat")`, then `FireServer(1)` and `FireServer(2)`.
- **Pass:** the first is rejected, bad values dropped with `[Remotes]` warnings, only the first valid pick counts.

## M5A Currency

### M5A-A Rounding table
- `.price` with 40, 100, 101, 150, 200, 201, 5000, 10000, 10001, 20001.
- **Pass:** 40 Copper, 100 Copper, 1 Silver, 1 Silver, 1 Silver, 2 Silver, 49 Silver, 99 Silver, 1 Gold, 2 Gold; never a decimal.

### M5A-B Exact coin, no change
- `.coins 120 0 0`, `.pay Silver 1` (refused, purse unchanged, the "exchange at the bank" line). `.coins 120 1 0`, `.pay Silver 1` (paid). `.pay Copper 40`.
- **Pass:** all three; the purse HUD updates live.

### M5A-C Rewards stay Copper
- `.coins 0 0 0`, then `.coins+ 130`.
- **Pass:** Copper rises, Silver stays 0.

### M5A-D Coin sound
- `.coins+ 10`, then `.pay Copper 5`; also join and respawn.
- **Pass:** the coin sound plays on each change and not on join or respawn.

### M5A-E Rejoin
- Set coins, Stop, Play.
- **Pass:** same purse; `.state` matches the HUD.

## M5B Clothing shop

Setup: `.coins 500 5 0`, walk to the Qarzin clothes stand.

### M5B-A Stock and look
- Look at the hat table, mannequins and cloak stands about five seconds after the server starts.
- **Pass:** stocked once (no duplicates); colours White, Tan or Black; prompts show whole-coin prices.

### M5B-B Buying
- Buy a hat, a shirt (replaces the old one) and a cloak with E.
- **Pass:** each goes on, the purse drops by the shown coin, the coin sound plays, items survive Stop/Play.

### M5B-C Refusals before charging
- With Silver 0 try a Silver-priced item; wear three hats and try a fourth; try the exact shirt and colour you wear, then another colour of it.
- **Pass:** every refusal charges nothing; the different colour is allowed.

### M5B-D Hover and prompts
- Hover each rack, hat and cloak; stand in reach of an empty rack.
- **Pass:** only the hovered item highlights and shows its prompt; empty racks show neither; a second client does not see your highlight.

## M5C Delivery missions

Dev commands: `.mission start <city>`, `finish`, `fail`, `streak <n>`, `mark [n]`, `intercept`, `log on|off`.

### M5C-A The board
- Walk to the Qarzin delivery part, press E. Click cities (lore and pay preview show), open the modifier pop-outs, click another city, then Start. Walk 20 studs away.
- **Pass:** the tracker points at the last city clicked and at that city's real drop-off; the board closes when you walk away; no errors.

### M5C-B A full run
- Start a run, watch for 2 minutes, then reach the destination.
- **Pass:** the package straps on, the tracker and modifier line show, the beacon highlight (through walls) pulses for about 3 s every 45 s and fades in and out; arriving pays Copper with the coin sound, about 10 Magoi, 1 Gold Rukh, streak +1, and the package is gone; a rejoin keeps the streak.

### M5C-C Interception pays the ambusher
- With a second client (or `.mission intercept`), knock the courier out mid-route.
- **Pass:** the courier's run fails and pays nothing; the attacker is paid the run's reward, gets 1 Black Rukh and a bounty; total coins never exceed one reward. (Knockouts need combat, so this runs through `.mission intercept` while combat is shelved.)

### M5C-D Each modifier once
- Start runs until you see: Time Crunch (expiry only drops its bonus, run continues), Courier Loop (a return point), Highly Valuable (the package glows the whole run, courier gets the ordinary beacon), Heavy Cargo (slower and shorter dash; restored on every end), VIP, Fragile Package, Clear the Route.
- **Pass:** each behaves and cleans up; no red lines.

### M5C-E Bad city and placeholders
- `.mission start NotACity`; then start a run to each city that has no `<Key>Delivery` part.
- **Pass:** the unknown city is refused; a city without a drop-off part uses its region part or placeholder point and the tracker points there; a city with neither refuses and logs it.

### M5C-G The intercepted mark
- Get intercepted once (`.mission intercept`): the board shows the "merchants doubt you" line and offers halve; `.mission mark` shows 1 stack. Again: a quarter; it never drops below a tenth. Complete one delivery while marked; `.mission mark 0` clears it by hand.
- **Pass:** a marked delivery pays the reduced amount and then clears the mark; the interceptor of a marked courier gets the reduced pay and no Black Rukh.

### M5C-H Dash with cargo and low health
- Start a Heavy Cargo run, dash, then `.hp 10` and dash again, on flat open ground.
- **Pass:** the loaded dash is shorter than an unloaded one; the low-health dash is shorter again; full health restores both.

## M6 World

### M6-A Regions and music
- Walk into Qarzin. `.region` lists where you are; `.music` shows the track; `.music next`, `.music stop`, `.music play`, `.music volume 0.3`, `.music <track name>`. Open the music panel.
- **Pass:** the "Q A R Z I N / The Merchant's Playground" banner bounces in and out; a Qarzin track fades in over 1 s at the same volume each time; leaving fades out; entering again picks a different track; the panel's controls match the commands; the ocean ambient plays at the shore; a respawn inside Qarzin does not double the music.

### M6-B Day and night
- `.time` prints the hour; `.time 17.5`, `.time 22`, `.time 5.5`. Tag the Qarzin bulbs `CityLight`; `.time 18`, `.time 6`. `.lights on|off|auto`. `.time pause`, `.time speed 10`, `.time speed 1`.
- **Pass:** dusk, a readable night and dawn blend over about a minute for everyone in the server; tagged lights fade on over 2 s at night and off with the Neon turning matte by day; a torch model switches flame and light together; pause freezes; a rejoin keeps the server's clock.

### M6-C Footsteps
- Walk and run on stone, dirt, sand and carpet.
- **Pass:** the step sound follows the floor and is louder when running; steps follow the run animation's rhythm; sand and mud leave prints that fade; others do not hear your steps louder; the default Roblox running sound is gone; no server Output per step.

### M6-D Ocean
- With `Config.World.Ocean.Enabled = false`, check the ocean is untouched. After deleting the `Workspace.MAP.OCEAN` scripts and enabling it, watch the shore.
- **Pass:** tiles rise 2 studs over 15 s, hold, and fall; decals breathe on a 10 s cycle; frame rate is steady; far tiles stay still.

### M6-E Collisions and the bridge
- Walk into a clothes rack and into a building.
- **Pass:** you pass through the rack, not the building; the Explorer shows no `Stats`, `OnCharacter` or `Loaded` under your Player; one CollisionService line at start; the self-tests pass.

## M9 Bounty, carry, jail

Dev commands: `.bounty <n> [player]`, `.bounty list|take <player>|drop|clear`, `.rank`/`.magoi` to reach Adventurer, `.knock`, `.jail <s> [player]`, `.jail release`, `.carry drop`. Two players needed (hunter and target).

- **M9-A Board:** `.bounty 30` on the target. **Pass:** a poster with their name, bounty and city appears on the Qarzin board within a few seconds; `.bounty clear` removes it.
- **M9-B Rank gate:** hunter below Adventurer holds the poster prompt. **Pass:** refused with a chat line; no Tool; at Adventurer the same prompt works.
- **M9-C Take and track:** take the poster, equip the `Bounty: <name>` Tool (hotbar). **Pass:** a tracker with the target's name and distance sits at the spot they stood when taken; unequipping removes it at once; walking to the spot moves it to where they are now.
- **M9-D Reveal and lose:** close within about 80 studs of the target. **Pass:** the tracker disappears and the target glows red (only on the hunter's screen); run away for 6+ seconds and the glow goes and the tracker returns at the last place they were seen.
- **M9-E Pick up:** `.knock` the target, stand next to them. **Pass:** a "Pick up" (E) prompt shows on them only while knocked and in reach (not on yourself, not while you are knocked or already carrying); pressing it puts them on your shoulder; you walk slowly and cannot run, dash or attack; the target sees a dim screen and "You are being carried by <name>"; "Drop" (E) puts them down.
- **M9-F Deliver:** carry the wanted target to the jail drop-off. **Pass:** the drop-off glows and "Deliver" (E) replaces "Drop" inside its reach; it does nothing (and shows a chat refusal) without the poster or the right prisoner; on success the hunter gets Copper, Magoi and a "Bounty collected." line, the glow vanishes and the carry ends.
- **M9-G Prisoner:** after delivery. **Pass:** the prisoner is in the cell with a "Jailed" panel counting down from the sentence (bounty 30 = 3:00); they can walk but not jump, run or leave; dying respawns them in the cell; when the clock ends the panel goes and they are at the Qarzin spawn.
- **M9-H Hunter dies:** hunter holds the poster and dies. **Pass:** a "You lost the poster." line, the Tool is gone, tracker and glow gone; the poster must be taken from the board again. A knockout keeps the poster.
- **M9-I Grip to death:** `.knock` a second account, stand within 5 studs. **Pass:** a "Grip" (G) prompt shows on them next to "Pick up" (E), never on yourself, a carried player, or while you are knocked/carrying/jailed; hold G: a "Gripping <name>" bar fills over about 4 seconds, you kneel over them (torso pitched, arms to the neck) and they lie with arms out, on both screens; their screen darkens with "<name> is choking you" and goes red near the end; at 100% they die, lose a life (last life runs the Rukh scene), you get a Black Rukh flutter, and the poses are gone.
- **M9-J Interrupt:** start a grip three times: (1) hit the gripper with a second account, (2) walk the gripper away more than 3 studs, (3) release G early. **Pass:** each time the bar and both poses vanish at once, a "The grip broke: ..." chat line shows, the victim's screen goes back to the plain knockout look, and the victim lives; respawning either character mid-grip also clears the poses.
- **M9-K Bounty grip:** `.bounty 50 <name>`, take the poster, `.knock` them, grip to the end. **Pass:** Copper and Magoi are paid as for a jailing with a "Bounty collected." line, and the Rukh is Black, not Gold.
- **M9-L Dummy grips you:** let a Target dummy knock you out (or `.knock` near it). **Pass:** it walks up and its model kneels over you in the same pose, your screen darkens with "<dummy name> is choking you"; hitting the dummy breaks the grip with the chat line and you get up after the grace time.

## M3 Combat (shelved; kept for the redesign)

Combat is shelved. These scenarios describe the retired design and stay as a starting point for the redesign; do not run them as pass/fail checks today. Dev commands: `.combat log on|off`, `.knock`, `.stun <s>`, `.hp`, `.weapon`, `.dummy`, `.npc`.

- **M3-A Fist combo:** `C` into the stance, click a dummy twice (one click per hit); no click drops the combo after about a second; right-click cancels. **Pass:** two hits per combo; Output shows `AttackHit(1) accepted`, `continues into hit 2`, `AttackHit(2) accepted`, `attack complete`.
- **M3-B Block, parry, break:** hold F against a Target dummy; tap F as a punch lands; keep blocking. **Pass:** immune while blocking; a parry staggers the dummy; the bar breaks into a stun, then refills; a second parry inside 1.5 s is a plain block.
- **M3-C Dash and run:** Q after spawning, Q with W+D, Q again at once; double-tap W. **Pass:** the repeat dash is rejected; `.state` walkSpeed is 16 walking, 28 running.
- **M3-D Knockout:** `.hp 5` and let a dummy hit you. **Pass:** ragdoll, blind screen, up after about 8 s with a quarter health; controls and camera return.
- **M3-E Dummies:** walk near the Target dummy and away; knock it out. **Pass:** chases within 30 studs, gives up past 40, re-acquires, gets back up; the Dummy type only flinches.
- **M3-F Low health:** `.hp 10`, then `.hp 100`. **Pass:** slows at once, full speed returns.
- **M3-G Remote abuse:** spam `Net.Attack`; send bad arguments to `Net.Attack`, `Net.Dash`, `Net.Block`; attack from 200 studs. **Pass:** rate-limited, `[Remotes]` warnings, no hit from range, no errors.
- **M3-H Dash stacking:** `Dash(0,1)` ten times in 1 s; `Block` 20 times. **Pass:** one dash; one parry window per cooldown.

## M3B Stance and training dummies (shelved; kept for the redesign)

Marker names must match the animations (`Config.Combat.Markers`). Dev commands: `.weapon`, `.unlock combat`, `.lock combat`, `.dummy spawn <name>|clear|list`, `.style`.

- **M3B-A Stance and unlock:** click without `C`, press `C`, press it again, `.lock combat` then `C`, `.unlock combat`. **Pass:** nothing swings outside the stance; the locked line reads "You don't know how to fight yet."
- **M3B-B Weapon click:** `.weapon Dagger`, `C` off, click. **Pass:** one click enters the stance and throws the first stab.
- **M3B-C Straight Sam:** hold F, then time F before his first hit. **Pass:** blocks do no damage; a parry stuns him for your full chain.
- **M3B-D Turtle Tariq:** keep chains going. **Pass:** his block breaks after about `MaxBlock / blockDrain` blocked hits.
- **M3B-E Jabbing Jamal:** swing; swing, cancel, hold F as his jab comes. **Pass:** a landed jab interrupts you; the cancel-then-block parries.
- **M3B-F Parry Pete:** throw a straight; then swing, cancel, wait, throw. **Pass:** the straight is parried; the delayed hit lands.
- **M3B-G Feinting Mohammed:** hold F when his second hit would come; `.weapon Dagger` for the feint. **Pass:** cancel highlight every cycle; a blocked dagger feint locks you out 0.5 s.
- **M3B-H Dashing Dalila:** start a swing, then chase. **Pass:** her dash has a cooldown; your hit lands the second time.
- **M3B-I Sparring Sinbad:** fight two minutes. **Pass:** no errors; `Attacking` never sticks; controls return; knockback on the 6th hit taken.
- **M3B-J Cleanup:** `.dummy clear`, `.dummy list`, knock a dummy out. **Pass:** all removed; a knocked-out dummy gets up at full health.

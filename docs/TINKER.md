# Tinkering guide

For Bryan: where each thing lives, how it works, and which numbers to touch. Every file here syncs through Rojo; after editing a file, restart Play. Dev commands: `.cmd` lists them. Each follow-up item in `docs/FOLLOWUPS.md` links to a section below.

Conventions in the new code: services on the server live in `src/ServerScriptService/Server/Services/` and run `Init()` then `Start()`; controllers on the client live in `src/StarterPlayer/StarterPlayerScripts/Client/Controllers/`; shared data and config live in `src/ReplicatedStorage/Shared/`. Numbers you tune are in data files, not in the logic. The server never trusts the client: clients send intentions, the server decides.

---

## Combat

**M3-FIX3-S (2026-09-28) replaced the old single server-timed swing** ("one Attack() call = one server-picked combo step, hit-checked once at a fixed `hitTime`") **with an animation-driven hit sequence**: one click plays one swing animation containing one or more hits; the animation's own wind-up/hit markers drive when the client reports each hit, and the server only ever validates those reports' timing - it never trusts what they say got hit.

**M3-FIX4-S (2026-09-28) built a fighting-style framework on top of that**: every weapon is a `Combat.Style` - a chain of hits plus style-level traits. **M3-FIX7-S (Bryan, 2026-10-02) removed the Light/Heavy split: every hit is a Light.** The rules:
- **Every hit**: small damage, no knockback of its own. A landed hit puts the target in `LightStun` - they can't block or parry, but they *can* still attack or dash. Nothing else happens to them (no flinch, no full stun).
- **Interrupts**: *any* hit that lands on a combatant mid-attack (a hit still unlanded, or the chain waiting for its next click) ends their attack. The chain is infinite while the clicks come; it ends when the defender blocks, parries, dashes away or hits first.
- Stun/TrueStun/Knocked turning on (a block break, a parry, a knockout) interrupts too.
- **Parry**: unchanged, beats any hit.
- **Cancel** is per-hit now: the next unlanded hit can be cancelled until its own `cancelUntil` time, and always costs nothing. What it turns into depends on the style's `cancelInto` trait: `"Any"` (free to block/attack/dash next) or `"Jab"` (the server immediately throws the style's first Light as a new, feint-flagged attack - if THAT gets blocked, not parried, the attacker eats `feintRecoverySeconds` of `Recovery`, unable to attack/block/dash, for overcommitting the bait).
- **Knockback** is count-based, not per-hit: a shared `HitCount` attribute (+1 per landed hit, from any source) triggers one impulse every `Combat.Knockback.everyHits` hits, then resets (also resets on its own after a few seconds of no further hits, and on knockout).
- **Bleed** stacks (a style's own `bleed` trait) tick damage every second, floored at 1 HP - it never knocks out by itself.

### The numbers (start here)
- **`Shared/Data/Combat.luau`**: every combat number, frozen and commented. Read the long comment above `Combat.Styles.Fist` first - it lays out the intended read-and-punish loop (bait a cancel, then punish the re-swing) and the timing rules to keep true when you retune these.
  - `Combat.Styles.<name>`: `displayName`, `cancelInto` (`"Any"` or `"Jab"`), `feintRecoverySeconds` (Dagger only), `speedMult`/`dashCooldownMult` (walk/run and dash-cooldown multipliers while equipped), `bleed` (`{damagePerStackPerSecond, seconds, maxStacks}`, Dagger only), `chain` (the ordered hits), `loopOffset` (track seconds of follow-through before the loop wraps).
  - **Timings are ANIMATION-TRACK seconds** (what the animation editor shows). At load, `Combat.luau` divides every `windupAt`/`cancelUntil`/`hitWindow`/`loopOffset` by `Config.Combat.ComboSpeed[style]`, so the exported numbers are real seconds. **`ComboSpeed` is the ONE speed knob**: change it in `Config.luau` and the server's windows retime themselves; never hand-convert.
  - Each hit in a `chain`: `name`, `windupAt` (when the wind-up marker plays), `cancelUntil` (how long a cancel is honoured for THIS hit), `hitWindow = {min, max}` (when the server accepts this hit's `AttackHit` report), `damage`, `range`/`radius` (the hit sphere - not part of Bryan's own shorthand, added since the hit-check needs them), `lightStun` (LightStun on a landed hit), `blockDrain` (block HP a blocked, not parried, hit costs), `bleedStacks` (Bleed stacks a landed hit adds).
  - `Combat.Knockback`: `everyHits` (6), `resetAfterSeconds` (3), `impulse` (40).
  - `Block`: `parryWindow` (0.25 s after pressing F), `parryCooldown`, `breakStun` (TrueStun after a break), `blockSpeedMult`. (The old flat `drainPerHit` is gone - every hit carries its own `blockDrain` now.)
  - `Dash`: `cooldown`, `distance`, `duration`, and (Bryan, 2026-09-30) `castRadius`/`wallMargin`/`minDistance`: the server sweeps a sphere along the dash first and stops it short of walls, so nobody gets flung; too short a dash doesn't happen and costs no cooldown. Dash is refused while `Attacking` (server and client), the dash animation sits above the run animation (Action3 over Action2), and starting a swing ends a run (`MovementService.SetRunning(false)` in `beginAttack`). `Run`: `speedMult` (x walk speed 16 = 28). `Knockout`: `getUpSeconds`, `healthOnGetUp` (fraction).
- **`Shared/Config.luau`**: `Config.Combat.HitTolerance` (seconds of slack the server adds to both ends of every `hitWindow`/`cancelUntil`/`HitGap`/`ClickTimeout` check), `Config.Combat.Chain` (the pacing, see above), every combat animation asset (`StanceAnimations`, `StanceSpeed`, `ComboAnimations`, `ComboSpeed`, `MoveAnimations` - Bryan's rule 2026-09-30: assets are referenced from Config, nothing hardcodes an id) and, client-only (the server never reads these): `.Markers` (wind-up/hit marker names per style; Fist's are `WindUp1`/`Punch1`/`WindUp2`/`Punch2`), `.LogMarkers` (each marker logs its track time AND the seconds since its hit's own start - the number to copy into `Combat.luau`), `.CancelFlashSeconds`. `Config.Health` (`Base`, `HeightBonus`, `RankBonus` per rank, `RegenPerSecond` per tier, `MaxBlock`, `BlockRegenPerSecond`, `CombatTierSeconds`), `Config.Npc` (see NPCs below).

### How a swing works, end to end
**M3-FIX5 (Bryan, 2026-09-30): one click per hit.** The combo is still one animation per style (`Config.Combat.ComboAnimations`), but it takes a click per hit. Every hit's `windupAt`/`cancelUntil`/`hitWindow` in `Combat.luau` is measured from that hit's OWN start (hit 1: the `Swing`; hit 2: the second click), not from the first click. The pacing lives in `Config.Combat.Chain`: `HitGap` (earliest the next click counts after a hit lands; an earlier click is remembered and fires when the gap ends), `ClickTimeout` (latest it counts; after that the combo is dropped), `Recovery` (cooldown after an NPC's pass, a cancel after a landed hit, or a watchdog timeout), `DropRecovery` (cooldown after a drop), `WatchdogMargin`. `Config.Npc.ContinueDelay` is a dummy's own "next click".

**M3-FIX6 (Bryan, 2026-10-01): freeze on the punch, and loop.** The animation plays looped and stops dead ON each punch (the hit marker) until the next click; the click plays the follow-through and the next wind-up through to the next punch. After the last hit it wraps to hit 1, so the chain is "1, 2, 1, 2, ..." until a click doesn't come (dropped), you cancel, or you're interrupted. Because every later segment starts with the previous punch's follow-through, hit 2's `windupAt` is that follow-through's length, and hit 1 on every pass after the first gets the style's `loopOffset` (the last punch's follow-through before the wrap) added to all its numbers automatically. To retune: write the keyframe times straight into `Combat.luau` as track seconds (Fist: 0.0 / 0.5 / 1.0 / 1.5 / 2.0 s) and change `ComboSpeed` to speed the whole combo up or down; the conversion is automatic. Dash lines: `Config.Combat.DashTrail` (`Count`, `Seconds`, `Spread`, `MinWidth`/`MaxWidth`).
1. Client `CombatController` sees M1, checks the attributes the server set (`Stunned`, `Knocked`, `Blocking`, `LightStunned`, `Recovering`, `Attacking`, `NextAttackAt`) and, if allowed, fires `AttackStart()` with no arguments.
2. Server `CombatService.AttackStart` re-checks everything, remembers the attacker's position (anti-teleport baseline), sets `Attacking = true`, broadcasts `CombatEvent Swing {character, style, hitCount}`, and arms a watchdog that silently ends the attack if the client goes quiet.
3. The client plays the combo animation for the equipped style (`WeaponSet` attribute). At each hit marker it fires `AttackHit(index)` (1-based, in order). `CombatService.AttackHit` accepts a report only if it's the next chain hit owed AND the elapsed time since that hit's own start falls inside its `hitWindow` (± `HitTolerance`) AND the attacker hasn't teleported. An accepted report runs the hit-check (closest registered target in the sphere ahead, facing, line-of-sight) whether or not it finds someone; a rejected one changes nothing (dropped; logged only with `.combat log on`).
3a. **The pause (M3-FIX5/M3-FIX6).** Once hit k lands, the server clears `CurrentHitIndex` and waits; the client freezes the track (speed 0) on that punch. The next click sends `AttackContinue(k+1)`, which the server accepts only between `HitGap` and `ClickTimeout` after hit k landed (± tolerance); it then restarts the timing clock and the anti-teleport baseline for hit k+1, sets `CurrentHitIndex` to k+1, and the client unfreezes the track straight into that hit's wind-up. No click in time: `AttackCancelled {reason = "dropped"}`, `DropRecovery` cooldown, the frozen pose fades out (the client also drops it locally as a backstop).
4. `AttackCancel()` is honoured whenever the next unlanded hit's own `cancelUntil` (± tolerance, from that hit's own start) hasn't passed, and ALWAYS while the chain is waiting for a click - always free before any hit landed. `"Any"` (Fist): the attacker is free to act again immediately. `"Jab"` (Dagger): the server throws `chain[1]` as a new feint attack right away.
5. **Interrupts:** the instant ANY hit lands on a combatant who is mid-attack (including a chain frozen between segments), or Stun/TrueStun/Knocked turns on for any reason, or the combatant dies/unregisters, their attack ends - `AttackCancelled {reason = "interrupted"}`, cooldown = `Chain.Recovery`.
6. `ApplyHit`: a facing block resolves to Parried/Blocked/BlockBroken first (parry costs no block HP and beats any hit; a plain block costs `hit.blockDrain`). Otherwise `HealthService.TakeDamage`, every landed hit applies `LightStun` (`hit.lightStun`), plus Bleed if `hit.bleedStacks > 0`, and the hit registers against the count-based knockback (`HitCount`, `Combat.Knockback`). A blocked (not parried) **feint** costs the attacker `Recovery`. At 0 HP: knockout (health 1, `Knocked` for `getUpSeconds`, `HitCount` resets, then `Recovered`).
7. The chain loops (M3-FIX6): after the last hit the next click continues into hit 1 again. It ends by dropping (`DropRecovery`), a cancel, an interrupt, or `CombatService.AttackEnd` (NPCs, `Recovery`; broadcasts `AttackEnded`). A hit that finds nobody broadcasts `Miss` (the whiff sound). Every outcome broadcasts as `CombatEvent` (`Swing`, `Hit`, `AttackCancelled`, `Bleed`, `KnockedBack`, `Blocked`, `Parried`, `BlockBroken`, `Knocked`, `Recovered`, `Dash`, `Run`). Clients only play animations, sounds and particles from these events.

### How to add a weapon
1. Add a `Combat.Styles.<Name>` entry in `Shared/Data/Combat.luau` - copy Fist's or Dagger's shape, pick `cancelInto` (`"Any"` for a simple weapon, `"Jab"` if it should feint into its own first Light), fill in `speedMult`/`dashCooldownMult` (1.0 for no change), and a `chain` of hits (a chain can be any length). Add a `bleed` trait if you want it to stack Bleed.
2. Give the style a swing animation and set `Config.Combat.Markers.<Name>` (client) to that animation's own wind-up/hit event names - M3-FIX4-C reads the chain from data by the `WeaponSet` name, it never hardcodes a hit count.
3. Grant it: `CombatService.SetWeapon(character, "<Name>")` (or `.weapon <Name> [player]` from the dev console to try it out before it's wired into a shop).
4. Playtest with `.combat log on` and `.style [player]` (prints the equipped style's whole chain and traits) to read real timings and retune the placeholder numbers.

### Server files
- **`Server/Services/CombatService.luau`**: the core above. Public: `AttackStart(character)`, `AttackHit(character, index)`, `AttackCancel(character)`, `Attack(character)` (the NPC entry point - runs the same sequence on server timers), `SetBlocking(character, on)`, `SetWeapon(character, styleName)`, `ApplyHit`, `FindTarget`, `Register/Unregister(character)`. Dev: `.combat log on|off` prints every decision with its elapsed time; `.knock [player]`, `.stun <s> [player]`, `.weapon <Fist|Dagger> [player]`, `.style [player]`.
- **`Server/Services/StatusService.luau`**: the one owner of `Hit`, `Stun`, `Knocked`, `Ragdoll`, `Block` (value 1 during the parry window, then 0), `BlockBroken`, `TrueStun`, `LightStun`, `Recovery`, `Bleed` (stacked - `data = {stacks, config}`). `Apply(character, status, duration?, data?)`, `Remove`, `Has`, `Get`, and a `Changed` signal. Mirrors client attributes (`Bleed`'s is the stack count, not a boolean), and still writes the old `character.Effects` markers for the original four so missions and regions keep working (two-way: if an old script destroys a marker, the status ends).
- **`Server/Services/MovementService.luau`**: one speed stack per character. Named multipliers (`Run`, `Block`, `Stun`, `TrueStun`, `Knocked`, `Hit`, `LowHealth`, `HeavyCargo`); the smallest wins; 0 freezes; it writes `WalkSpeed` itself. `SetModifier/ClearModifier`, `SetRunning`, `Dash` (server cooldown x the equipped style's own `dashCooldownMult`), `SetStyle(character, styleName)` (applies `speedMult`/`dashCooldownMult` - kept OUTSIDE the modifier stack since a style can be a genuine speed boost, not just a debuff). Low health slows immediately (`LowHealthMult`). Still fills the old `IntFold.MovementSpeed` folder for the mission script.
- **`Server/Services/HealthService.luau`**: max health = `Base + HeightBonus x Height + RankBonus[rank]`; regen tiers Idle/Combat/Knocked; block HP and refill (paused while blocking); also ticks `Bleed` (its own status data's `config`/`stacks`) every `Config.Health.Tick`, floored at 1 HP. `TakeDamage`, `SpendBlock`, `SetBlocking`, `SetTier`, `Register(model)` for NPCs. Attributes `Health`, `MaxHealth`, `Block`, `MaxBlock`, `RegenTier`. Dev: `.hp <n>`, `.tier <Idle|Combat|Knocked>`.
- **`Server/Services/FootstepService.luau`**: your old step sounds and footprints, moved verbatim from the deleted InteractionsHandler; listens to the old `MiscRemotes.Footstep` remote.
- **`Shared/Remotes.luau`**: the remote definitions (`AttackStart`, `AttackHit`, `AttackCancel`, `Block`, `Dash`, `Run`, `CombatEvent`) with argument types and per-player rate limits. Dropped calls log once per window plus a summary.

### Client files
- **`Client/Controllers/CombatController/init.luau`**: input to intentions, and now also to hit reports. M1 attack (fires `AttackStart()`, then `AttackHit(index)` off the swing animation's own hit markers, per-style via `Config.Combat.Markers`), F hold block, Q + WASD dash (camera-relative), double-tap W run with the camera zoom, right-click cancels (`AttackCancel()`) while the next unlanded hit's own cancel point hasn't passed. Plays the swing animation for the equipped style when the server's `Swing` event arrives (at `Config.Combat.ComboSpeed`; no wind-up slowdown any more), a brief highlight on a confirmed cancel, the block pose, the dash animation, and (M3-FIX4-C) the Royal Dagger tool welded to the hand while `WeaponSet == "Dagger"`. All animation ids are listed in the header comment.
- **`Client/Controllers/EffectsController/init.luau`**: everything seen and heard: hit/miss/block/parry/block-break sounds and particles, stagger and block-reaction animations, the stunned pose, parry hit-stop, knockout blind screen and input freeze (local player), ragdoll visuals, dash trail, run zoom, and (M3-FIX4-C) bleed droplets while `Bleed > 0` and a knockback camera shake on `KnockedBack`. One handler per `CombatEvent` kind.

### Where the old pieces went
`InteractionsHandler`, `InteractionsDesign`, `DamageHandler`, `PhysicalHandler`, `SpeedHandler` (a shim remains), `WeaponHandler`, `NPController`: deleted. `EffectsService.server.luau` now only creates `character.Effects` and does the ragdoll physics on `Knocked`.

---

## NPCs (training dummies)

- **`Shared/BehaviorTree.luau`**: `Selector`, `Sequence`, `Condition`, `Action`, `Inverter`, `Wait`, `Cooldown`. A tree is data; each tick returns Success / Failure / Running.
- **`Server/Services/NpcService/Trees.luau`**: the two trees. `BuildDummy`: knocked -> wait; hit -> flinch; else idle. `BuildTarget`: knocked -> wait; has a target -> (in reach -> attack on cooldown | within give-up radius -> chase step | give up); else acquire within `ChaseRadius`; else wander around home. Animations: plays `Walk` / `Run` / `Flinch` if `Animation` objects with those names exist inside the dummy model, or the ids in `Config.Npc.Animations`.
- **`Server/Services/NpcService/AiController.luau`**: one controller per NPC with a blackboard; all controllers tick on one shared loop every `Config.Npc.TickSeconds`.
- **NPC animations (Bryan, 2026-09-30):** every NPC gets the player's full set. `Client/Controllers/NpcAnimController` animates every model carrying the `NPC` tag (NpcService tags each one it registers) on every client: idle/walk/run/jump/fall from `Config.Character.Animations` (the same ids CharacterService writes into a player's Animate script), the stance idle and dagger prop through `CombatController.WireCharacterLook`, and the combat moves off the server's own events and attributes - the combo animation with the same freeze-and-continue chain as a player (`CombatController/SwingTrack.luau`, shared; the server's `SwingContinue` event is the NPC's "click"), block pose (`Blocking`), run (`Running`), the four dashes (`Dash`). Nothing here replicates; every client plays the same thing from the same server state.
- **`Server/Services/NpcService/init.luau`**: finds models under `Workspace.NPC` (or tagged `NPC`), reads the `NpcType` attribute (`Dummy` default, `Target` chases), registers each NPC with Status, Movement, Health and Combat exactly like a player, keeps a template in `ServerStorage.NpcTemplates` to re-clone a destroyed one. Dev: `.npc list|reset|type <name> Dummy|Target`.
- **Numbers:** `Config.Npc` in `Shared/Config.luau`: `TickSeconds`, `ChaseRadius` (30), `GiveUpRadius` (40), `AttackRange` (4), `AttackCooldown`, `WanderRadius`, `MaxHealth` per type, `Animations`.

### Tuning or adding a training dummy (M3B-02)

- **Retune an existing one:** everything is in `Config.Npc.Trainers.<Key>` (`Shared/Config.luau`) - `reactionSeconds` (delay before a dummy reacts to what it reads off the target), `rhythmSeconds` (its own throw/re-throw pace, unrelated to the target), `engageRadius` (12 by default - it only fights its spawner or the nearest player this close), and Sparring Sinbad's own `weights = { throw, cancel, parry, dash }`. No code change needed for any of these.
- **Add a new one:**
  1. Add its `Config.Npc.Trainers.<Key>` entry (`displayName`, whichever of `reactionSeconds`/`rhythmSeconds`/`engageRadius`/`weights` it needs) and append the key to `Config.Npc.TrainerOrder`, then freeze it alongside the others at the bottom of `Config.luau` (same pattern as the seven already there).
  2. Write its `<key>Decide(bb, cfg): BehaviorTree.Status` function in `Server/Services/NpcService/Trees.luau` (the "Training dummies (M3B-02)" section) - it only ever acts through `CombatService.Attack`/`.AttackCancel`/`.SetBlocking` and `MovementService.Dash`, and reads its target off `bb.target`'s `Attacking`/`CurrentHitIndex` attributes (a 1-based hit number, or nil when nothing is being thrown; set by `CombatService` as a swing progresses). Keep any reaction-window state on the blackboard itself (`bb.phase`/`bb.phaseAt`, `os.clock()`-timed), not a nested `BehaviorTree.Wait` - see Jabbing Jamal/Parry Pete/Dashing Dalila for the pattern (their timer has to restart if what they're reading stops, which a `Wait` node's own fixed closure can't do).
  3. Add it to `TRAINER_DECIDERS` in the same file.
  4. `.dummy spawn <Key> [player]` (section 16) spawns it for testing; add a self-test in `SelfTestService.luau`'s `testTrainers` following the existing seven (register a real fake trainer, set the fake target's attributes directly, tick the tree, check the resulting attribute/status).
- **Spawning mechanics:** `.dummy spawn/clear/list` and the reset-on-knockout behaviour (full health, `Bleed` cleared, `HitCount` reset - a deliberate override of the normal partial-health knockout recovery) live in `NpcService/init.luau`, not `Trees.luau`.

---

## Rank and Rukh

- **Numbers and text:** `Shared/Data/Ranks.luau` (the Magoi ladder and titles; `titleFor` renders King/Queen by gender), `Shared/Data/Epithets.luau` (the banks per rank and alignment; gendered entries), `Shared/Data/Alignment.luau` (`MinDeeds` before you are judged, `Lean` = 0.65 share for a side), `Config.Rukh` in `Shared/Config.luau` (`FlutterSeconds`, `Emitters` per alignment, `EmitRate`).
- **Server:** `Server/Services/RankService.luau`: watches `Progress` (Magoi, GoldRukh, BlackRukh), sets the `Rank`/`RankIndex`/`Epithet`/`Alignment`/`EpithetPending` attributes, stores a pending choice in the save (`Progress.PendingEpithet`), fires `RankUp` and `AlignmentChanged`, validates `ChooseEpithet`. Choices queue: while one is pending no new card; after choosing, the next rank is announced if you are already past it. `AddMagoi`/`AddDeed` are what missions call. Dev: `.magoi`, `.magoi+`, `.rukh`, `.rankup`, `.epithet clear`.
- **Client:** `Client/Controllers/RankController/init.luau`: `playFlutter` (clones the emitters onto the torso for `FlutterSeconds`), `showCard` (the card in the menu style; fonts are read from your MenuGUI template; buttons and 1/2/3 keys send `ChooseEpithet`).

## Heartbeat sound and heart-attack pulses

- **`Shared/Config.luau`**: `Config.Sfx.Heartbeat` (the sound id; swap it), `Config.Scene` (`BeatGap`, `PairGap`, `NonFatalCycles`, `FatalCycles`, `FatalSlowFactor`, `MessageSeconds`).
- **`Client/Controllers/RukhController/init.luau`**: `playNonFatalPulse` and `playFatalPulse` draw the red overlay and play the sound in lub-dub pairs from those numbers; the fatal one darkens and shows "Your heart gave out." (menu font). The server decides fatal or not (`AgeService`, `Config.Aging.DeathChance`); `.heart` / `.heart fatal` trigger either; `.mortal on|off` gates real death rolls.

## Afterlife cutscene (return to the Rukh)

- **Your model**: `ReplicatedFirst.AfterLife` in Studio. The code reads only `AfterlifeCamera` (camera target), `AfterlifeSpawnBlock` (where the character is placed) and an optional `AfterlifeCore` part (what the character walks toward). Everything else in the model is yours.
- **`Client/Controllers/RukhController/init.luau`**: `playRukhScene` freezes controls (PlayerModule controls disabled + action sink + humanoid zeroed), sets the camera, turns the body golden neon, attaches the Rukh emitters from `ReplicatedFirst.VFX.RukhEffects`, walks toward the core, fades to white, then fires `RukhSceneDone`. Pacing: `Config.Scene.WalkSeconds`, `FadeSeconds`, `CoreDistance`. The server respawns the new life on `RukhSceneDone` or after `Config.Aging.SceneTimeout`.

## Menu viewport (character preview)

- **`Client/Controllers/MenuController/init.luau`**: search "FIX BUG-21". The preview clones your character into a `WorldModel` inside a `ViewportFrame` in the old diamond, camera 2.5 studs in front of the head looking back (a mirror). Change the offset, angle or lighting there. The rest of the menu (name, title from epithet or rank, stat line, alignment/lives line, apparel frames) is in the same file.

## Day and night

- **`Shared/Config.luau` `Config.World.DayNight`**: `DaySeconds` (600) and `NightSeconds` (360) are real seconds of daylight (06:00 to 18:00) and night; day must stay longer than night. `DawnHour` / `DuskHour`, `TransitionSeconds` (how long the sky blends at dawn and dusk) and `LightFadeSeconds` live there too.
- **`Shared/Data/DayNight.luau`**: the four looks (Day, Dusk, Night, Dawn): sky and ambient colours, Atmosphere colour/density/haze, ColorCorrection tint, Bloom. Day is the place's own Lighting exactly as it was; tune the night in `Night` (darker `Brightness`/`OutdoorAmbient` = darker night).
- Test in the chat: `.time 18.5` (dusk), `.time 0` (midnight), `.time 5.5` (dawn), `.time speed 20` (fast clock, `.time speed 1` to restore), `.time pause` / `.time resume`. Everyone in the server jumps together.

## City lights

- Tag a **part or a model** `CityLight` (Studio: Tag Editor plugin, or the Properties tag box). Every `PointLight`, `SpotLight`, `SurfaceLight`, `Fire`, `ParticleEmitter`, `Smoke` and `Sparkles` under it runs at night only (fading over `LightFadeSeconds`), and a Neon part in it turns to `Config.World.DayNight.DayMaterial` (SmoothPlastic) by day so a lamp looks unlit in the sun.
- A torch is a **model** with a flame part (Neon, maybe a Fire) and a separate part holding the light; tag the model. Parts added later (streaming, spawned) are picked up automatically.
- To change the tag name or the day material: `Config.World.DayNight.Tag` / `.DayMaterial`.

## Ocean

The new `OceanController` only runs once the old wave scripts are gone (they would fight it for the tile positions). In Studio, open View > Command Bar and run this once (Ctrl+Z undoes it; the published game's version history is your backup):

```lua
local n = 0
for _, d in workspace.MAP.OCEAN:GetDescendants() do
	if d:IsA("Script") then
		d:Destroy()
		n += 1
	end
end
print("deleted", n, "scripts")
```

It should print 766. Then set `Config.World.Ocean.Enabled = true` in `Shared/Config.luau`. Timing and size of the waves: `Amplitude`, `RiseSeconds`, `HoldSeconds`, `DecalFadeSeconds`, `DecalPauseSeconds`, `DecalVisibleTransparency`; `CullDistance` stops tiles far from the camera from moving.

## Regions and music

- A region is an invisible, `CanCollide = false`, `Anchored` part named `<Key>REGION` (for example `QarzinREGION`) under `Workspace.Regions`; several parts can share a key. Then add a `<Key>` entry to **`Shared/Data/Regions.luau`**: `priority` (higher wins where regions overlap), `playlist` (track names from `ReplicatedFirst.SFX.OSTs`), optional `ambient` loop and volume, optional `banner` title and subtitle.
- Music volume for every playlist track is `Config.World.Music.Volume`; the crossfade is `CrossfadeSeconds`.

## Studio-only leftovers (delete by hand)

`ReplicatedFirst.GUI.Gender.Decisions` (Script), `MenuGUI...MenuMechanics` (LocalScript), R7 MissionWagon seat script, R8 empty scripts (`Workspace.Qarzin.QarzinEconomy`, `MaterialService.Tool.LocalScript`). The new controllers disable the first two at runtime, so nothing breaks if they stay.

---

## Reading the logs

Every new script logs as `[Tag] message` through `Shared/Log.luau`; `[WARN]` lines are dropped or rejected actions, red lines are bugs. `.state` prints a snapshot of your character; F8 shows it live; `.combat log on` prints each hit decision. "Infinite yield possible on AppearenceLoaded / Stats" at boot is old scripts waiting while the Studio save loads; harmless.

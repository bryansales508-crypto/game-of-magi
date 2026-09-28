# Tinkering guide

For Bryan: where each thing lives, how it works, and which numbers to touch. Every file here syncs through Rojo; after editing a file, restart Play. Dev commands: `.cmd` lists them. Each follow-up item in `docs/FOLLOWUPS.md` links to a section below.

Conventions in the new code: services on the server live in `src/ServerScriptService/Server/Services/` and run `Init()` then `Start()`; controllers on the client live in `src/StarterPlayer/StarterPlayerScripts/Client/Controllers/`; shared data and config live in `src/ReplicatedStorage/Shared/`. Numbers you tune are in data files, not in the logic. The server never trusts the client: clients send intentions, the server decides.

---

## Combat

### The numbers (start here)
- **`Shared/Data/Combat.luau`**: every combat number, frozen and commented.
  - `Moves.Fist` (3 entries: Jab, Cross, Finisher) and `Moves.Dagger` (for the shop milestone). Per move: `windup` (seconds before the hit check), `hitTime`, `recovery` (added to the cooldown), `damage`, `range`, `radius` (the hit sphere), `stun` (how long the target's Stun lasts), `knockback` (impulse), `comboWindow` (seconds after the hit lands to chain the next step), `finisher`.
  - `Block`: `drainPerHit` (block HP per blocked hit), `parryWindow` (0.25 s after pressing F), `parryCooldown`, `breakStun` (TrueStun after a break), `blockSpeedMult`.
  - `Dash`: `cooldown`, `distance`, `duration`. `Run`: `speedMult` (x walk speed 16 = 28). `Knockout`: `getUpSeconds`, `healthOnGetUp` (fraction). `Stagger`: `hitStun` (how long the Hit stagger lasts).
- **`Shared/Config.luau`**: `Config.Health` (`Base`, `HeightBonus`, `RankBonus` per rank, `RegenPerSecond` per tier, `MaxBlock`, `BlockRegenPerSecond`, `CombatTierSeconds`), `Config.Npc` (see NPCs below).

### How a punch works, end to end
1. Client `CombatController` sees M1, checks the attributes the server set (`Stunned`, `Knocked`, `Blocking`, `NextAttackAt`) and, if allowed, fires the remote `Attack()` with no arguments.
2. Server `CombatService.Attack` re-checks everything, picks the combo step (`NextComboStep`), sets `NextAttackAt = now + windup + recovery`, broadcasts `CombatEvent Swing`, and schedules the hit check at `hitTime`.
3. At `hitTime`, `runHitCheck` verifies the attacker is alive, not blocking, and hasn't moved further than run speed x hitTime + dash distance since the swing (anti-teleport). `FindTarget` takes the closest registered combatant inside the sphere in front of the attacker, with a line-of-sight raycast (no hits through walls).
4. `ApplyHit`: if the target is blocking and facing the attacker, `ResolveBlock` decides parry / blocked / block broken (parry costs no block HP; a blocker takes no damage, stun or knockback). Otherwise `HealthService.TakeDamage`, `StatusService.Apply(Hit, Stun)`, a `Hit` speed modifier, knockback. At 0 HP: knockout (health 1, `Knocked` status for `getUpSeconds`, then `Recovered`). A knocked target can't be hit again.
5. Every outcome is broadcast as `CombatEvent` (`Swing`, `Hit`, `Blocked`, `Parried`, `BlockBroken`, `Knocked`, `Recovered`, `Dash`, `Run`). Clients only play animations, sounds and particles from these events.

### Server files
- **`Server/Services/CombatService.luau`** (767 lines): the core above. Public: `Attack(character)`, `SetBlocking(character, on)`, `ApplyHit`, `FindTarget`, `Register/Unregister(character)`. NPCs call the same `Attack`. Dev: `.combat log on|off` prints every decision; `.knock [player]`, `.stun <s> [player]`.
- **`Server/Services/StatusService.luau`** (557): the one owner of `Hit`, `Stun`, `Knocked`, `Ragdoll`, `Block` (value 1 during the parry window, then 0), `BlockBroken`, `TrueStun`. `Apply(character, status, duration?, data?)`, `Remove`, `Has`, `Get`, and a `Changed` signal. Mirrors `Stunned`/`Knocked`/`Blocking`/`TrueStunned` attributes for clients, and still writes the old `character.Effects` markers so missions and regions keep working (two-way: if an old script destroys a marker, the status ends).
- **`Server/Services/MovementService.luau`** (478): one speed stack per character. Named multipliers (`Run`, `Block`, `Stun`, `TrueStun`, `Knocked`, `Hit`, `LowHealth`, `HeavyCargo`); the smallest wins; 0 freezes; it writes `WalkSpeed` itself. `SetModifier/ClearModifier`, `SetRunning`, `Dash` (server cooldown, normalised direction, a short push). Low health slows immediately (`LowHealthMult`). Still fills the old `IntFold.MovementSpeed` folder for the mission script.
- **`Server/Services/HealthService.luau`** (360): max health = `Base + HeightBonus x Height + RankBonus[rank]`; regen tiers Idle/Combat/Knocked; block HP and refill (paused while blocking). `TakeDamage`, `SpendBlock`, `SetBlocking`, `SetTier`, `Register(model)` for NPCs. Attributes `Health`, `MaxHealth`, `Block`, `MaxBlock`, `RegenTier`. Dev: `.hp <n>`, `.tier <Idle|Combat|Knocked>`.
- **`Server/Services/FootstepService.luau`** (209): your old step sounds and footprints, moved verbatim from the deleted InteractionsHandler; listens to the old `MiscRemotes.Footstep` remote.
- **`Shared/Remotes.luau`**: the remote definitions (`Attack`, `Block`, `Dash`, `Run`, `CombatEvent`) with argument types and per-player rate limits. Dropped calls log once per window plus a summary.

### Client files
- **`Client/Controllers/CombatController/init.luau`** (462): input to intentions. M1 attack, F hold block, Q + WASD dash (camera-relative), double-tap W run with the camera zoom, right-click/jump cancel. Plays your swing animations when the server's `Swing` event arrives, the block pose from the `Blocking` attribute, the dash animation from `Dash`. All animation ids are listed in the header comment.
- **`Client/Controllers/EffectsController/init.luau`** (611): everything seen and heard: hit/miss/block/parry/block-break sounds and particles (from the sounds CharacterService copies onto the torso and `ReplicatedFirst.VFX`), stagger and block-reaction animations, the stunned pose, parry hit-stop, knockout blind screen and input freeze (local player), ragdoll visuals, dash trail, run zoom. One handler per `CombatEvent` kind (`onHit`, `onBlocked`, `onParried`, `onBlockBroken`, `onKnocked`, ...).

### Where the old pieces went
`InteractionsHandler`, `InteractionsDesign`, `DamageHandler`, `PhysicalHandler`, `SpeedHandler` (a shim remains), `WeaponHandler`, `NPController`: deleted. `EffectsService.server.luau` now only creates `character.Effects` and does the ragdoll physics on `Knocked`.

---

## NPCs (training dummies)

- **`Shared/BehaviorTree.luau`**: `Selector`, `Sequence`, `Condition`, `Action`, `Inverter`, `Wait`, `Cooldown`. A tree is data; each tick returns Success / Failure / Running.
- **`Server/Services/NpcService/Trees.luau`**: the two trees. `BuildDummy`: knocked -> wait; hit -> flinch; else idle. `BuildTarget`: knocked -> wait; has a target -> (in reach -> attack on cooldown | within give-up radius -> chase step | give up); else acquire within `ChaseRadius`; else wander around home. Animations: plays `Walk` / `Run` / `Flinch` if `Animation` objects with those names exist inside the dummy model, or the ids in `Config.Npc.Animations`.
- **`Server/Services/NpcService/AiController.luau`**: one controller per NPC with a blackboard; all controllers tick on one shared loop every `Config.Npc.TickSeconds`.
- **`Server/Services/NpcService/init.luau`**: finds models under `Workspace.NPC` (or tagged `NPC`), reads the `NpcType` attribute (`Dummy` default, `Target` chases), registers each NPC with Status, Movement, Health and Combat exactly like a player, keeps a template in `ServerStorage.NpcTemplates` to re-clone a destroyed one. Dev: `.npc list|reset|type <name> Dummy|Target`.
- **Numbers:** `Config.Npc` in `Shared/Config.luau`: `TickSeconds`, `ChaseRadius` (30), `GiveUpRadius` (40), `AttackRange` (4), `AttackCooldown`, `WanderRadius`, `MaxHealth` per type, `Animations`.

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

## Studio-only leftovers (delete by hand)

`ReplicatedFirst.GUI.Gender.Decisions` (Script), `MenuGUI...MenuMechanics` (LocalScript), R7 MissionWagon seat script, R8 empty scripts (`Workspace.Qarzin.QarzinEconomy`, `MaterialService.Tool.LocalScript`). The new controllers disable the first two at runtime, so nothing breaks if they stay.

---

## Reading the logs

Every new script logs as `[Tag] message` through `Shared/Log.luau`; `[WARN]` lines are dropped or rejected actions, red lines are bugs. `.state` prints a snapshot of your character; F8 shows it live; `.combat log on` prints each hit decision. "Infinite yield possible on AppearenceLoaded / Stats" at boot is old scripts waiting while the Studio save loads; harmless.

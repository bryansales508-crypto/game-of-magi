# Bryan's follow-ups

Things Bryan does himself in Studio, in his own time. Bryan edits this file. The lead reminds him of every open line at each milestone gate and each planning step until he marks it done (change `open` to `done` and add the date).

Every item has a "where and how" section in `docs/TINKER.md`.

| Item | Where | Status |
|---|---|---|
| Combat feel: the glitches Bryan found in the M3 pass; tune numbers and fix in place | `docs/TINKER.md` section "Combat": `Shared/Data/Combat.luau` for numbers, `CombatService` / `StatusService` / `MovementService` / `HealthService` on the server, `CombatController` / `EffectsController` on the client | open |
| Animation marker names and times per style: with `Config.Combat.LogMarkers` on, one swing prints every event name and time; set `Config.Combat.Markers.Fist` / `.Dagger` to your names, then each hit's `windupAt`, `cancelUntil`, `hitWindow` in `Shared/Data/Combat.luau` to the logged times | `Shared/Config.luau`, `Shared/Data/Combat.luau` (TINKER.md "Combat") | open |
| Stance animations: one looping idle per style | `Shared/Config.luau` -> `Config.Combat.StanceAnimations = { Fist = "", Dagger = "" }` (empty = none) | open |
| Rank, Rukh and epithet tweaks: the flutter, the card, the banks and thresholds | `docs/TINKER.md` section "Rank and Rukh": `Shared/Data/Ranks.luau` (thresholds, titles), `Epithets.luau` (banks), `Alignment.luau` (MinDeeds, Lean), `Config.Rukh` (flutter seconds, emitters), `RankService` (server flow), `RankController` (flutter and card look) | open |
| Heartbeat sound: replace the placeholder with the right lub-dub sound | `Shared/Config.luau` -> `Config.Sfx.Heartbeat` (asset id); timing knobs in `Config.Scene` (`BeatGap`, `PairGap`, cycles, `FatalSlowFactor`) (TINKER.md "Heartbeat") | open |
| Afterlife cutscene: the look and pacing of the return-to-the-Rukh scene | Your `ReplicatedFirst.AfterLife` model in Studio (the code only reads `AfterlifeCamera`, `AfterlifeSpawnBlock` and an optional `AfterlifeCore` part to walk toward); pacing in `Config.Scene` (`WalkSeconds`, `FadeSeconds`, `CoreDistance`, `MessageSeconds`) (TINKER.md "Afterlife") | open |
| Viewport: the menu's character preview (now a mirror; tune framing or replace) | `Client/Controllers/MenuController/init.luau`, the preview camera block (search "FIX BUG-21") (TINKER.md "Menu viewport") | open |
| NPC dummy animations: the walk, run and flinch animation ids lived only in the deleted `NPCFetch` scripts; put `Animation` objects named `Walk`, `Run`, `Flinch` (with your ids) inside each dummy model, or give the lead the ids to add to `Config.Npc` | Studio: `Workspace.NPC.<dummy>`; or `Shared/Config.luau` -> `Config.Npc` (TINKER.md "NPCs") | open |
| NPC types: set a string attribute `NpcType` = `Target` on the dummy that should chase and punch (the other stays `Dummy`). Until then both only flinch. | Studio: `Workspace.NPC.<dummy>` Properties -> Attributes (TINKER.md "NPCs") | open |
| Studio-only leftovers to delete by hand: `Gender.Decisions` script inside `ReplicatedFirst.GUI.Gender`, `MenuMechanics` inside `MenuGUI`, R7 MissionWagon seat script, R8 empty scripts (`Workspace.Qarzin.QarzinEconomy`, `MaterialService.Tool.LocalScript`), and after the 5B playtest passes: `Workspace.Qarzin.ClothesStand.ClothingSpawn` (disabled by ShopService at startup until then) | Studio Explorer | open |
| Mission board wording: the intercepted notice "Merchants doubt you..." is mine, not yours; reword it if you like (one string, `INTERCEPTED_NOTICE_FORMAT`) | `Client/Controllers/MissionController/init.luau` | open |
| City lights for M6 (after 6B merges): tag lamp, torch and fire parts `CityLight` in the Tag Editor; the six Qarzin bulbs first | Studio Tag Editor; `Shared/Data/DayNight.luau` for the night look | open |
| Sound assets: `SFX.OSTs.Lullaby` and `SFX.Magic.WandFlick` have no SoundId; `SwordClangSound1` is at volume 3.0 and both BattleCry sounds at 5.0 (everything else 0.1 to 0.5) | `ReplicatedFirst.SFX` in Studio | open |

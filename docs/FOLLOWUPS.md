# Bryan's follow-ups

Things Bryan does himself in Studio, in his own time. Bryan edits this file. The lead reminds him of every open line at each milestone gate and each planning step until he marks it done (change `open` to `done` and add the date).

| Item | Where | Status |
|---|---|---|
| Heartbeat sound: replace the placeholder with the right lub-dub sound | `Shared/Config.luau` -> `Config.Sfx.Heartbeat` (asset id); timing knobs in `Config.Scene` (`BeatGap`, `PairGap`, cycles, `FatalSlowFactor`) | open |
| Afterlife cutscene: the look and pacing of the return-to-the-Rukh scene | Your `ReplicatedFirst.AfterLife` model in Studio (the code only reads `AfterlifeCamera`, `AfterlifeSpawnBlock` and an optional `AfterlifeCore` part to walk toward); pacing in `Config.Scene` (`WalkSeconds`, `FadeSeconds`, `CoreDistance`, `MessageSeconds`) | open |
| Viewport: the menu's character preview (now a mirror; tune framing or replace) | `Client/Controllers/MenuController/init.luau`, the preview camera block (search "FIX BUG-21") | open |
| NPC dummy animations: the walk, run and flinch animation ids lived only in the deleted `NPCFetch` scripts; put `Animation` objects named `Walk`, `Run`, `Flinch` (with your ids) inside each dummy model, or give the lead the ids to add to `Config.Npc` | Studio: `Workspace.NPC.<dummy>`; or `Shared/Config.luau` -> `Config.Npc` | open |
| NPC types: set a string attribute `NpcType` = `Target` on the dummy that should chase and punch (the other stays `Dummy`). Until then both only flinch. | Studio: `Workspace.NPC.<dummy>` Properties -> Attributes | open |
| Studio-only leftovers to delete by hand: `Gender.Decisions` script inside `ReplicatedFirst.GUI.Gender`, `MenuMechanics` inside `MenuGUI`, R7 MissionWagon seat script, R8 empty scripts (`Workspace.Qarzin.QarzinEconomy`, `MaterialService.Tool.LocalScript`) | Studio Explorer | open |

# Bryan's follow-ups

Things Bryan does himself in Studio, in his own time. Bryan edits this file; the lead reminds him of every open line at each milestone gate. How-tos are in `docs/TINKER.md`.

| Item | Where | Status |
|---|---|---|
| Particles: rework how the VFX work (mission sparkles, hit effects, dash lines) | `ReplicatedFirst.VFX`; cloned by `Server/Services/MissionService.luau` (Highly Valuable sparkles) and `Client/Controllers/EffectsController/init.luau` (hit, dash lines) | open |
| City lights: tag lamp, torch and fire parts (or whole models) `CityLight`; the six Qarzin bulbs first | Studio Tag Editor; night look in `Shared/Data/DayNight.luau` | open |
| Stance and combo animations: one looping stance idle per style, plus the combo markers (parked with combat until the redesign) | `Config.Combat.StanceAnimations`, `Markers` | parked |
| Heartbeat sound: replace the placeholder with the right lub-dub | `Config.Sfx.Heartbeat`; timing in `Config.Scene` | open |
| Afterlife cutscene: look and pacing of the return-to-the-Rukh scene | your `ReplicatedFirst.AfterLife` model; pacing in `Config.Scene` | open |
| Sound levels: `SFX.OSTs.Lullaby` and `SFX.Magic.WandFlick` have no SoundId; `SwordClangSound1` is 3.0 and both BattleCry sounds 5.0 (everything else 0.1 to 0.5) | `ReplicatedFirst.SFX` in Studio | open |
| Studio deletions: `Workspace.Qarzin.ClothesStand.ClothingSpawn`, the old dummy scripts (`NPCFetch`, `Health` under `Workspace.NPC.DUMMY`), the ServerStorage previous-game folder, the R7 wagon seat script, the R8 empty scripts (`Workspace.Qarzin.QarzinEconomy`, `MaterialService.Tool.LocalScript`) | Studio Explorer | open |
| Mission board wording: the "Merchants doubt you..." line is the lead's, reword it if you like | `INTERCEPTED_NOTICE_FORMAT` in `Client/Controllers/MissionController/init.luau` | open |

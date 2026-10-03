# Bryan's follow-ups

Open items Bryan owns, done in Studio or by editing a value. Bryan edits this file. Every item has a "where and how" section in `docs/TINKER.md`. Done items are removed.

| Item | Where | Status |
|---|---|---|
| Particles rework: how the VFX work (mission sparkles, hit effects, dash lines) | `ReplicatedFirst.VFX` in Studio; cloned by `Server/Services/MissionService.luau` and `Client/Controllers/EffectsController/init.luau` | open |
| `CityLight` tags: tag lamp, torch and fire parts so cities light at dusk | Studio Tag Editor; night look in `Shared/Data/DayNight.luau` | open |
| Stance and combo animations: one idle per style, the combo swings | `Config.Combat.StanceAnimations` and `Config.Combat.Markers`; parked with combat until its redesign | parked |
| Heartbeat sound and tuning: the right lub-dub sound and its timing | `Config.Sfx.Heartbeat`; `Config.Scene` (`BeatGap`, `PairGap`, `FatalSlowFactor`) | open |
| Afterlife scene tuning: the look and pacing of the return to the Rukh | `ReplicatedFirst.AfterLife` in Studio; `Config.Scene` (`WalkSeconds`, `FadeSeconds`, `MessageSeconds`) | open |
| SFX volume levels: `SwordClangSound1` is 3.0 and both BattleCry sounds 5.0, everything else 0.1 to 0.5; `Lullaby` and `WandFlick` have no SoundId | `ReplicatedFirst.SFX` in Studio | open |
| Dagger kit: import when M10 starts | `assets/dagger-kit-roblox.zip`, `docs/reference/dagger-kit.md` | open (M10) |
| Jewelry kit: import when M10 starts | `assets/jewelry-kit-roblox-r6.zip`, `docs/reference/jewelry-kit.md` | open (M10) |

# When Bryan is back at Studio (updated 2026-10-03)

**Rojo first:** the serve is up (port 34872, restart loop); press Connect in the plugin once.

## Playtest, in order (everything below was fixed 2026-10-02/03, see BUGS.md BUG-33..64)
1. **M5B shop:** A (racks: hover highlight + E prompt on the hovered rack), C (refusals before charging), D (hover only for you). When it passes, delete `Workspace.Qarzin.ClothesStand.ClothingSpawn` by hand.
2. **M5C delivery:** A (board colours/buttons, modifier chips in their own row, one description card), B (tracker at the real drop-off, FOV-proof, beacon pulse every 45 s), C (interceptor paid + coin sound), D (each modifier once: `.mission fail` or let Time Crunch run out), E (bad city), F (nothing left behind), G (intercepted mark clears on a completed delivery). Unbuilt cities have a magenta placeholder drop-off; `.tp <city>` reaches any city.
3. **M6 world:** A (`.region`, `.music stop|play|next|volume`, the bottom-left music panel), C (walk and run footsteps, no engine footstep sound), B after you tag lamps/torches/fires `CityLight`.
4. **Spot checks:** `.fresh` empties the purse GUI too; no overhead name/health on players; dash whoosh; Highly Valuable glow permanent on the package, courier pulses like everyone; Heavy Cargo pack bigger and dashes shorter; low health shortens walk, run AND dash; last life plays the whole Rukh scene (M3B-K).
5. **Open, needs a repro:** the desert dash fling (BUG-58) - note where you were and whether you were on a slope.

**Combat is shelved** (your call, 2026-10-03): don't playtest it; it gets redesigned from the top after everything else.

## After the playtests: M7 close-out, then the gameplay-loop talk, then M8
Fold InputHandler and the IntFold bridge into the new services; strip the rbxm-embedded scripts; your Studio deletions (clothes stocker, ServerStorage previous-game folder, R7/R8); then the gameplay-loop conversation (docs/ROADMAP.md section 4) before M8 talking NPCs and the tutorial.

---

# Older notes (2026-09-29)

In order. **Rojo first:** the serve is up on port 34872, but today's 5C merge deleted the old mission scripts, which makes Rojo 7.7.0 restart; check the Studio plugin shows connected and press Connect if not. Everything below is in `docs/PLAYTEST.md`; write your notes under each scenario the way you have been.

## Still owed from before today
1. ~~Join check~~ done 2026-09-28. ~~Milestone 4~~ done 2026-09-28.
2. **Combat playtest** ("M3B" A to K, then the older "M3 Combat" A to G for feel): first set the marker names per style in `Config.Combat.Markers` from one swing with `LogMarkers` on. Tune `Shared/Data/Combat.luau` as you go.
3. **Phase 5A currency** ("M5A" A to E): the band table with `.price`, exact-coin refusal with `.pay`, Copper-only rewards, the coin sound, a rejoin.
4. **Phase 5B shop** ("M5B" A to D): buy a hat, shirt, cloak; colours; full hat slots; the hover highlight only for you; nothing paid twice. When it passes, delete `Workspace.Qarzin.ClothesStand.ClothingSpawn` by hand.

## Built today (2026-09-29): Phase 5C delivery missions
5. **"M5C" A to G.** What changed and why, in plain words:
   - The delivery board, city panels, lore, modifiers, package, tracker and payouts are the same as before but rebuilt: the server now decides everything (route, modifiers, pay), so a client can no longer name any city or print money (AUDIT H7/H8), and the board's modifier buttons and start button work every time (M14).
   - **Failing a modifier never fails the run** (your rule): Time Crunch running out, a hit on a Fragile package, no knockout for Clear the Route just drop that bonus; the pop-out says "Failed." and the run continues. Only leaving, dying, respawning or being intercepted end a run.
   - **Highly Valuable** couriers are highlighted for everyone the whole run (no pulse). Everyone else gets the old beacon every 30 s for 3 s.
   - **Interception** pays the interceptor instantly (the run's worth just before the knocking blow), plus a Black Rukh and Bounty, exactly once. It only counts 100 studs or 30 s into the run (`Config.Missions.InterceptMin*`, tune if farmed).
   - **The intercepted mark** (your rule): each interception halves the victim's offers and payouts, floored at 10%; the interceptor of a marked courier gets the same reduced pay and no Black Rukh; one completed delivery clears it. The board shows "Merchants doubt you. Offers at 50% until you deliver." (reword in `MissionController`, see FOLLOWUPS).
   - Bonuses add together as in the old game (1.2 and 1.3 give 1.5). Veto in `docs/M5-PLAN.md` if you want a product instead.
   - Dev: `.mission start <city>`, `.mission finish`, `.mission fail`, `.mission streak <n>`, `.mission mark [n]`, `.mission intercept`, `.mission log on|off`. Scenario G is doable alone with `.mission intercept`.
   - Save schema is v4 (`Progress.DeliveryStreak`, `Progress.Routes`, `Progress.Intercepted`); old test saves migrate.

## Later
6. **Studio placements for M5 (later phases):** `Blacksmith` (Rathole, 5E), `BountyBoard` (each city, 5F). No money changer (Bank milestone later).
7. **Follow-ups you own** (`docs/FOLLOWUPS.md`, how-to in `docs/TINKER.md`): combat feel, marker names, stance animations, heartbeat sound, afterlife cutscene, viewport framing, NPC animations, NPC type attribute, Studio-only script deletions, the intercepted-notice wording.
## Also built today: Milestone 6, the world (merged)
8. **"M6" A to E** in `docs/PLAYTEST.md`. In plain words: regions and music are now detected by position on your own client with real crossfades; the world has a shared day clock (10 min day, 6 min night; `.time 18` to see dusk); lamps, torches and fires you tag `CityLight` (a part or a whole model) light at dusk and go out at dawn; footsteps and sand prints are local to you; the ocean has one client script that stays OFF until you run the TINKER.md snippet that deletes the 766 old wave scripts and then set `Config.World.Ocean.Enabled = true`; map collisions moved into a service and the old `Stats`/`OnCharacter` folders are gone for good. Numbers you may want to tune: `Config.World.Footsteps` (old-game volumes and the 0.75 s print fade are set) and the night look in `Shared/Data/DayNight.luau`.

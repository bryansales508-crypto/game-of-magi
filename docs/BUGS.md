# BUGS

Found during Phase 5 playtests. Lead logs them; IDs are used in commit messages (`BUG-01: ...`).

| ID | Found | Milestone | Severity | What | Status |
|---|---|---|---|---|---|
| BUG-01 | M1 playtest 1 (2026-09-27) | M1-05 | high | Dev panel was bound to **F9**, which Roblox reserves for its Developer Console, so the panel could never open. Lead's spec error. | fixed: panel moved to **backquote (`)**; F7 turned out reserved by the Studio input tool too (overlay stays F8) |
| BUG-02 | M1 playtest 1 | M1-05 | medium | Dev commands typed in chat (`.state`) could not be verified: the playtester's virtual keyboard can't open chat. The server listens on `Player.Chatted`, which should fire under TextChatService, but nobody has seen it work yet. | closed: Bryan confirmed chat commands work (2026-09-27) |
| BUG-03 | M1 playtest 1 | M1-03 (bridge) | info | A brand-new Studio save showed age 20 after ~220 s of play. Cause: the OLD AgeController still runs at its debug rate (`SECONDS_PER_YEAR = 30`). The bridge mirrors it correctly; not an M1 bug. Aging is rebuilt in M2. | noted |
| BUG-04 | M1 playtest 3 | M1-02 (Remotes) | low | Dropped-call warnings are throttled to one per player+remote per window, so after the "string too long" warning the wrong-type drop and 17 rate-limit drops in the same window logged nothing. Works as designed but hides information. | open: log a per-window summary ("dropped N more calls: reasons") when the window ends |
| BUG-05 | M1 playtest 3 | M1-05 / Backpack | low | The dev panel key (backquote) is also `ARROW_HOTKEY` in the old `BackpackGUI.client.luau:59`. No conflict seen. | open: goes away when the backpack is rebuilt (M2 #18); revisit if it bites |
| BUG-06 | M1 playtest 3 | World data | info | Only `QarzinSpawn` exists under `Workspace.MAP.Spawns`; `.tp rathole` correctly replies "no spawn". PLAYTEST.md changed to `.tp qarzin`. Other city spawns are M6 content. | noted |
| BUG-07 | M1 playtest 3 | World | info | Studio pathfinding can't route from the Qarzin spawn to the clothes-stand racks (~57 studs). Playtester tooling limitation for now; matters if NPC pathing ever crosses the market. | noted for M6 |

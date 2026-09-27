# BUGS

Found during Phase 5 playtests. Lead logs them; IDs are used in commit messages (`BUG-01: ...`).

| ID | Found | Milestone | Severity | What | Status |
|---|---|---|---|---|---|
| BUG-01 | M1 playtest 1 (2026-09-27) | M1-05 | high | Dev panel was bound to **F9**, which Roblox reserves for its Developer Console, so the panel could never open. Lead's spec error. | fixed: panel moved to **F7** (overlay stays F8) |
| BUG-02 | M1 playtest 1 | M1-05 | medium | Dev commands typed in chat (`.state`) could not be verified: the playtester's virtual keyboard can't open chat. The server listens on `Player.Chatted`, which should fire under TextChatService, but nobody has seen it work yet. | open: Bryan to type `.state` in chat once during play and report whether `[DevService]` logs it |
| BUG-03 | M1 playtest 1 | M1-03 (bridge) | info | A brand-new Studio save showed age 20 after ~220 s of play. Cause: the OLD AgeController still runs at its debug rate (`SECONDS_PER_YEAR = 30`). The bridge mirrors it correctly; not an M1 bug. Aging is rebuilt in M2. | noted |

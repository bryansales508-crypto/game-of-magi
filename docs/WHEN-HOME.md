# When Bryan is back at Studio (2026-09-27)

In order. Rojo: check the plugin shows connected first (the server is up; press Connect if not).

1. **Join check (BUG-27, blocks everything else):** Play, let the loading screen fade, `.state`. `joinState` must be `Ready`. If it says `Loaded` and you're naked with no creation screen, paste every Output line mentioning `ClientReady`, `Remotes` or `LoadController`.
2. **Milestone 4 pass** (`docs/PLAYTEST.md`, section "M4 Status and Rukh"): A origin at birth, B rank-up card, C pending choice across a rejoin, D alignment flutters, E rank down and clear. Notes here or in the file.
3. **Milestone 3 feel pass** whenever you want (`docs/PLAYTEST.md`, "M3 Combat", A to G). Tune `Shared/Data/Combat.luau` as you go; `.combat log on` prints each decision. Set `NpcType = Target` on one dummy first.
4. **Approve or edit the Milestone 5 plan** (`docs/M5-PLAN.md`): eight numbered decisions, each changeable.
5. **Studio placements for M5:** parts named `MoneyChanger` (each city), `BountyBoard` (each city), `Blacksmith` (Rathole).
6. **Follow-ups you own** (`docs/FOLLOWUPS.md`, how-to in `docs/TINKER.md`): combat feel, heartbeat sound, afterlife cutscene, viewport framing, NPC animations, NPC type attribute, Studio-only script deletions.

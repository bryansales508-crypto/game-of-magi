# Game of Magi — Lead Agent Instructions (Renovation Mode)

> **If you are a subagent** (server-builder, client-builder, reviewer, playtester), including one running in the cloud: follow **your own agent file** in `.claude/agents/`. The lead sections below are not your job. The Renovation rules at the bottom still apply to you.

You lead a small team working on **an existing Roblox game Bryan built himself**: a desert/Arabian-themed RPG. This is a renovation, not a new build. Your first job is to understand what exists, then diagnose it, then help Bryan decide what to keep, fix, rewrite, or remove. Only then does building start.

Read this file at the start of every session, then `docs/TASKS.md` to see which phase you're in.

## Who's who
- **Bryan** wrote this game. He approves every phase gate and every keep/fix/rewrite/remove decision. He wants to understand his own code, so every report you give him includes a short plain-language summary of what changed and why. Ask him at most one question at a time.
- **You (lead)** plan, dispatch subagents, keep the docs current, and are the only one who talks to Bryan. You log every bug and audit finding yourself; other agents report to you.
- **Subagents** (in `.claude/agents/`): `server-builder`, `client-builder`, `reviewer`, `playtester`. The playtester is the ONLY agent that uses Roblox Studio tools.

## How the team talks
Through shared files you keep current:
- `docs/TASKS.md`: the current phase, tasks, owners, statuses, acceptance criteria.
- `docs/SYSTEMS.md`: the map of every existing system (Phase 2).
- `docs/AUDIT.md`: diagnosis findings ranked by severity (Phase 3).
- `docs/TRIAGE.md`: the keep / fix / rewrite / remove list (Phase 4).
- `docs/BUGS.md`: bugs found during building (Phase 5).
- `docs/DESIGN.md`: where Bryan wants the game to go. Bryan provides this.

## The phases (never skip ahead; stop at every gate for Bryan's OK)

### Phase 1: Inventory and extract
1. Dispatch `playtester` to inventory the place in Studio, **read-only**: list every Script, LocalScript, and ModuleScript with its full path, and note which top-level containers hold scripts. Flag any scripts living inside Workspace models or other non-standard places.
2. Using that inventory, write `default.project.json` so Rojo covers **only the containers that hold code**. Never include Workspace, and never include containers that hold only models, maps, or assets. Scripts found inside Workspace models get listed in `docs/SYSTEMS.md` as "not synced" instead.
3. Show Bryan the inventory and the project file, then tell him to run syncback on a file snapshot of the place.
4. After syncback, confirm the file count matches the inventory, then commit.
**Gate:** Bryan confirms every script made it into `src/`.

### Phase 2: Understand (read-only, no code changes)
Read every script. Write `docs/SYSTEMS.md`: for each system, say what it does in plain language, its files, what it depends on and what depends on it, the RemoteEvents/RemoteFunctions it uses, any DataStore keys and data shapes, and any admin or dev commands. End with a simple dependency list showing how systems connect.
**Gate:** Bryan reads SYSTEMS.md and corrects anything you misunderstood.

### Phase 3: Diagnose
- Dispatch `reviewer` for a full audit: security, bugs, race conditions, memory leaks, dead code, performance, and fragile patterns.
- Dispatch `playtester` to run the game, try each system, and report every Output error and warning.
- Write findings to `docs/AUDIT.md`, each with an ID, severity (critical / high / medium / low), system, file and line, what's wrong, and a plain-language explanation.
**Gate:** Bryan reviews the audit.

### Phase 4: Triage
Write `docs/TRIAGE.md`: one line per system with a recommendation (**keep**, **fix**, **rewrite**, or **remove**) and a one-sentence reason tied to AUDIT.md and DESIGN.md. Default to **keep** or **fix**. Recommend rewrite only when fixing costs more than rebuilding, and say why.
**Gate:** Bryan approves, vetoes, or changes every line. His approved TRIAGE.md becomes the milestones in TASKS.md.

### Phase 5: Build
The same loop as always: plan → build (server and client builders in parallel) → review → test → commit (`git commit -m "<task ID>: <summary>"`) → stop at each milestone gate for Bryan's approval. If the same bug fails three fix attempts, stop and ask Bryan.

**Cloud workflow** (builders and reviewer run on Claude cloud machines, on cheaper models; the lead and playtester stay local). **Dispatch with `claude --cloud` sessions only**: write the prompt to `.claude/cloud-prompts/<task>.txt`, commit and push, then run `bash scripts/cloud-launch.sh <TASK-ID>` (it starts `launch.ps1` in a new console, because `claude --cloud` needs a real terminal, and prints the session link plus the GitHub check). This uses Bryan's cloud-session credit. **Never use routines** (RemoteTrigger), which bill Bryan's plan, and **never** the Agent tool's `isolation: "remote"`, which silently runs locally. Cloud sessions need the Claude GitHub App to have access to this repo; otherwise they can't clone or push. Builders make their last commit start with `DONE <TASK-ID>:`.
1. The lead pushes `main` to `origin`, then dispatches each builder in the cloud with a task ID, the **exact files it owns**. The cloud names each session's branch itself (for example `claude/m1-01-folder-layout-qf1ju2`), so work is tracked by the `DONE <TASK-ID>:` commit, not by branch name. Two builders never own the same file at the same time.
2. The builder works only on the branch its session starts on, commits with `<TASK-ID>: <summary>` (last commit `DONE <TASK-ID>: ...`), pushes that branch, and reports. It never merges and never pushes `main`. The lead finds it by running `bash scripts/watch-done.sh <TASK-ID> [...]` under the **Monitor tool**, which notifies on each DONE line (a background Bash only notifies when the script exits, i.e. after the last task); it scans every branch for the DONE commit; use `ID@oldsha` after a follow-up). Prompts may contain double quotes; `launch.ps1` escapes them (Windows PowerShell 5.1 otherwise mangles the prompt). Follow-ups: `claude -p "<msg>" --cloud <session_id> < /dev/null`.
3. The reviewer (cloud, **Opus** for big or risky tasks: `bash scripts/cloud-launch.sh <REVIEW-ID> opus`; Sonnet is fine for small ones) reviews `git diff main...<branch>` and gives a verdict of PASS or CHANGES NEEDED. Small, mechanical tasks may be reviewed by the lead directly.
4. The lead pulls the branch locally, merges it into `main` (one branch at a time), pushes `main`, and Rojo syncs to Studio. The playtester then tests.
5. Cloud agents have no Studio, no Rojo serve, and no files outside the repo. Anything needing those comes back to the lead.

## Renovation rules
- **Build it right, keep the look** (Bryan's rule, 2026-09-26). Treat this as fixing up a run-down house from the owner's picture of it. Bryan's code style, naming, and structure do **not** need to be kept: use the cleanest, most efficient modern Roblox architecture. Keep his **aesthetic**: art, UI look, animations, sounds, names of places, people and items, and game feel.
- **Every change still traces back** to an AUDIT finding, a TRIAGE decision, or DESIGN.md, and Bryan approves the plan before building.
- **Nothing is deleted without approval.** Any removal must be on the approved TRIAGE list.
- **Saving:** there is no real player data, so DataStore formats may change. Every change to a save format must be written up in SYSTEMS.md, and existing handlers (such as versioned age data) must be updated consistently.
- **The server never trusts the client.** Every remote is validated on the server. Admin and dev commands must check permissions on the server.
- **Files first, Studio second.** Builders only edit files. Only the playtester touches Studio, and it never edits code.
- **Never** publish the game. **Pushing is allowed only to Bryan's private GitHub repo** (`origin`, Bryan's rule, 2026-09-26). Never force-push, and never push `main` from the cloud; only the lead merges into `main`.
- **Working on the published place is allowed** (Bryan's rule, 2026-09-26). Studio keeps version history for the published game and Bryan can revert it himself, so the playtester may playtest the published place opened in Studio, and Rojo may sync into it. Play tests there may read and write the live DataStore; that is fine. Studio stays open on the published place, not on a local copy. Publishing is still Bryan's call alone.

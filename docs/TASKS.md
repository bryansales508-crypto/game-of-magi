# Task board

Current phase: **Phase 3: Diagnose** (see CLAUDE.md for all phases)

## Phase 1: Inventory and extract (done, gate passed 2026-09-26)

| ID | Task | Owner | Status | Acceptance criteria |
| --- | --- | --- | --- | --- |
| P1-01 | Inventory every script in the place (read-only) | playtester | done | Full path and class of every Script, LocalScript, and ModuleScript; scripts in Workspace flagged |
| P1-02 | Write default.project.json covering only code containers | lead | done | No Workspace; no asset-only containers; every inventoried script covered or listed as "not synced" |
| P1-03 | Bryan runs syncback on the copy; verify and commit | lead | done | File count in src/ matches the inventory (68 .luau + 10 inside .rbxm) |

## Phase 2: Understand (done, gate passed 2026-09-26)

| ID | Task | Owner | Status | Acceptance criteria |
| --- | --- | --- | --- | --- |
| P2-01 | Read the Studio-only scripts (10 inside .rbxm, plus the not-synced scripts that run) | playtester | done | Plain summary of each: what it does, remotes, requires, DataStores |
| P2-02 | Read every script in src/ | lead | done | Every .luau file read |
| P2-03 | Write docs/SYSTEMS.md | lead | done | Per system: purpose, files, depends on / depended on by, remotes, DataStore keys and data shapes, admin/dev commands; ends with a dependency list |

## Phase 3: Diagnose

Bryan's direction: judge each system by what it was **meant** to do (comments, Trello board, DESIGN.md), not just what the code does now.

| ID | Task | Owner | Status | Acceptance criteria |
| --- | --- | --- | --- | --- |
| P3-01 | Full code audit: security, bugs, race conditions, leaks, dead code, performance, fragile patterns | reviewer | done | Every finding has file, line, severity, what's wrong, plain explanation |
| P3-02 | Playtest every system and capture every Output error and warning | playtester | partial (stopped early; Bryan confirming the rest) | Each system in SYSTEMS.md tried; every error/warning reported with repro steps |
| P3-03 | Write docs/AUDIT.md | lead | waiting on Bryan | Findings with ID, severity, system, file:line, what's wrong, plain explanation |

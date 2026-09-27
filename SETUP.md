# Renovation setup

## Phase 0: Protect the original (do this first)
1. Open your RPG in Studio and use **File → Save to File As** to save a copy, for example `sindria-copy.rbxl`, inside this project folder. The agents only ever touch this copy.
2. Copy `rojo.exe` into this folder.
3. In a terminal here:
   ```
   git init
   git add -A
   git commit -m "Renovation kit"
   ```
4. Close the original place. Open **sindria-copy.rbxl** in Studio.

## Connect Claude Code
In **Command Prompt** in this folder (Studio is already registered from The Grave War, but it's per-project):
```
claude mcp add Roblox_Studio -- cmd.exe /c %LOCALAPPDATA%\Roblox\mcp.bat
```
Then run `claude` and check `/mcp`.

**Don't run `rojo serve` yet.** Until the project file is written, Rojo could overwrite scripts in the copy.

## First message to the lead
> Read CLAUDE.md. Add the Studio tool names to playtester's tools line, commit, then start Phase 1: inventory the place and draft default.project.json. Show me both before I run syncback.

## When the lead says it's time for syncback
1. In Studio, **save** the copy (Ctrl+S).
2. In the terminal:
   ```
   .\rojo syncback default.project.json --input sindria-copy.rbxl
   ```
3. Tell the lead "syncback done."

After Phase 1 passes, `rojo serve` and **Connect** work the same as in The Grave War.

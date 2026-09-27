#!/usr/bin/env bash
# Starts a cloud builder session for a task whose prompt is in .claude/cloud-prompts/<TASK>.txt.
# Opens a new console (claude --cloud needs a real terminal), then prints the session link and
# whether the session cloned from GitHub ("GitHub app is installed") or fell back to a bundle.
#
# Usage: scripts/cloud-launch.sh M1-03 [model]      (model defaults to sonnet)
# Then:  scripts/watch-done.sh M1-03                (in the background)

set -u
task="${1:?usage: scripts/cloud-launch.sh <TASK> [model]}"
model="${2:-sonnet}"
dir='C:\Users\bryan\Documents\game-of-magi\.claude\cloud-prompts'
here="$(cd "$(dirname "$0")/.." && pwd)/.claude/cloud-prompts"

[ -f "$here/$task.txt" ] || { echo "missing prompt: $here/$task.txt"; exit 1; }
rm -f "$here/$task.log" "$here/$task-debug.log"

powershell -NoProfile -Command "Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$dir\\launch.ps1','$dir\\$task.txt','$dir\\$task.log','$dir\\$task-debug.log','$model'"

for _ in $(seq 1 40); do
	grep -q "View:" "$here/$task.log" 2>/dev/null && break
	sleep 3
done
github=$(grep -o 'GitHub app is[^(]*\|Bundling[^)]*)' "$here/$task-debug.log" 2>/dev/null | head -1)
link=$(grep -o 'https://claude.ai/code/session_[A-Za-z0-9]*' "$here/$task.log" 2>/dev/null)
echo "$task: ${github:-no GitHub line yet} | ${link:-NO SESSION LINK (check the console window)}"

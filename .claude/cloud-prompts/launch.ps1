# Starts a Claude Code cloud session (uses the cloud-session credit, not the plan) from a prompt file.
# claude --cloud needs a real terminal, so the lead starts this in a new console:
#   powershell Start-Process powershell -ArgumentList '-File','.claude\cloud-prompts\launch.ps1','<prompt-file>','<log-file>'
# The log file shows the session link. Pass a DebugFile to confirm the session cloned from GitHub
# (look for "GitHub app is installed", not "Bundling (reason: github_preflight_failed)").
param([string]$PromptFile, [string]$LogFile, [string]$DebugFile = "", [string]$Model = "sonnet")
Set-Location "C:\Users\bryan\Documents\game-of-magi"
$prompt = Get-Content -Raw $PromptFile
Start-Transcript -Path $LogFile -Force | Out-Null
if ($DebugFile -ne "") {
	claude --cloud $prompt --model $Model --debug-file $DebugFile
} else {
	claude --cloud $prompt --model $Model
}
Stop-Transcript | Out-Null

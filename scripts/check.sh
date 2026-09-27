#!/usr/bin/env bash
# Checks the new (renovated) code with selene and luau-lsp, using a Rojo
# sourcemap so luau-lsp knows the real Roblox instance types (e.g. that
# script.Parent.Config is a ModuleScript, not a generic Instance).
#
# First run downloads pinned selene, luau-lsp and rojo Linux binaries into
# ~/tools/bin (skipped if already present). Versions are pinned on purpose:
# no GitHub API "latest" lookups, so a run never silently picks up a newer
# tool with different behavior. Bump the *_VERSION values below on purpose,
# not by accident.
#
# Only the new code is checked; the rest of the game is still being
# rebuilt and isn't held to this yet:
#   - src/ServerScriptService/Server
#   - src/StarterPlayer/StarterPlayerScripts/Client
#   - src/ReplicatedStorage/Shared
#
# luau-lsp analyze also ignores two paths that sit inside those targets (or
# get required by something inside them) but aren't "the new code" either:
# Server/Packages (vendored third-party libraries; --!nocheck at the top of
# each one already opts out, but its own diagnostics still leak into
# `analyze`'s file list otherwise) and ReplicatedFirst/Assets (Bryan's old
# game-data module, pulled in transitively by Shared/SaveSchema.luau; its
# pre-existing type errors belong to its own M2 rebuild, not this check).
# selene doesn't need the same treatment: its lints are silenced inline
# with `-- selene: allow(...)` in Packages, and it never analyzes Assets at
# all since nothing in TARGETS requires it in a way selene follows.
#
# Usage: scripts/check.sh

set -euo pipefail
cd "$(dirname "$0")/.."

SELENE_VERSION="0.29.0"
LUAU_LSP_VERSION="1.54.0"
ROJO_VERSION="7.5.1"

TOOLS_DIR="$HOME/tools/bin"
mkdir -p "$TOOLS_DIR"
export PATH="$TOOLS_DIR:$PATH"

log() { echo "[check.sh] $*" >&2; }

# Downloads $1 to $2, or aborts immediately (set -e + curl -f) with a clear
# error naming the URL, instead of unzipping a 403/404 error page.
fetch() {
	log "downloading $1"
	curl -fsSL "$1" -o "$2"
}

install_selene() {
	if [ -x "$TOOLS_DIR/selene" ]; then return; fi
	local zip
	zip="$(mktemp)"
	fetch "https://github.com/Kampfkarren/selene/releases/download/${SELENE_VERSION}/selene-${SELENE_VERSION}-linux.zip" "$zip"
	unzip -o -q "$zip" -d "$TOOLS_DIR"
	chmod +x "$TOOLS_DIR/selene"
	rm -f "$zip"
}

install_luau_lsp() {
	if [ -x "$TOOLS_DIR/luau-lsp" ]; then return; fi
	local zip
	zip="$(mktemp)"
	fetch "https://github.com/JohnnyMorganz/luau-lsp/releases/download/${LUAU_LSP_VERSION}/luau-lsp-linux-x86_64.zip" "$zip"
	unzip -o -q "$zip" -d "$TOOLS_DIR"
	chmod +x "$TOOLS_DIR/luau-lsp"
	rm -f "$zip"
	# Not a release asset: the type definitions ship as a file in the repo,
	# tagged in lockstep with each luau-lsp release.
	fetch "https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/${LUAU_LSP_VERSION}/scripts/globalTypes.d.luau" "$TOOLS_DIR/globalTypes.d.luau"
}

install_rojo() {
	if [ -x "$TOOLS_DIR/rojo" ]; then return; fi
	local zip
	zip="$(mktemp)"
	fetch "https://github.com/rojo-rbx/rojo/releases/download/v${ROJO_VERSION}/rojo-${ROJO_VERSION}-linux-x86_64.zip" "$zip"
	unzip -o -q "$zip" -d "$TOOLS_DIR"
	chmod +x "$TOOLS_DIR/rojo"
	rm -f "$zip"
}

install_selene
install_luau_lsp
install_rojo

# selene.toml sets std = "roblox"; selene fetches and caches the Roblox API
# dump itself (into its OS cache dir) the first time it needs it.

SOURCEMAP="sourcemap.json"
log "generating Rojo sourcemap"
rojo sourcemap default.project.json -o "$SOURCEMAP"

TARGETS=(
	"src/ServerScriptService/Server"
	"src/StarterPlayer/StarterPlayerScripts/Client"
	"src/ReplicatedStorage/Shared"
)

echo
echo "== selene =="
selene_raw="$(mktemp)"
selene_exit=0
selene "${TARGETS[@]}" > "$selene_raw" 2>&1 || selene_exit=$?
cat "$selene_raw"
selene_errors="$(grep -c '^error\[' "$selene_raw" || true)"
rm -f "$selene_raw"

echo
echo "== luau-lsp analyze =="
# luau-lsp reports each diagnostic once for the file's disk path and once
# for its sourcemap (instance) path; dedupe lines so a single real error
# isn't misread as two.
luau_lsp_raw="$(mktemp)"
luau_lsp_deduped="$(mktemp)"
luau_lsp_exit=0
luau-lsp analyze \
	--sourcemap="$SOURCEMAP" \
	--defs="$TOOLS_DIR/globalTypes.d.luau" \
	--ignore="**/Server/Packages/**" \
	--ignore="**/ReplicatedFirst/Assets/**" \
	"${TARGETS[@]}" > "$luau_lsp_raw" 2>&1 || luau_lsp_exit=$?
# Normalize away the absolute-vs-relative path and the optional
# "[game/Instance/Path]" sourcemap annotation before deduping, since the
# same diagnostic is otherwise printed once per addressing mode.
awk -v repo="$(pwd)/" '{
	line = $0
	gsub(repo, "", line)
	gsub(/ \[[^]]*\]/, "", line)
	if (!seen[line]++) print line
}' "$luau_lsp_raw" > "$luau_lsp_deduped"
cat "$luau_lsp_deduped"
# luau-lsp analyze prints nothing but one line per diagnostic (no header,
# no summary), so a line count is an error count.
luau_lsp_errors="$(grep -c '.' "$luau_lsp_deduped" || true)"
rm -f "$luau_lsp_raw" "$luau_lsp_deduped"

echo
log "selene: $selene_errors error(s) (exit=$selene_exit)"
log "luau-lsp: $luau_lsp_errors error(s) (exit=$luau_lsp_exit)"

if [ "$selene_exit" -eq 0 ] && [ "$luau_lsp_exit" -eq 0 ]; then
	log "PASS"
	exit 0
else
	log "FAIL"
	exit 1
fi

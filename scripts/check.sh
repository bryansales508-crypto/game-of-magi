#!/usr/bin/env bash
# Checks the new (renovated) code with selene and luau-lsp, using a Rojo
# sourcemap so luau-lsp knows the real Roblox instance types (e.g. that
# script.Parent.Config is a ModuleScript, not a generic Instance).
#
# First run downloads selene, luau-lsp and rojo (7.x) Linux binaries into
# ~/tools/bin (skipped if already present).
#
# Only the new code is checked; the rest of the game is still being
# rebuilt and isn't held to this yet:
#   - src/ServerScriptService/Server
#   - src/StarterPlayer/StarterPlayerScripts/Client
#   - src/ReplicatedStorage/Shared
#
# Usage: scripts/check.sh

set -uo pipefail
cd "$(dirname "$0")/.."

TOOLS_DIR="$HOME/tools/bin"
mkdir -p "$TOOLS_DIR"
export PATH="$TOOLS_DIR:$PATH"

log() { echo "[check.sh] $*" >&2; }

# Resolves the latest release tag for a GitHub repo (e.g. "Kampfkarren/selene").
latest_tag() {
	curl -fsSL "https://api.github.com/repos/$1/releases/latest" | jq -r '.tag_name'
}

# Resolves the latest release tag matching a prefix (e.g. rojo's 7.x line),
# so a future 8.x release doesn't silently get picked up here.
latest_tag_matching() {
	curl -fsSL "https://api.github.com/repos/$1/releases" | jq -r --arg p "$2" '[.[] | select(.tag_name | startswith($p))][0].tag_name'
}

fetch() {
	log "downloading $1"
	curl -fsSL "$1" -o "$2"
}

install_selene() {
	if [ -x "$TOOLS_DIR/selene" ]; then return; fi
	local tag zip
	tag="$(latest_tag Kampfkarren/selene)"
	zip="$(mktemp)"
	fetch "https://github.com/Kampfkarren/selene/releases/download/${tag}/selene-linux.zip" "$zip"
	unzip -o -q "$zip" -d "$TOOLS_DIR"
	chmod +x "$TOOLS_DIR/selene"
	rm -f "$zip"
}

install_luau_lsp() {
	if [ -x "$TOOLS_DIR/luau-lsp" ]; then return; fi
	local tag zip
	tag="$(latest_tag JohnnyMorganz/luau-lsp)"
	zip="$(mktemp)"
	fetch "https://github.com/JohnnyMorganz/luau-lsp/releases/download/${tag}/luau-lsp-linux.zip" "$zip"
	unzip -o -q "$zip" -d "$TOOLS_DIR"
	chmod +x "$TOOLS_DIR/luau-lsp"
	rm -f "$zip"
	fetch "https://github.com/JohnnyMorganz/luau-lsp/releases/download/${tag}/globalTypes.d.lua" "$TOOLS_DIR/globalTypes.d.lua"
}

install_rojo() {
	if [ -x "$TOOLS_DIR/rojo" ]; then return; fi
	local tag version zip
	tag="$(latest_tag_matching rojo-rbx/rojo v7.)"
	version="${tag#v}"
	zip="$(mktemp)"
	fetch "https://github.com/rojo-rbx/rojo/releases/download/${tag}/rojo-${version}-linux-x86_64.zip" "$zip"
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
selene "${TARGETS[@]}"
selene_exit=$?

echo
echo "== luau-lsp analyze =="
luau-lsp analyze \
	--sourcemap="$SOURCEMAP" \
	--defs="$TOOLS_DIR/globalTypes.d.lua" \
	"${TARGETS[@]}"
luau_lsp_exit=$?

echo
if [ "$selene_exit" -eq 0 ] && [ "$luau_lsp_exit" -eq 0 ]; then
	log "PASS: selene exit=$selene_exit, luau-lsp exit=$luau_lsp_exit"
	exit 0
else
	log "FAIL: selene exit=$selene_exit, luau-lsp exit=$luau_lsp_exit"
	exit 1
fi

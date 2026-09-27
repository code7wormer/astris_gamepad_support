#!/bin/bash
# Launch Azahar with raw-HID Ares-to-keyboard translation.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRANSLATOR_BIN="$DIR/.build/debug/AresTranslator"
TRANSLATOR_LOG="/tmp/astris-ares-translator.log"
AZAHAR_APP="${AZAHAR_APP:-/Applications/Azahar.app}"
AZAHAR_BIN="$AZAHAR_APP/Contents/MacOS/azahar"

fail() { echo "[Ares Azahar launcher] Error: $*" >&2; exit 1; }
require_tool() { command -v "$1" >/dev/null || fail "'$1' is required. Install Xcode Command Line Tools with: xcode-select --install"; }

[ -x "$AZAHAR_BIN" ] || fail "Azahar was not found at '$AZAHAR_APP'. Set AZAHAR_APP to its .app path and run again."
if pgrep -x azahar >/dev/null; then
    fail "Azahar is already open. Quit it first, then relaunch through this script so the controller bridge can load."
fi
if pgrep -x Astris >/dev/null; then
    fail "Astris is open and already owns the Ares bridge. Quit Astris before launching Azahar with controller support."
fi

require_tool swift
if [ ! -x "$TRANSLATOR_BIN" ] || [ "$DIR/Sources/AresTranslator/main.swift" -nt "$TRANSLATOR_BIN" ]; then
    echo "[Ares Azahar launcher] Building controller helper..."
    (cd "$DIR" && swift build --target AresTranslator)
fi

for helper_pid in $(pgrep -x AresTranslator || true); do
    helper_command="$(ps -o command= -p "$helper_pid" 2>/dev/null || true)"
    echo "[Ares Azahar launcher] Restarting controller helper in Azahar keyboard mode (PID $helper_pid)..."
    kill "$helper_pid" 2>/dev/null || true
done
sleep 0.2

echo "[Ares Azahar launcher] Starting controller helper..."
ARES_AZAHAR_KEYBOARD=1 "$TRANSLATOR_BIN" >"$TRANSLATOR_LOG" 2>&1 &
sleep 0.5
pgrep -x AresTranslator >/dev/null || fail "The controller helper did not start. See $TRANSLATOR_LOG"

echo "[Ares Azahar launcher] Launching Azahar.app with Ares keyboard controls..."
open -n "$AZAHAR_APP" --args "$@"

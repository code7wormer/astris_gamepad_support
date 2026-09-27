#!/bin/bash
# Launch Azahar with the Cosmic Byte Ares GameController bridge.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_SOURCE="$DIR/bridge/AresGCBridge.m"
BRIDGE_DYLIB="$DIR/bridge/libAresGCBridge.dylib"
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

require_tool clang
require_tool swift
if [ ! -f "$BRIDGE_DYLIB" ] || [ "$BRIDGE_SOURCE" -nt "$BRIDGE_DYLIB" ]; then
    echo "[Ares Azahar launcher] Building controller bridge..."
    clang -dynamiclib -O2 -fobjc-arc -framework Foundation -framework GameController -framework IOKit \
        -o "$BRIDGE_DYLIB" "$BRIDGE_SOURCE"
fi
if [ ! -x "$TRANSLATOR_BIN" ] || [ "$DIR/Sources/AresTranslator/main.swift" -nt "$TRANSLATOR_BIN" ]; then
    echo "[Ares Azahar launcher] Building controller helper..."
    (cd "$DIR" && swift build --target AresTranslator)
fi

CURRENT_HELPER_RUNNING=false
for helper_pid in $(pgrep -x AresTranslator || true); do
    helper_command="$(ps -o command= -p "$helper_pid" 2>/dev/null || true)"
    if [[ "$helper_command" == "$TRANSLATOR_BIN"* ]]; then
        CURRENT_HELPER_RUNNING=true
    else
        echo "[Ares Azahar launcher] Stopping stale controller helper (PID $helper_pid)..."
        kill "$helper_pid" 2>/dev/null || true
    fi
done
sleep 0.2

if [ "$CURRENT_HELPER_RUNNING" = false ]; then
    echo "[Ares Azahar launcher] Starting controller helper..."
    "$TRANSLATOR_BIN" >"$TRANSLATOR_LOG" 2>&1 &
    sleep 0.5
    pgrep -x AresTranslator >/dev/null || fail "The controller helper did not start. See $TRANSLATOR_LOG"
fi

echo "[Ares Azahar launcher] Launching Azahar.app with Ares controller support..."
# LaunchServices preserves Azahar's normal app-bundle environment (camera,
# documents, and sandbox paths). `open --env` passes the bridge only to this
# new instance, avoiding Azahar's direct-executable warning.
open -n --env "DYLD_INSERT_LIBRARIES=$BRIDGE_DYLIB" --env "ARES_DEBUG=${ARES_DEBUG:-0}" \
    --stdout /tmp/azahar-ares-bridge.log --stderr /tmp/azahar-ares-bridge.log \
    "$AZAHAR_APP" --args "$@"

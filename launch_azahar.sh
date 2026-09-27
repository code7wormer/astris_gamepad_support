#!/bin/bash
# Launch Azahar with raw-HID Ares-to-keyboard translation.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRANSLATOR_BIN="$DIR/.build/debug/AresTranslator"
TRANSLATOR_LOG="/tmp/astris-ares-translator.log"
TRANSLATOR_SERVICE="com.code7wormer.astris-gamepad.azahar"
AZAHAR_APP="${AZAHAR_APP:-/Applications/Azahar.app}"
AZAHAR_BIN="$AZAHAR_APP/Contents/MacOS/azahar"

fail() { echo "[Ares Azahar launcher] Error: $*" >&2; exit 1; }
require_tool() { command -v "$1" >/dev/null || fail "'$1' is required. Install Xcode Command Line Tools with: xcode-select --install"; }

helper_started=0
cleanup() {
    if [ "$helper_started" -eq 1 ]; then
        echo "[Ares Azahar launcher] Stopping controller helper..."
        launchctl bootout "gui/$(id -u)/$TRANSLATOR_SERVICE" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM

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
    echo "[Ares Azahar launcher] Restarting controller helper in Azahar keyboard mode (PID $helper_pid)..."
    kill "$helper_pid" 2>/dev/null || true
done
sleep 0.2

echo "[Ares Azahar launcher] Starting persistent controller helper..."
# Run under launchd so the helper is reliable while the launcher waits for
# Azahar. The EXIT trap below always unloads it when Azahar or this launcher exits.
launchctl bootout "gui/$(id -u)/$TRANSLATOR_SERVICE" 2>/dev/null || true
launchctl submit -l "$TRANSLATOR_SERVICE" \
    -o "$TRANSLATOR_LOG" -e "$TRANSLATOR_LOG" -- \
    /usr/bin/env ARES_AZAHAR_KEYBOARD=1 "$TRANSLATOR_BIN"
sleep 0.5
launchctl print "gui/$(id -u)/$TRANSLATOR_SERVICE" >/dev/null 2>&1 || \
    fail "The controller helper service did not start. See $TRANSLATOR_LOG"
helper_started=1

# A Swift rebuild can make macOS treat the helper as a newly authorized
# executable. Stop here with an actionable error rather than opening Azahar
# without usable controller input.
sleep 0.5
if grep -q 'NOT GRANTED / DENIED' "$TRANSLATOR_LOG"; then
    fail "macOS denied AresTranslator Input Monitoring or Accessibility. Enable the current AresTranslator entry in both Privacy & Security panes, then launch again."
fi

echo "[Ares Azahar launcher] Launching Azahar.app with Ares keyboard controls..."
open -n "$AZAHAR_APP" --args "$@"

# Keep this launcher alive while Azahar is open. Its EXIT trap also cleans up
# the service if this Terminal window is closed early.
for _ in {1..50}; do
    pgrep -x azahar >/dev/null && break
    sleep 0.1
done
pgrep -x azahar >/dev/null || fail "Azahar did not launch."
echo "[Ares Azahar launcher] Azahar is running. Closing Azahar or this Terminal window stops the helper."
while pgrep -x azahar >/dev/null; do
    sleep 1
done

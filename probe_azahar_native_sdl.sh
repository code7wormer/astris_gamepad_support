#!/bin/bash
# Report the physical Ares GUID as seen by Azahar's bundled SDL.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_SOURCE="$DIR/bridge/AresGCBridge.m"
BRIDGE_DYLIB="$DIR/bridge/libAresGCBridge.dylib"
AZAHAR_APP="${AZAHAR_APP:-/Applications/Azahar.app}"
AZAHAR_BIN="$AZAHAR_APP/Contents/MacOS/azahar"
LOG="/tmp/azahar-native-sdl-probe.log"

[ -x "$AZAHAR_BIN" ] || { echo "Azahar is not installed at $AZAHAR_APP" >&2; exit 1; }
if pgrep -x azahar >/dev/null; then
    echo "Quit Azahar before running this probe." >&2
    exit 1
fi
if [ ! -f "$BRIDGE_DYLIB" ] || [ "$BRIDGE_SOURCE" -nt "$BRIDGE_DYLIB" ]; then
    clang -dynamiclib -O2 -fobjc-arc -framework Foundation -framework GameController \
        -o "$BRIDGE_DYLIB" "$BRIDGE_SOURCE"
fi

echo "Opening Azahar briefly to identify its native SDL controller..."
open -n --env "DYLD_INSERT_LIBRARIES=$BRIDGE_DYLIB" --env "ARES_DEBUG=1" \
    --env "ARES_SDL_PROBE_ONLY=1" --stdout "$LOG" --stderr "$LOG" "$AZAHAR_APP"
echo "Wait three seconds, then run: grep 'SDL joystick' $LOG"

#!/bin/bash
# Launch Astris with the Cosmic Byte Ares GameController bridge.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_SOURCE="$DIR/bridge/AresGCBridge.m"
BRIDGE_DYLIB="$DIR/bridge/libAresGCBridge.dylib"
TRANSLATOR_BIN="$DIR/.build/debug/AresTranslator"
TRANSLATOR_LOG="/tmp/astris-ares-translator.log"
ASTRIS_APP="${ASTRIS_APP:-/Applications/Astris.app}"
ASTRIS_BIN="$ASTRIS_APP/Contents/MacOS/Astris"

fail() { echo "[Ares launcher] Error: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: ./launch_astris.sh [--diagnose | --stop | Astris options]

  --diagnose  Check Astris compatibility and show the helper log location.
  --stop      Stop the AresTranslator helper (Astris is left open).
EOF
}

require_tool() { command -v "$1" >/dev/null || fail "'$1' is required. Install Xcode Command Line Tools with: xcode-select --install"; }

check_astris() {
    [ -x "$ASTRIS_BIN" ] || fail "Astris was not found at '$ASTRIS_APP'. Set ASTRIS_APP to its .app path and run again."

    local entitlements
    entitlements="$(codesign -d --entitlements :- "$ASTRIS_APP" 2>&1 || true)"
    if ! grep -q 'com.apple.security.cs.allow-dyld-environment-variables' <<<"$entitlements" || \
       ! grep -q 'com.apple.security.cs.disable-library-validation' <<<"$entitlements"; then
        fail "This Astris version does not permit the required controller bridge injection. Its update changed the signing entitlements; do not launch it with this bridge."
    fi
}

build_components() {
    require_tool clang
    require_tool swift
    if [ ! -f "$BRIDGE_DYLIB" ] || [ "$BRIDGE_SOURCE" -nt "$BRIDGE_DYLIB" ]; then
        echo "[Ares launcher] Building controller bridge..."
        clang -dynamiclib -O2 -fobjc-arc -framework Foundation -framework GameController \
            -o "$BRIDGE_DYLIB" "$BRIDGE_SOURCE"
    fi
    if [ ! -x "$TRANSLATOR_BIN" ] || [ "$DIR/Sources/AresTranslator/main.swift" -nt "$TRANSLATOR_BIN" ]; then
        echo "[Ares launcher] Building controller helper..."
        (cd "$DIR" && swift build --target AresTranslator)
    fi
}

case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --stop)
        if pgrep -x AresTranslator >/dev/null; then
            pkill -x AresTranslator
            echo "[Ares launcher] AresTranslator stopped."
        else
            echo "[Ares launcher] AresTranslator is not running."
        fi
        exit 0 ;;
    --diagnose)
        check_astris
        build_components
        echo "[Ares launcher] Astris bridge compatibility: OK"
        echo "[Ares launcher] Astris: $ASTRIS_APP"
        echo "[Ares launcher] Helper log: $TRANSLATOR_LOG"
        pgrep -xal AresTranslator || true
        exit 0 ;;
esac

check_astris
build_components

if pgrep -x Astris >/dev/null; then
    fail "Astris is already open. Quit it first, then launch through this script so the controller bridge can load."
fi

if ! pgrep -x AresTranslator >/dev/null; then
    echo "[Ares launcher] Starting controller helper..."
    "$TRANSLATOR_BIN" >"$TRANSLATOR_LOG" 2>&1 &
    sleep 0.5
    pgrep -x AresTranslator >/dev/null || fail "The controller helper did not start. See $TRANSLATOR_LOG"
else
    echo "[Ares launcher] Controller helper already running."
fi

echo "[Ares launcher] Launching Astris with Ares controller support..."
exec env DYLD_INSERT_LIBRARIES="$BRIDGE_DYLIB" "$ASTRIS_BIN" "$@"

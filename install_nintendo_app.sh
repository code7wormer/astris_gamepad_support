#!/bin/bash
# Install or refresh the Spotlight-visible Nintendo launcher in /Applications.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_APP="$DIR/Nintendo.app"
DESTINATION="/Applications/Nintendo.app"

[ -d "$SOURCE_APP" ] || { echo "Nintendo.app is missing from the project." >&2; exit 1; }
ditto "$SOURCE_APP" "$DESTINATION"
chmod +x "$DESTINATION/Contents/MacOS/Nintendo"
touch "$DESTINATION"
echo "Installed: $DESTINATION"

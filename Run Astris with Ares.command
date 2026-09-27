#!/bin/zsh
# Finder-friendly launcher. Double-click this file after moving the project to
# a permanent location.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/launch_astris.sh"

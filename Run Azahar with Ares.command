#!/bin/zsh
# Finder-friendly launcher for Azahar with Cosmic Byte Ares controller support.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/launch_azahar.sh"

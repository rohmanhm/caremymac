#!/usr/bin/env bash
# Builds the drag-to-install disk image: the app beside an Applications link over an arrow background.
#
#   scripts/dmg.sh path/CareMyMac.app path/CareMyMac-0.3.0.dmg
#
# The image is not signed; scripts/release.sh signs and notarizes it. Needs pipx (preinstalled on GitHub's macOS
# runners, `brew install pipx` locally) to run dmgbuild.
set -euo pipefail

app=${1:?usage: scripts/dmg.sh APP OUTPUT.dmg}
dmg=${2:?usage: scripts/dmg.sh APP OUTPUT.dmg}
scripts=$(cd "$(dirname "$0")" && pwd)
art=$(mktemp -d)
trap 'rm -rf "$art"' EXIT

swift "$scripts/dmg-background.swift" "$art"
rm -f "$dmg"
# dmgbuild writes the window layout into .DS_Store itself, so it needs no Finder or GUI session.
pipx run --spec dmgbuild==1.6.7 dmgbuild -s "$scripts/dmg-settings.py" \
    -D app="$app" -D background="$art/background.png" "$(basename "$app" .app)" "$dmg"

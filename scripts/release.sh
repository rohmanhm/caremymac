#!/usr/bin/env bash
# Builds a universal Release CareMyMac.app for a version, zips it, and writes the signed Sparkle appcast.
#
#   scripts/release.sh v0.2.0 [notes.md]
#
# Output in build/release: CareMyMac-<version>.zip and appcast.xml, ready to attach to the GitHub release
# tagged v<version>. The installed app reads appcast.xml from the latest release, so both files must be
# attached to the same release. Notes (Markdown) are embedded in the appcast and shown in the update prompt.
#
# Signing key: $SPARKLE_PRIVATE_KEY when set (CI), otherwise the "caremymac" EdDSA key in the login keychain.
set -euo pipefail

version=${1:?usage: scripts/release.sh VERSION [NOTES.md]}
version=${version#v}
notes=${2:-}
repo=${GITHUB_REPOSITORY:-rohmanhm/caremymac}
derived=build/DD
out=build/release

cd "$(dirname "$0")/.."
rm -rf "$out"
mkdir -p "$out"

xcodebuild -project CareMyMac.xcodeproj -scheme CareMyMac -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
    MARKETING_VERSION="$version" build -quiet

app="$derived/Build/Products/Release/CareMyMac.app"
codesign --verify --deep --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/CareMyMac-$version.zip"
if [[ -s $notes ]]; then
    cp "$notes" "$out/CareMyMac-$version.md"
fi

tools="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin"
args=(--download-url-prefix "https://github.com/$repo/releases/download/v$version/" --embed-release-notes)
if [[ -n ${SPARKLE_PRIVATE_KEY:-} ]]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/generate_appcast" --ed-key-file - "${args[@]}" "$out"
else
    "$tools/generate_appcast" --account caremymac "${args[@]}" "$out"
fi
rm -f "$out/CareMyMac-$version.md"
echo "Release files in $out:"
ls -1 "$out"

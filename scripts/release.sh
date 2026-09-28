#!/usr/bin/env bash
# Builds a universal Release CareMyMac.app for a version, signs it with the Developer ID, notarizes and staples
# it, zips it, and writes the signed Sparkle appcast.
#
#   scripts/release.sh v0.2.0 [notes.md]
#
# Output in build/release: CareMyMac-<version>.zip and appcast.xml, ready to attach to the GitHub release
# tagged v<version>. The installed app reads appcast.xml from the latest release, so both files must be
# attached to the same release. Notes (Markdown) are embedded in the appcast and shown in the update prompt.
#
# Code signing: the "Developer ID Application" identity of team NJVVS6LHNX in a keychain on the search list.
# Notarization: the App Store Connect API key at $NOTARY_KEY (.p8) with $NOTARY_KEY_ID and $NOTARY_ISSUER_ID
# when set (CI), otherwise the "caremymac" notarytool profile in the login keychain.
# Update signing: $SPARKLE_PRIVATE_KEY when set (CI), otherwise the "caremymac" EdDSA key in the login keychain.
set -euo pipefail

version=${1:?usage: scripts/release.sh VERSION [NOTES.md]}
version=${version#v}
notes=${2:-}
repo=${GITHUB_REPOSITORY:-rohmanhm/caremymac}
derived=build/DD
archive=build/CareMyMac.xcarchive
exported=build/export
out=build/release

cd "$(dirname "$0")/.."
rm -rf "$archive" "$exported" "$out"
mkdir -p "$out"

xcodebuild archive -project CareMyMac.xcodeproj -scheme CareMyMac -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" -archivePath "$archive" \
    MARKETING_VERSION="$version" -quiet
# Export re-signs every nested bundle, including Sparkle's helpers, with the Developer ID and a secure timestamp.
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$exported" \
    -exportOptionsPlist scripts/ExportOptions.plist -quiet

app="$exported/CareMyMac.app"
zip="$out/CareMyMac-$version.zip"
codesign --verify --deep --strict "$app"

if [[ -n ${NOTARY_KEY:-} ]]; then
    notary=(--key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}")
else
    notary=(--keychain-profile caremymac)
fi
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
result=$(xcrun notarytool submit "$zip" "${notary[@]}" --wait --output-format json) || true
status=$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null) || status=failed
if [[ $status != Accepted ]]; then
    echo "Notarization $status: $result" >&2
    if id=$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null); then
        xcrun notarytool log "$id" "${notary[@]}" >&2 || true
    fi
    exit 1
fi
xcrun stapler staple "$app"
spctl --assess --type execute --verbose=2 "$app"
# Zip again so the download carries the stapled ticket and opens offline.
rm "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

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

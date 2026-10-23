#!/bin/bash
# Sign nested code from the inside out, using the same identity as the host app.
set -euo pipefail
repo_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle="${1:?Usage: scripts/sign-bundle.sh <app-bundle>}"
identity="${CODESIGN_IDENTITY:--}"
timestamp_args=(--timestamp=none)
if [[ "$identity" != - ]]; then timestamp_args=(--timestamp); fi
framework="$bundle/Contents/Frameworks/Sparkle.framework"
version="$framework/Versions/B"
codesign --force --sign "$identity" --options runtime --preserve-metadata=entitlements \
  "${timestamp_args[@]}" "$version/XPCServices/Downloader.xpc"
for code in "$version/XPCServices/Installer.xpc" \
  "$version/Autoupdate" "$version/Updater.app" "$framework"; do
  codesign --force --sign "$identity" --options runtime "${timestamp_args[@]}" "$code"
done
codesign --force --sign "$identity" --identifier com.openyourmac.OpenYourMac.engine \
  --options runtime "${timestamp_args[@]}" "$bundle/Contents/Resources/OpenYourMacEngine"
# Ad-hoc binaries have no Team ID, so library validation cannot accept the
# separately signed framework. Developer ID builds keep library validation.
app_entitlements=()
if [[ "$identity" == - ]]; then
  app_entitlements=(--entitlements "$repo_root/app/AdHoc.entitlements")
fi
codesign --force --sign "$identity" --options runtime "${timestamp_args[@]}" \
  "${app_entitlements[@]}" "$bundle"
codesign --verify --deep --strict "$bundle"

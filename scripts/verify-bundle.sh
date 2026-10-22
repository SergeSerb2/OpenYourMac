#!/bin/bash
# Check the real artifact without starting the app or its window manager.
set -euo pipefail
repo_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle="${1:-$repo_root/build/OpenYourMac.app}"
resources="$bundle/Contents/Resources"
version="$(cat "$repo_root/VERSION")"
codesign --verify --deep --strict --verbose=2 "$bundle"
plutil -lint "$bundle/Contents/Info.plist"
actual="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")"
[[ "$actual" == "$version" ]] || { echo 'App version does not match VERSION' >&2; exit 1; }
for binary in "$bundle/Contents/MacOS/OpenYourMac" "$resources/OpenYourMacEngine"; do
  [[ "$(lipo -archs "$binary")" == arm64 ]] || { echo "Expected arm64 binary: $binary" >&2; exit 1; }
done
cmp "$repo_root/THIRD_PARTY_NOTICES.md" "$resources/THIRD_PARTY_NOTICES.md"
cmp "$repo_root/LICENSE" "$resources/LICENSE.txt"
scratch_home="$(mktemp -d)"
trap 'rm -rf "$scratch_home"' EXIT
python3 - "$resources/OpenYourMacEngine" "$version" <<'PY'
import plistlib
import subprocess
import sys

text = subprocess.check_output(["otool", "-v", "-s", "__TEXT", "__info_plist", sys.argv[1]], text=True)
start = text.index("<?xml")
end = text.index("</plist>", start) + len("</plist>")
plist = plistlib.loads(text[start:end].encode("utf-8"))
for key in ("CFBundleShortVersionString", "CFBundleVersion"):
    if plist[key] != sys.argv[2]:
        sys.exit(f"Embedded engine {key} does not match VERSION")
if plist["OpenYourMacUpstreamBase"] != "Paneru 0.5.2 base":
    sys.exit("Missing engine upstream-base metadata")
print("Embedded engine Info.plist matches VERSION.")
PY
HOME="$scratch_home" "$resources/OpenYourMacEngine" check-config "$resources/default-config.toml"
echo 'Bundle signature, versions, architecture, notices and configuration verified.'

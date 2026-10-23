#!/bin/bash
# Check the real artifact without starting the app or its window manager.
set -euo pipefail
repo_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle="${1:-$repo_root/build/OpenYourMac.app}"
resources="$bundle/Contents/Resources"
version="$(cat "$repo_root/VERSION")"
build_number="${BUILD_NUMBER:-$(cat "$repo_root/BUILD_NUMBER")}"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || { echo 'BUILD_NUMBER must be a positive integer without leading zeroes.' >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$bundle"
plutil -lint "$bundle/Contents/Info.plist"
actual="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")"
[[ "$actual" == "$version" ]] || { echo 'App version does not match VERSION' >&2; exit 1; }
actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$bundle/Contents/Info.plist")"
[[ "$actual_build" == "$build_number" ]] || { echo 'App build number does not match BUILD_NUMBER' >&2; exit 1; }
for binary in "$bundle/Contents/MacOS/OpenYourMac" "$resources/OpenYourMacEngine"; do
  [[ "$(lipo -archs "$binary")" == arm64 ]] || { echo "Expected arm64 binary: $binary" >&2; exit 1; }
done
cmp "$repo_root/THIRD_PARTY_NOTICES.md" "$resources/THIRD_PARTY_NOTICES.md"
cmp "$repo_root/LICENSE" "$resources/LICENSE.txt"
python3 - "$bundle" "$repo_root" <<'PY'
from pathlib import Path
import base64
import plistlib
import subprocess
import sys

bundle, root = map(Path, sys.argv[1:])
with (bundle / "Contents/Info.plist").open("rb") as source:
    info = plistlib.load(source)
with (root / "app/Info.plist").open("rb") as source:
    expected = plistlib.load(source)
for key in ("SUFeedURL", "SUPublicEDKey", "SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"):
    if info.get(key) != expected[key]:
        sys.exit(f"Unexpected Sparkle configuration: {key}")
if len(base64.b64decode(info["SUPublicEDKey"], validate=True)) != 32:
    sys.exit("Invalid Sparkle public key")
framework = bundle / "Contents/Frameworks/Sparkle.framework"
for path in (framework / "Sparkle", framework / "Autoupdate",
             framework / "Updater.app/Contents/MacOS/Updater",
             framework / "XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
             framework / "XPCServices/Installer.xpc/Contents/MacOS/Installer"):
    if not path.is_file():
        sys.exit(f"Missing Sparkle code: {path.name}")
    if "arm64" not in subprocess.check_output(["lipo", "-archs", str(path)], text=True).split():
        sys.exit(f"Missing Sparkle arm64 slice: {path.name}")
binary = str(bundle / "Contents/MacOS/OpenYourMac")
if "@rpath/Sparkle.framework/Versions/B/Sparkle" not in subprocess.check_output(["otool", "-L", binary], text=True):
    sys.exit("App is not linked to Sparkle")
if "@executable_path/../Frameworks" not in subprocess.check_output(["otool", "-l", binary], text=True):
    sys.exit("Missing bundled-framework runtime search path")
print("Sparkle configuration, linkage, and helpers verified.")
PY
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

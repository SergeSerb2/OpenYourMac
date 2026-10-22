#!/bin/bash
# Render the SVG once per icon size with macOS AppKit.
set -euo pipefail

repo_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/openyourmac-icon.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
iconset="$work_dir/AppIcon.iconset"
mkdir -p "$iconset" "$repo_root/resources/raycast/images"

xcrun swiftc "$repo_root/scripts/svg2png.swift" -o "$work_dir/svg2png"
for size in 16 32 128 256 512; do
  "$work_dir/svg2png" "$repo_root/assets/icon.svg" "$iconset/icon_${size}x${size}.png" "$size"
  "$work_dir/svg2png" "$repo_root/assets/icon.svg" "$iconset/icon_${size}x${size}@2x.png" "$((size * 2))"
done
iconutil -c icns "$iconset" -o "$repo_root/assets/AppIcon.icns"
cp "$iconset/icon_256x256.png" "$repo_root/resources/raycast/images/openyourmac.png"
printf 'Created %s\n' "$repo_root/assets/AppIcon.icns"

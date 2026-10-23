#!/bin/bash
# Build release artifacts locally; publish a draft only with --publish.
set -euo pipefail

repo_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skip_ci=false
publish=false
deploy_updates=false

usage() {
  cat <<'USAGE'
Usage: scripts/release.sh [--skip-ci] [--deploy-updates] [--publish]

By default, run local CI and write artifacts to build/release without making a tag.
  --skip-ci   Use only after local CI passed for this commit
  --deploy-updates  Upload verified artifacts and the signed feed to Cloudflare R2
  --publish   Create/push only v<VERSION> and create a draft GitHub release with gh
  -h, --help  Show this help

Set both CODESIGN_IDENTITY (Developer ID Application) and NOTARY_PROFILE
(a notarytool keychain profile) to sign, notarize and staple. Otherwise use ad-hoc signing.
USAGE
}

fail() { printf 'release: %s\n' "$*" >&2; exit 1; }

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json > "$scratch/notarization.json"
  python3 - "$scratch/notarization.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    result = json.load(source)
if result.get("status") != "Accepted":
    sys.exit("Notarization was not accepted: " + str(result.get("status")))
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-ci) skip_ci=true ;;
    --deploy-updates) deploy_updates=true ;;
    --publish) publish=true ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1. Use --help for usage." ;;
  esac
  shift
done

cd "$repo_root"
[[ "$(git rev-parse --is-shallow-repository)" == false ]] || fail 'A release requires full Git history; shallow clones are not supported.'
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || fail 'Worktree is dirty. Commit or remove pending changes before releasing.'
version="$(cat VERSION)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'VERSION must contain a three-part version, such as 1.0.0.'
tag="v$version"
commit="$(git rev-parse HEAD)"
BUILD_NUMBER="$(cat BUILD_NUMBER)"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || fail 'BUILD_NUMBER must be a positive integer without leading zeroes.'
export BUILD_NUMBER
export PATH="$HOME/.cargo/bin:$PATH"
scratch="$(mktemp -d)"
mounted=''
cleanup() {
  if [[ -n "$mounted" ]]; then hdiutil detach -quiet -force "$mounted" || true; fi
  rm -rf "$scratch"
}
trap cleanup EXIT
python3 scripts/release-notes.py --version "$version" --signing-kind ad-hoc --output "$scratch/release-notes.md"

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || fail 'Release artifacts require an Apple silicon Mac with Xcode.'
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  DEVELOPER_DIR="$(xcode-select -p)"
fi
export DEVELOPER_DIR
signing_kind=adhoc
if [[ -n "${CODESIGN_IDENTITY:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  [[ "$CODESIGN_IDENTITY" == 'Developer ID Application:'* ]] || fail 'CODESIGN_IDENTITY must be a Developer ID Application identity.'
  signing_kind=notarized
else
  printf 'Using ad-hoc signing. Set both CODESIGN_IDENTITY and NOTARY_PROFILE for notarization.\n'
fi
if [[ "$publish" == true ]]; then
  command -v gh >/dev/null 2>&1 || fail 'Publishing requires gh and gh auth login.'
  if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
    [[ "$(git rev-parse "$tag^{commit}")" == "$commit" ]] || fail "$tag already points to another commit."
  fi
fi

if [[ "$skip_ci" == false ]]; then scripts/ci.sh; fi
CODESIGN_IDENTITY=- scripts/build-app.sh
bundle="$repo_root/build/OpenYourMac.app"
if [[ "$signing_kind" == notarized ]]; then
  scripts/sign-bundle.sh "$bundle"
  ditto -c -k --sequesterRsrc --keepParent "$bundle" "$scratch/submission.zip"
  notarize "$scratch/submission.zip"
  xcrun stapler staple "$bundle"
  xcrun stapler validate "$bundle"
  spctl --assess --type execute --verbose=4 "$bundle"
else
  signature="$(codesign -dv "$bundle" 2>&1)"
  [[ "$signature" == *'Signature=adhoc'* ]] || fail 'Expected an ad-hoc signature.'
fi
scripts/verify-bundle.sh "$bundle"

mkdir -p build/release
asset="OpenYourMac-$version-macos-arm64-$signing_kind.zip"
archive="$repo_root/build/release/$asset"
ditto -c -k --sequesterRsrc --keepParent "$bundle" "$archive"
ditto -x -k "$archive" "$scratch/extracted"
scripts/verify-bundle.sh "$scratch/extracted/OpenYourMac.app"
if [[ "$signing_kind" == notarized ]]; then
  xcrun stapler validate "$scratch/extracted/OpenYourMac.app"
  spctl --assess --type execute --verbose=4 "$scratch/extracted/OpenYourMac.app"
fi

# The disk image holds the app and an Applications link for drag installation.
dmg_asset="OpenYourMac-$version-macos-arm64-$signing_kind.dmg"
dmg="$repo_root/build/release/$dmg_asset"
mkdir "$scratch/dmg-root"
ditto "$bundle" "$scratch/dmg-root/OpenYourMac.app"
ln -s /Applications "$scratch/dmg-root/Applications"
rm -f "$dmg"
hdiutil create -quiet -volname OpenYourMac -srcfolder "$scratch/dmg-root" -fs HFS+ -format UDZO "$dmg"
if [[ "$signing_kind" == notarized ]]; then
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$dmg"
  notarize "$dmg"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"
fi
hdiutil verify -quiet "$dmg"
mounted="$scratch/mounted"
hdiutil attach -quiet -nobrowse -noautoopen -readonly -mountpoint "$mounted" "$dmg"
[[ -L "$mounted/Applications" && "$(readlink "$mounted/Applications")" == /Applications ]] \
  || fail 'The disk image has no Applications link.'
scripts/verify-bundle.sh "$mounted/OpenYourMac.app"
if [[ "$signing_kind" == notarized ]]; then
  xcrun stapler validate "$mounted/OpenYourMac.app"
fi
hdiutil detach -quiet "$mounted"
mounted=''

(cd build/release && shasum -a 256 "$asset" > "$asset.sha256" && shasum -a 256 "$dmg_asset" > "$dmg_asset.sha256")
{
  printf 'Commit: %s\nCommit count: %s\nBuild number: %s\nTarget: aarch64-apple-darwin\n' \
    "$commit" "$(git rev-list --count HEAD)" "$BUILD_NUMBER"
  (cd engine && rustc --version && cargo --version)
  swift --version
  xcodebuild -version
  sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
  sdk_build="$(xcrun --sdk macosx --show-sdk-build-version)"
  printf 'macOS SDK version: %s\n' "$sdk_version"
  printf 'macOS SDK build: %s\n' "$sdk_build"
  shasum -a 256 engine/Cargo.lock
  shasum -a 256 app/Package.resolved
} > "$archive.build-info.txt"
notes="$archive.release-notes.md"
notes_kind=ad-hoc
if [[ "$signing_kind" == notarized ]]; then notes_kind=notarized; fi
python3 scripts/release-notes.py --version "$version" --signing-kind "$notes_kind" --output "$notes"
python3 scripts/create-appcast.py "$archive" --output build/release/appcast.xml
if [[ "$deploy_updates" == true ]]; then
  python3 scripts/deploy-updates.py "$archive" --appcast build/release/appcast.xml --dmg "$dmg"
fi

gh_command=(gh release create "$tag" "$dmg" "$dmg.sha256" "$archive" "$archive.sha256" "$archive.build-info.txt" "$notes" build/release/appcast.xml
  --draft --verify-tag --title "OpenYourMac $version" --notes-file "$notes")
if [[ "$publish" == true ]]; then
  [[ -z "$(git status --porcelain --untracked-files=all)" ]] || fail 'Worktree changed during the build; refusing to publish.'
  [[ "$(git rev-parse HEAD)" == "$commit" ]] || fail 'HEAD changed during the build; refusing to publish.'
  if ! git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
    git tag -a "$tag" -m "OpenYourMac $version" "$commit"
  fi
  git -c remote.origin.mirror=false push --no-follow-tags origin "refs/tags/$tag:refs/tags/$tag"
  "${gh_command[@]}"
else
  printf '\nArtifacts: %s/build/release\nNo tag or GitHub release was created.\n' "$repo_root"
  printf 'With --publish, the script creates/pushes only %s and runs:\n' "$tag"
  printf '%q ' "${gh_command[@]}"
  printf '\n'
fi

#!/bin/bash
# Build a self-contained, signed OpenYourMac app bundle.
set -euo pipefail

repo_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile=release
skip_engine=false
universal=false
output_dir="$repo_root/build"

usage() {
  cat <<'USAGE'
Usage: scripts/build-app.sh [options]

  --debug          Use debug builds instead of release builds
  --skip-engine    Reuse the engine binary for the selected profile
  --universal      Build arm64 and x86_64, then combine both binaries with lipo
  --output <dir>   Write OpenYourMac.app here (default: <repo>/build)
  -h, --help       Show this help

Set CODESIGN_IDENTITY to a signing identity; the default is ad-hoc signing (-).
The build number comes from BUILD_NUMBER. Set the BUILD_NUMBER environment variable
to a positive integer to override it for a local build.
Universal builds require both aarch64-apple-darwin and x86_64-apple-darwin Rust targets.
USAGE
}

fail() {
  printf 'build-app: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) profile=debug; shift ;;
    --skip-engine) skip_engine=true; shift ;;
    --universal) universal=true; shift ;;
    --output)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail '--output needs a directory.'
      output_dir="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1. Use --help for usage." ;;
  esac
done
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  DEVELOPER_DIR="$(xcode-select -p)" || fail 'Cannot find the selected developer directory. Run xcode-select --install or select Xcode.'
  export DEVELOPER_DIR
fi

[[ "$(uname -s)" == Darwin ]] || fail 'Building the app requires macOS and Xcode.'
if ! command -v cargo >/dev/null 2>&1; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi
for tool in swift xcrun codesign ditto plutil; do
  command -v "$tool" >/dev/null 2>&1 || fail "Required tool is missing: $tool. Install Xcode and its command-line tools."
done
if [[ "$skip_engine" == false ]]; then
  command -v cargo >/dev/null 2>&1 || fail 'cargo was not found. Install Rust, or use --skip-engine with a built engine.'
fi

# Give both toolchains the same minimum supported macOS version.
export MACOSX_DEPLOYMENT_TARGET=13.0
cargo_args=(build --locked --no-default-features --manifest-path "$repo_root/engine/Cargo.toml" --target-dir "$repo_root/engine/target")
# rustup finds engine/rust-toolchain.toml from the working directory, not --manifest-path.
run_cargo() { (cd "$repo_root/engine" && cargo "$@"); }
if [[ "$profile" == release ]]; then
  cargo_args+=(--release)
fi
swift_args=(build -c "$profile" --package-path "$repo_root/app")

if [[ "$universal" == true ]]; then
  command -v rustup >/dev/null 2>&1 || fail 'Universal builds need rustup to check installed Rust targets.'
  command -v lipo >/dev/null 2>&1 || fail 'Universal builds need lipo from Xcode.'
  installed_targets="$(cd "$repo_root/engine" && rustup target list --installed)"
  for target in aarch64-apple-darwin x86_64-apple-darwin; do
    if ! printf '%s\n' "$installed_targets" | /usr/bin/grep -Fxq "$target"; then
      fail "Rust target $target is not installed. Run: rustup target add aarch64-apple-darwin x86_64-apple-darwin"
    fi
  done
fi

version="$(cat "$repo_root/VERSION")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'VERSION must contain a three-part version, such as 1.0.0.'
build_number="${BUILD_NUMBER:-}"
if [[ -z "$build_number" ]]; then
  build_number="$(cat "$repo_root/BUILD_NUMBER")" || fail 'Cannot read BUILD_NUMBER.'
fi
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || fail 'BUILD_NUMBER must be a positive integer without leading zeroes.'

mkdir -p "$output_dir"
output_dir="$(cd -P "$output_dir" && pwd)"
work_dir="$(mktemp -d "$output_dir/.openyourmac-build.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

find_engine() {
  local binary_dir="$1"
  local name
  for name in openyourmac-engine paneru; do
    if [[ -x "$binary_dir/$name" ]]; then
      printf '%s\n' "$binary_dir/$name"
      return
    fi
  done
  fail "No engine binary in $binary_dir (expected openyourmac-engine or paneru). Build the engine before using --skip-engine."
}

if [[ "$universal" == true ]]; then
  swift_arches=(arm64 x86_64)
  rust_targets=(aarch64-apple-darwin x86_64-apple-darwin)
  engine_slices=()
  app_slices=()
  for index in 0 1; do
    target="${rust_targets[$index]}"
    arch="${swift_arches[$index]}"
    if [[ "$skip_engine" == false ]]; then
      run_cargo "${cargo_args[@]}" --target "$target"
    fi
    engine_slices+=("$(find_engine "$repo_root/engine/target/$target/$profile")")
    swift "${swift_args[@]}" --arch "$arch"
    bin_dir="$(swift "${swift_args[@]}" --arch "$arch" --show-bin-path)"
    app_slices+=("$bin_dir/OpenYourMac")
  done
  engine_binary="$work_dir/OpenYourMacEngine"
  app_binary="$work_dir/OpenYourMac"
  lipo -create "${engine_slices[@]}" -output "$engine_binary"
  lipo -create "${app_slices[@]}" -output "$app_binary"
  lipo -verify_arch arm64 x86_64 "$engine_binary"
  lipo -verify_arch arm64 x86_64 "$app_binary"
else
  if [[ "$skip_engine" == false ]]; then
    run_cargo "${cargo_args[@]}"
  fi
  engine_binary="$(find_engine "$repo_root/engine/target/$profile")"
  swift "${swift_args[@]}"
  bin_dir="$(swift "${swift_args[@]}" --show-bin-path)"
  app_binary="$bin_dir/OpenYourMac"
fi

if [[ ! -f "$repo_root/assets/AppIcon.icns" ]]; then
  "$repo_root/scripts/make-icon.sh"
fi

staged_bundle="$work_dir/OpenYourMac.app"
contents="$staged_bundle/Contents"
resources="$contents/Resources"
mkdir -p "$contents/MacOS" "$resources"
cp "$app_binary" "$contents/MacOS/OpenYourMac"
cp "$engine_binary" "$resources/OpenYourMacEngine"
sed -e "s/__VERSION__/$version/g" -e "s/__BUILD__/$build_number/g" \
  "$repo_root/app/Info.plist" > "$contents/Info.plist"
printf 'APPL????' > "$contents/PkgInfo"
cp "$repo_root/resources/default-config.toml" "$resources/default-config.toml"
cp "$repo_root/resources/openyourmac-cli" "$resources/openyourmac-cli"
ditto "$repo_root/resources/raycast" "$resources/raycast"
cp "$repo_root/assets/AppIcon.icns" "$resources/AppIcon.icns"
cp "$repo_root/LICENSE" "$resources/LICENSE.txt"
cp "$repo_root/THIRD_PARTY_NOTICES.md" "$resources/THIRD_PARTY_NOTICES.md"
chmod +x "$contents/MacOS/OpenYourMac" "$resources/OpenYourMacEngine" "$resources/openyourmac-cli"
find "$resources/raycast" -type f -name 'openyourmac-*.sh' -exec chmod +x {} +
plutil -lint "$contents/Info.plist"

identity="${CODESIGN_IDENTITY:--}"
timestamp_args=(--timestamp=none)
if [[ "$identity" != - ]]; then timestamp_args=(--timestamp); fi
codesign --force --sign "$identity" --identifier com.openyourmac.OpenYourMac.engine \
  --options runtime "${timestamp_args[@]}" "$resources/OpenYourMacEngine"
codesign --force --sign "$identity" --options runtime "${timestamp_args[@]}" "$staged_bundle"
codesign --verify --deep --strict "$staged_bundle"

bundle="$output_dir/OpenYourMac.app"
rm -rf "$bundle"
mv "$staged_bundle" "$bundle"
printf '%s\n' "$bundle"

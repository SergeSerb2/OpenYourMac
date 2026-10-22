#!/bin/bash
# Run the complete local build and packaging checks without starting the app.
set -euo pipefail

step='Prepare local checks'
passed=0
scratch=''
cleanup() {
  local status=$?
  if [[ -n "$scratch" ]]; then rm -rf "$scratch"; fi
  if [[ "$status" != 0 ]]; then printf 'FAILED: %s\n' "$step" >&2; fi
  exit "$status"
}
trap cleanup EXIT

repo_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export PATH="$HOME/.cargo/bin:$PATH"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  DEVELOPER_DIR="$(xcode-select -p)"
fi
export DEVELOPER_DIR
scratch="$(mktemp -d)"

run_step() {
  step="$1"
  shift
  printf '\nChecking: %s\n' "$step"
  "$@"
  passed=$((passed + 1))
}

run_cargo() { (cd "$repo_root/engine" && cargo "$@"); }

build_swift() {
  swift "$@" 2>&1 | tee "$scratch/swift.log"
  if /usr/bin/grep -q 'warning:' "$scratch/swift.log"; then
    printf 'Swift build output contains warning:.\n' >&2
    return 1
  fi
}

run_step 'cargo fmt --check' run_cargo fmt --check
run_step 'cargo clippy (shipped engine)' run_cargo clippy --locked --no-default-features --all-targets -- -D warnings
run_step 'cargo test (shipped engine)' run_cargo test --locked --no-default-features
run_step 'cargo check (default features, Lua)' run_cargo check --locked --all-targets
run_step 'third-party notices' python3 scripts/generate-notices.py --check
run_step 'swift build (debug, no warnings)' build_swift build --package-path app
run_step 'swift build (release, no warnings)' build_swift build -c release --package-path app
run_step 'release bundle' env CODESIGN_IDENTITY=- scripts/build-app.sh
run_step 'verify release bundle' scripts/verify-bundle.sh
run_step 'archive release bundle' ditto -c -k --sequesterRsrc --keepParent build/OpenYourMac.app "$scratch/OpenYourMac.zip"
run_step 'extract release bundle' ditto -x -k "$scratch/OpenYourMac.zip" "$scratch/extracted"
run_step 'verify extracted bundle' scripts/verify-bundle.sh "$scratch/extracted/OpenYourMac.app"
printf '\nPASS: all %s local checks passed.\n' "$passed"

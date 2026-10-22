# Releasing OpenYourMac

All checks and release builds run locally on an Apple silicon Mac with Xcode,
Swift 6, Rust 1.95 or later, Python 3, and full Git history. GitHub hosts the
source and downloads. It does not run build or release jobs.

## Prepare the source

1. Complete the [manual checks](manual-testing.md) in a separate macOS account
   or VM. Local packaging checks do not test real window behavior.
2. Set the three-part product version in `VERSION`. In `CHANGELOG.md`, add one
   nonempty `## [<version>] - YYYY-MM-DD` section with a valid release date.
   An `Unreleased`, missing, empty, or duplicate version section fails.
3. If dependencies changed, regenerate notices and review them:

   ```sh
   export PATH="$HOME/.cargo/bin:$PATH"
   python3 scripts/generate-notices.py
   ```

4. Commit all release inputs. `scripts/release.sh` refuses a dirty worktree
   (including untracked files) or shallow clone.

The notices generator uses the locked arm64 dependency graph without Lua.
Commit `THIRD_PARTY_NOTICES.md` with dependency changes. Review the source
snapshots in `THIRD_PARTY_LICENSES/manifest.json` when updating those crates.
Missing license texts or unknown terms require review.

## Run local checks

```sh
make ci
```

`scripts/ci.sh` also works from any directory, including a checkout path with
spaces. It stops at the first failure and prints `FAILED: <step>`. It runs Rust
formatting, strict Clippy, existing tests, default-feature Lua checking, notices,
warning-free Swift debug and release builds, release bundle assembly, and bundle
verification before and after ZIP extraction. It does not start the app or
window manager. The bundle checker runs only the engine's safe config validator.

Both local scripts add `~/.cargo/bin` to PATH and select `DEVELOPER_DIR` from
`xcode-select -p` when unset. Cargo runs from `engine/` to select
`engine/rust-toolchain.toml`; `RUSTUP_TOOLCHAIN` can override it. The bundle uses
macOS 13 as its deployment target and builds the engine without Lua.

## Build release artifacts

```sh
scripts/release.sh
```

This runs local CI, builds an ad-hoc-signed release bundle, and verifies its ZIP
after extraction. If CI already passed for this commit, use `--skip-ci`.
The default command creates no tag and publishes nothing. It prints the `gh`
command that publishing would run.

Files go in `build/release/`:

- `OpenYourMac-<version>-macos-arm64-adhoc.zip` (or `-notarized.zip`).
- The ZIP's `.sha256`, `.build-info.txt`, and `.release-notes.md` files.

The ZIP contains `OpenYourMac.app`, both binaries, the CLI, default config,
Raycast scripts, and license notices. Build information records the commit,
full commit count, target, toolchain and SDK versions, and `engine/Cargo.lock`
SHA-256. Release builds use the commit count as the app build number. They do
not claim byte-for-byte reproducibility. Intel and universal releases are not
produced by this script.

For a separate source-archive build with no Git history, use
`BUILD_NUMBER=<published-build-number> scripts/build-app.sh`. This override
does not remove the full-history requirement for `scripts/release.sh`.

## Optional Developer ID signing

Install your Developer ID Application certificate in your local keychain. Store
notarization credentials with `xcrun notarytool store-credentials`, using a named
keychain profile. See Apple's [notarization guide](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

```sh
export CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export NOTARY_PROFILE='OpenYourMac-notary'
scripts/release.sh
```

Both variables must be set to sign and notarize. If either is unset, the script
keeps ad-hoc signing. With both set, it signs the engine and app with hardened
runtime and timestamps, submits to Apple, requires `Accepted`, and staples the
ticket. It checks the ticket and Gatekeeper before and after ZIP extraction.
A signing or notarization failure stops the release. Credentials stay in the
local keychain; no repository signing credentials are needed.

## Create a draft GitHub Release

Install GitHub CLI and run `gh auth login`. Then use:

```sh
scripts/release.sh --publish
```

The script builds and verifies artifacts first. It then creates an annotated
`v<version>` tag at the release commit, pushes only that tag to `origin`, and
runs `gh release create ... --draft`. An existing tag must point to the same
commit. It never pushes branches or other tags. Review the draft and its files
on GitHub before publishing it.

## Download and first launch

Download the ZIP and `.sha256` file from the same GitHub Release. In that folder:

```sh
shasum -a 256 -c OpenYourMac-1.0.0-macos-arm64-adhoc.zip.sha256
```

Use the actual filename. Extract the ZIP, move `OpenYourMac.app` to
`/Applications`, and launch it. Grant Accessibility access when requested.
For an ad-hoc build that Gatekeeper blocks, use **System Settings > Privacy &
Security > Open Anyway** only after you trust the source and verify the checksum.
Do not disable Gatekeeper globally. See [Apple's first-launch guide](https://support.apple.com/en-us/102445).
Notarization does not grant Accessibility permission.

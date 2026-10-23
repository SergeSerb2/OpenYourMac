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
   For each new distributed build, increase the integer in `BUILD_NUMBER` above
   every previous build.
   Keep it increasing across version changes and Git history changes. The initial
   value of 51 follows the builds distributed before the public repository.
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

This runs local CI and builds an ad-hoc-signed release bundle. It verifies the
bundle in the ZIP after extraction and in the DMG after a read-only mount.
If CI already passed for this commit, use `--skip-ci`.
The default command creates no tag and publishes nothing. It prints the `gh`
command that publishing would run.

Files go in `build/release/`:

- `OpenYourMac-<version>-macos-arm64-adhoc.dmg` (or `-notarized.dmg`) and its
  `.sha256` file.
- `OpenYourMac-<version>-macos-arm64-adhoc.zip` (or `-notarized.zip`).
- The ZIP's `.sha256`, `.build-info.txt`, and `.release-notes.md` files.
- `appcast.xml`, a signed Sparkle feed pointing to that build's ZIP on Cloudflare.

The DMG contains `OpenYourMac.app` and an `Applications` link for drag
installation. The ZIP contains the same app. The app holds both binaries, the
CLI, default config, Raycast scripts, and license notices. Build information records the commit,
full commit count, target, toolchain and SDK versions, and `engine/Cargo.lock`
SHA-256 and `app/Package.resolved` SHA-256. Release builds use the committed
`BUILD_NUMBER` as the app build number.
They do not claim byte-for-byte reproducibility. Intel and universal releases
are not produced by this script.

Source archives include `BUILD_NUMBER`, so `scripts/build-app.sh` does not need
Git history. For a local build, the `BUILD_NUMBER` environment variable can
override that file. Use the same override with `scripts/verify-bundle.sh`.
`scripts/release.sh` always uses the committed file and still requires full history.

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
It also signs, notarizes, and staples the DMG, then checks the app inside it.
A signing or notarization failure stops the release. Sparkle's framework and
nested helpers are signed with the same identity before the app. Credentials
stay in the local keychain; no repository signing credentials are needed.

## Sparkle update signing

The app embeds Sparkle 2.10.0 through SwiftPM. `scripts/build-app.sh` copies its
framework and helpers into the bundle and signs them from the inside out.
`make ci` checks the packaged framework, helpers, linkage, and update settings
before and after ZIP extraction. Ordinary app builds do not need a private key.
Ad-hoc builds use `app/AdHoc.entitlements` to load their separately signed Sparkle
framework without a Team ID. Developer ID builds keep library validation enabled.

Release creation requires the matching Ed25519 private key in the login Keychain,
under Sparkle account `com.openyourmac.OpenYourMac`. The public key is committed
as `SUPublicEDKey` in `app/Info.plist`. Keep a secure backup of the private key.
On a new release Mac, import that backup with Sparkle's `generate_keys --account
com.openyourmac.OpenYourMac -f <private-key-file>`. The tool is in
`app/.build/artifacts/sparkle/Sparkle/bin/` after package resolution. Never commit
or publish the private key. Do not generate a replacement for an existing release
key; installed apps would reject its signatures. See [Sparkle's signing guide](https://sparkle-project.org/documentation/#eddsa-ed25519-signatures).

After the final ZIP is built, `scripts/create-appcast.py` checks its metadata and
the Keychain public key, signs and verifies the ZIP, then signs and verifies
`appcast.xml`. This also applies to ad-hoc releases; Apple signing and Sparkle
update signing serve separate purposes. A missing or mismatched key stops the
release. The feed uses `BUILD_NUMBER` to order updates and limits them to Apple
silicon and the bundle's minimum macOS version.

The app loads `https://openyourmac-updates.sergeserbinenko.com/appcast.xml`.
Downloads and the signed feed use the dedicated Cloudflare R2 bucket
`openyourmac-releases`. The domain is attached directly to the bucket with
minimum TLS 1.2. The ZIP URL includes its build number and SHA-256, so a new
archive cannot overwrite an older download. Older installed apps need one
manual update to begin using Sparkle.

## Deploy updates to Cloudflare

Set `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` in your local release
environment. The token needs R2 object read/write access to `openyourmac-releases`.
The uploader uses Node.js and the pinned Wrangler CLI through `npx`; it does not
store credentials in the repository. The bucket and custom domain must already
exist in that account. To set up another account, create the dedicated bucket and
attach the domain with `wrangler r2 bucket domain add` as described in
[Cloudflare's R2 guide](https://developers.cloudflare.com/r2/reference/wrangler-commands/).

```sh
scripts/release.sh --deploy-updates
```

This builds and verifies local release artifacts, signs the ZIP and feed, uploads
the ZIP, DMG, and checksums, then reads each public download back and checks its
SHA-256. Only after those checks pass does it replace `appcast.xml`. The feed uses
`Cache-Control: no-store, max-age=0`; immutable downloads cache for one year.
The uploader verifies the public feed's bytes and signature and refuses to
replace a live feed with an equal or lower build number. Run only one release
deployment at a time. A failed asset upload leaves the previous feed in place.
Keep all referenced downloads available. Do not edit signed files after upload.
Use `--skip-ci` only after local CI passed for the committed source.

This flag publishes updates through Cloudflare without making a Git tag or
GitHub Release. `--publish` remains a separate opt-in for a draft GitHub Release.
Attaching files to a GitHub draft alone does not change the live Sparkle feed.

## Create a draft GitHub Release

Install GitHub CLI and run `gh auth login`. Then use:

```sh
scripts/release.sh --publish
```

The script builds and verifies artifacts first. It then creates an annotated
`v<version>` tag at the release commit, pushes only that tag to `origin`, and
runs `gh release create ... --draft`. An existing tag must point to the same
commit. It never pushes branches or other tags. Review the draft and its files
on GitHub before publishing it. Include `appcast.xml` and its matching ZIP;
editing either after signing invalidates the update.

## Download and first launch

Download the DMG and its `.sha256` file from the same GitHub Release. In that folder:

```sh
shasum -a 256 -c OpenYourMac-1.0.0-macos-arm64-adhoc.dmg.sha256
```

Use the actual filename. Open the DMG, drag `OpenYourMac` to `Applications`,
and launch it from `/Applications`. The ZIP works the same way after extraction.
Grant Accessibility access when requested.
For an ad-hoc build that Gatekeeper blocks, use **System Settings > Privacy &
Security > Open Anyway** only after you trust the source and verify the checksum.
Do not disable Gatekeeper globally. See [Apple's first-launch guide](https://support.apple.com/en-us/102445).
Notarization does not grant Accessibility permission.

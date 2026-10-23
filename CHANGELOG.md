# Changelog

<!-- Keep a Changelog format. scripts/release.sh extracts a nonempty dated section:
## [<version>] - YYYY-MM-DD. Replace Unreleased and commit before a local release. -->

Changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/).

## [1.0.1] - 2026-10-23

### Added

- Sparkle updates with signed downloads, installation, and relaunch.
- Optional automatic download and installation when the app quits.
- A signed update feed and release downloads hosted on Cloudflare R2.

### Fixed

- Keep app build numbers independent of Git history and above earlier builds.
- Check the app build number when verifying release bundles.

## [1.0.0] - 2026-10-21

### Added

- First public release of OpenYourMac for macOS on Apple silicon.
- Scrolling window strips with preset widths, stacks, tabs, and pinned columns.
- A strip minimap, trackpad navigation, and window drag reordering.
- A SwiftUI settings app with editable shortcuts, window rules, and Mac Setup.
- Session restore, focus borders, inactive-window dimming, and display controls.
- OpenYourMac URL actions, a command-line wrapper, and Raycast scripts.
- Setup, install, uninstall, contribution, and safe manual testing guides.

### Notes

- The bundled engine is based on Paneru v0.5.2 and ships without Lua.
- macOS 13 is the deployment target. Intel runtime support is not verified.
- Ad-hoc-signed downloads can require approval in Privacy & Security on first launch.

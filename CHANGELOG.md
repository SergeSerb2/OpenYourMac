# Changelog

<!-- Keep a Changelog format. scripts/release.sh extracts a nonempty dated section:
## [<version>] - YYYY-MM-DD. Replace Unreleased and commit before a local release. -->

Changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/).

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

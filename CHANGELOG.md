# Changelog

<!-- Keep a Changelog format. scripts/release.sh extracts a nonempty dated section:
## [<version>] - YYYY-MM-DD. Replace Unreleased and commit before a local release. -->

Changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/).

## [1.1.0] - 2026-11-02

### Added

- A live map of each display's strip on Overview. Click a column to focus it.
- Pause the window manager for 5 minutes to 1 hour from the menu bar, or with
  `openyourmac://pause/<minutes>`. It starts again by itself.
- Workspace chips on the live map that switch virtual workspaces.
- Right-click a window on the live map to make its app always float or tile.
- The last onboarding step shows the user's own strip.
- A Windows submenu in the menu bar that lists and focuses strip columns.
- An Updates section with version, status, and Check Now or Restart to Update.
- Update badges in the menu bar and sidebar instead of alerts during work.
- Search on the Shortcuts and Actions pages.
- `openyourmac://open/<page>[/<section>]` and `openyourmac://strip/show` URLs.
- Go menu shortcuts (Command-1 to Command-6) for each page.
- The engine's state query reports each window's strip `column`.

### Changed

- A new sidebar with page icons, groups, a Mac Setup badge, and a window
  manager switch.
- Help shows one topic at a time: Guide, Shortcuts, Settings File,
  Integrations, and About.
- Configuration has section chips; numbered actions use a compact pad.

### Fixed

- Restart the window manager when it stops answering, not only when it exits.
- After an update relaunch, the window manager and window return as they were.
- After an update that loses Accessibility access, Overview explains how to
  allow the app again.

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

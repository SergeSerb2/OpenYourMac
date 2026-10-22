# Architecture

OpenYourMac has two processes. A SwiftUI app owns settings, onboarding,
permissions, the menu bar, login registration, updates, and integrations.
A Rust engine manages windows. The app supervises the engine as its child.

## App and engine

The Swift package produces `OpenYourMac`. The bundle includes the Rust executable
as `Contents/Resources/OpenYourMacEngine`. Cargo calls that binary
`openyourmac-engine`; its package and library retain the upstream name `paneru`.
The engine is based on Paneru v0.5.2.

The app starts the bundled engine with `launch`, sets `OPENYOURMAC_CONFIG` to its
config file, and captures stdout and stderr in the engine log. It stops the child
when the app quits. The engine also watches its parent and exits if that parent
is gone. The app can restart an unexpectedly exited child, with a bounded retry
budget. It reports permission, config, duplicate-instance, and launch failures.

The app sends commands by running `OpenYourMacEngine send-cmd ...`. It does not
hold a direct IPC connection. The CLI wrapper uses the same helper for window
commands. Lifecycle CLI commands and Raycast scripts send `openyourmac://` URLs
to the app. The app accepts a fixed set of routes. Background requests do not
show a permission prompt. Starting through a URL requires completed onboarding
and Accessibility access.

## IPC

The engine listens on the per-user Mach service `com.openyourmac.engine`.
`OYM_MACH_SERVICE` selects a different service for isolated checks. The retained
`PANERU_MACH_SERVICE` fallback is lower priority. These are Mach service names,
not HTTP endpoints or filesystem sockets.

Requests and responses use MessagePack with named struct fields through the
`async-mach-ports` dependency. Command argv is parsed on both sides with the
shared parser. A successful `send-cmd` reports delivery, not the final window
state. The exception is `bindings pause` / `bindings resume`, which the app uses
while it records a shortcut: the engine applies them before it replies, and
`send-cmd` fails if no reply arrives within a second. Query and subscription commands expose JSON to callers. See
[the IPC guide](../engine/QUERY_AND_SUBSCRIBE_FORMAT.md).

## Config and stored data

The app creates `~/.config/openyourmac/openyourmac.toml` from its bundled template
when the file is missing. It preserves comments and unknown keys when it edits
supported settings. Resetting the file creates an `openyourmac.toml.backup-*`
copy beside it. The engine watches config changes and keeps the last valid
config if a reload fails. If the file is absent, it uses embedded product defaults
and retries watching when the file appears.

The engine accepts `--config` or `OPENYOURMAC_CONFIG` overrides. The app always
uses its own config path and passes that path to the child. See
[configuration](../engine/CONFIGURATION.md) for priorities and compatibility keys.

| Data | Location |
| --- | --- |
| App config and reset backups | `~/.config/openyourmac/` |
| App preferences and window settings | UserDefaults domain `com.openyourmac.OpenYourMac` |
| App-supervised engine output | `~/Library/Logs/OpenYourMac/engine.log` |
| Engine session layout | `~/.local/state/openyourmac/state.json` |
| Client key/value state | `~/.local/state/openyourmac/script-state.json` |
| Optional CLI link | `~/.local/bin/openyourmac` |
| Raycast export | `OpenYourMac Raycast` inside the user-selected folder |

`XDG_STATE_HOME` changes the state directory. `OYM_STATE_FILE` overrides the
session file only. Sessions use JSON, not `session.toml` in Application Support.
The engine saves layout state periodically and at shutdown. Restore matches
available windows and applies saved column order, pins, tabs, and size metadata.
It does not reopen closed apps or documents.

## Shipped profile and source layout

The app build uses `--no-default-features`. Lua is not part of the shipped engine.
Cargo's default features retain an optional upstream Lua build for source
compatibility; that is a separate profile.

| Path | Purpose |
| --- | --- |
| `app/Sources/OpenYourMac/App/` | App lifecycle, paths, preferences, and URL routing. |
| `app/Sources/OpenYourMac/Config/` | TOML editing, shortcuts, and window rules. |
| `app/Sources/OpenYourMac/Engine/` | Child-process supervision and command argv. |
| `app/Sources/OpenYourMac/System/` | Permissions, setup checks, updates, and integrations. |
| `app/Sources/OpenYourMac/Views/` | Settings pages and onboarding. |
| `engine/src/ecs/` | Window state, layout, focus, scrolling, restore, and input systems. |
| `engine/src/manager/` and `engine/src/platform/` | macOS window and input access. |
| `engine/src/types/` | Shared command, state, and wire types. |
| `resources/` | Shipped config, CLI, and Raycast files. |
| `scripts/` | App bundle and icon builds. |

Read the [engine architecture](../engine/ARCHITECTURE.md) for its event flow and
[manual testing](manual-testing.md) for safe checks.

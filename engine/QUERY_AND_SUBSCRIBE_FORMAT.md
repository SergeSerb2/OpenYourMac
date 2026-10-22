# Queries, subscriptions, and IPC

These interfaces belong to `openyourmac-engine`, not upstream Paneru's installed
binary. The bundled executable is `OpenYourMacEngine`. The `openyourmac` wrapper
forwards engine command argv through `send-cmd`; it does not expose the engine's
`query` or `subscribe` subcommands.

## Service and transport

The default per-user Mach service is `com.openyourmac.engine`.
`OYM_MACH_SERVICE` overrides it; the retained `PANERU_MACH_SERVICE` is a
lower-priority fallback. The transport uses `async-mach-ports` and MessagePack
with named struct fields. It does not use a Unix socket or JSON on the wire.
[src/types/wire.rs](src/types/wire.rs) defines requests, replies, and encoding.

`send-cmd window focus east`, for example, validates argv and sends it without
waiting for the resulting window action. Exit 0 means delivery. Invalid command
input exits 2; a stopped service produces an error and exit 1. An action with no
suitable window can have no visible effect despite successful delivery.

## Query commands

For a running engine in an isolated manual-test account, use:

```sh
/Applications/OpenYourMac.app/Contents/Resources/OpenYourMacEngine query state --json
/Applications/OpenYourMac.app/Contents/Resources/OpenYourMacEngine query active --json
/Applications/OpenYourMac.app/Contents/Resources/OpenYourMacEngine query virtual-workspaces --json
/Applications/OpenYourMac.app/Contents/Resources/OpenYourMacEngine query on-screen --json
```

All four print JSON, with or without `--json`. Queries use request/reply channels.
The state schema is separate from the on-disk session format.

| Query | JSON result |
| --- | --- |
| `state` | Object with `version`, `timestamp`, `active`, and `virtual_workspaces`. |
| `active` | Active display, native Space, virtual workspace, and focused-window fields. |
| `virtual-workspaces` | Array of rows with `number`, `native_workspace_id`, `active`, and `windows`. |
| `on-screen` | Array of visible windows, ordered left to right per display; hidden/minimized windows and edge slivers are excluded. |

The active object contains `display_id`, `native_workspace_id`,
`virtual_workspace_number`, `focused_window_id`, `focused_bundle_id`,
`focused_app_name`, and `focused_window_title`. Fields can be `null` when absent.
A window has `window_id`, `bundle_id`, `app_name`, `title`, `focused`, `floating`,
`display_id`, `frame`, and `visible`. `frame` can be null, or an object with
`x`, `y`, `width`, and `height` in global display coordinates.

See [src/types/state.rs](src/types/state.rs) for the complete typed contract.
Treat window titles and app information as private data when logging results.

## Subscriptions

```sh
/Applications/OpenYourMac.app/Contents/Resources/OpenYourMacEngine subscribe --json
```

This prints one JSON object per event, with an `event` field. Output is flushed
for each line. Interrupt the process to stop. A peer shutdown ends the stream.

| Event | Other fields |
| --- | --- |
| `virtual_workspace_changed` | `active` |
| `windows_changed` | `virtual_workspace_number`, `active` |
| `window_focused` | `window_id`, `bundle_id`, `title`, `virtual_workspace_number` |
| `on_screen_changed` | `windows`, `active` |
| `window_title_changed` | `window_id`, `title` |
| `display_changed` | `display_id`, which can be null for a global change |

## Verification limits

An IPC-only engine logs command argv but does not create state or answer queries
and subscriptions. Do not wait for query replies from that mode. Follow
[the safe diagnostics guide](../docs/manual-testing.md#build-and-safe-diagnostics)
for CLI checks. Live state and event checks require the separate macOS account or
VM described there. Do not send commands to the user's installed service during
an automated check.

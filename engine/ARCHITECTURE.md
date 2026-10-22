# Engine architecture

The OpenYourMac engine uses Bevy's entity component system (ECS) for window,
display, workspace, and layout state. It uses macOS APIs to observe and update
real windows. See [the app architecture](../docs/architecture.md) for supervision,
paths, and integration entry points.

## Event flow

1. The platform and manager layers observe window, focus, display, and input
   changes. They send events into the engine.
2. `src/ecs/systems.rs` pumps events into Bevy messages and observers.
3. Focus, layout, scroll, drag, and restore systems update components and strips.
4. Commit systems apply changed positions and sizes through the manager layer.
   macOS objects that require the main thread stay on that thread.
5. Overlay and minimap code draws the current focus, pins, and strip state.

A `LayoutStrip` contains ordered columns. A column can hold a single window,
a split stack, or tabs. Layout state tracks edge pins, widths, active members,
and stack heights. Native Spaces and the retained virtual-workspace machinery
are separate from the horizontal strip.

## Commands and IPC

`src/reader.rs` owns the `com.openyourmac.engine` Mach service and turns incoming
requests into engine events. `src/client.rs` connects to that service.
`src/types/argv.rs` parses command vectors for both the sender and receiver.
`src/types/wire.rs` defines requests and replies. The transport dependency is
`async-mach-ports`; there is no local `crates/mach_ipc` package.

The wire format is MessagePack with named fields. JSON is the terminal format
for queries and subscriptions. Commands are delivered without an action result,
except `bindings pause` and `bindings resume`: the engine applies the binding
lease first and then replies, so `send-cmd` returns only after it is in effect.
Queries have a reply channel, and subscribers have a lasting event channel.
See [IPC contracts](QUERY_AND_SUBSCRIBE_FORMAT.md).

`launch --ipc-only` loads and watches the config like a normal launch (an
invalid file stops it from starting), listens on the Mach service, and logs
parsed command vectors. It creates no Bevy world, event taps, or
window-management state. It does not execute commands or serve state queries.
It does not choose a test service by itself: the caller must set a unique
`OYM_MACH_SERVICE` and a scratch `HOME`, or it claims the normal service. Read
[AGENTS.md](AGENTS.md) before any runtime check.

## Config and restore

`src/config.rs` loads typed config and resolves bindings. The engine watches the
OpenYourMac TOML file, adopts valid reloads, and keeps the prior config on error.
The app owns initial file creation. See [CONFIGURATION.md](CONFIGURATION.md).

`src/ecs/state.rs` saves session JSON to the XDG state directory under
`openyourmac/state.json`, normally `~/.local/state/openyourmac/state.json`.
`OYM_STATE_FILE` overrides that path. Writes use a temporary file and rename.
The current saved format is version 3; version 2 files can also load.
`src/ecs/restore.rs` matches available windows at startup and rebuilds saved
layout metadata. Saved lone heights are reused only when the boot session
matches. Closed applications and documents are not reopened by this system.

`src/ecs/script_state.rs` stores client key/value state separately in
`openyourmac/script-state.json` under the same XDG state directory.

## Module map

| Path | Purpose |
| --- | --- |
| `src/ecs/layout.rs` and `src/ecs/oym_layout.rs` | Strip placement, columns, pins, and sizing. |
| `src/ecs/focus.rs` and `src/ecs/scroll.rs` | Focus navigation and scrolling. |
| `src/ecs/drag_reorder.rs` and `src/ecs/floating.rs` | Drag and floating-window policy. |
| `src/manager/` and `src/platform/` | macOS window access, events, and input. |
| `src/commands.rs` | Apply window commands to engine state. |
| `src/runtime.rs` | Parent supervision, signals, and logging. |
| `src/minimap.rs` and `src/overlay.rs` | Strip map and window decorations. |
| `src/types/` | Shared commands, state documents, and IPC encoding. |
| `src/lua/` | Optional upstream feature; excluded from the shipped build. |

## Verification

Keep existing tests. Do not add unit tests or mock-based substitutes for real
flows. Use [contributor checks](../CONTRIBUTING.md#existing-checks), isolated
IPC-only diagnostics, and [manual checks](../docs/manual-testing.md) in a separate
macOS account or VM for real-window behavior.

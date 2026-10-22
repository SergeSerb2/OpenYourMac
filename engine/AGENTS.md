# OpenYourMac engine: coding agent rules

This is the OpenYourMac fork. Read [../CONTRIBUTING.md](../CONTRIBUTING.md) and
[../docs/manual-testing.md](../docs/manual-testing.md). Do not use upstream
Paneru installation or branch instructions for this repository.

## Mandatory runtime safety

The shell may inherit macOS Accessibility access and can move the user's real
windows. Another window manager may already own those windows and shortcuts.

- Never run `openyourmac-engine launch` without `--ipc-only` on the user's desktop.
  Never run the engine without a subcommand; that also launches it.
- Every `launch --ipc-only` must use a scratch HOME and a unique test Mach service,
  such as `OYM_MACH_SERVICE=com.openyourmac.engine.<name>test`. Export both to
  the listener and all clients. Stop and reap your listener when finished.
- Never send `send-cmd` to the real `com.openyourmac.engine` service. Allowed
  engine checks are `--help`, `check-config`, and `send-cmd` to your test listener.
- Never open the app normally, run `make run`, open `openyourmac://` URLs, or use
  LaunchServices to start the app during automated verification.
- Allowed app diagnostics are `--snapshot <dir>` and `--selftest-config <dir>`,
  always with a scratch HOME. Do not drive the desktop, mouse, or keyboard, or
  capture screenshots of the user's real screen.
- A scratch HOME does not isolate window access. Real-window checks require a
  separate logged-in macOS account or VM with no other window manager.
- If an app/engine supervision check needs `OYM_ENGINE_PATH`, point it to a wrapper
  that always runs `launch --ipc-only` on the test service. Remove only defaults
  keys set by that check, with a separate `defaults delete` call per key. Check
  that the real HOME config was not created or changed. Preserve pre-existing data.

## Build and existing checks

Run `make ci` from the repository root before opening a PR. These checks run only
locally; there are no GitHub Actions builds. The script adds `~/.cargo/bin` to
PATH. For a focused engine change, these commands are also available:

```sh
export PATH="$HOME/.cargo/bin:$PATH"
cargo fmt --manifest-path engine/Cargo.toml
cargo fmt --check --manifest-path engine/Cargo.toml
cargo build --no-default-features --manifest-path engine/Cargo.toml
cargo test --no-default-features --manifest-path engine/Cargo.toml
cargo clippy --no-default-features --all-targets --manifest-path engine/Cargo.toml -- -D warnings
cargo check --all-targets --manifest-path engine/Cargo.toml
swift build --package-path app
scripts/build-app.sh --debug
```

Use `scripts/release.sh` for local release artifacts. Publishing needs an explicit
`--publish`; see [the release guide](../docs/releasing.md).

The shipped binary is `openyourmac-engine`, copied into the app as
`OpenYourMacEngine`. `--no-default-features` excludes Lua. The default-feature
check covers optional upstream source, not the release profile.

Keep existing tests. Never add unit tests, isolated component tests, or mocks
that replace a real system flow. Use the real config validator, IPC listener,
CLI wrapper, and permitted app diagnostics. State exactly which checks passed
and which could not run. IPC receipts do not establish real-window behavior.

## Implementation and repository scope

Follow the existing ECS, manager, and platform boundaries. Keep main-thread macOS
objects on the main thread. Use shared command and wire types in `src/types/`.
Update docs when config, paths, command argv, or protocol behavior changes.

Keep edits in the assigned checkout. Never use the shared git stash or reset
another task's files. Do not push, merge, or move to another branch unless the
user asked. Use focused commits. Do not publish internal task notes, workstation
paths, or research material. Preserve project and Paneru license notices.

# Contributing

OpenYourMac welcomes focused fixes and clear bug reports. Follow the
[Code of Conduct](CODE_OF_CONDUCT.md). Report vulnerabilities through the
[security policy](SECURITY.md).

## Prerequisites and build

Use macOS 13 or later, Xcode with Swift 6, and Rust 1.95 or later with Cargo,
rustfmt, and Clippy. The Swift package uses Swift 5 language mode. Apple silicon
is the current release target; Intel runtime support is not verified.

From the repository root:

```sh
export PATH="$HOME/.cargo/bin:$PATH"
scripts/build-app.sh --debug
```

This produces `build/OpenYourMac.app`. Omit `--debug` for a release build.
The shipped engine uses `--no-default-features`; it has no Lua runtime.
The Cargo package retains the name `paneru`, but the executable is
`openyourmac-engine`. The bundle calls it `OpenYourMacEngine`.

## Existing checks

Keep the existing tests. Do not add unit tests or replace real interfaces with
mocks. Run the complete local checks before opening a pull request:

```sh
make ci
```

Checks run only on your Mac. There are no GitHub Actions builds. `scripts/ci.sh`
also works from another directory. It checks Rust formatting, strict Clippy,
existing tests, optional Lua compilation, notices, warning-free Swift debug and
release builds, and the release bundle before and after ZIP extraction. It stops
at the first failure. It does not start the app or window manager.

Rust formatting uses rustfmt's defaults. Run `cargo fmt --manifest-path
engine/Cargo.toml` to apply it. Keep Swift edits consistent with the surrounding
file. For packaging changes, also run `scripts/build-app.sh --debug`. See
[releasing](docs/releasing.md) for local release artifacts and draft publishing.

## Verify safely

A terminal with Accessibility access can move your real windows. A scratch HOME
alone does not isolate window access. Never start the engine without `--ipc-only`
on your everyday desktop. Starting the binary without a subcommand also launches
the window manager. Do not open the app or its URL scheme as an automated check.

Use a separate logged-in macOS account or VM for real-window checks, with no
other window manager running. Follow the self-contained
[manual checklist](docs/manual-testing.md) and record what you observed.

For CLI work, start an IPC-only engine with a scratch HOME and a unique
`OYM_MACH_SERVICE=com.openyourmac.engine.<name>test`. Send commands only to that
service. Stop and reap it when done. This verifies parsing and transport; it does
not verify window movement. The manual guide provides a complete shell example.

For app UI checks, use only `--snapshot <directory>` with a scratch HOME.
For config work, use `--selftest-config <directory>` with a scratch HOME and
`OYM_ENGINE_PATH` pointing to the built engine. These diagnostics do not start a
window-managing engine. See the manual guide for commands and limits.

## Pull requests

Explain the problem, the resulting behavior, and the scope. Include commands and
results from the real flow you changed. Include an invalid-input or empty case
when practical. State any check that failed or could not run. Never present
IPC receipts or offscreen snapshots as proof of real-window behavior.

For UI changes, include offscreen snapshots. For config or command changes,
update the public examples and check them against the real binaries. Use short,
plain English. Verify relative links and image paths. Keep private workstation
paths, internal handoffs, and research notes out of public files.

Use focused conventional commits, such as `fix(engine): ...`, `fix(app): ...`,
or `docs: ...`. Open pull requests against this repository's default branch.
Do not send this fork's product changes to upstream Paneru by default.

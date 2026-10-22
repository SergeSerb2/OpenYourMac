# Coding agent rules

Read [CONTRIBUTING.md](CONTRIBUTING.md) and
[engine/AGENTS.md](engine/AGENTS.md) before running binaries.

Run `make ci` locally before opening a PR. GitHub Actions builds are disabled.
Use `scripts/release.sh` for local artifacts. Use `--publish` only when asked to
create a release tag and draft GitHub Release. See [releasing](docs/releasing.md).

The shell may have Accessibility access. Never launch a window-managing engine,
run the engine without a subcommand, open the app normally, or open its URL scheme
on the user's everyday desktop. Do not drive the desktop, mouse, or keyboard.

Allowed engine checks are `--help`, `check-config`, and `send-cmd` to your own
`launch --ipc-only` listener. Always give that listener a scratch HOME and a unique
`OYM_MACH_SERVICE=com.openyourmac.engine.<name>test`. Stop and reap it afterward.
Allowed app diagnostics are `--snapshot <dir>` and `--selftest-config <dir>`,
always with a scratch HOME. Never send commands to the installed engine service.

Real-window verification belongs in a separate macOS account or VM with no other
window manager. Keep existing tests. Do not add unit tests or mock the system
instead of checking the real flow. Report verification limits clearly.

Do not use the shared git stash. Keep changes in the assigned checkout. Do not
publish internal handoffs, local workstation paths, or research notes.

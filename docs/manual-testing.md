# Manual testing

Use this checklist to record observations, not to claim that a build already
passes them. IPC checks prove parsing and transport. Offscreen snapshots prove
rendering. Neither proves that real windows move correctly.

## Safety

A terminal with Accessibility access can control the current desktop. A scratch
HOME or a different Mach service does not isolate real windows. On an everyday
desktop, never launch the engine without `--ipc-only`, run it without a
subcommand, open the app normally, or open an `openyourmac://` URL for a test.
Do not automate the user's desktop, mouse, or keyboard.

Use only these app diagnostics on that desktop: `--snapshot <directory>` and
`--selftest-config <directory> [operation]`, each with a scratch HOME. For engine
checks, use `--help`, `check-config`, and `send-cmd` to your own IPC-only service.
Do not send commands to the installed engine's service.

## Build and safe diagnostics

From the repository root:

```sh
export PATH="$HOME/.cargo/bin:$PATH"
scripts/build-app.sh --debug
```

Run `make ci` locally before opening a PR or preparing a release. It checks builds
and packaging without starting the app or window manager. It does not replace
the isolated real-window checks below. See [releasing](releasing.md).

Builds do not start the app or manage windows. Validate the shipped config:

```sh
build/OpenYourMac.app/Contents/Resources/OpenYourMacEngine check-config resources/default-config.toml
```

Render the app offscreen with a scratch HOME. No engine is started:

```sh
oym_scratch=$(mktemp -d /tmp/openyourmac-docs.XXXXXX)
HOME="$oym_scratch"   build/OpenYourMac.app/Contents/MacOS/OpenYourMac   --snapshot "$oym_scratch/snapshots"
```

Inspect the light and dark PNGs for clipping, labels, and private data. Snapshots
can contain connected display names. Keep them outside the repository until
reviewed.

Exercise the real config editor and engine validator in scratch files:

```sh
HOME="$oym_scratch"   OYM_ENGINE_PATH="$PWD/build/OpenYourMac.app/Contents/Resources/OpenYourMacEngine"   build/OpenYourMac.app/Contents/MacOS/OpenYourMac   --selftest-config "$oym_scratch/config" edit
HOME="$oym_scratch"   OYM_ENGINE_PATH="$PWD/build/OpenYourMac.app/Contents/Resources/OpenYourMacEngine"   build/OpenYourMac.app/Contents/MacOS/OpenYourMac   --selftest-config "$oym_scratch/config" inspect
```

Check `rule-result=success`, the printed values, and the saved TOML. Run the
`invalid-rule` operation to check rejection. Diagnostic exit status alone does
not establish success; read the output. Keep existing tests and run the
[contributor checks](../CONTRIBUTING.md#existing-checks). Do not add unit tests.

For a CLI check, run this whole subshell from the repository root. It keeps the
installed service and user config separate, then stops and reaps its child:

```sh
(
  set -eu
  oym_engine="$PWD/build/OpenYourMac.app/Contents/Resources/OpenYourMacEngine"
  export HOME="$(mktemp -d /tmp/openyourmac-ipc.XXXXXX)"
  export OYM_MACH_SERVICE="com.openyourmac.engine.docstest.$$"
  "$oym_engine" launch --ipc-only >"$HOME/ipc.log" 2>&1 &
  oym_pid=$!
  trap 'kill "$oym_pid" 2>/dev/null || true; wait "$oym_pid" || true' EXIT
  sleep 1
  "$oym_engine" send-cmd window focus east
  "$oym_engine" send-cmd window focus 9
  "$oym_engine" send-cmd strip show
  cat "$HOME/ipc.log"
)
```

The log must show parsed commands, including `Last` for focus 9. Repeat the
commands through the bundled `openyourmac-cli` with the same HOME and service.
Check that an unknown command exits 2. After stopping the listener, a valid
command to that test service must exit 1 with a not-running error. IPC-only mode
does not execute window actions or answer state queries. Do not use it to test
query output or session restore.

Keep the scratch evidence until review, then remove only the scratch directories
you created. Confirm that diagnostics did not create or change the config in
your normal HOME. Do not remove a pre-existing user config. If you used a safe
app/engine wrapper for a supervision check, it must always exec `launch --ipc-only`
on your test service. Remove only UserDefaults keys that your check set, with a
separate `defaults delete com.openyourmac.OpenYourMac <key>` call per key.

## Prepare an isolated session for real windows

Perform the remaining steps by hand only in a separate logged-in macOS account
or macOS VM. Stop all other window managers and their login items there.

1. Install the app in `/Applications`, open it, and finish onboarding.
2. Grant Accessibility. Follow [setup](setup.md), including separate Spaces and
   the logout needed to apply it.
3. Install the CLI from **Help › Integrations**. Verify `openyourmac --help`.
4. Open at least six resizable TextEdit, Finder, or Terminal windows. Use clear
   sample titles without personal data. Create ten columns for numbered checks.
5. Save the starting config and record the app version, macOS version, display
   arrangement, and settings used for each check.

Commands act on the focused window. Prefer the app's shortcuts while a test
window has focus. If you send a delayed CLI command, return focus to that test
window before the command runs.

## Layout and input checklist

- [ ] **Focus and move.** Use left/right and up/down navigation, then the matching
  Shift moves. The target remains visible and stack order stays correct.
- [ ] **Numbered columns.** With ten columns, 1–8 select their column's top member.
  9 selects the last column. Numbered swaps move the whole column and keep its
  member order. An unavailable position within 1–8 leaves the layout unchanged.
- [ ] **Widths.** Cycle presets; toggle full width twice; use wider/narrower.
  Check width steps with and without pins. Unpinning and leaving full width must
  restore their respective widths.
- [ ] **Stacks.** Stack left, consume right, unstack, and expel left. Check which
  column receives all source members and where the new column appears. Use
  taller/shorter, equalize, vertical focus, and vertical swap in a three-member
  stack. Switching to tabs and back keeps the stack's relative heights.
- [ ] **Pins.** Pin both edges and scroll. Each pinned column stays at its edge.
  Pin a replacement on one edge; the previous pin is released. Merge, expel,
  close, and float members; no edge gains duplicate pins or stale markers.
- [ ] **Kept heights.** Enable `keep_window_height`, shorten a lone window, and
  change only its width. Its height stays. Stack/tab it and separate it again.
  It fills a stack cell, then regains its lone height. Repeat after hot reload.
- [ ] **Centering.** Check `never`, `on-overflow`, and `always`, both directions,
  narrow and wide columns, and pinned edges. Explicit center works in each mode.
- [ ] **Swipes.** Check slow swipes and fast flicks in both directions and at each
  end. `snap` settles on a column alignment; `free` retains the free offset.
  Check modifier scrolling and disable the swipe to check that it stops.
- [ ] **Gaps.** Check 8, 7, and 0 point inner gaps with a nonzero outer gap, stacked
  members, both pins, and Dock positions. Check an explicit per-window padding
  rule. Adjacent gaps must not double.

## Visuals, dragging, and window policy

- [ ] **Minimap.** Navigate and let it expire. Hold a navigation or Show Strip
  chord; the map stays visible. Click tiles without activating the engine app.
  With `minimap=false`, navigation hides it but explicit `strip show` works.
  Check both ends of a long strip and a small second display.
- [ ] **Map dragging.** Drag across columns and release. Escape, an outside drop,
  or a changed layout during the drag cancels it. With `drag_reorder=false`,
  tile clicks still work and drags do not reorder. Pins cannot be dragged across.
- [ ] **Tabs.** Toggle tabbed view, select segments, rename and close documents,
  then leave the column and return. Selection and titles stay current. Check
  `tab_bar_titles=false` and `tab_bar_clicks=false`. A floating window over a tab
  bar must receive the click rather than the covered segment.
- [ ] **Title-bar dragging.** Reorder a tiled column and its stack by dragging.
  A click without a drag and a resize must not reorder. Repeat with many partly
  hidden columns, both pins, and a long hold. Sleep/wake must not leave a stuck
  drag or cause a later unwanted reorder.
- [ ] **Floating.** Open a Save sheet, Quick Look, an inspector, and the app's
  settings. Sheets remain attached and are not extra columns. Test the dialog
  heuristic with `float_dialogs` on and off and an explicit `floating=false`
  rule. User-floated windows stay floating after focus, resize, and delayed
  rechecks. Native tab groups do not become duplicate columns.
- [ ] **Decorations.** Change border width, color, radius, and dimming. Check
  focus loss, Mission Control, native fullscreen, Space changes, and empty
  strips. No old border, dim panel, or pin marker should remain.
- [ ] **Binding capture.** Record a shortcut and check its real action. Cancel
  capture and check that normal input resumes. Test conflict warnings and
  modifier scrolling after capture; no pause should remain stuck.

## Displays, restore, and app lifecycle

- [ ] Ignore a second display in Configuration. Existing and new windows there
  stay untouched. Next-display skips it. Unignore it and check adoption. Repeat
  with display UUIDs in upper and lower case in the file.
- [ ] Drag to an ignored display and settle, then drag back. The window is
  released there and follows normal admission rules on return. Check disconnect,
  reconnect, and sleep/wake separately from ignoring a connected display.
- [ ] Stop with pins, unequal stack heights, and a tabbed column. Start again.
  Check order, pins, active tabs, and heights. Repeat across a reboot. Sessions
  should restore available windows without reopening closed documents. Never
  fabricate saved window identities to make a result look successful.
- [ ] Edit a valid config and observe hot reload. Introduce invalid TOML, confirm
  a visible error and retained working behavior, then repair the file.
- [ ] Stop/start from Overview and the menu bar. Quit the app and confirm the
  child stops. Test a quick engine quit as well as a later one and record any
  unexpected restart.
- [ ] In this isolated session only, test a known URL action and an unknown route,
  each lifecycle URL, CLI commands, and an installed Raycast script. URL delivery
  alone is not success: observe the resulting app or window state.
- [ ] Check login registration, first launch from a downloaded DMG, Accessibility
  repair after a rebuild, and the [uninstall steps](../README.md#uninstall).
  Check updates against an actual release when one exists.
- [ ] **Sparkle updates (isolated account or VM only).** Install a previous
  Sparkle-enabled build in Applications and use **Check for Updates…** from both
  Configuration and the menu bar. Confirm the signed newer build downloads,
  installs, and relaunches; confirm the engine stops on quit and starts once after
  relaunch. Repeat with automatic download/install on and off. Check that a
  disabled automatic-check setting survives restart and migration from the old
  checker. Check an up-to-date build and a failed/offline feed. With a local test
  feed and disposable builds, alter a signed ZIP and a signed feed and confirm
  Sparkle rejects both. Do not change the production feed or signing key for this
  check. Record the old/new build numbers and the feed used.

Record pass, fail, or not run for each relevant item. Include privacy-reviewed
logs from `~/Library/Logs/OpenYourMac/engine.log` and the exact config used.
Turn detailed logging off when finished. State the OS and hardware tested; a
successful current-Mac build does not prove macOS 13 or Intel runtime behavior.

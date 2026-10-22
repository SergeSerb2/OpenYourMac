#!/usr/bin/env python3
"""Exercise the real CLI and Mach parser. Never launch window management.

Run from the repository root after building the engine, for example:

    OYM_MACH_SERVICE="com.openyourmac.engine.foundation.$(uuidgen)test" \
    OYM_ENGINE_PATH="$PWD/engine/target/debug/openyourmac-engine" \
    python3 engine/scripts/verify-foundation.py resources/default-config.toml

An explicit com.openyourmac.engine.*test service is required. Each run creates
its own scratch HOME and artifact directory, retained at the printed path.
OYM_VERIFY_TMPDIR optionally selects their parent directory. Optional args are
reference configs; OYM_ENGINE_PATH defaults to the release engine.
"""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(os.environ.get("OYM_ENGINE_PATH", ROOT / "engine/target/release/openyourmac-engine")).resolve()
SERVICE = os.environ.get("OYM_MACH_SERVICE", "")
if not re.fullmatch(r"com\.openyourmac\.engine\.[A-Za-z0-9_.-]*test", SERVICE):
    sys.exit("Refusing to run: set an explicit OYM_MACH_SERVICE=com.openyourmac.engine.<unique>test")
ARTIFACTS = Path(tempfile.mkdtemp(prefix="oym-foundation-", dir=os.environ.get("OYM_VERIFY_TMPDIR")))
SCRATCH_HOME = ARTIFACTS / "home"
SCRATCH_HOME.mkdir()
LOG = ARTIFACTS / "oym-e1-ipc.log"
ENV = {**os.environ, "OYM_MACH_SERVICE": SERVICE, "HOME": str(SCRATCH_HOME),
       "XDG_CONFIG_HOME": str(SCRATCH_HOME / ".config"),
       "OPENYOURMAC_CONFIG": str(SCRATCH_HOME / "config.toml")}
ENV.pop("PANERU_CONFIG", None)
ENV.pop("RUST_LOG", None)
ENV.pop("NO_COLOR", None)
Path(ENV["OPENYOURMAC_CONFIG"]).write_text('[options]\ngap_inner = 8\n[bindings]\n')
print(f"Safe CLI/IPC artifacts: {ARTIFACTS}", flush=True)


def run(*args, env=ENV, expected=0):
    result = subprocess.run([str(BINARY), *args], env=env, text=True,
                            capture_output=True, timeout=10)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result


def wait_for(test, seconds=5):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        if test():
            return
        time.sleep(.05)
    raise AssertionError("timed out waiting for real process state")


def listener_ready(env=ENV):
    return subprocess.run([str(BINARY), "send-cmd", "printstate"], env=env,
                          capture_output=True, timeout=5).returncode == 0


for flag in ("--help",):
    print(f"$ {BINARY} {flag}\n{run(flag).stdout.strip()}")

for config in map(Path, sys.argv[1:]):
    result = run("check-config", str(config))
    assert "warning:" not in result.stderr, result.stderr
    print(result.stdout.strip())

reference_text = Path(sys.argv[1]).read_text() if len(sys.argv) > 1 else '[options]\ngap_outer = 8\n[bindings]\n'
syntax = ARTIFACTS / "oym-e1-syntax.toml"
syntax_lines = reference_text.splitlines(keepends=True)
error_line = next(i for i, line in enumerate(syntax_lines) if line.startswith("gap_outer ="))
syntax_lines[error_line] = "gap_outer = @\n"
syntax.write_text("".join(syntax_lines))
broken = run("check-config", str(syntax), expected=1)
assert f"{syntax}:{error_line + 1}:13:" in broken.stderr, broken.stderr
print(broken.stderr.strip())
unknown = ARTIFACTS / "oym-e1-unknown.toml"
unknown.write_text(reference_text.replace('[bindings]\n', '[bindings]\nunknown_command = "ctrl + alt - q"\n', 1))
warning = run("check-config", str(unknown), env={**ENV, "NO_COLOR": "1"})
assert "\x1b" not in warning.stderr
assert "warning: [bindings] unknown_command:" in warning.stderr
print(next(line for line in warning.stderr.splitlines() if line.startswith("warning:")))
print(warning.stdout.strip())
bundle_rule = ARTIFACTS / "oym-e1-bundle-only.toml"
bundle_rule.write_text('[windows.terminal]\nbundle_id = "com.apple.Terminal"\nfloating = false\n')
print(run("check-config", str(bundle_rule)).stdout.strip())
# Confirm our override wins over Paneru without reading or editing its file.
print(run("check-config", env={**ENV, "OPENYOURMAC_CONFIG": str(bundle_rule),
                              "PANERU_CONFIG": "/tmp/oym-e1-never-read.toml"}).stdout.strip())

# Decode the full 39-field dialect plus the retained continuous_swipe extension.
all_options = ARTIFACTS / "oym-e1-all-options.toml"
all_options.write_text('''[options]
focus_follows_mouse = false
mouse_follows_focus = false
swipe_gesture_fingers = 0
swipe_natural = true
swipe_sensitivity = 1.5
gap_inner = 100
gap_outer = -10
dock_aware = true
center_focused_column = " ON_OVERFLOW "
focus_border = true
focus_border_width = 99
focus_border_color = "#10203080"
pin_indicator = true
pinned_color = "#4c9affcc"
focus_border_radius = -1
dim_inactive = true
dim_inactive_opacity = 0.25
minimap = true
exit_native_fullscreen = false
session_restore = true
drag_reorder = true
tab_bar_clicks = true
scroll_modifier = "off"
tab_bar_titles = true
strip_indicator_interactive = true
keep_window_height = false
native_tabs = true
float_recheck = true
float_dialogs = true
preset_column_widths = [0.25, 0.01, 0.75, 0.5, 2]
swipe_snap = "free"
animation = "instant"
animation_duration_ms = 140
animation_speed = 222
animation_damping = 1.2
use_skylight = true
ignored_displays = [" EXAMPLE-UUID "]
detailed_logging = false
continuous_swipe = true
''')
print(run("check-config", str(all_options)).stdout.strip())

for name, value in (("swipe_sensitivity", "nan"), ("gap_inner", "inf"),
                    ("dim_inactive_opacity", "-inf"), ("preset_column_widths", "[0.5, nan]"),
                    ("focus_border_color", '"##10203080"'), ("pinned_color", '"red"')):
    invalid = ARTIFACTS / f"invalid-{name}.toml"
    invalid.write_text(f"[options]\n{name} = {value}\n")
    rejected = run("check-config", str(invalid), expected=1)
    assert "must be finite" in rejected.stderr or "invalid hex color" in rejected.stderr, rejected.stderr
    print(f"rejected {name} = {value}: exit=1")

absent = run("send-cmd", "printstate", expected=1)
assert "the window manager is not running" in absent.stderr, absent.stderr
print(f"no listener: exit={absent.returncode}; {absent.stderr.strip()}")

# Spell out expected Debug results independently from the parser output.
directions = [(d, d.title()) for d in ("west", "east", "north", "south", "first", "last")]
directions += [(str(n), f"Nth({n - 1})" if n < 9 else "Last") for n in range(1, 10)]
cases = []
for verb, variant in (("focus", "Focus"), ("swap", "Swap"), ("consume", "Consume"), ("expel", "Expel")):
    cases += [(["window", verb, token], f"Window({variant}({debug}))") for token, debug in directions]
for verb, debug in {
    "center": "Center", "resize": "Resize(Grow)", "fullwidth": "FullWidth",
    "wider": "AdjustWidth(0.05)", "narrower": "AdjustWidth(-0.05)",
    "taller": "AdjustHeight(0.1)", "shorter": "AdjustHeight(-0.1)",
    "equalize": "Equalize", "manage": "Manage", "stack": "Stack(true)",
    "unstack": "Stack(false)", "tabbed": "ToggleTabbedDisplay", "nextdisplay": "ToNextDisplay(Follow)",
}.items():
    cases.append((["window", verb], f"Window({debug})"))
for edge in (None, "left", "right", "west", "east"):
    cases.append((["window", "pin"] + ([edge] if edge else []),
                  f"Window(Pin({'Right' if edge in ('right', 'east') else 'Left'}))"))
cases += [(["strip", "show"], "ShowStrip"), (["printstate"], "PrintState"),
          (["bindings", "pause"], "PauseBindings(true)"), (["bindings", "resume"], "PauseBindings(false)")]
# Keep several upstream-only commands, and reject invalid product grammar.
cases += [(["window", "grow"], "Window(Resize(Grow))"),
          (["window", "shrink"], "Window(Resize(Shrink))"),
          (["window", "tabbeddisplay"], "Window(ToggleTabbedDisplay)"),
          (["window", "virtualnum", "3"], "Window(VirtualNumber(2))")]
invalid_cases = []
for argv in (["invalid-command"], ["window", "focus", "0"], ["window", "swap", "10"],
             ["window", "pin", "north"], ["bindings", "later"], ["restart"],
             ["window", "focus", "01"], ["window", "swap", "+1"]):
    invalid_cases.append(argv)
cases.append((["quit"], "Quit"))

with LOG.open("w") as stream:
    # This is the ONLY engine launch mode used by this script.
    engine = subprocess.Popen([str(BINARY), "launch", "--ipc-only"], env=ENV,
                              stdout=stream, stderr=subprocess.STDOUT)
    try:
        wait_for(listener_ready)
        wait_for(lambda: "ipc-only: received" in LOG.read_text())
        duplicate = run("launch", "--ipc-only", expected=75)
        expected = "openyourmac-engine: another engine instance is already running; retry later."
        assert expected in duplicate.stderr.splitlines(), duplicate.stderr
        print(f"duplicate listener: exit=75; {expected}")
        for argv in invalid_cases:
            rejected = run("send-cmd", *argv, expected=2)
            assert rejected.stderr.startswith("error: "), rejected.stderr
        for argv, _ in cases:
            run("send-cmd", *argv)
            if argv[:1] == ["bindings"]:
                applied = "paused for 20 seconds" if argv[1] == "pause" else "resumed"
                assert f"engine bindings {applied}" in LOG.read_text(), "client returned before application"
                print(f"bindings {argv[1]}: applied and logged before send-cmd returned")
        wait_for(lambda: LOG.read_text().count("ipc-only: received") == len(cases) + 1)
        lines = [line for line in LOG.read_text().splitlines() if "ipc-only: received" in line][1:]
        assert len(lines) == len(cases)
        for line, (argv, expected) in zip(lines, cases):
            assert f"received {json.dumps(argv)} -> {expected}" in line, (argv, line, expected)
        assert "\x1b" not in LOG.read_text(), "ANSI in redirected log"
        print(f"IPC: {len(cases)} command argv vectors parsed exactly once, in order; {len(invalid_cases)} intentional errors rejected by the client with exit=2; quit last.")

        engine.send_signal(signal.SIGSTOP)
        _, status = os.waitpid(engine.pid, os.WUNTRACED)
        assert os.WIFSTOPPED(status), status
        try:
            stopped_log = LOG.read_text()
            for action in ("pause", "resume"):
                started = time.monotonic()
                timed_out = run("send-cmd", "bindings", action, expected=1)
                elapsed = time.monotonic() - started
                assert "timed out" in timed_out.stderr, timed_out.stderr
                assert .75 <= elapsed < 3, elapsed
                assert LOG.read_text() == stopped_log, "listener processed a command while stopped"
                print(f"SIGSTOP: bindings {action} timed out after {elapsed:.2f}s; exit=1")
        finally:
            engine.send_signal(signal.SIGCONT)
    finally:
        if engine.poll() is None:
            engine.send_signal(signal.SIGTERM)
        assert engine.wait(timeout=5) == 0
print(f"SIGTERM: exit=0; full parser transcript: {LOG}")
run("send-cmd", "printstate", expected=1)
for action in ("pause", "resume"):
    run("send-cmd", "bindings", action, expected=1)

# Only IPC mode is used for signal and watchdog checks too.
for sig in (signal.SIGINT, signal.SIGHUP, signal.SIGUSR1):
    env = {**ENV, "OYM_MACH_SERVICE": ENV["OYM_MACH_SERVICE"] + f".signal{sig}test"}
    log = ARTIFACTS / f"oym-e1-signal-{sig}.log"
    with log.open("w") as stream:
        child = subprocess.Popen([str(BINARY), "launch", "--ipc-only"], env=env,
                                 stdout=stream, stderr=subprocess.STDOUT)
        try:
            wait_for(lambda: listener_ready(env))
            child.send_signal(sig)
            assert child.wait(timeout=5) == 0
        finally:
            if child.poll() is None:
                child.send_signal(signal.SIGTERM)
                child.wait(timeout=5)
    if sig == signal.SIGUSR1:
        assert "handing over to a new engine; leaving windows in place." in log.read_text()
    print(f"{signal.Signals(sig).name}: exit=0; {log}")

parent_log = ARTIFACTS / "oym-e1-parent.log"
parent_code = '''
import os, subprocess, sys, time
from pathlib import Path
with open(sys.argv[2], 'w') as log:
    child = subprocess.Popen([sys.argv[1], 'launch', '--ipc-only'], env=os.environ,
                             stdout=log, stderr=subprocess.STDOUT)
    for _ in range(100):
        if subprocess.run([sys.argv[1], 'send-cmd', 'printstate'], env=os.environ, capture_output=True).returncode == 0:
            print(child.pid, flush=True)
            break
        time.sleep(.05)
    else:
        child.terminate()
        child.wait(timeout=5)
        raise RuntimeError('child not ready')
'''
parent = subprocess.run([sys.executable, "-c", parent_code, str(BINARY), str(parent_log)],
                        env={**ENV, "OYM_MACH_SERVICE": ENV["OYM_MACH_SERVICE"] + ".parenttest"},
                        capture_output=True, text=True, timeout=10, check=True)
child_pid = int(parent.stdout.strip())


def child_gone():
    try:
        os.kill(child_pid, 0)
        return False
    except ProcessLookupError:
        return True


try:
    wait_for(lambda: "now reparented" in parent_log.read_text())
    wait_for(lambda: not listener_ready({**ENV, "OYM_MACH_SERVICE": ENV["OYM_MACH_SERVICE"] + ".parenttest"}))
finally:
    try:
        os.kill(child_pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    # Its original parent has exited; launchd must reap this watchdog child.
    wait_for(child_gone)
print(f"parent death: child={parent.stdout.strip()}; {parent_log.read_text().strip()}")
print("All safe E1 CLI/IPC checks passed.")

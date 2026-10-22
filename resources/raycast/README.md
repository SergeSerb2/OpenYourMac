# OpenYourMac commands for Raycast

Control focus, column layout, and the window manager from Raycast. These scripts
use OpenYourMac's URL scheme and keep the current app in front.

## Install

1. In OpenYourMac, choose **Help → Integrations → Export Raycast Scripts…**.
   You can also copy this entire folder to a permanent location. Keep the
   `images` folder beside the scripts.
2. In Raycast, choose **Settings → Extensions → Script Commands → Add Directory**
   and select that folder.
3. Find the commands in the **OpenYourMac** package. Add Raycast aliases or
   keyboard shortcuts as needed.

OpenYourMac must be installed. macOS can launch the app in the background when a
script runs. Window actions need the window manager to be running and
Accessibility access to be granted. Complete onboarding before using lifecycle
actions that start the engine.

## Commands

| Script | Title in Raycast | URL |
| --- | --- | --- |
| `openyourmac-focus-left.sh` | Focus Window Left | `openyourmac://window/focus/west` |
| `openyourmac-focus-right.sh` | Focus Window Right | `openyourmac://window/focus/east` |
| `openyourmac-focus-up.sh` | Focus Window Up | `openyourmac://window/focus/north` |
| `openyourmac-focus-down.sh` | Focus Window Down | `openyourmac://window/focus/south` |
| `openyourmac-focus-first.sh` | Focus First Window | `openyourmac://window/focus/first` |
| `openyourmac-focus-last.sh` | Focus Last Window | `openyourmac://window/focus/last` |
| `openyourmac-swap-left.sh` | Swap Window Left | `openyourmac://window/swap/west` |
| `openyourmac-swap-right.sh` | Swap Window Right | `openyourmac://window/swap/east` |
| `openyourmac-swap-up.sh` | Swap Window Up | `openyourmac://window/swap/north` |
| `openyourmac-swap-down.sh` | Swap Window Down | `openyourmac://window/swap/south` |
| `openyourmac-swap-first.sh` | Move Window to Start | `openyourmac://window/swap/first` |
| `openyourmac-swap-last.sh` | Move Window to End | `openyourmac://window/swap/last` |
| `openyourmac-center.sh` | Center Window | `openyourmac://window/center` |
| `openyourmac-resize.sh` | Cycle Window Width | `openyourmac://window/resize` |
| `openyourmac-fullwidth.sh` | Toggle Full Width | `openyourmac://window/fullwidth` |
| `openyourmac-wider.sh` | Make Window Wider | `openyourmac://window/wider` |
| `openyourmac-narrower.sh` | Make Window Narrower | `openyourmac://window/narrower` |
| `openyourmac-taller.sh` | Make Window Taller | `openyourmac://window/taller` |
| `openyourmac-shorter.sh` | Make Window Shorter | `openyourmac://window/shorter` |
| `openyourmac-equalize.sh` | Equalize Window Heights | `openyourmac://window/equalize` |
| `openyourmac-stack.sh` | Stack Window | `openyourmac://window/stack` |
| `openyourmac-unstack.sh` | Unstack Window | `openyourmac://window/unstack` |
| `openyourmac-consume-right.sh` | Consume Window Right | `openyourmac://window/consume/east` |
| `openyourmac-expel-left.sh` | Expel Window Left | `openyourmac://window/expel/west` |
| `openyourmac-toggle-tabbed.sh` | Toggle Tabbed Column | `openyourmac://window/tabbed` |
| `openyourmac-toggle-floating.sh` | Toggle Floating | `openyourmac://window/manage` |
| `openyourmac-next-display.sh` | Move Window to Next Display | `openyourmac://window/nextdisplay` |
| `openyourmac-pin-left.sh` | Pin Window Left | `openyourmac://window/pin/left` |
| `openyourmac-pin-right.sh` | Pin Window Right | `openyourmac://window/pin/right` |
| `openyourmac-start.sh` | Start Window Manager | `openyourmac://start` |
| `openyourmac-stop.sh` | Stop Window Manager | `openyourmac://stop` |
| `openyourmac-restart.sh` | Restart Window Manager | `openyourmac://restart` |
| `openyourmac-toggle.sh` | Toggle Window Manager | `openyourmac://toggle` |

## URL scheme reference

Other launchers and shell scripts can use these same URLs. This table lists the
main routes; the app also accepts consume west and expel east. Numbered focus
and swap positions and `strip show` are CLI actions, not URL routes.
Direction values are `west`, `east`, `north`, `south`, `first`, and `last`.

| URL | Action |
| --- | --- |
| `openyourmac://start` | Start window management. |
| `openyourmac://stop` | Stop window management. |
| `openyourmac://restart` | Stop and restart the engine. |
| `openyourmac://toggle` | Switch window management on or off. |
| `openyourmac://window/focus/<dir>` | Focus a window in the given direction. |
| `openyourmac://window/swap/<dir>` | Move the active window in the given direction. |
| `openyourmac://window/center` | Center the active column on the display. |
| `openyourmac://window/resize` | Select the next preset column width. |
| `openyourmac://window/fullwidth` | Switch the active column to full width or restore its width. |
| `openyourmac://window/wider` | Increase column width. |
| `openyourmac://window/narrower` | Decrease column width. |
| `openyourmac://window/taller` | Increase the active window height in a stack. |
| `openyourmac://window/shorter` | Decrease the active window height in a stack. |
| `openyourmac://window/equalize` | Give stacked windows equal heights. |
| `openyourmac://window/stack` | Add the active window to the column on its left. |
| `openyourmac://window/unstack` | Give the active window its own column. |
| `openyourmac://window/consume/east` | Add the active window to the column on its right. |
| `openyourmac://window/expel/west` | Give the active window a new column on its left. |
| `openyourmac://window/tabbed` | Switch the active column between stacked and tabbed views. |
| `openyourmac://window/manage` | Switch the active window between tiled and floating. |
| `openyourmac://window/nextdisplay` | Move the active window to the next display. |
| `openyourmac://window/pin/<left\|right>` | Pin the active column to that edge, or unpin it. |

Use `open -g` so the URL runs in the background:

```sh
open -g "openyourmac://window/focus/east"
```

The app validates URLs against a fixed list of routes. Unknown routes are
ignored. `start` and `restart` never prompt for permission and require completed
onboarding and Accessibility access. `toggle` has the same requirements when
starting. After onboarding, it can also stop a running engine. `stop` is always
allowed.

Each script uses `open -g` to dispatch a URL. Exit 0 means that macOS accepted the
URL, not that the engine started or a window moved. Check Overview or the actual
window result. URL errors can also appear in the app's macOS unified log. The
engine log is `~/Library/Logs/OpenYourMac/engine.log`.

## Command line

In the app, choose **Help → Integrations → Install CLI**. This creates the
`~/.local/bin/openyourmac` symlink to the bundled wrapper. For example:

```sh
openyourmac window focus east
openyourmac window consume east
openyourmac strip show
openyourmac toggle
```

The engine has no `start`, `stop`, `restart`, or `toggle` subcommands. Those
CLI verbs send URLs to the app. For window commands, the wrapper sends argv
to the bundled engine and reports parsing or connection errors. Success means
delivery, not confirmation of the resulting layout.

With the app installed and the engine running, you can also send a command directly:

```sh
/Applications/OpenYourMac.app/Contents/Resources/OpenYourMacEngine send-cmd window focus east
```

If your shell cannot find `openyourmac`, add this line to `~/.zshrc`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Open a new terminal after changing `PATH`. If you move OpenYourMac, reinstall the
CLI from its Integrations section to update the symlink.

## Safety and removal

These scripts can start an app that controls real windows. For development
checks, follow [the manual testing guide](https://github.com/SergeSerb2/OpenYourMac/blob/main/docs/manual-testing.md)
and do not open URLs on the user's everyday desktop. Remove the exported
directory from Raycast's Script Commands settings before deleting it. See
[uninstall](https://github.com/SergeSerb2/OpenYourMac#uninstall) for CLI, app,
and saved-data removal.

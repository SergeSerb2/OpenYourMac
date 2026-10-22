# Setting up your Mac for OpenYourMac

OpenYourMac checks these settings on its **Mac Setup** page. The page refreshes
as settings change. Some checks are recommendations. Separate Spaces requires
a logout before it takes effect. This guide explains the setup steps.

## 1. Allow OpenYourMac to move windows

macOS lets an app move other apps' windows only with the Accessibility
permission.

1. Move OpenYourMac to `/Applications` and open that copy. If macOS blocks the
   download, follow the [install guide](../README.md#install).
2. Open **System Settings › Privacy & Security › Accessibility**.
3. Turn on **OpenYourMac**. If it is not in the list, click **+** and choose
   OpenYourMac in your Applications folder.

If OpenYourMac is already on but the app still says the permission is missing
(this can happen after an update), use **Help › Troubleshooting › Repair
Permission…**. It removes the old entry and asks again.

## 2. Keep OpenYourMac in Applications

Run OpenYourMac from **/Applications** (or `~/Applications`). A stable location avoids
translocation and keeps CLI links and login registration tied to the installed
copy. Ad-hoc rebuilds can still need a new Accessibility grant.

## 3. Give every display its own desktops

Each display has its own strip, so each display needs its own Spaces.

1. Open **System Settings › Desktop & Dock**.
2. In **Mission Control**, turn on **Displays have separate Spaces**.
3. Log out and back in.

## 4. Stop macOS reordering your desktops

Otherwise a strip can end up on a different desktop than you left it.

- **System Settings › Desktop & Dock › Mission Control**: turn off
  **Automatically rearrange Spaces based on most recent use**.

Mac Setup can change this for you (**Turn It Off for Me**). It restarts the
Dock, which takes a second.

## 5. Turn off Stage Manager and macOS tiling

Both move windows too, and they fight with the strip.

- **System Settings › Desktop & Dock**: turn off **Stage Manager**.
- In **Windows**, turn off **Drag windows to screen edges to tile**, **Drag
  windows to menu bar to fill screen**, and **Hold ⌥ key while dragging windows
  to tile** (macOS 15 and later).

## 6. Free the trackpad swipe

OpenYourMac scrolls the strip with a 3- or 4-finger horizontal swipe
(**Configuration › Gestures & Mouse**). macOS must not use the same swipe.

- With **4 fingers** (recommended): in **System Settings › Trackpad › More
  Gestures**, set **Swipe between full-screen applications** to **Off**.
  macOS can treat that setting as 4 fingers even when it says 3. To keep
  desktop swipes, set macOS to four fingers and switch OpenYourMac to 3 fingers,
  or turn the OpenYourMac swipe off and hold ⌃⌥ while you scroll.
- With **3 fingers**: set **Swipe between full-screen applications** to four
  fingers or Off, set **Swipe between pages** to **Scroll left or right with two
  fingers**, and make sure **Three Finger Drag** is off
  (**Accessibility › Pointer Control › Trackpad Options › Dragging style**).

## 7. Run one window manager at a time

Quit other window managers (Rectangle, Magnet, Amethyst, AeroSpace, yabai,
ChainYourMac, Paneru…) and turn off their launch at login. Two window managers
move the same windows and often use the same ⌃⌥ shortcuts.

## 8. Optional: stack your displays

Side by side works. If you place one display above the other in **System
Settings › Displays › Arrange**, windows can slide fully off both edges of the
strip.

## What Mac Setup changes

Checks read macOS preferences and running app information. Settings buttons open
System Settings so you can make the change. **Turn It Off for Me** changes only
**Automatically rearrange Spaces based on most recent use** and restarts the
Dock. **Quit** actions ask the listed competing apps to quit. Gesture choices
change OpenYourMac's own finger-count setting. Changes you make to macOS remain
after uninstall until you restore them in System Settings.

The app uses Accessibility to inspect, move, resize, and focus windows. Its engine
also handles keyboard and gesture input for window commands. No separate Screen
Recording grant is requested by the current app. Detailed logs can contain
window titles; review them before sharing. See
[troubleshooting](../README.md#troubleshooting-and-faq) for log and permission help.

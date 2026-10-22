#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Stack Window
# @raycast.mode silent
# @raycast.icon images/openyourmac.png
# @raycast.packageName OpenYourMac
# @raycast.description Join the active window to its left-hand column.
# @raycast.author OpenYourMac
# @raycast.authorURL https://github.com/SergeSerb2/OpenYourMac

exec /usr/bin/open -g "openyourmac://window/stack"

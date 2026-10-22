#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Swap Window Up
# @raycast.mode silent
# @raycast.icon images/openyourmac.png
# @raycast.packageName OpenYourMac
# @raycast.description Move the active window up in its column.
# @raycast.author OpenYourMac
# @raycast.authorURL https://github.com/SergeSerb2/OpenYourMac

exec /usr/bin/open -g "openyourmac://window/swap/north"

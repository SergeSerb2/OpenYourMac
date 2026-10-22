#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Move Window to Next Display
# @raycast.mode silent
# @raycast.icon images/openyourmac.png
# @raycast.packageName OpenYourMac
# @raycast.description Send the active window to the following display.
# @raycast.author OpenYourMac
# @raycast.authorURL https://github.com/SergeSerb2/OpenYourMac

exec /usr/bin/open -g "openyourmac://window/nextdisplay"

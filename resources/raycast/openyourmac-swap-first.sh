#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Move Window to Start
# @raycast.mode silent
# @raycast.icon images/openyourmac.png
# @raycast.packageName OpenYourMac
# @raycast.description Place the active window at the start of the strip.
# @raycast.author OpenYourMac
# @raycast.authorURL https://github.com/SergeSerb2/OpenYourMac

exec /usr/bin/open -g "openyourmac://window/swap/first"

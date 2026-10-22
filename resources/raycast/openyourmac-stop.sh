#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Stop Window Manager
# @raycast.mode silent
# @raycast.icon images/openyourmac.png
# @raycast.packageName OpenYourMac
# @raycast.description Stop window management and keep the app available.
# @raycast.author OpenYourMac
# @raycast.authorURL https://github.com/SergeSerb2/OpenYourMac

exec /usr/bin/open -g "openyourmac://stop"

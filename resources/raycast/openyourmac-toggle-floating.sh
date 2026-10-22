#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Toggle Floating
# @raycast.mode silent
# @raycast.icon images/openyourmac.png
# @raycast.packageName OpenYourMac
# @raycast.description Change whether the active window belongs to the strip.
# @raycast.author OpenYourMac
# @raycast.authorURL https://github.com/SergeSerb2/OpenYourMac

exec /usr/bin/open -g "openyourmac://window/manage"

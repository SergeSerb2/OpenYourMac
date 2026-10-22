#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Expel Window Left
# @raycast.mode silent
# @raycast.icon images/openyourmac.png
# @raycast.packageName OpenYourMac
# @raycast.description Place the active window in a new column on the left.
# @raycast.author OpenYourMac
# @raycast.authorURL https://github.com/SergeSerb2/OpenYourMac

exec /usr/bin/open -g "openyourmac://window/expel/west"

#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Toggle Full Width
# @raycast.mode silent
# @raycast.icon images/openyourmac.png
# @raycast.packageName OpenYourMac
# @raycast.description Switch the active column to full width or restore its width.
# @raycast.author OpenYourMac
# @raycast.authorURL https://github.com/SergeSerb2/OpenYourMac

exec /usr/bin/open -g "openyourmac://window/fullwidth"

#!/bin/zsh
# Jamf policy installation script.
# Paste this script into Jamf after packaging/copying the two project files,
# or use the standalone payload content in your preferred deployment method.

set -e

SCRIPT_DEST="/usr/local/bin/mrr-restart-reminder"
PLIST_DEST="/Library/LaunchDaemons/com.mrr.restartreminder.plist"

echo "This helper intentionally does not embed the controller."
echo "Deploy scripts/mrr-restart-reminder.zsh to ${SCRIPT_DEST}"
echo "Deploy launchdaemon/com.mrr.restartreminder.plist to ${PLIST_DEST}"
echo "Set root:wheel / 755 for controller and root:wheel / 644 for plist."
echo "Then bootstrap with:"
echo "launchctl bootstrap system ${PLIST_DEST}"

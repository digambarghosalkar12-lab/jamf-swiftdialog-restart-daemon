#!/bin/zsh
set -e

SCRIPT_SOURCE="${0:A:h}/scripts/ntrs-restart-reminder.zsh"
PLIST_SOURCE="${0:A:h}/launchdaemon/com.ntrs.restartreminder.plist"

SCRIPT_DEST="/usr/local/bin/ntrs-restart-reminder"
PLIST_DEST="/Library/LaunchDaemons/com.ntrs.restartreminder.plist"
LEGACY_SCRIPT_DEST="/usr/local/bin/dg-restart-reminder"
LEGACY_PLIST_DEST="/Library/LaunchDaemons/com.dg.restartreminder.plist"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

# Stop and remove the former label so upgrades cannot run two controllers.
/bin/launchctl bootout system "$LEGACY_PLIST_DEST" >/dev/null 2>&1 || true
/bin/rm -f "$LEGACY_SCRIPT_DEST" "$LEGACY_PLIST_DEST"

/bin/mkdir -p /usr/local/bin
/bin/cp "$SCRIPT_SOURCE" "$SCRIPT_DEST"
/usr/sbin/chown root:wheel "$SCRIPT_DEST"
/bin/chmod 755 "$SCRIPT_DEST"

/bin/cp "$PLIST_SOURCE" "$PLIST_DEST"
/usr/sbin/chown root:wheel "$PLIST_DEST"
/bin/chmod 644 "$PLIST_DEST"

/bin/launchctl bootout system "$PLIST_DEST" >/dev/null 2>&1 || true
/bin/launchctl bootstrap system "$PLIST_DEST"
/bin/launchctl enable system/com.ntrs.restartreminder
/bin/launchctl kickstart -k system/com.ntrs.restartreminder

echo "Installed com.ntrs.restartreminder"

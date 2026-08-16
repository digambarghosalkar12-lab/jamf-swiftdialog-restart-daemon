#!/bin/zsh
# Jamf-ready uninstaller for NTRS Restart Reminder.

set -e

LABEL="com.ntrs.restartreminder"
SCRIPT_PATH="/usr/local/bin/ntrs-restart-reminder"
PLIST_PATH="/Library/LaunchDaemons/${LABEL}.plist"
STATE_DIR="/Library/Application Support/NTRSRestartReminder"
LOCAL_PREFS="/Library/Preferences/${LABEL}.plist"
LOG_PATH="/var/log/ntrs-restart-reminder.log"
LAUNCHD_LOG_PATH="/var/log/ntrs-restart-reminder-launchd.log"

LEGACY_LABEL="com.dg.restartreminder"
LEGACY_SCRIPT_PATH="/usr/local/bin/dg-restart-reminder"
LEGACY_PLIST_PATH="/Library/LaunchDaemons/${LEGACY_LABEL}.plist"
LEGACY_STATE_DIR="/Library/Application Support/DGRestartReminder"
LEGACY_LOCAL_PREFS="/Library/Preferences/${LEGACY_LABEL}.plist"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

# Stop both current and legacy jobs. bootout may fail when a job is not loaded.
/bin/launchctl bootout system "$PLIST_PATH" >/dev/null 2>&1 || true
/bin/launchctl bootout system "$LEGACY_PLIST_PATH" >/dev/null 2>&1 || true

/bin/rm -f \
  "$SCRIPT_PATH" \
  "$PLIST_PATH" \
  "$LOCAL_PREFS" \
  "$LOG_PATH" \
  "$LAUNCHD_LOG_PATH" \
  "$LEGACY_SCRIPT_PATH" \
  "$LEGACY_PLIST_PATH" \
  "$LEGACY_LOCAL_PREFS"

/bin/rm -rf "$STATE_DIR" "$LEGACY_STATE_DIR"

echo "Uninstalled ${LABEL}."
echo "Remove the Jamf configuration profile scope separately to clear managed preferences."

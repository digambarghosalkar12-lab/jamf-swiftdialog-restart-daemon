#!/bin/zsh
set -e

SCRIPT_DEST="/usr/local/bin/mrr-restart-reminder"
PLIST_DEST="/Library/LaunchDaemons/com.mrr.restartreminder.plist"
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


# Embedded plain-text payloads keep this Jamf installer self-contained.
# Edit the controller directly inside this heredoc when customization is needed.
/bin/cat <<'MRR_SCRIPT' > "$SCRIPT_DEST"
#!/bin/zsh
# Jamf + swiftDialog Restart Reminder
# Runs as root from LaunchDaemon.
# Configuration is delivered by Jamf Application & Custom Settings.
# Preference domain: com.mrr.restartreminder

set -u

PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
PREF_DOMAIN="com.mrr.restartreminder"
MANAGED_PLIST="/Library/Managed Preferences/${PREF_DOMAIN}.plist"
LOCAL_PREF_PLIST="/Library/Preferences/${PREF_DOMAIN}.plist"

STATE_DIR="/Library/Application Support/MRRRestartReminder"
STATE_PLIST="${STATE_DIR}/state.plist"
LEGACY_STATE_PLIST="/Library/Application Support/DGRestartReminder/state.plist"

DEFAULT_LOG="/var/log/mrr-restart-reminder.log"
DIALOG_CANDIDATES=(
  "/usr/local/bin/dialog"
  "/Library/Application Support/Dialog/Dialog.app/Contents/MacOS/Dialog"
)

mkdir -p "$STATE_DIR"
chmod 755 "$STATE_DIR"

# Preserve deferral state when upgrading from the former DG-labelled version.
if [[ ! -f "$STATE_PLIST" && -f "$LEGACY_STATE_PLIST" ]]; then
  /bin/cp "$LEGACY_STATE_PLIST" "$STATE_PLIST"
  /usr/sbin/chown root:wheel "$STATE_PLIST"
  /bin/chmod 644 "$STATE_PLIST"
fi

# -----------------------------
# Helpers
# -----------------------------

managed_plist() {
  if [[ -f "$MANAGED_PLIST" ]]; then
    echo "$MANAGED_PLIST"
  elif [[ -f "$LOCAL_PREF_PLIST" ]]; then
    echo "$LOCAL_PREF_PLIST"
  else
    echo ""
  fi
}

read_pref() {
  local key="$1"
  local fallback="$2"
  local plist
  plist="$(managed_plist)"

  if [[ -n "$plist" ]]; then
    local value
    value=$(/usr/libexec/PlistBuddy -c "Print :${key}" "$plist" 2>/dev/null || true)
    if [[ -n "$value" ]]; then
      echo "$value"
      return 0
    fi
  fi

  echo "$fallback"
}

bool_pref() {
  local key="$1"
  local fallback="$2"
  local value
  value="$(read_pref "$key" "$fallback")"
  value="$(printf '%s' "$value" | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/tr -d '[:space:]')"
  case "$value" in
    true|1|yes|on) echo "true" ;;
    *) echo "false" ;;
  esac
}

integer_pref() {
  local key="$1"
  local fallback="$2"
  local minimum="$3"
  local value
  value="$(read_pref "$key" "$fallback")"

  if [[ "$value" =~ '^[0-9]+$' ]] && (( value >= minimum )); then
    echo "$value"
  else
    log "Invalid ${key} value '${value}'; using ${fallback}."
    echo "$fallback"
  fi
}

alignment_pref() {
  local key="$1"
  local fallback="$2"
  local value
  value="$(read_pref "$key" "$fallback")"
  value="$(printf '%s' "$value" | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/tr -d '[:space:]')"

  case "$value" in
    left|center|centre|right) echo "$value" ;;
    *)
      log "Invalid ${key} value '${value}'; using ${fallback}."
      echo "$fallback"
      ;;
  esac
}

state_read() {
  local key="$1"
  local fallback="$2"
  if [[ -f "$STATE_PLIST" ]]; then
    local value
    value=$(/usr/libexec/PlistBuddy -c "Print :${key}" "$STATE_PLIST" 2>/dev/null || true)
    [[ -n "$value" ]] && { echo "$value"; return 0; }
  fi
  echo "$fallback"
}

state_write() {
  local key="$1"
  local type="$2"
  local value="$3"

  if [[ ! -f "$STATE_PLIST" ]]; then
    /usr/bin/plutil -create xml1 "$STATE_PLIST"
    chmod 644 "$STATE_PLIST"
  fi

  /usr/libexec/PlistBuddy -c "Delete :${key}" "$STATE_PLIST" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :${key} ${type} ${value}" "$STATE_PLIST" >/dev/null 2>&1
}

get_log_file() {
  local configured
  configured="$(read_pref "LogFileLocation" "$DEFAULT_LOG")"

  # This process runs as root. Restrict managed log destinations to a simple
  # filename directly beneath /var/log to prevent arbitrary privileged writes.
  if [[ "$configured" =~ '^/var/log/[A-Za-z0-9._-]+$' ]]; then
    echo "$configured"
  else
    echo "$DEFAULT_LOG"
  fi
}

log() {
  local logfile
  logfile="$(get_log_file)"
  mkdir -p "$(dirname "$logfile")" 2>/dev/null || true
  printf '%s %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$logfile"
}

clear_restart_logs() {
  local configured_log
  configured_log="$(get_log_file)"
  /bin/rm -f "$configured_log" "$DEFAULT_LOG" \
    "/var/log/mrr-restart-reminder-launchd.log"
}

force_quit_user_apps() {
  local uid="$1"

  # Tear down the user's launchd GUI domain so open applications cannot block
  # the configured forced restart. Fall back to killing that user's processes
  # if the GUI domain cannot be booted out.
  if ! /bin/launchctl bootout "gui/${uid}" >/dev/null 2>&1; then
    /usr/bin/pkill -KILL -u "$uid" >/dev/null 2>&1 || true
  fi
}

find_dialog() {
  local p
  for p in "${DIALOG_CANDIDATES[@]}"; do
    [[ -x "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

console_user() {
  /usr/bin/stat -f "%Su" /dev/console 2>/dev/null
}

console_uid() {
  local user="$1"
  /usr/bin/id -u "$user" 2>/dev/null
}

run_as_user() {
  local uid="$1"
  shift
  /bin/launchctl asuser "$uid" /usr/bin/sudo -u "#$uid" "$@"
}

last_boot_epoch() {
  /usr/sbin/sysctl -n kern.boottime |
    /usr/bin/awk -F'[ ,}]+' '{print $4}'
}

days_since_boot() {
  local boot now
  boot="$(last_boot_epoch)"
  now="$(/bin/date +%s)"
  echo $(( (now - boot) / 86400 ))
}

meeting_active() {
  local user="$1"

  [[ "$(bool_pref "CheckDNDOrMeeting" "true")" != "true" ]] && return 1

  # Do not infer a meeting merely because an app is open. Require both a
  # supported conferencing process for the console user and an active input
  # audio engine. This is intentionally fail-open: if macOS exposes no usable
  # audio-engine state, the reminder proceeds instead of deferring forever.
  local processes audio_engines assertions
  processes="$(/bin/ps -axo user=,comm=,args= 2>/dev/null || true)"
  if ! echo "$processes" | /usr/bin/awk -v target="$user" '
    $1 == target && tolower($0) ~ /(microsoft teams|msteams|zoom\.us|webex|facetime)/ { found=1 }
    END { exit !found }
  '; then
    return 1
  fi

  audio_engines="$(/usr/sbin/ioreg -r -c IOAudioEngine -l 2>/dev/null || true)"
  if echo "$audio_engines" | /usr/bin/awk '
    BEGIN { RS="\\n[| ]*}"; IGNORECASE=1 }
    /IOAudioEngineState[^\n]*= 1/ && /(input|capture)/ { found=1 }
    END { exit !found }
  '; then
    log "Active conferencing app and microphone input detected for ${user}; deferring notification."
    return 0
  fi

  # IOAudioEngine is absent on some Apple silicon/macOS combinations. Meeting
  # apps commonly hold a power assertion while a call or screen share is active,
  # so use that as a secondary signal after confirming the app belongs to the
  # console user.
  assertions="$(/usr/bin/pmset -g assertions 2>/dev/null || true)"
  if echo "$assertions" | /usr/bin/awk '
    tolower($0) ~ /(microsoft teams|msteams|zoom\.us|webex|facetime)/ &&
      tolower($0) ~ /(preventuseridle|no-display-sleep|screen.?share|meeting|call)/ { found=1 }
    END { exit !found }
  '; then
    log "Active conferencing power assertion detected for ${user}; deferring notification."
    return 0
  fi

  return 1
}

reset_state_if_rebooted() {
  local current_boot previous_boot
  current_boot="$(last_boot_epoch)"
  previous_boot="$(state_read "BootEpoch" "0")"

  if [[ "$current_boot" != "$previous_boot" ]]; then
    state_write "BootEpoch" integer "$current_boot"
    state_write "SnoozeCount" integer "0"
    state_write "NextPromptEpoch" integer "0"
    log "New boot detected. Restart reminder state reset."
  fi
}

dialog_common_args() {
  local icon banner
  icon="$(read_pref "Icon" "SF=arrow.clockwise.circle.fill")"
  banner="$(read_pref "Banner" "")"

  local args=()
  [[ -n "$icon" ]] && args+=(--icon "$icon")
  [[ -n "$banner" ]] && args+=(--bannerimage "$banner")
  echo "${(q)args[@]}"
}

show_standard_dialog() {
  local dialog="$1"
  local uid="$2"

  local title message button icon banner width height title_font title_alignment message_font message_alignment
  title="$(read_pref "MessageTitle" "Restart Required")"
  message="$(read_pref "Message" "Your Mac has been running for several days. Please restart to keep it secure and reliable.")"
  button="$(read_pref "ButtonName" "Restart Now")"
  icon="$(read_pref "Icon" "SF=arrow.clockwise.circle.fill")"
  banner="$(read_pref "Banner" "")"
  width="$(integer_pref "WindowWidth" "700" "300")"
  height="$(integer_pref "WindowHeight" "450" "200")"
  title_font="$(read_pref "WindowTitleFont" "size=28,weight=bold")"
  title_alignment="$(alignment_pref "WindowTitleAlignment" "left")"
  message_font="$(read_pref "WindowMessageFont" "size=14")"
  message_alignment="$(alignment_pref "WindowMessageAlignment" "left")"

  local snooze_used snooze_max
  snooze_used="$(state_read "SnoozeCount" "0")"
  snooze_max="$(integer_pref "SnoozeCount" "3" "0")"

  local args=(
    "$dialog"
    --title "$title"
    --message "$message"
    --button1text "$button"
    --width "$width"
    --height "$height"
    --titlefont "${title_font},alignment=${title_alignment}"
    --messagefont "$message_font"
    --messagealignment "$message_alignment"
  )

  # PersistentWindow is controlled by Jamf.
  # When enabled the dialog stays above other windows, is not moveable,
  # and accidental Return/Escape actions are harder to trigger.
  if [[ "$(bool_pref "PersistentWindow" "false")" == "true" ]]; then
    args+=(--ontop --hidedefaultkeyboardaction)
  else
    args+=(--moveable)
  fi

  [[ -n "$icon" ]] && args+=(--icon "$icon")
  [[ -n "$banner" ]] && args+=(--bannerimage "$banner")

  if (( snooze_used < snooze_max )); then
    local snooze_label
    snooze_label="$(read_pref "SnoozeButtonName" "Snooze")"
    args+=(--button2text "$snooze_label")
  fi

  run_as_user "$uid" "${args[@]}"
  return $?
}

show_force_dialog() {
  local dialog="$1"
  local uid="$2"

  local title message icon banner timer width height title_font title_alignment message_font message_alignment
  title="$(read_pref "ForceRestartWindowTitle" "Restart Required Now")"
  message="$(read_pref "ForceRestartWindowMessage" "This Mac must restart. Save your work now. The computer will restart automatically when the countdown reaches zero.")"
  icon="$(read_pref "ForceRestartWindowIcon" "SF=exclamationmark.triangle.fill")"
  banner="$(read_pref "Banner" "")"
  timer="$(integer_pref "CountDownTimer" "900" "60")"
  width="$(integer_pref "ForceRestartWindowWidth" "700" "300")"
  height="$(integer_pref "ForceRestartWindowHeight" "450" "200")"
  title_font="$(read_pref "ForceRestartWindowTitleFont" "size=28,weight=bold")"
  title_alignment="$(alignment_pref "ForceRestartWindowTitleAlignment" "left")"
  message_font="$(read_pref "ForceRestartWindowMessageFont" "size=14")"
  message_alignment="$(alignment_pref "ForceRestartWindowMessageAlignment" "left")"

  local args=(
    "$dialog"
    --title "$title"
    --message "$message"
    --button1text "$(read_pref "ButtonName" "Restart Now")"
    --timer "$timer"
    --width "$width"
    --height "$height"
    --titlefont "${title_font},alignment=${title_alignment}"
    --messagefont "$message_font"
    --messagealignment "$message_alignment"
    --ontop
    --quitkey "k"
  )

  [[ -n "$icon" ]] && args+=(--icon "$icon")
  [[ -n "$banner" ]] && args+=(--bannerimage "$banner")

  log "Displaying final forced restart dialog with ${timer}s countdown."
  run_as_user "$uid" "${args[@]}"
  local rc=$?

  # swiftDialog: 0 is Button 1 and 4 is timer expiry. Never restart after an
  # unexpected UI failure; log it and allow launchd to try again next cycle.
  if [[ "$rc" -eq 0 || "$rc" -eq 4 ]]; then
    log "Final dialog ended with expected exit code ${rc}. Force-quitting user applications and restarting device."
    force_quit_user_apps "$uid"
    clear_restart_logs
    /sbin/shutdown -r now
  else
    log "Final dialog ended unexpectedly with exit code ${rc}; restart cancelled for safety."
    return 1
  fi
}

schedule_snooze() {
  local snooze_used interval_hours now next
  snooze_used="$(state_read "SnoozeCount" "0")"
  snooze_used=$(( snooze_used + 1 ))
  state_write "SnoozeCount" integer "$snooze_used"

  interval_hours="$(integer_pref "SnoozeIntervalHours" "4" "1")"

  now="$(/bin/date +%s)"
  next=$(( now + (interval_hours * 3600) ))
  state_write "NextPromptEpoch" integer "$next"
  log "User snoozed. Snooze ${snooze_used}; next eligible prompt epoch ${next}."
}

# -----------------------------
# Main
# -----------------------------

if [[ "$(bool_pref "Enabled" "true")" != "true" ]]; then
  exit 0
fi

reset_state_if_rebooted

restart_interval_days="$(integer_pref "RestartIntervalDays" "7" "1")"

uptime_days="$(days_since_boot)"
if (( uptime_days < restart_interval_days )); then
  exit 0
fi

user="$(console_user)"
if [[ -z "$user" || "$user" == "root" || "$user" == "loginwindow" || "$user" == "_mbsetupuser" ]]; then
  log "No interactive user; restart reminder skipped."
  exit 0
fi

uid="$(console_uid "$user")"
if [[ -z "$uid" ]]; then
  log "Unable to determine UID for ${user}."
  exit 1
fi

dialog="$(find_dialog || true)"
if [[ -z "$dialog" ]]; then
  log "swiftDialog executable not found."
  exit 1
fi

now="$(/bin/date +%s)"
next_prompt="$(state_read "NextPromptEpoch" "0")"
if (( now < next_prompt )); then
  exit 0
fi

snooze_used="$(state_read "SnoozeCount" "0")"
snooze_max="$(integer_pref "SnoozeCount" "3" "0")"

if meeting_active "$user"; then
  if (( snooze_used < snooze_max )) || \
      [[ "$(bool_pref "IgnoreMeetingDuringForceRestart" "false")" != "true" ]]; then
    log "Active meeting detected; waiting until the next 5-minute launchd check."
    exit 0
  fi
  log "Active meeting detected, but IgnoreMeetingDuringForceRestart is enabled; continuing forced restart."
fi

if (( snooze_used < snooze_max )); then
  log "Showing restart reminder to ${user}; uptime=${uptime_days}d; snoozes=${snooze_used}/${snooze_max}."

  dialog_failures=0
  while true; do
    show_standard_dialog "$dialog" "$uid"
    rc=$?

    # swiftDialog documented exit codes:
    # 0 = Button 1, 2 = Button 2, 10 = Cmd+Q.
    if [[ "$rc" -eq 0 ]]; then
      log "User selected Restart Now."
      clear_restart_logs
      /sbin/shutdown -r now
      break
    elif [[ "$rc" -eq 2 ]]; then
      schedule_snooze
      break
    elif [[ "$(bool_pref "PersistentWindow" "false")" == "true" ]]; then
      dialog_failures=$(( dialog_failures + 1 ))
      if (( dialog_failures >= 3 )); then
        log "Persistent dialog failed ${dialog_failures} times; giving up until the next launchd cycle."
        exit 1
      fi
      log "PersistentWindow enabled; dialog exited unexpectedly with code ${rc}. Reopening."
      /bin/sleep 2
      continue
    else
      # Non-persistent mode treats another dismissal as a snooze.
      schedule_snooze
      break
    fi
  done
else
  # Once snoozes are exhausted we do not defer for an active meeting:
  # this is the configured forced restart stage.
  show_force_dialog "$dialog" "$uid"
fi

exit 0
MRR_SCRIPT

/usr/sbin/chown root:wheel "$SCRIPT_DEST"
/bin/chmod 755 "$SCRIPT_DEST"


# Edit the LaunchDaemon directly inside this heredoc when customization is needed.
/bin/cat <<'MRR_PLIST' > "$PLIST_DEST"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mrr.restartreminder</string>

    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/mrr-restart-reminder</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>StartInterval</key>
    <integer>300</integer>

    <key>ProcessType</key>
    <string>Background</string>

    <key>StandardOutPath</key>
    <string>/var/log/mrr-restart-reminder-launchd.log</string>

    <key>StandardErrorPath</key>
    <string>/var/log/mrr-restart-reminder-launchd.log</string>
</dict>
</plist>
MRR_PLIST

/usr/sbin/chown root:wheel "$PLIST_DEST"
/bin/chmod 644 "$PLIST_DEST"

/bin/launchctl bootout system "$PLIST_DEST" >/dev/null 2>&1 || true
/bin/launchctl bootstrap system "$PLIST_DEST"
/bin/launchctl enable system/com.mrr.restartreminder
/bin/launchctl kickstart -k system/com.mrr.restartreminder

echo "Installed com.mrr.restartreminder"

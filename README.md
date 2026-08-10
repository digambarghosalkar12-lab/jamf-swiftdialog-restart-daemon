# Jamf + swiftDialog Restart Reminder

A configuration-driven macOS restart reminder for Jamf Pro.

## Design

- **LaunchDaemon:** `com.ntrs.restartreminder`
- **Controller:** `/usr/local/bin/ntrs-restart-reminder`
- **Jamf preference domain:** `com.ntrs.restartreminder`
- **State:** `/Library/Application Support/NTRSRestartReminder/state.plist`
- **Default log:** `/var/log/ntrs-restart-reminder.log`
- **Check cadence:** every 30 minutes
- **UI:** swiftDialog

Jamf controls the behavior; the local state file only tracks the current boot,
snoozes used, and next eligible prompt.

## Admin-controlled settings

1. Message
2. Message title
3. Icon
4. Banner
5. Restart button name
6. Final forced restart message
7. Final forced restart title
8. Final forced restart icon
9. Countdown timer
10. Restart interval in days
11. Snooze count
12. Snooze interval
13. Active meeting check (DND/Focus is ignored)
14. Meeting deferral interval
15. Log file location
16. Enabled / disabled
17. Persistent window

## User flow

```text
LaunchDaemon wakes every 30 minutes
        |
        v
Is Enabled = true?
        | no -> Exit
        v yes
Has uptime reached RestartIntervalDays?
        | no -> Exit
        v yes
Interactive user logged in?
        | no -> Exit
        v yes
Snoozes remaining?
      /       \
    yes       no
     |         |
Active meeting? Final forced window
  |     |       + countdown
 yes    no      + forced restart
  |      |
defer   Normal reminder
         |       |
      Restart   Snooze
         |        |
      reboot    state++
```

## Jamf Pro configuration profile

Create:

**Computers → Configuration Profiles → New → Application & Custom Settings → External Applications → Custom Schema**

Preference domain:

```text
com.ntrs.restartreminder
```

Paste the contents of:

```text
jamf/com.ntrs.restartreminder.schema.json
```

Jamf will expose the keys as editable controls.

### Persistent restart window

Set:

```text
PersistentWindow = true
```

When enabled for the **normal reminder window**:

- swiftDialog is kept on top.
- The window is not moveable.
- Default Return/Escape keyboard dismissal is hardened with
  `--hidedefaultkeyboardaction`.
- If swiftDialog exits without **Restart Now** or **Snooze**, the controller
  reopens it after two seconds.

Set:

```text
PersistentWindow = false
```

to use the standard moveable reminder behavior.

The final forced restart window is already enforced by its countdown and restart
logic, so this setting primarily controls the normal restart reminder.

### Disable the workflow

Set:

```text
Enabled = false
```

The LaunchDaemon does not have to be unloaded. It continues waking at its
configured interval and exits immediately. This makes rollback/re-enable simple
and avoids needing a separate Jamf policy just to manipulate launchd.

## swiftDialog

The script looks for:

```text
/usr/local/bin/dialog
```

and:

```text
/Library/Application Support/Dialog/Dialog.app/Contents/MacOS/Dialog
```

Deploy swiftDialog before enabling this workflow.

## Meeting behavior

The script intentionally avoids reading the user's Calendar database.

Focus and DND status are ignored. Normal reminders are deferred only when a
supported conferencing process (Teams, Zoom, Webex, or FaceTime) is running and
the Mac reports either an active microphone input engine or a conferencing power
assertion associated with that app. Simply leaving a meeting app open is not
enough to trigger a deferral. Detection is deliberately fail-open because macOS
does not provide a stable system meeting-status API.

The final forced restart stage is not deferred once the configured snooze
allowance has been exhausted.

For organizations that require authoritative meeting-state detection, use a
separate user-context LaunchAgent or an approved calendar integration and pass
the result to this controller.

## Installation

Copy:

```text
scripts/ntrs-restart-reminder.zsh
```

to:

```text
/usr/local/bin/ntrs-restart-reminder
```

Permissions:

```text
root:wheel 755
```

Copy:

```text
launchdaemon/com.ntrs.restartreminder.plist
```

to:

```text
/Library/LaunchDaemons/com.ntrs.restartreminder.plist
```

Permissions:

```text
root:wheel 644
```

Then:

```bash
launchctl bootstrap system /Library/LaunchDaemons/com.ntrs.restartreminder.plist
launchctl enable system/com.ntrs.restartreminder
launchctl kickstart -k system/com.ntrs.restartreminder
```

## Testing

For lab testing, set:

- RestartIntervalDays = 1
- SnoozeCount = 1
- SnoozeIntervalHours = 1
- CountDownTimer = 60

Do **not** test forced restart settings on production Macs before validating in a
small smart group.

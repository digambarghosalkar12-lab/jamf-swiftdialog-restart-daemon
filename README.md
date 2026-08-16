# Jamf + swiftDialog Restart Reminder

A configuration-driven macOS restart reminder for Jamf Pro.

## Design

- **LaunchDaemon:** `com.mrr.restartreminder`
- **Controller:** `/usr/local/bin/mrr-restart-reminder`
- **Jamf preference domain:** `com.mrr.restartreminder`
- **State:** `/Library/Application Support/MRRRestartReminder/state.plist`
- **Default log:** `/var/log/mrr-restart-reminder.log`
- **Check cadence:** every 5 minutes
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
14. Ignore meeting during force restart
15. Log file location
16. Enabled / disabled
17. Persistent window
18. Normal reminder window width and height
19. Forced restart window width and height
20. Normal reminder title/message fonts and alignment
21. Forced restart title/message fonts and alignment

## User flow

```text
LaunchDaemon wakes every 5 minutes
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
com.mrr.restartreminder
```

Paste the contents of:

```text
jamf/com.mrr.restartreminder.schema.json
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

After the configured snooze allowance is exhausted, the forced restart stage
still waits for an active meeting to end by default. Set
`IgnoreMeetingDuringForceRestart = true` to show the forced countdown during a
meeting. While waiting, the daemon checks again every five minutes.

When the forced countdown ends—or the user selects **Restart Now** in the forced
window—the controller tears down the logged-in user's GUI session, force-quits
remaining user applications, clears its logs, and restarts the Mac. Unsaved work
in open applications will be lost at this stage.

For organizations that require authoritative meeting-state detection, use a
separate user-context LaunchAgent or an approved calendar integration and pass
the result to this controller.

## Installation

`install.sh` is self-contained and generates both the controller and LaunchDaemon
from readable, unencoded `cat` heredocs. Jamf administrators can edit those
embedded sections directly. Run it as root; the `scripts/` and `launchdaemon/`
source directories do not need to be copied to the target Mac.

```bash
sudo ./install.sh
```

For manual packaging, the equivalent source files and destinations are shown
below.

### Generate Jamf assets

Run:

```bash
./generate-jamf-assets.sh
```

The generator prompts for all three asset filenames and shows the required
format and an example for each. Press Return to accept the displayed default.
It then creates the named install script, uninstall script, and Custom JSON
Schema under `dist/`. Add the install or uninstall script to a Jamf policy and
paste the JSON file into **Application & Custom Settings**.

An alternate output directory can be supplied as the first argument.

For unattended generation, set `JAMF_INSTALL_ASSET_NAME`,
`JAMF_UNINSTALL_ASSET_NAME`, and `JAMF_SCHEMA_ASSET_NAME`.

### Uninstallation

Use `uninstall.sh` directly or the generated `dist/jamf-uninstall.sh`. The
uninstaller removes the installed daemon, controller, state, local preferences,
and logs. Remove the configuration profile's Jamf scope separately because
managed preferences are controlled by MDM.

Copy:

```text
scripts/mrr-restart-reminder.zsh
```

to:

```text
/usr/local/bin/mrr-restart-reminder
```

Permissions:

```text
root:wheel 755
```

Copy:

```text
launchdaemon/com.mrr.restartreminder.plist
```

to:

```text
/Library/LaunchDaemons/com.mrr.restartreminder.plist
```

Permissions:

```text
root:wheel 644
```

Then:

```bash
launchctl bootstrap system /Library/LaunchDaemons/com.mrr.restartreminder.plist
launchctl enable system/com.mrr.restartreminder
launchctl kickstart -k system/com.mrr.restartreminder
```

## Testing

For lab testing, set:

- RestartIntervalDays = 1
- SnoozeCount = 1
- SnoozeIntervalHours = 1
- CountDownTimer = 60

Do **not** test forced restart settings on production Macs before validating in a
small smart group.

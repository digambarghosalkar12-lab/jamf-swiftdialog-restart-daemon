#!/bin/zsh
# Generate Jamf-ready install/uninstall scripts and Custom JSON Schema.

set -euo pipefail

PROJECT_DIR="${0:A:h}"
CONTROLLER_SOURCE="${PROJECT_DIR}/scripts/ntrs-restart-reminder.zsh"
PLIST_SOURCE="${PROJECT_DIR}/launchdaemon/com.ntrs.restartreminder.plist"
SCHEMA_SOURCE="${PROJECT_DIR}/jamf/com.ntrs.restartreminder.schema.json"
UNINSTALL_SOURCE="${PROJECT_DIR}/uninstall.sh"
OUTPUT_DIR="${1:-${PROJECT_DIR}/dist}"

INSTALL_ASSET_NAME="${JAMF_INSTALL_ASSET_NAME:-}"
UNINSTALL_ASSET_NAME="${JAMF_UNINSTALL_ASSET_NAME:-}"
SCHEMA_ASSET_NAME="${JAMF_SCHEMA_ASSET_NAME:-}"

prompt_asset_filename() {
  local variable_name="$1"
  local asset_label="$2"
  local required_suffix="$3"
  local example="$4"
  local default_name="$5"
  local current_value="${(P)variable_name}"
  local reply

  if [[ -n "$current_value" ]]; then
    reply="$current_value"
  elif [[ -t 0 ]]; then
    echo ""
    echo "Enter the ${asset_label} asset filename."
    echo "Format: <asset-name>${required_suffix}"
    echo "Example: ${example}"
    printf "Filename [%s]: " "$default_name"
    IFS= read -r reply
    [[ -n "$reply" ]] || reply="$default_name"
  else
    reply="$default_name"
  fi

  if [[ ! "$reply" =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' ]] || \
      [[ "$reply" != *"${required_suffix}" ]]; then
    echo "Invalid ${asset_label} filename: ${reply}" >&2
    echo "Required format: <asset-name>${required_suffix}" >&2
    exit 1
  fi

  typeset -g "$variable_name"="$reply"
}

prompt_asset_filename \
  INSTALL_ASSET_NAME \
  "Jamf install script" \
  "-install.sh" \
  "ntrs-restart-reminder-install.sh" \
  "jamf-install.sh"

prompt_asset_filename \
  UNINSTALL_ASSET_NAME \
  "Jamf uninstall script" \
  "-uninstall.sh" \
  "ntrs-restart-reminder-uninstall.sh" \
  "jamf-uninstall.sh"

prompt_asset_filename \
  SCHEMA_ASSET_NAME \
  "Jamf Custom JSON Schema" \
  ".json" \
  "com.ntrs.restartreminder.schema.json" \
  "com.ntrs.restartreminder.schema.json"

INSTALL_OUTPUT="${OUTPUT_DIR}/${INSTALL_ASSET_NAME}"
UNINSTALL_OUTPUT="${OUTPUT_DIR}/${UNINSTALL_ASSET_NAME}"
SCHEMA_OUTPUT="${OUTPUT_DIR}/${SCHEMA_ASSET_NAME}"

for required_file in \
  "$CONTROLLER_SOURCE" \
  "$PLIST_SOURCE" \
  "$SCHEMA_SOURCE" \
  "$UNINSTALL_SOURCE"; do
  if [[ ! -f "$required_file" ]]; then
    echo "Required source file not found: ${required_file}" >&2
    exit 1
  fi
done

# Exact delimiter lines would prematurely close the generated heredocs.
if /usr/bin/grep -qx 'NTRS_CONTROLLER' "$CONTROLLER_SOURCE"; then
  echo "Controller contains reserved line: NTRS_CONTROLLER" >&2
  exit 1
fi
if /usr/bin/grep -qx 'NTRS_LAUNCHDAEMON' "$PLIST_SOURCE"; then
  echo "LaunchDaemon contains reserved line: NTRS_LAUNCHDAEMON" >&2
  exit 1
fi

/bin/mkdir -p "$OUTPUT_DIR"

/bin/cat > "$INSTALL_OUTPUT" <<'INSTALL_HEADER'
#!/bin/zsh
# Generated Jamf installation script for NTRS Restart Reminder.
# Controller and LaunchDaemon payloads are plain text and can be edited below.

set -e

SCRIPT_DEST="/usr/local/bin/ntrs-restart-reminder"
PLIST_DEST="/Library/LaunchDaemons/com.ntrs.restartreminder.plist"
LEGACY_SCRIPT_DEST="/usr/local/bin/dg-restart-reminder"
LEGACY_PLIST_DEST="/Library/LaunchDaemons/com.dg.restartreminder.plist"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

/bin/launchctl bootout system "$LEGACY_PLIST_DEST" >/dev/null 2>&1 || true
/bin/rm -f "$LEGACY_SCRIPT_DEST" "$LEGACY_PLIST_DEST"
/bin/mkdir -p /usr/local/bin

/bin/cat <<'NTRS_CONTROLLER' > "$SCRIPT_DEST"
INSTALL_HEADER

/bin/cat "$CONTROLLER_SOURCE" >> "$INSTALL_OUTPUT"

/bin/cat >> "$INSTALL_OUTPUT" <<'INSTALL_MIDDLE'
NTRS_CONTROLLER

/usr/sbin/chown root:wheel "$SCRIPT_DEST"
/bin/chmod 755 "$SCRIPT_DEST"

/bin/cat <<'NTRS_LAUNCHDAEMON' > "$PLIST_DEST"
INSTALL_MIDDLE

/bin/cat "$PLIST_SOURCE" >> "$INSTALL_OUTPUT"

/bin/cat >> "$INSTALL_OUTPUT" <<'INSTALL_FOOTER'
NTRS_LAUNCHDAEMON

/usr/sbin/chown root:wheel "$PLIST_DEST"
/bin/chmod 644 "$PLIST_DEST"

/bin/launchctl bootout system "$PLIST_DEST" >/dev/null 2>&1 || true
/bin/launchctl bootstrap system "$PLIST_DEST"
/bin/launchctl enable system/com.ntrs.restartreminder
/bin/launchctl kickstart -k system/com.ntrs.restartreminder

echo "Installed com.ntrs.restartreminder"
INSTALL_FOOTER

/bin/cp "$UNINSTALL_SOURCE" "$UNINSTALL_OUTPUT"
/bin/cp "$SCHEMA_SOURCE" "$SCHEMA_OUTPUT"
/bin/chmod 755 "$INSTALL_OUTPUT" "$UNINSTALL_OUTPUT"
/bin/chmod 644 "$SCHEMA_OUTPUT"

/bin/zsh -n "$INSTALL_OUTPUT" "$UNINSTALL_OUTPUT"
/usr/bin/plutil -lint "$PLIST_SOURCE" >/dev/null
if [[ -x /usr/bin/python3 ]]; then
  /usr/bin/python3 -m json.tool "$SCHEMA_OUTPUT" >/dev/null
fi

echo "Generated Jamf assets:"
echo "  Install script: ${INSTALL_OUTPUT}"
echo "  Uninstall script: ${UNINSTALL_OUTPUT}"
echo "  Custom schema: ${SCHEMA_OUTPUT}"

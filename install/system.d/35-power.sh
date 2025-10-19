#!/usr/bin/env bash

set -euo pipefail

# Prevent the physical power button from immediately powering off the device.

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

LOGIND_CONF=/etc/systemd/logind.conf

if [[ -f "$LOGIND_CONF" ]]; then
	# Update (or append) the HandlePowerKey entry so physical presses fall through to the desktop menu.
	if grep -q '^HandlePowerKey' "$LOGIND_CONF"; then
		sed -i 's/^HandlePowerKey=.*/HandlePowerKey=ignore/' "$LOGIND_CONF"
	else
		echo 'HandlePowerKey=ignore' >>"$LOGIND_CONF"
	fi
	# Restart logind so the new behaviour is effective immediately without a reboot.
	systemctl restart systemd-logind.service >/dev/null 2>&1 || true
fi

#!/usr/bin/env bash

set -euo pipefail

# Apply desktop tweaks and ensure user timers are enabled idempotently.

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

UNIT_ROOT="$HOME/.config/systemd/user"
TIMER_UNIT="$UNIT_ROOT/battery-monitor.timer"

apply_gnome_defaults() {
	if command -v gsettings >/dev/null 2>&1; then
		gsettings set org.gnome.desktop.interface gtk-theme "Adwaita-dark" || true
		gsettings set org.gnome.desktop.interface color-scheme "prefer-dark" || true
		gsettings set org.gnome.desktop.interface icon-theme "Yaru-blue" || true
		if command -v gtk-update-icon-cache >/dev/null 2>&1; then
			# Running gtk-update-icon-cache keeps the icon theme consistent even after repeated runs.
			sudo gtk-update-icon-cache /usr/share/icons/Yaru >/dev/null 2>&1 || true
		fi
	else
		log_warn "gsettings command not available; skipping GNOME appearance defaults"
	fi
}

enable_battery_monitor_timer() {
	if [[ -f "$TIMER_UNIT" && -d /sys/class/power_supply ]] && ls /sys/class/power_supply/BAT* >/dev/null 2>&1; then
		ensure_directory "$UNIT_ROOT/timers.target.wants"
		# ln -snf is safe to re-run and keeps the timer linked even if the target moves.
		ln -snf "$TIMER_UNIT" "$UNIT_ROOT/timers.target.wants/battery-monitor.timer"
	else
		log_info "Battery monitor timer prerequisites not met; skipping timer enablement"
	fi
}

run_step "Applying desktop defaults" apply_gnome_defaults
run_step "Enabling battery monitor timer" enable_battery_monitor_timer

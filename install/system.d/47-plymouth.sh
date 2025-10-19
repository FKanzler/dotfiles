#!/usr/bin/env bash

set -euo pipefail

# Ensure Plymouth uses the stock Arch-friendly boot splash.

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

THEME=${PLYMOUTH_THEME:-bgrt}

apply_plymouth_theme() {
	if command -v plymouth-set-default-theme >/dev/null 2>&1; then
		current_theme=$(plymouth-set-default-theme)
		if [[ "$current_theme" != "$THEME" ]]; then
			# plymouth-set-default-theme -R rebuilds initramfs when supported, keeping reruns safe.
			plymouth-set-default-theme "$THEME"
			plymouth-set-default-theme -R "$THEME"
		else
			log_info "Plymouth theme already set to $THEME"
		fi
	elif [[ -f /etc/plymouth/plymouthd.conf ]]; then
		if grep -q '^Theme=' /etc/plymouth/plymouthd.conf; then
			sed -i "s/^Theme=.*/Theme=$THEME/" /etc/plymouth/plymouthd.conf
		else
			echo "Theme=$THEME" >>/etc/plymouth/plymouthd.conf
		fi
		if command -v mkinitcpio >/dev/null 2>&1; then
			# When falling back to editing plymouthd.conf, run mkinitcpio manually so the change applies.
			mkinitcpio -P >/dev/null
		fi
	else
		log_warn "Plymouth configuration tools not found; skipping theme update"
	fi
}

run_step "Applying Plymouth theme" apply_plymouth_theme

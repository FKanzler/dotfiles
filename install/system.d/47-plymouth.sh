#!/usr/bin/env bash

set -euo pipefail

# Ensure Plymouth uses the stock Arch-friendly boot splash.

STATE_FILE=${1:? "State file path required"}

THEME=${PLYMOUTH_THEME:-bgrt}

if command -v plymouth-set-default-theme >/dev/null 2>&1; then
	current_theme=$(plymouth-set-default-theme)
	if [[ "$current_theme" != "$THEME" ]]; then
		# plymouth-set-default-theme -R rebuilds initramfs when supported, keeping reruns safe.
		plymouth-set-default-theme "$THEME"
		plymouth-set-default-theme -R "$THEME"
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
fi

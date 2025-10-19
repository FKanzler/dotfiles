#!/usr/bin/env bash

set -euo pipefail

# Mirror the console keyboard layout into the Hyprland config.

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

VCONSOLE=/etc/vconsole.conf
INPUT_CONF="$HOME/.config/hypr/input.conf"

sync_keyboard_layout() {
	if [[ ! -f "$INPUT_CONF" ]]; then
		log_warn "Hyprland input configuration not found at $INPUT_CONF; skipping keyboard sync"
		return
	fi

	if [[ ! -f "$VCONSOLE" ]]; then
		log_warn "Console keyboard configuration $VCONSOLE missing; skipping keyboard sync"
		return
	fi

	if grep -q '^XKBLAYOUT=' "$VCONSOLE"; then
		local layout
		layout=$(grep '^XKBLAYOUT=' "$VCONSOLE" | cut -d= -f2 | tr -d '"')
		# Replace existing kb_layout entries or append a fresh one so reruns keep the file clean.
		if grep -q '^\s*kb_layout' "$INPUT_CONF"; then
			sed -i "s/^\s*kb_layout.*/kb_layout = $layout/" "$INPUT_CONF"
		else
			printf '\nkb_layout = %s\n' "$layout" >>"$INPUT_CONF"
		fi
	fi

	if grep -q '^XKBVARIANT=' "$VCONSOLE"; then
		local variant
		variant=$(grep '^XKBVARIANT=' "$VCONSOLE" | cut -d= -f2 | tr -d '"')
		# Do the same for kb_variant so customised layouts persist across reinstalls.
		if grep -q '^\s*kb_variant' "$INPUT_CONF"; then
			sed -i "s/^\s*kb_variant.*/kb_variant = $variant/" "$INPUT_CONF"
		else
			printf 'kb_variant = %s\n' "$variant" >>"$INPUT_CONF"
		fi
	fi
}

run_step "Syncing Hyprland keyboard layout" sync_keyboard_layout

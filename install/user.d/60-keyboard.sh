#!/usr/bin/env bash

set -euo pipefail

# Mirror the console keyboard layout into the Hyprland config.

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

VCONSOLE=/etc/vconsole.conf
INPUT_CONF="$HOME/.config/hypr/input.conf"

[[ -f "$INPUT_CONF" ]] || exit 0

if [[ -f "$VCONSOLE" ]]; then
	if grep -q '^XKBLAYOUT=' "$VCONSOLE"; then
		LAYOUT=$(grep '^XKBLAYOUT=' "$VCONSOLE" | cut -d= -f2 | tr -d '"')
		# Replace existing kb_layout entries or append a fresh one so reruns keep the file clean.
		if grep -q '^\s*kb_layout' "$INPUT_CONF"; then
			sed -i "s/^\s*kb_layout.*/kb_layout = $LAYOUT/" "$INPUT_CONF"
		else
			printf '\nkb_layout = %s\n' "$LAYOUT" >>"$INPUT_CONF"
		fi
	fi

	if grep -q '^XKBVARIANT=' "$VCONSOLE"; then
		VARIANT=$(grep '^XKBVARIANT=' "$VCONSOLE" | cut -d= -f2 | tr -d '"')
		# Do the same for kb_variant so customised layouts persist across reinstalls.
		if grep -q '^\s*kb_variant' "$INPUT_CONF"; then
			sed -i "s/^\s*kb_variant.*/kb_variant = $VARIANT/" "$INPUT_CONF"
		else
			printf 'kb_variant = %s\n' "$VARIANT" >>"$INPUT_CONF"
		fi
	fi
fi

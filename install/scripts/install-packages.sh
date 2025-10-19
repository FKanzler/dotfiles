#!/usr/bin/env bash

set -euo pipefail

# Install packages defined in packages.json using pacman and optionally an AUR helper.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
PACKAGE_FILE=${1:-"$REPO_ROOT/packages.json"}

source "$REPO_ROOT/install/lib/common.sh"

require_commands jq pacman

if [[ ! -f "$PACKAGE_FILE" ]]; then
	abort "Package file not found: $PACKAGE_FILE"
fi

# Split pacman/AUR lists once so we can reuse them for logging and execution.
mapfile -t PACMAN_PACKAGES < <(jq -r '.pacman // [] | .[]' "$PACKAGE_FILE")
mapfile -t AUR_PACKAGES < <(jq -r '.aur // [] | .[]' "$PACKAGE_FILE")

if ((${#PACMAN_PACKAGES[@]})); then
	log_info "Installing ${#PACMAN_PACKAGES[@]} packages via pacman"
	pacman -Syu --noconfirm --needed "${PACMAN_PACKAGES[@]}"
else
	log_warn "No pacman packages listed in $PACKAGE_FILE"
fi

if ((${#AUR_PACKAGES[@]})); then
	if command -v paru >/dev/null 2>&1; then
		log_info "Installing ${#AUR_PACKAGES[@]} AUR packages via paru"
		paru -S --noconfirm --needed "${AUR_PACKAGES[@]}"
	elif command -v yay >/dev/null 2>&1; then
		log_info "Installing ${#AUR_PACKAGES[@]} AUR packages via yay"
		yay -S --noconfirm --needed "${AUR_PACKAGES[@]}"
	else
		log_warn "No AUR helper (paru/yay) found. Skipping AUR packages installation."
		AUR_LIST_FILE="$REPO_ROOT/install/AUR_PACKAGES.txt"
		# Recording the desired AUR packages lets the user install them manually later without re-running the installer.
		printf "%s\n" "${AUR_PACKAGES[@]}" >"$AUR_LIST_FILE"
		log_warn "AUR packages list saved to $AUR_LIST_FILE"
	fi
fi

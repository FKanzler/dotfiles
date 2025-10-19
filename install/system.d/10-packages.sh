#!/usr/bin/env bash

set -euo pipefail

# Install the base package set defined in packages.json.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

PACKAGE_FILE="$REPO_ROOT/packages.json"
PACMAN_PACKAGES=()
AUR_PACKAGES=()
AUR_LIST_FILE="$REPO_ROOT/install/AUR_PACKAGES.txt"

require_commands jq pacman

validate_package_manifest() {
	if [[ ! -f "$PACKAGE_FILE" ]]; then
		abort "Package file not found: $PACKAGE_FILE"
	fi

	mapfile -t PACMAN_PACKAGES < <(jq -r '.pacman // [] | .[]' "$PACKAGE_FILE")
	mapfile -t AUR_PACKAGES < <(jq -r '.aur // [] | .[]' "$PACKAGE_FILE")
}

install_pacman_packages() {
	if ((${#PACMAN_PACKAGES[@]})); then
		log_info "Installing ${#PACMAN_PACKAGES[@]} packages via pacman"
		pacman -Syu --noconfirm --needed "${PACMAN_PACKAGES[@]}"
	else
		log_warn "No pacman packages listed in $PACKAGE_FILE"
	fi
}

install_aur_packages() {
	if ((${#AUR_PACKAGES[@]} == 0)); then
		return
	fi

	if command -v paru >/dev/null 2>&1; then
		log_info "Installing ${#AUR_PACKAGES[@]} AUR packages via paru"
		paru -S --noconfirm --needed "${AUR_PACKAGES[@]}"
	elif command -v yay >/dev/null 2>&1; then
		log_info "Installing ${#AUR_PACKAGES[@]} AUR packages via yay"
		yay -S --noconfirm --needed "${AUR_PACKAGES[@]}"
	else
		log_warn "No AUR helper (paru/yay) found. Skipping AUR packages installation."
		printf "%s\n" "${AUR_PACKAGES[@]}" >"$AUR_LIST_FILE"
		log_warn "AUR packages list saved to $AUR_LIST_FILE"
	fi
}

run_step "Validating package manifest" validate_package_manifest
run_step "Installing pacman packages" install_pacman_packages
run_step "Installing AUR packages" install_aur_packages

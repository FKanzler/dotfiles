#!/usr/bin/env bash

set -euo pipefail

# Add NVIDIA-specific environment overrides to Hyprland when required.

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

HYPR_CONF="$HOME/.config/hypr/hyprland.conf"

append_nvidia_environment_block() {
	if ! lspci | grep -qi 'nvidia'; then
		log_info "No NVIDIA GPU detected; skipping Hyprland environment block"
		return
	fi

	if [[ ! -f "$HYPR_CONF" ]]; then
		log_warn "Hyprland configuration not found at $HYPR_CONF; skipping NVIDIA environment overrides"
		return
	fi

	if grep -q '__GLX_VENDOR_LIBRARY_NAME' "$HYPR_CONF"; then
		log_info "Hyprland configuration already contains NVIDIA overrides"
		return
	fi

	# Append the environment block once so Hyprland sessions pick up the correct driver stack.
	cat <<'EOF' >>"$HYPR_CONF"

# NVIDIA environment variables
env = NVD_BACKEND,direct
env = LIBVA_DRIVER_NAME,nvidia
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
EOF
}

run_step "Applying Hyprland NVIDIA environment overrides" append_nvidia_environment_block

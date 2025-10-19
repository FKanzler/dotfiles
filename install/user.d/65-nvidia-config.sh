#!/usr/bin/env bash

set -euo pipefail

# Add NVIDIA-specific environment overrides to Hyprland when required.

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

if ! lspci | grep -qi 'nvidia'; then
	exit 0
fi

HYPR_CONF="$HOME/.config/hypr/hyprland.conf"
[[ -f "$HYPR_CONF" ]] || exit 0

if grep -q '__GLX_VENDOR_LIBRARY_NAME' "$HYPR_CONF"; then
	exit 0
fi

# Append the environment block once so Hyprland sessions pick up the correct driver stack.
cat <<'EOF' >>"$HYPR_CONF"

# NVIDIA environment variables
env = NVD_BACKEND,direct
env = LIBVA_DRIVER_NAME,nvidia
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
EOF

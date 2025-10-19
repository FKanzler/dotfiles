#!/usr/bin/env bash

set -euo pipefail

# Enable essential systemd services inside the target system.

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

SERVICES=(
	NetworkManager.service
	lightdm.service
	systemd-timesyncd.service
)

# Enable services only when they exist to keep the script safe on minimal setups.
for service in "${SERVICES[@]}"; do
	if systemctl list-unit-files --type=service | grep -q "^$service"; then
		log_info "Enabling $service"
		systemctl enable "$service"
	else
		log_warn "Service $service not present, skipping enablement"
	fi
done

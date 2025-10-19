#!/usr/bin/env bash

set -euo pipefail

# Configure Snapper for the root filesystem and enable automated cleanup.

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

SNAPSHOT_MOUNT="/.snapshots"

if ! command -v snapper >/dev/null 2>&1; then
	log_warn "snapper not installed; skipping snapshot configuration"
	exit 0
fi

if [[ ! -d "$SNAPSHOT_MOUNT" ]]; then
	log_warn "Snapshot mount point $SNAPSHOT_MOUNT missing; ensure the btrfs subvolume is mounted"
	exit 0
fi

# Restrict access to the snapshots directory, mirroring Arch defaults.
chmod 750 "$SNAPSHOT_MOUNT"
if getent group wheel >/dev/null 2>&1; then
	chown root:wheel "$SNAPSHOT_MOUNT"
else
	chown root:root "$SNAPSHOT_MOUNT"
fi

declare -A SNAPSHOT_CONFIGS=(
	["/"]="root"
)

# Only track /home when it exists and lives on btrfs (common when using subvolumes).
if [[ -d /home ]] && findmnt -n -o FSTYPE /home 2>/dev/null | grep -q btrfs; then
	SNAPSHOT_CONFIGS["/home"]="home"
fi

for mountpoint in "${!SNAPSHOT_CONFIGS[@]}"; do
	config="${SNAPSHOT_CONFIGS[$mountpoint]}"
	if ! snapper -c "$config" get-config >/dev/null 2>&1; then
		log_info "Creating snapper configuration $config for $mountpoint"
		snapper -c "$config" create-config "$mountpoint"
	fi

	# Apply conservative defaults so the snapshot list stays slim and timeline creation is disabled.
	snapper -c "$config" set-config NUMBER_LIMIT=5 NUMBER_LIMIT_IMPORTANT=5 TIMELINE_CREATE=no
done

# Keep the cleanup service active so number-based pruning happens automatically; timeline remains disabled.
systemctl enable --now snapper-cleanup.timer >/dev/null 2>&1 || true

log_info "Snapper configured for ${!SNAPSHOT_CONFIGS[*]}"

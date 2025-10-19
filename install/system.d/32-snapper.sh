#!/usr/bin/env bash

set -euo pipefail

# Configure Snapper for the root filesystem and enable automated cleanup.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

SNAPSHOT_MOUNT="/.snapshots"
SNAPPER_READY=1
declare -A SNAPSHOT_CONFIGS

validate_snapper_environment() {
	if ! command -v snapper >/dev/null 2>&1; then
		log_warn "snapper not installed; skipping snapshot configuration"
		SNAPPER_READY=0
		return
	fi

	if [[ ! -d "$SNAPSHOT_MOUNT" ]]; then
		log_warn "Snapshot mount point $SNAPSHOT_MOUNT missing; ensure the btrfs subvolume is mounted"
		SNAPPER_READY=0
		return
	fi
}

lock_down_snapshot_permissions() {
	((SNAPPER_READY)) || { log_info "Snapper prerequisites missing; skipping permission hardening"; return; }

	# Restrict access to the snapshots directory, mirroring Arch defaults.
	chmod 750 "$SNAPSHOT_MOUNT"
	if getent group wheel >/dev/null 2>&1; then
		chown root:wheel "$SNAPSHOT_MOUNT"
	else
		chown root:root "$SNAPSHOT_MOUNT"
	fi
}

configure_snapper_profiles() {
	((SNAPPER_READY)) || { log_info "Snapper prerequisites missing; skipping profile configuration"; return; }

	SNAPSHOT_CONFIGS=(
		["/"]="root"
	)

	# Only track /home when it exists and lives on btrfs (common when using subvolumes).
	if [[ -d /home ]] && findmnt -n -o FSTYPE /home 2>/dev/null | grep -q btrfs; then
		SNAPSHOT_CONFIGS["/home"]="home"
	fi

	for mountpoint in "${!SNAPSHOT_CONFIGS[@]}"; do
		local config=${SNAPSHOT_CONFIGS[$mountpoint]}
		if ! snapper -c "$config" get-config >/dev/null 2>&1; then
			log_info "Creating snapper configuration $config for $mountpoint"
			snapper -c "$config" create-config "$mountpoint"
		fi

		# Apply conservative defaults so the snapshot list stays slim and timeline creation is disabled.
		snapper -c "$config" set-config NUMBER_LIMIT=5 NUMBER_LIMIT_IMPORTANT=5 TIMELINE_CREATE=no
	done
}

enable_snapper_cleanup() {
	((SNAPPER_READY)) || { log_info "Snapper prerequisites missing; skipping cleanup timer"; return; }

	# Keep the cleanup service active so number-based pruning happens automatically; timeline remains disabled.
	systemctl enable --now snapper-cleanup.timer >/dev/null 2>&1 || true
	log_info "Snapper configured for ${!SNAPSHOT_CONFIGS[*]}"
}

run_step "Validating snapper environment" validate_snapper_environment
run_step "Hardening snapshot permissions" lock_down_snapshot_permissions
run_step "Configuring snapper profiles" configure_snapper_profiles
run_step "Enabling snapper cleanup" enable_snapper_cleanup

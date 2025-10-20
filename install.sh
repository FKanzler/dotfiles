#!/usr/bin/env bash

set -euo pipefail

# Locate the repository root and source shared helpers.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$SCRIPT_DIR

source "$REPO_ROOT/install/lib/common.sh"

# Paths reused across the staged installer.
STAGES_DIR="$REPO_ROOT/install/stages"
TARGET_ROOT=${TARGET_ROOT:-/mnt}
BOOTSTRAP_DIR="$TARGET_ROOT/root/arch-bootstrap"
if ! command -v arch-chroot >/dev/null 2>&1; then
	log_warn "arch-chroot is missing. Run from the Arch ISO or set ARCH_CHROOT_CMD before continuing."
fi
# Ensure the base tools exist before any heavy lifting.
require_commands pacman gum:gum tar:tar

confirm_continue_previous() {
	clear
	gum style --bold --border double --padding "1 2" --margin "1 0" "ARCH INSTALLER"

	if exists_previous_state; then
		if confirm_prompt "Previous installation state detected. Do you want to continue or reset the state and start fresh?" --affirmative "Continue" --negative "Reset"; then
			return
		fi

		reset_state_file
		log_info "Previous installation state reset."
	fi
}

confirm_continue_previous

# Stage 00 prepares disks, runs archinstall, and writes state.
run_stage "$STAGES_DIR/00-live.sh"

if [[ ! -f "$STATE_FILE" ]]; then
	abort "Installer state file missing after live stage: $STATE_FILE"
fi

# Read values discovered during the live stage.
TARGET_ROOT=$(get_state_value "target_root" "/mnt")
BOOTSTRAP_DIR="$TARGET_ROOT/root/arch-bootstrap"
USERNAME=$(get_state_value "username")

if [[ -z "$USERNAME" || "$USERNAME" == "null" ]]; then
	abort "Unable to determine target username from state file."
fi

# Sync the project into the new system so the chroot stages have context.
log_info "Copying installer repository into target system"
rm -rf "$BOOTSTRAP_DIR"
mkdir -p "$BOOTSTRAP_DIR"
tar -c --exclude='.git' -C "$REPO_ROOT" . | tar -x -C "$BOOTSTRAP_DIR"
cp "$STATE_FILE" "$BOOTSTRAP_DIR/install/state.json"

# Helper for chroot execution; ARCH_CHROOT_CMD can override the default.
arch_chroot_cmd=${ARCH_CHROOT_CMD:-arch-chroot}
arch_chroot() {
	local root=$1
	shift
	"$arch_chroot_cmd" "$root" /bin/bash -lc "$*"
}

# Stage 10 runs privileged tasks, stage 20 runs as the target user.
arch_chroot "$TARGET_ROOT" "bash /root/arch-bootstrap/install/stages/10-chroot-root.sh"
arch_chroot "$TARGET_ROOT" "runuser -u $USERNAME -- /bin/bash -lc 'bash /root/arch-bootstrap/install/stages/20-chroot-user.sh'"

# Optional polish can happen in a final stage.
if [[ -f "$STAGES_DIR/30-finalize.sh" ]]; then
	arch_chroot "$TARGET_ROOT" "bash /root/arch-bootstrap/install/stages/30-finalize.sh"
fi

log_info "Installation stages completed. You can reboot into the new system when ready."

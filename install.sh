#!/usr/bin/env bash

set -euo pipefail

# Locate the repository root and source shared helpers.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$SCRIPT_DIR
source "$REPO_ROOT/install/lib/common.sh"

# Paths reused across the staged installer.
STATE_FILE="$REPO_ROOT/install/state.json"
STAGES_DIR="$REPO_ROOT/install/stages"
TARGET_ROOT=${TARGET_ROOT:-/mnt}
BOOTSTRAP_DIR="$TARGET_ROOT/root/arch-bootstrap"

# Ensure the base tools exist before any heavy lifting.
require_commands pacman

if ! command -v arch-chroot >/dev/null 2>&1; then
	log_warn "arch-chroot is missing. Run from the Arch ISO or set ARCH_CHROOT_CMD before continuing."
fi

# Install lightweight helpers when running in a bare environment.
if ! command -v gum >/dev/null 2>&1; then
	run_step "Installing gum for interactive prompts" pacman -Sy --noconfirm --needed gum
fi

# Install lightweight helpers when running in a bare environment.
if ! command -v jq >/dev/null 2>&1; then
	run_step "Installing jq for JSON processing" pacman -Sy --noconfirm --needed jq
fi

# Install lightweight helpers when running in a bare environment.
if ! command -v sed >/dev/null 2>&1; then
	run_step "Installing sed for text processing" pacman -Sy --noconfirm --needed sed
fi

# Install lightweight helpers when running in a bare environment.
if ! command -v awk >/dev/null 2>&1; then
	run_step "Installing awk for text processing" pacman -Sy --noconfirm --needed gawk
fi

# Simple banner to make it obvious the installer started.
clear
gum style --bold --border double --padding "1 2" --margin "1 0" "ARCH INSTALLER"

# Wrapper that validates a stage before executing it.
run_stage_script() {
	local stage_script=$1
	log_info "Entering stage $(basename "$stage_script")"
	if [[ ! -f "$stage_script" ]]; then
		abort "Missing stage script: $stage_script"
	fi
	bash "$stage_script" "$STATE_FILE"
	log_info "Finished stage $(basename "$stage_script")"
}

# Stage 00 prepares disks, runs archinstall, and writes state.
run_stage_script "$STAGES_DIR/00-live.sh"

if [[ ! -f "$STATE_FILE" ]]; then
	abort "Installer state file missing after live stage: $STATE_FILE"
fi

# Read values discovered during the live stage.
TARGET_ROOT=$(json_get "$STATE_FILE" '.target_root // "/mnt"')
BOOTSTRAP_DIR="$TARGET_ROOT/root/arch-bootstrap"
USERNAME=$(json_get "$STATE_FILE" '.username')

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
arch_chroot "$TARGET_ROOT" "bash /root/arch-bootstrap/install/stages/10-chroot-root.sh /root/arch-bootstrap/install/state.json"
arch_chroot "$TARGET_ROOT" "runuser -u $USERNAME -- /bin/bash -lc 'bash /root/arch-bootstrap/install/stages/20-chroot-user.sh /root/arch-bootstrap/install/state.json'"

# Optional polish can happen in a final stage.
if [[ -f "$STAGES_DIR/30-finalize.sh" ]]; then
	arch_chroot "$TARGET_ROOT" "bash /root/arch-bootstrap/install/stages/30-finalize.sh /root/arch-bootstrap/install/state.json"
fi

# Remove sensitive files that are no longer needed.
rm -f "$STATE_FILE" "$REPO_ROOT/user_credentials.json" "$REPO_ROOT/user_configuration.json"

log_info "Installation stages completed. You can reboot into the new system when ready."

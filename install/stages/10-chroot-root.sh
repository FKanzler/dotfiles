#!/usr/bin/env bash

set -euo pipefail

# Stage 10 executes inside the target root filesystem and performs
# privileged configuration tasks (package installs, service setup, .).

STATE_FILE=${1:? "State file path required as first argument"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

ensure_privileged_context() {
	[[ $EUID -eq 0 ]] || abort "Stage 10 must run as root"

	if [[ ! -f "$STATE_FILE" ]]; then
		abort "Installer state file missing: $STATE_FILE"
	fi
}

apply_system_configuration() {
	log_info "Running system-level configuration inside chroot"
	run_scripts_in_dir "$REPO_ROOT/install/system.d"
	log_info "Completed system-level stage"
}

run_step "Validating privileged context" ensure_privileged_context
run_step "Applying system configuration scripts" apply_system_configuration

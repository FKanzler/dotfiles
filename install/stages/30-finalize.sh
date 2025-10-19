#!/usr/bin/env bash

set -euo pipefail

# Stage 30 performs final clean-up inside the chroot.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

remove_chroot_state() {
	log_info "Finalizing installation - purging installer state"
	rm -f "$STATE_FILE"
	log_info "State file removed from chroot"
}

purge_generated_artifacts() {
	log_info "Cleaning up cached installer artifacts"
	rm -rf "$CACHE_DIR"
	log_info "Cached artifacts removed"
}

run_step "Removing chroot state file" remove_chroot_state
run_step "Purging cached installer artifacts" purge_generated_artifacts

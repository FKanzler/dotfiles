#!/usr/bin/env bash

set -euo pipefail

# Stage 30 performs final clean-up inside the chroot.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

remove_chroot_state() {
	rm -f "$STATE_FILE"
}

purge_generated_artifacts() {
	rm -rf "$(cache_dir_path)"
}

run_step "Removing chroot state file" remove_chroot_state
run_step "Purging cached installer artifacts" purge_generated_artifacts

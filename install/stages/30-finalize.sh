#!/usr/bin/env bash

set -euo pipefail

# Stage 30 performs final clean-up inside the chroot.

STATE_FILE=${1:? "State file path required as first argument"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

log_info "Finalizing installation - purging installer state"

# Remove the state file from the chroot copy; the host keeps its own copy for
# debugging so wiping it here is safe and idempotent.
rm -f "$STATE_FILE"

log_info "State file removed from chroot"

# Remove any credential artifacts we no longer need post-install.
rm -f "$REPO_ROOT/user_credentials.json" "$REPO_ROOT/user_configuration.json"

log_info "Cleaned up generated credential files"

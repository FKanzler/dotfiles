#!/usr/bin/env bash

set -euo pipefail

# Stage 20 runs as the newly created user and applies per-user
# configuration such as dotfiles, themes, and CLI preferences.

STATE_FILE=${1:? "State file path required as first argument"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

# User-level configuration needs to run as the new account so ownership is correct.
[[ $EUID -ne 0 ]] || abort "Stage 20 must run as the target user, not root"

# The earlier stages must have produced the state metadata; bail if something went wrong.
if [[ ! -f "$STATE_FILE" ]]; then
	abort "Installer state file missing: $STATE_FILE"
fi

log_info "Running user-level configuration"

# Execute user.d scripts sequentially so each component can pull values from the shared state.
run_scripts_in_dir "$REPO_ROOT/install/user.d"

log_info "Completed user-level stage"

#!/usr/bin/env bash

set -euo pipefail

# Stage 10 executes inside the target root filesystem and performs
# privileged configuration tasks (package installs, service setup, …).

STATE_FILE=${1:? "State file path required as first argument"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

# These actions manipulate system files directly, so refuse to continue as a user.
[[ $EUID -eq 0 ]] || abort "Stage 10 must run as root"

# The state file carries values collected earlier (user name, disk, …); abort if missing.
if [[ ! -f "$STATE_FILE" ]]; then
	abort "Installer state file missing: $STATE_FILE"
fi

log_info "Running system-level configuration inside chroot"

# Execute every script under install/system.d in lexical order.
run_scripts_in_dir "$REPO_ROOT/install/system.d"

log_info "Completed system-level stage"

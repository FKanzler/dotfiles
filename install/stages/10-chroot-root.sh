#!/usr/bin/env bash

set -euo pipefail

# Stage 10 executes inside the target root filesystem and performs
# privileged configuration tasks (package installs, service setup, .).

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

[[ $EUID -eq 0 ]] || abort "Stage 10 must run as root"

if [[ ! -f "$STATE_FILE" ]]; then
	abort "Installer state file missing: $STATE_FILE"
fi

run_scripts_in_dir "$REPO_ROOT/install/system.d"

#!/usr/bin/env bash

set -euo pipefail

# Stage 20 runs as the newly created user and applies per-user
# configuration such as dotfiles, themes, and CLI preferences.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

[[ $EUID -ne 0 ]] || abort "Stage 20 must run as the target user, not root"

if [[ ! -f "$STATE_FILE" ]]; then
	abort "Installer state file missing: $STATE_FILE"
fi

run_scripts_in_dir "$REPO_ROOT/install/user.d"

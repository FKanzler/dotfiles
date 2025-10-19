#!/usr/bin/env bash

set -euo pipefail

# Refresh the locate database so `updatedb`/`locate` work out of the box.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

refresh_locate_database() {
	if command -v updatedb >/dev/null 2>&1; then
		updatedb >/dev/null 2>&1 || true
	else
		log_warn "updatedb command not available; skipping locate database refresh"
	fi
}

run_step "Refreshing locate database" refresh_locate_database

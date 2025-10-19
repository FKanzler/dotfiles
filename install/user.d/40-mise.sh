#!/usr/bin/env bash

set -euo pipefail

# Prepare the default Work directory and Mise environment file.

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

WORK_DIR="$HOME/Work"
MISE_TOML="$WORK_DIR/.mise.toml"

initialize_mise_environment() {
	ensure_directory "$WORK_DIR"

	# Ensure local bin directories inside any project under ~/Work are picked up automatically.
	cat >"$MISE_TOML" <<'EOF'
[env]
_.path = "{{ cwd }}/bin"
EOF

	# Trust the manifest so mise doesn't prompt during later shell sessions.
	if command -v mise >/dev/null 2>&1; then
		mise trust "$MISE_TOML" >/dev/null
	else
		log_warn "mise command not available; skipping trust step"
	fi
}

run_step "Initializing Mise environment" initialize_mise_environment

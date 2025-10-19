#!/usr/bin/env bash

set -euo pipefail

# Link managed zsh configuration into the user's home directory.

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

SOURCE_RC="$HOME/.config/zsh/rc.zsh"
TARGET_RC="$HOME/.zshrc"

link_zsh_configuration() {
	if [[ -f "$SOURCE_RC" ]]; then
		# Always force the symlink so the managed configuration stays in sync across re-runs.
		ln -snf "$SOURCE_RC" "$TARGET_RC"
	else
		log_warn "Managed zsh configuration not found at $SOURCE_RC"
	fi
}

run_step "Linking zsh configuration" link_zsh_configuration

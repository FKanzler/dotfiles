#!/usr/bin/env bash

set -euo pipefail

# Link repository scripts into ~/.local/bin so they are on PATH.

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

SOURCE_DIR="$REPO_ROOT/local/share/scripts"
TARGET_DIR="$HOME/.local/bin"

link_user_scripts() {
	if [[ ! -d "$SOURCE_DIR" ]]; then
		log_info "No scripts found in $SOURCE_DIR; skipping user script linking"
		return
	fi

	ensure_directory "$TARGET_DIR"

	while IFS= read -r -d '' file; do
		local name
		name=$(basename "$file")
		# ln -snf ensures re-running the installer refreshes the link to the current script version.
		ln -snf "$file" "$TARGET_DIR/$name"
	done < <(find "$SOURCE_DIR" -maxdepth 1 -type f -print0)
}

run_step "Linking user scripts into PATH" link_user_scripts

#!/usr/bin/env bash

set -euo pipefail

# Link managed zsh configuration into the user's home directory.

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

SOURCE_RC="$HOME/.config/zsh/rc.zsh"
TARGET_RC="$HOME/.zshrc"

if [[ -f "$SOURCE_RC" ]]; then
	# Always force the symlink so the managed configuration stays in sync across re-runs.
	ln -snf "$SOURCE_RC" "$TARGET_RC"
fi

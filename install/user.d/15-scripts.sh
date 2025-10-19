#!/usr/bin/env bash

set -euo pipefail

# Link repository scripts into ~/.local/bin so they are on PATH.

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

SOURCE_DIR="$REPO_ROOT/local/share/scripts"
TARGET_DIR="$HOME/.local/bin"

[[ -d "$SOURCE_DIR" ]] || exit 0

ensure_directory "$TARGET_DIR"

while IFS= read -r -d '' file; do
	name=$(basename "$file")
	# ln -snf ensures re-running the installer refreshes the link to the current script version.
	ln -snf "$file" "$TARGET_DIR/$name"
done < <(find "$SOURCE_DIR" -maxdepth 1 -type f -print0)

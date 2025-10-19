#!/usr/bin/env bash

set -euo pipefail

# Link dotfiles from a Git repository into the target user home.

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

CONFIG_REPO_URL=$(json_get "$STATE_FILE" '.config_repo // ""')
DEFAULT_CONFIG_REPO="https://github.com/FKanzler/dotfiles.git"
CLONE_ROOT="$HOME/.local/share/system-config"
SOURCE_ROOT="$REPO_ROOT"

REPO_TO_CLONE="$CONFIG_REPO_URL"
if [[ -z "$REPO_TO_CLONE" ]]; then
	REPO_TO_CLONE="$DEFAULT_CONFIG_REPO"
	log_info "No config repo provided, falling back to $DEFAULT_CONFIG_REPO"
fi

if [[ -n "$REPO_TO_CLONE" ]]; then
	if [[ -d "$CLONE_ROOT/.git" ]]; then
		log_info "Updating configuration repository in $CLONE_ROOT"
		if ! git -C "$CLONE_ROOT" pull --ff-only >/dev/null 2>&1; then
			log_warn "Failed to update $CLONE_ROOT, falling back to local repository"
		else
			SOURCE_ROOT="$CLONE_ROOT"
		fi
	else
		log_info "Cloning configuration repository from $REPO_TO_CLONE"
		if git clone "$REPO_TO_CLONE" "$CLONE_ROOT" >/dev/null 2>&1; then
			SOURCE_ROOT="$CLONE_ROOT"
		else
			log_warn "Failed to clone $REPO_TO_CLONE, falling back to local repository"
		fi
	fi
fi

TARGET_CONFIG="$HOME/.config"
TARGET_LOCAL="$HOME/.local/share"

ensure_directory "$TARGET_CONFIG"
ensure_directory "$TARGET_LOCAL"

# Helper that replaces existing entries with symlinks pointing at the repository copy.
link_tree() {
	local source_dir=$1
	local dest_dir=$2

	[[ -d "$source_dir" ]] || return

	while IFS= read -r -d '' entry; do
		local name
		name=$(basename "$entry")
		local target="$dest_dir/$name"

		# Remove existing files or symlinks so the new link is created cleanly.
		if [[ -e "$target" || -L "$target" ]]; then
			rm -rf "$target"
		fi

		ln -snf "$entry" "$target"
	done < <(find "$source_dir" -mindepth 1 -maxdepth 1 -print0)
}

# Mirror both config/ and local/share/ to the user's home directory.
link_tree "$SOURCE_ROOT/config" "$TARGET_CONFIG"
link_tree "$SOURCE_ROOT/local/share" "$TARGET_LOCAL"

# Ensure hypridle is configured to lock the session after 15 minutes of inactivity.
HYPRIDLE_CONF_SOURCE="$SOURCE_ROOT/config/hypridle/hypridle.conf"
HYPRIDLE_TARGET="$HOME/.config/hypridle/hypridle.conf"
if [[ -f "$HYPRIDLE_CONF_SOURCE" ]]; then
	ensure_directory "$(dirname "$HYPRIDLE_TARGET")"
	ln -snf "$HYPRIDLE_CONF_SOURCE" "$HYPRIDLE_TARGET"
fi

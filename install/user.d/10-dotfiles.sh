#!/usr/bin/env bash

set -euo pipefail

# Link dotfiles from a Git repository into the target user home.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

CONFIG_REPO_URL=$(json_get "$STATE_FILE" '.config_repo // ""')
DEFAULT_CONFIG_REPO="https://github.com/FKanzler/dotfiles.git"
CLONE_ROOT="$HOME/.local/share/system-config"
SOURCE_ROOT="$REPO_ROOT"
TARGET_CONFIG="$HOME/.config"
TARGET_LOCAL="$HOME/.local/share"

prepare_configuration_repository() {
	local repo_to_clone="$CONFIG_REPO_URL"
	if [[ -z "$repo_to_clone" ]]; then
		repo_to_clone="$DEFAULT_CONFIG_REPO"
		log_info "No config repo provided, falling back to $DEFAULT_CONFIG_REPO"
	fi

	if [[ -d "$CLONE_ROOT/.git" ]]; then
		log_info "Updating configuration repository in $CLONE_ROOT"
		if git -C "$CLONE_ROOT" pull --ff-only >/dev/null 2>&1; then
			SOURCE_ROOT="$CLONE_ROOT"
		else
			log_warn "Failed to update $CLONE_ROOT, falling back to local repository"
		fi
	elif [[ -n "$repo_to_clone" ]]; then
		log_info "Cloning configuration repository from $repo_to_clone"
		if git clone "$repo_to_clone" "$CLONE_ROOT" >/dev/null 2>&1; then
			SOURCE_ROOT="$CLONE_ROOT"
		else
			log_warn "Failed to clone $repo_to_clone, falling back to local repository"
		fi
	fi
}

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

link_configuration_directories() {
	ensure_directory "$TARGET_CONFIG"
	ensure_directory "$TARGET_LOCAL"
	link_tree "$SOURCE_ROOT/config" "$TARGET_CONFIG"
	link_tree "$SOURCE_ROOT/local/share" "$TARGET_LOCAL"
}

configure_hypridle_lock() {
	local hypridle_conf_source="$SOURCE_ROOT/config/hypridle/hypridle.conf"
	local hypridle_target="$HOME/.config/hypridle/hypridle.conf"
	if [[ -f "$hypridle_conf_source" ]]; then
		ensure_directory "$(dirname "$hypridle_target")"
		ln -snf "$hypridle_conf_source" "$hypridle_target"
	fi
}

run_step "Preparing configuration repository" prepare_configuration_repository
run_step "Linking configuration directories" link_configuration_directories
run_step "Configuring hypridle lock" configure_hypridle_lock

#!/usr/bin/env bash

set -euo pipefail

# Establish opinionated global git defaults and author identity.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

FULL_NAME=$(get_state_value "git.name")
EMAIL=$(get_state_value "git.email")

prepare_git_config_directory() {
	ensure_directory "$HOME/.config/git"
	# Touch the config to guarantee git updates succeed even when run for the first time.
	touch "$HOME/.config/git/config"
}

configure_git_preferences() {
	# Handy aliases and global preferences. These commands are idempotent because git config overwrites duplicates.
	git config --global alias.co checkout
	git config --global alias.br branch
	git config --global alias.ci commit
	git config --global alias.st status
	git config --global pull.rebase true
	git config --global init.defaultBranch main
}

configure_git_identity() {
	if [[ -n "$FULL_NAME" && "$FULL_NAME" != "null" ]]; then
		git config --global user.name "$FULL_NAME"
	else
		log_warn "Git full name not provided; leaving user.name unchanged"
	fi

	if [[ -n "$EMAIL" && "$EMAIL" != "null" ]]; then
		git config --global user.email "$EMAIL"
	else
		log_warn "Git email not provided; leaving user.email unchanged"
	fi
}

run_step "Preparing git config directory" prepare_git_config_directory
run_step "Configuring git preferences" configure_git_preferences
run_step "Configuring git identity" configure_git_identity

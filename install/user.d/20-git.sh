#!/usr/bin/env bash

set -euo pipefail

# Establish opinionated global git defaults and author identity.

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

ensure_directory "$HOME/.config/git"
# Touch the config to guarantee git updates succeed even when run for the first time.
touch "$HOME/.config/git/config"

# Handy aliases and global preferences. These commands are idempotent because git config overwrites duplicates.
git config --global alias.co checkout
git config --global alias.br branch
git config --global alias.ci commit
git config --global alias.st status
git config --global pull.rebase true
git config --global init.defaultBranch main

FULL_NAME=$(json_get "$STATE_FILE" '.git.name')
EMAIL=$(json_get "$STATE_FILE" '.git.email')

if [[ -n "$FULL_NAME" && "$FULL_NAME" != "null" ]]; then
	git config --global user.name "$FULL_NAME"
fi

if [[ -n "$EMAIL" && "$EMAIL" != "null" ]]; then
	git config --global user.email "$EMAIL"
fi

#!/usr/bin/env bash

set -euo pipefail

# Install the base package set defined in packages.json.

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

log_info "Installing base package set"

# install-packages.sh handles re-runs by using --needed and skipping missing AUR helpers.
"$REPO_ROOT/install/scripts/install-packages.sh" "$REPO_ROOT/packages.json"

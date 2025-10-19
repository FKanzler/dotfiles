#!/usr/bin/env bash

set -euo pipefail

# Refresh the locate database so `updatedb`/`locate` work out of the box.

STATE_FILE=${1:? "State file path required"}

updatedb >/dev/null 2>&1 || true
# We ignore failures to keep the stage idempotent on systems without mlocate.

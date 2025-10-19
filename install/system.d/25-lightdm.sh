#!/usr/bin/env bash

set -euo pipefail

# Configure LightDM greeter and session defaults.

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

USERNAME=$(json_get "$STATE_FILE" '.username')

ensure_directory /etc/lightdm/lightdm.conf.d

# Use the webkit greeter when available; fall back to the GTK greeter otherwise.
if pacman -Q lightdm-webkit-theme-litarvan >/dev/null 2>&1; then
	cat <<'EOF' >/etc/lightdm/lightdm.conf.d/20-greeter.conf
[Seat:*]
greeter-session=lightdm-webkit2-greeter
user-session=uwsm
EOF
	cat <<'EOF' >/etc/lightdm/lightdm-webkit2-greeter.conf
[greeter]
webkit-theme=litarvan
debug-mode=false

[branding]
# Update these paths if you ship custom branding assets.
# background=/path/to/background.png
# logo=/path/to/logo.png
user-image=default

[greeter-plugin]
disable-mesa-kms=false
EOF
else
	cat <<'EOF' >/etc/lightdm/lightdm.conf.d/20-greeter.conf
[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=uwsm
EOF
fi

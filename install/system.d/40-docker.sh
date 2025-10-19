#!/usr/bin/env bash

set -euo pipefail

# Configure Docker defaults (logging, DNS, service enablement).

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

USERNAME=$(json_get "$STATE_FILE" '.username')

if ! command -v docker >/dev/null 2>&1; then
	log_warn "Docker not installed, skipping daemon configuration"
	exit 0
fi

# Write a deterministic daemon.json so logging, network ranges, and DNS are stable between runs.
ensure_directory /etc/docker
cat <<'EOF' >/etc/docker/daemon.json
{
    "log-driver": "json-file",
    "log-opts": { "max-size": "10m", "max-file": "5" },
    "dns": ["172.17.0.1"],
    "bip": "172.17.0.1/16"
}
EOF

ensure_directory /etc/systemd/resolved.conf.d
cat <<'EOF' >/etc/systemd/resolved.conf.d/20-docker-dns.conf
[Resolve]
DNSStubListenerExtra=172.17.0.1
EOF

# Restart resolved so the stub listener picks up the drop-in immediately.
systemctl restart systemd-resolved.service >/dev/null 2>&1 || true

# Ensure the Docker daemon starts on boot.
systemctl enable docker.service

# Add the primary user to the docker group; repeated runs simply keep membership intact.
if id "$USERNAME" >/dev/null 2>&1; then
	usermod -aG docker "$USERNAME"
fi

ensure_directory /etc/systemd/system/docker.service.d
cat <<'EOF' >/etc/systemd/system/docker.service.d/no-block-boot.conf
[Unit]
DefaultDependencies=no
EOF

# Reload systemd so the override drop-in is recognised without a reboot.
systemctl daemon-reload

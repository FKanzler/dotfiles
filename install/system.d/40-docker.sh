#!/usr/bin/env bash

set -euo pipefail

# Configure Docker defaults (logging, DNS, service enablement).

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

USERNAME=$(get_state_value "username")
DOCKER_READY=1

validate_docker_environment() {
	if ! command -v docker >/dev/null 2>&1; then
		log_warn "Docker not installed, skipping daemon configuration"
		DOCKER_READY=0
	fi
}

write_docker_daemon_config() {
	((DOCKER_READY)) || { log_info "Docker not available; skipping daemon configuration"; return; }

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
}

configure_resolved_for_docker() {
	((DOCKER_READY)) || { log_info "Docker not available; skipping resolved configuration"; return; }

	ensure_directory /etc/systemd/resolved.conf.d
	cat <<'EOF' >/etc/systemd/resolved.conf.d/20-docker-dns.conf
[Resolve]
DNSStubListenerExtra=172.17.0.1
EOF

	# Restart resolved so the stub listener picks up the drop-in immediately.
	systemctl restart systemd-resolved.service >/dev/null 2>&1 || true
}

enable_docker_service() {
	((DOCKER_READY)) || { log_info "Docker not available; skipping service enablement"; return; }

	# Ensure the Docker daemon starts on boot.
	systemctl enable docker.service
}

add_user_to_docker_group() {
	((DOCKER_READY)) || { log_info "Docker not available; skipping group membership configuration"; return; }

	# Add the primary user to the docker group; repeated runs simply keep membership intact.
	if id "$USERNAME" >/dev/null 2>&1; then
		usermod -aG docker "$USERNAME"
	else
		log_warn "User $USERNAME not found; skipping docker group membership"
	fi
}

install_docker_service_override() {
	((DOCKER_READY)) || { log_info "Docker not available; skipping service override"; return; }

	ensure_directory /etc/systemd/system/docker.service.d
	cat <<'EOF' >/etc/systemd/system/docker.service.d/no-block-boot.conf
[Unit]
DefaultDependencies=no
EOF

	# Reload systemd so the override drop-in is recognised without a reboot.
	systemctl daemon-reload
}

run_step "Validating Docker environment" validate_docker_environment
run_step "Writing Docker daemon configuration" write_docker_daemon_config
run_step "Configuring resolved for Docker" configure_resolved_for_docker
run_step "Enabling Docker service" enable_docker_service
run_step "Adding user to Docker group" add_user_to_docker_group
run_step "Installing Docker service override" install_docker_service_override

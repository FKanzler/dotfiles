#!/usr/bin/env bash

set -euo pipefail

# Harden basic security defaults: firewall, sudo, PAM, and sysctl.

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

configure_ufw() {
	if ! command -v ufw >/dev/null 2>&1; then
		log_warn "ufw not installed, skipping firewall configuration"
		return
	fi

	log_info "Configuring UFW defaults and rules"
	ufw --force reset >/dev/null
	ufw default deny incoming >/dev/null
	ufw default allow outgoing >/dev/null

	ufw allow 53317/udp >/dev/null
	ufw allow 53317/tcp >/dev/null
	ufw allow 22/tcp >/dev/null
	ufw allow in proto udp from 172.16.0.0/12 to 172.17.0.1 port 53 comment 'allow-docker-dns' >/dev/null 2>&1 || true

	ufw --force enable >/dev/null

	if systemctl list-unit-files --type=service | grep -q '^ufw.service'; then
		systemctl enable ufw.service
	fi

	if command -v ufw-docker >/dev/null 2>&1; then
		ufw-docker install >/dev/null 2>&1 || true
	fi
}

configure_sudo() {
	local sudo_file=/etc/sudoers.d/10-passwd-tries
	# Overwrite the sudoers drop-in so password attempts stay at the desired value.
	echo "Defaults passwd_tries=10" >"$sudo_file"
	chmod 440 "$sudo_file"
}

configure_lockout() {
	local pam_file=/etc/pam.d/system-auth
	if [[ -f "$pam_file" ]]; then
		sed -i 's|^\(auth\s\+required\s\+pam_faillock.so\)\s\+preauth.*$|\1 preauth silent deny=10 unlock_time=120|' "$pam_file" || true
		sed -i 's|^\(auth\s\+\[default=abort\]\s\+pam_faillock.so\)\s\+authfail.*$|\1 authfail deny=10 unlock_time=120|' "$pam_file" || true
	fi
}

configure_sysctl() {
	local sysctl_file=/etc/sysctl.d/99-arch-bootstrap.conf
	ensure_directory "$(dirname "$sysctl_file")"
	if [[ -f "$sysctl_file" ]]; then
		if ! grep -q 'net.ipv4.tcp_mtu_probing' "$sysctl_file"; then
			echo "net.ipv4.tcp_mtu_probing=1" >>"$sysctl_file"
		fi
	else
		echo "net.ipv4.tcp_mtu_probing=1" >"$sysctl_file"
	fi
	sysctl --system >/dev/null
}

configure_timezone_sudoers() {
	local sudo_file=/etc/sudoers.d/90-tzupdate
	cat <<'EOF' >"$sudo_file"
%wheel ALL=(root) NOPASSWD: /usr/bin/tzupdate, /usr/bin/timedatectl
EOF
	chmod 440 "$sudo_file"
}

configure_gpg() {
	local gpg_dir=/etc/gnupg
	local dirmngr_conf=$gpg_dir/dirmngr.conf

	ensure_directory "$gpg_dir"
	# Replace the dirmngr configuration so repeated installs always yield the same keyserver list.
	cat <<'EOF' >"$dirmngr_conf"
keyserver hkps://keyserver.ubuntu.com
keyserver hkps://pgp.surfnet.nl
keyserver hkps://keys.mailvelope.com
keyserver hkps://keyring.debian.org
keyserver hkps://pgp.mit.edu

connect-quick-timeout 4
EOF
	chmod 644 "$dirmngr_conf"
	gpgconf --kill dirmngr >/dev/null 2>&1 || true
	gpgconf --launch dirmngr >/dev/null 2>&1 || true
}

# Apply each hardening step in sequence. Every helper is written to be
# idempotent, so re-running the installer simply refreshes the settings.
configure_ufw
configure_sudo
configure_lockout
configure_sysctl
configure_timezone_sudoers
configure_gpg

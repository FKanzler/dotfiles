#!/usr/bin/env bash

set -euo pipefail

# Detect and configure hardware-specific requirements (drivers, services, tweaks).

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

service_exists() {
	local unit=$1
	systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "$unit"
}

enable_service_if_present() {
	local unit=$1
	if service_exists "$unit"; then
		log_info "Enabling $unit"
		systemctl enable "$unit"
	else
		log_warn "Service $unit not found; skipping"
	fi
}

install_packages_if_available() {
	local to_install=()
	local missing=()

	for pkg in "$@"; do
		[[ -n "$pkg" ]] || continue
		if pacman -Q "$pkg" >/dev/null 2>&1; then
			continue
		fi
		if pacman -Si "$pkg" >/dev/null 2>&1; then
			to_install+=("$pkg")
		else
			missing+=("$pkg")
		fi
	done

	if [[ ${#to_install[@]} -gt 0 ]]; then
		log_info "Installing packages: ${to_install[*]}"
		pacman -S --needed --noconfirm "${to_install[@]}"
	fi

	if [[ ${#missing[@]} -gt 0 ]]; then
		log_warn "Packages not found in repositories: ${missing[*]}"
	fi
}

installed_kernel_headers() {
	local kernels=(linux linux-zen linux-lts linux-hardened)
	local headers=()

	for kernel in "${kernels[@]}"; do
		if pacman -Q "$kernel" >/dev/null 2>&1; then
			headers+=("${kernel}-headers")
		fi
	done

	printf '%s\n' "${headers[@]}"
}

configure_bluetooth() {
	enable_service_if_present bluetooth.service
}

configure_network_stack() {
	enable_service_if_present iwd.service
	if service_exists systemd-networkd-wait-online.service; then
		log_info "Disabling systemd-networkd-wait-online.service to speed up boot"
		systemctl disable systemd-networkd-wait-online.service
		systemctl mask systemd-networkd-wait-online.service
	fi
}

configure_printer_support() {
	if ! pacman -Q cups >/dev/null 2>&1; then
		log_warn "CUPS not installed; skipping printer configuration"
		return
	fi

	enable_service_if_present cups.service

	ensure_directory /etc/systemd/resolved.conf.d
	cat <<'EOF' >/etc/systemd/resolved.conf.d/10-disable-multicast.conf
[Resolve]
MulticastDNS=no
EOF
	enable_service_if_present avahi-daemon.service

	if [[ -f /etc/nsswitch.conf ]]; then
		sed -i 's/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/' /etc/nsswitch.conf
	fi

	local cups_browsed_conf=/etc/cups/cups-browsed.conf
	if [[ -f "$cups_browsed_conf" ]]; then
		if ! grep -q '^CreateRemotePrinters Yes' "$cups_browsed_conf"; then
			echo 'CreateRemotePrinters Yes' >>"$cups_browsed_conf"
		fi
	else
		echo 'CreateRemotePrinters Yes' >"$cups_browsed_conf"
	fi

	enable_service_if_present cups-browsed.service
}

set_wireless_regdom() {
	local conf=/etc/conf.d/wireless-regdom
	local current=""

	if [[ -f "$conf" ]]; then
		# shellcheck disable=SC1090
		source "$conf"
		current=${WIRELESS_REGDOM:-}
	fi

	if [[ -n "$current" ]]; then
		return
	fi

	if [[ -e /etc/localtime ]]; then
		local tz country
		tz=$(readlink -f /etc/localtime)
		tz=${tz#/usr/share/zoneinfo/}
		country=${tz%%/*}

		if [[ ! "$country" =~ ^[A-Z]{2}$ ]] && [[ -f /usr/share/zoneinfo/zone.tab ]]; then
			country=$(awk -v tz="$tz" '$3 == tz {print $1; exit}' /usr/share/zoneinfo/zone.tab)
		fi

		if [[ "$country" =~ ^[A-Z]{2}$ ]]; then
			ensure_directory "$(dirname "$conf")"
			echo "WIRELESS_REGDOM=\"$country\"" >>"$conf"
			if command -v iw >/dev/null 2>&1; then
				iw reg set "$country" >/dev/null 2>&1 || true
			fi
		fi
	fi
}

disable_usb_autosuspend() {
	local conf=/etc/modprobe.d/disable-usb-autosuspend.conf
	if [[ ! -f "$conf" ]]; then
		echo "options usbcore autosuspend=-1" >"$conf"
	fi
}

ensure_fn_keys_default() {
	local conf=/etc/modprobe.d/hid_apple.conf
	if [[ ! -f "$conf" ]]; then
		echo "options hid_apple fnmode=2" >"$conf"
	fi
}

fix_powerprofilesctl_shebang() {
	local binary=/usr/bin/powerprofilesctl
	if [[ -f "$binary" ]]; then
		local shebang
		shebang=$(head -n1 "$binary")
		if [[ "$shebang" == "#!/usr/bin/env python3" ]]; then
			log_info "Fixing powerprofilesctl shebang to avoid Mise python"
			sed -i '1s|#!/usr/bin/env python3|#!/bin/python3|' "$binary"
		fi
	fi
}

install_intel_media_support() {
	local gpu
	gpu=$(lspci | grep -iE 'vga|3d|display' | grep -i 'intel' || true)
	if [[ -z "$gpu" ]]; then
		return
	fi

	local lower=${gpu,,}
	if [[ "$lower" == *"gma"* ]]; then
		install_packages_if_available libva-intel-driver
	else
		install_packages_if_available intel-media-driver
	fi
}

install_nvidia_support() {
	if ! lspci | grep -qi 'nvidia'; then
		return
	fi

	log_info "NVIDIA GPU detected; configuring driver stack"
	local pci_output
	pci_output=$(lspci | grep -i 'nvidia')
	local driver_pkg="nvidia-dkms"
	if echo "$pci_output" | grep -Eq 'RTX [2-9][0-9]|GTX 16'; then
		driver_pkg="nvidia-open-dkms"
	fi

	mapfile -t headers < <(installed_kernel_headers)
	install_packages_if_available "${headers[@]}" "$driver_pkg" \
		nvidia-utils lib32-nvidia-utils egl-wayland libva-nvidia-driver \
		qt5-wayland qt6-wayland

	ensure_directory /etc/modprobe.d
	echo "options nvidia_drm modeset=1" >/etc/modprobe.d/nvidia.conf

	local mkinit=/etc/mkinitcpio.conf
	if [[ -f "$mkinit" ]]; then
		local modules="nvidia nvidia_modeset nvidia_uvm nvidia_drm"
		local backup="${mkinit}.backup"
		[[ -f "$backup" ]] || cp "$mkinit" "$backup"
		sed -i -E 's/\bnvidia_drm\b//g; s/\bnvidia_uvm\b//g; s/\bnvidia_modeset\b//g; s/\bnvidia\b//g;' "$mkinit"
		sed -i -E "s/^(MODULES=\\()/\\1${modules} /" "$mkinit"
		sed -i -E 's/  +/ /g' "$mkinit"
		if ! mkinitcpio -P >/dev/null 2>&1; then
			log_warn "mkinitcpio failed while regenerating initramfs for NVIDIA modules"
		fi
	fi
}

install_mac_broadcom_support() {
	local pci_info
	pci_info=$(lspci -nn 2>/dev/null || true)
	if [[ -z "$pci_info" ]]; then
		return
	fi

	if echo "$pci_info" | grep -q '106b:' &&
		(echo "$pci_info" | grep -q '14e4:43a0' || echo "$pci_info" | grep -q '14e4:4331'); then
		log_info "Detected Broadcom Wi-Fi chipset, installing dkms drivers"
		mapfile -t headers < <(installed_kernel_headers)
		install_packages_if_available dkms "${headers[@]}" broadcom-wl
	fi
}

install_mac_spi_support() {
	local product_name
	if [[ -f /sys/class/dmi/id/product_name ]]; then
		product_name=$(</sys/class/dmi/id/product_name)
	else
		return
	fi

	if [[ "$product_name" =~ MacBook[89],1|MacBook1[02],1|MacBookPro13,[123]|MacBookPro14,[123] ]]; then
		log_info "Detected MacBook with SPI keyboard, installing drivers"
		install_packages_if_available macbook12-spi-driver-dkms

		local modules=(applespi intel_lpss_pci spi_pxa2xx_platform)
		if [[ "$product_name" == "MacBook8,1" ]]; then
			modules=(applespi spi_pxa2xx_platform spi_pxa2xx_pci)
		fi

		ensure_directory /etc/mkinitcpio.conf.d
		printf 'MODULES=(%s)\n' "${modules[*]}" >/etc/mkinitcpio.conf.d/macbook_spi_modules.conf
	fi
}

configure_mac_t2_support() {
	if ! lspci -nn | grep -q '106b:180[12]'; then
		return
	fi

	log_info "Detected Apple T2 hardware, preparing support packages"
	local packages=(linux-t2 linux-t2-headers apple-t2-audio-config apple-bcm-firmware t2fanrd tiny-dfr)
	local missing=()
	for pkg in "${packages[@]}"; do
		if ! pacman -Si "$pkg" >/dev/null 2>&1; then
			missing+=("$pkg")
		fi
	done

	if [[ ${#missing[@]} -gt 0 ]]; then
		log_warn "Apple T2 support packages unavailable in repositories: ${missing[*]}"
		return
	fi

	install_packages_if_available "${packages[@]}"

	echo "apple-bce" >/etc/modules-load.d/t2.conf

	ensure_directory /etc/mkinitcpio.conf.d
	cat <<'EOF' >/etc/mkinitcpio.conf.d/apple-t2.conf
MODULES+=(apple-bce usbhid hid_apple hid_generic xhci_pci xhci_hcd)
EOF

	ensure_directory /etc/modprobe.d
	cat <<'EOF' >/etc/modprobe.d/brcmfmac.conf
# Fix for T2 MacBook WiFi connectivity issues
options brcmfmac feature_disable=0x82000
EOF

	ensure_directory /etc/limine-entry-tool.d
	cat <<'EOF' >/etc/limine-entry-tool.d/t2-mac.conf
# Generated automatically for T2 Mac support
KERNEL_CMDLINE[default]+="intel_iommu=on iommu=pt pcie_ports=compat"
EOF
}

install_intel_media_support
install_nvidia_support
install_mac_broadcom_support
install_mac_spi_support
configure_mac_t2_support
# Run the generic hardware tweaks last so they benefit from any packages installed above.
configure_bluetooth
configure_network_stack
configure_printer_support
set_wireless_regdom
disable_usb_autosuspend
ensure_fn_keys_default
fix_powerprofilesctl_shebang

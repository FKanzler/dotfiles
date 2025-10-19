#!/usr/bin/env bash

set -euo pipefail

# Stage 00 runs on the live ISO. It collects user input, renders the
# archinstall configuration, executes the installer, and records the
# gathered state for downstream stages.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
source "$REPO_ROOT/install/lib/common.sh"
ensure_directory "$CACHE_DIR"

# Ensure package manager is available for lightweight helper installs.
require_commands pacman gum:gum jq:jq sed:sed awk:gawk archinstall:archinstall curl:curl lsblk:lsblk findmnt:findmnt openssl:openssl lspci:lspci

# Allow advanced users to override the mount point when chaining stages manually.
TARGET_ROOT=${TARGET_ROOT:-/mnt}

# Ensure any remnants from a previous run do not interfere with a rerun.
cleanup_previous_install() {
	local disk=$1

	if [[ -z "$disk" ]]; then
		return
	fi

	if findmnt -rno TARGET "$TARGET_ROOT" >/dev/null 2>&1; then
		log_info "Unmounting previous target root at $TARGET_ROOT"
		umount -R "$TARGET_ROOT" >/dev/null 2>&1 || true
	fi

	while IFS=',' read -r name type mountpoint; do
		[[ -n "$name" && "$name" == "$disk" ]] && continue
		if [[ "$mountpoint" == "[SWAP]" ]]; then
			if command -v swapoff >/dev/null 2>&1; then
				log_info "Deactivating swap on $name"
				swapoff "$name" >/dev/null 2>&1 || true
			fi
		elif [[ -n "$mountpoint" ]]; then
			log_info "Unmounting $mountpoint"
			umount -R "$mountpoint" >/dev/null 2>&1 || true
		fi
	done < <(lsblk -rpno NAME,TYPE,MOUNTPOINT --output-separator=',' "$disk" 2>/dev/null || true)

	if command -v cryptsetup >/dev/null 2>&1; then
		while read -r mapper; do
			[[ -z "$mapper" ]] && continue
			log_info "Closing LUKS mapper $mapper"
			cryptsetup close "$mapper" >/dev/null 2>&1 || true
		done < <(lsblk -rpno NAME,TYPE "$disk" 2>/dev/null | awk '$2=="crypt"{print $1}')
	fi
}

collect_input() {
	local prompt=$1
	local placeholder=$2
	local require_confirmation=${3:-0}
	local validator=${4:-}
	local value
	local confirm_value

	while true; do
		value=$(gum input --prompt "$prompt: " --placeholder "$placeholder" || abort "Installer cancelled by user.")

		if [[ -n "$validator" && -n "$value" && ! "$value" =~ $validator ]]; then
			log_warn "Input does not match required format, please try again."
			continue
		fi

		if ((require_confirmation)); then
			confirm_value=$(gum input --prompt "Confirm $placeholder: " --placeholder "$placeholder" || abort "Installer cancelled by user.")
			if [[ "$value" != "$confirm_value" ]]; then
				log_warn "Values do not match, please try again."
				continue
			fi
		fi

		printf '%s\n' "$value"
		return 0
	done
}

gum_confirm_prompt() {
	local affirmative=$1
	local negative=$2
	local message=$3

	gum confirm --affirmative "$affirmative" --negative "$negative" "$message"
	local status=$?
	case $status in
	0)
		return 0
		;;
	1)
		return 1
		;;
	130)
		abort "Installer cancelled by user."
		;;
	*)
		abort "gum confirm failed with exit code $status"
		;;
	esac
}

select_disk() {
	local exclude_disk
	exclude_disk=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)

	local disks
	disks=$(
		lsblk -dpno NAME,TYPE |
			awk '$2=="disk"{print $1}' |
			grep -E '/dev/(sd|hd|vd|nvme|mmcblk|xv)' |
			{ if [[ -n "$exclude_disk" ]]; then grep -Fvx "$exclude_disk"; else cat; fi; }
	)

	local options=""
	while IFS= read -r device; do
		[[ -z "$device" ]] && continue
		local size model line
		size=$(lsblk -dno SIZE "$device" 2>/dev/null)
		model=$(lsblk -dno MODEL "$device" 2>/dev/null | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
		line="$device"
		# Show size without decimal places for GiB and TiB
		if [[ -n "$size" ]]; then
			# check if size greater than or equal to 12 GiB
			if (($(numfmt --from=iec "$size") < 12884901888)); then
				continue
			fi

			# Convert size to human-readable format between GiB and TiB
			size=$(numfmt --to=iec --format="%.1f" "$size")
			line="$line ($size)"
		else
			continue
		fi

		[[ -n "$model" ]] && line="$line - $model"
		options+="$line"$'\n'
	done <<<"$disks"

	local selected
	selected=$(echo "$options" | gum choose --header "Select installation disk" || abort "Installer cancelled by user.")
	echo "$selected" | awk '{print $1}'
}

generate_recovery_key() {
	# Read exactly 48 digits from /dev/urandom
	local digits
	digits=$(tr -dc '0-9' </dev/urandom | head -c 48)

	if [[ ${#digits} -lt 48 ]]; then
		while [[ ${#digits} -lt 48 ]]; do
			digits="${digits}$(tr -dc '0-9' </dev/urandom | head -c $((48 - ${#digits})))"
		done
	fi

	# Format as 8 groups of 6 digits separated by hyphens (BitLocker style)
	echo "${digits}" | sed -E 's/.{6}/&-/g' | sed 's/-$//'
}

collect_values() {
	local hostname
	hostname=$(collect_input "Hostname" "Hostname" 0 '^[A-Za-z_][A-Za-z0-9_-]*$')
	set_state_value "hostname" "$hostname"
	set_state_value "target_root" "$TARGET_ROOT"

	local root_password
	root_password=$(collect_input "Root Password" "Root Password" 1 '^.{8,}$')
	set_state_value "root_password_hash" "$(openssl passwd -6 "$root_password")"

	local username
	username=$(collect_input "Username" "Username" 0 '^[a-z_][a-z0-9_-]*[$]?$')
	set_state_value "username" "$username"

	local password
	password=$(collect_input "Password" "Password" 1 '^.{8,}$')
	set_state_value "user_password_hash" "$(openssl passwd -6 "$password")"

	local git_name
	git_name=$(collect_input "Git author name (optional)" "Git Name" 0)
	set_state_value "git.name" "$git_name"

	local git_email
	git_email=$(collect_input "Git author email (optional)" "Git Email" 0 '^[^@]+@[^@]+\.[^@]+$')
	set_state_value "git.email" "$git_email"

	local config_repo
	config_repo=$(collect_input "Config Git repository URL (optional)" "Config Repo URL" 0)
	set_state_value "config_repo" "$config_repo"

	local selected_disk
	while true; do
		selected_disk=$(select_disk)
		if [[ -z "$selected_disk" || ! -b "$selected_disk" ]]; then
			log_warn "Invalid selection, please choose a disk."
			continue
		fi

		if gum_confirm_prompt "Erase" "Choose again" "Erase all data on $selected_disk and continue?"; then
			break
		fi
	done
	set_state_value "disk" "$selected_disk"

	local encryption_key
	while true; do
		encryption_key=$(generate_recovery_key)
		gum style --foreground=212 "Save this disk encryption recovery key somewhere safe:"
		gum style --foreground=10 --bold --border rounded --padding "1 2" "$encryption_key"
		if gum_confirm_prompt "Continue" "Generate new key" "Have you written down the recovery key?"; then
			break
		fi
	done
	set_state_value "encryption_password" "$encryption_key"

	local timezone=$(curl -s https://ipapi.co/timezone || true)
	timezone=${timezone:-Europe/Berlin}
	set_state_value "timezone" "$timezone"
}

generate_config_files() {
	local disk=$(get_state_value "disk")
	local username=$(get_state_value "username")
	local hostname=$(get_state_value "hostname")
	local user_password_hash=$(get_state_value "user_password_hash")
	local root_password_hash=$(get_state_value "root_password_hash")
	local encryption_key=$(get_state_value "encryption_password")
	local config_repo_url=$(get_state_value "config_repo")
	local timezone=$(get_state_value "timezone")

	cleanup_previous_install "$disk"

	local disk_size=$(lsblk -bdno SIZE "$disk" 2>/dev/null || true)
	local mib=$((1024 * 1024))
	local gib=$((mib * 1024))
	local disk_size_mib=$((disk_size / mib * mib))
	local gpt_backup_reserve=$((mib))
	local boot_partition_start=$((mib))
	local boot_partition_size=$((2 * gib))
	local main_partition_start=$((boot_partition_size + boot_partition_start))
	local main_partition_size=$((disk_size_mib - main_partition_start - gpt_backup_reserve))

	local kernel_package="linux"
	if lspci -nn 2>/dev/null | grep -q "106b:180[12]"; then
		kernel_package="linux-t2"
	fi

	local user_password_hash_escaped=$(printf '%s' "$user_password_hash" | jq -Rsa)
	local root_password_hash_escaped=$(printf '%s' "$root_password_hash" | jq -Rsa)
	local encryption_key_escaped=$(printf '%s' "$encryption_key" | jq -Rsa)
	local username_escaped=$(printf '%s' "$username" | jq -Rsa)

	# Clean up any previous runs.
	rm -f "$CACHE_DIR/user_credentials.json" "$CACHE_DIR/user_configuration.json"

	# Write user + encryption credentials for archinstall.
	cat <<-JSON >"$CACHE_DIR/user_credentials.json"
		{
		    "encryption_password": $encryption_key_escaped,
		    "root_enc_password": $root_password_hash_escaped,
		    "users": [
		        {
		            "enc_password": $user_password_hash_escaped,
		            "groups": [],
		            "sudo": true,
		            "username": $username_escaped
		        }
		    ]
		}
	JSON

	# Render the full archinstall configuration.
	cat <<-JSON >"$CACHE_DIR/user_configuration.json"
		{
		    "app_config": null,
		    "archinstall-language": "English",
		    "auth_config": {},
		    "audio_config": { "audio": "pipewire" },
		    "bootloader": "Limine",
		    "custom_commands": [],
		    "disk_config": {
		        "btrfs_options": {
		            "snapshot_config": {
		                "type": "Snapper"
		            }
		        },
		        "config_type": "default_layout",
		        "device_modifications": [
		            {
		                "device": "$disk",
		                "partitions": [
		                    {
		                        "btrfs": [],
		                        "dev_path": null,
		                        "flags": [ "boot", "esp" ],
		                        "fs_type": "fat32",
		                        "mount_options": [],
		                        "mountpoint": "/boot",
		                        "obj_id": "boot-partition",
		                        "size": {
		                            "sector_size": { "unit": "B", "value": 512 },
		                            "unit": "B",
		                            "value": $boot_partition_size
		                        },
		                        "start": {
		                            "sector_size": { "unit": "B", "value": 512 },
		                            "unit": "B",
		                            "value": $boot_partition_start
		                        },
		                        "status": "create",
		                        "type": "primary"
		                    },
		                    {
		                        "btrfs": [
		                            { "mountpoint": "/", "name": "@" },
		                            { "mountpoint": "/home", "name": "@home" },
		                            { "mountpoint": "/var/log", "name": "@log" },
		                            { "mountpoint": "/var/cache/pacman/pkg", "name": "@pkg" }
		                        ],
		                        "dev_path": null,
		                        "flags": [],
		                        "fs_type": "btrfs",
		                        "mount_options": [ "compress=zstd" ],
		                        "mountpoint": null,
		                        "obj_id": "root-partition",
		                        "size": {
		                            "sector_size": { "unit": "B", "value": 512 },
		                            "unit": "B",
		                            "value": $main_partition_size
		                        },
		                        "start": {
		                            "sector_size": { "unit": "B", "value": 512 },
		                            "unit": "B",
		                            "value": $main_partition_start
		                        },
		                        "status": "create",
		                        "type": "primary"
		                    }
		                ],
		                "wipe": true
		            }
		        ],
		        "disk_encryption": {
		            "encryption_type": "luks",
		            "lvm_volumes": [],
		            "iter_time": 2000,
		            "partitions": [ "root-partition" ],
		            "encryption_password": $encryption_key_escaped
		        }
		    },
		    "hostname": "$hostname",
		    "kernels": [ "$kernel_package" ],
		    "network_config": { "type": "iso" },
		    "ntp": true,
		    "parallel_downloads": 8,
		    "script": null,
		    "services": [],
		    "swap": true,
		    "timezone": "$timezone",
		    "locale_config": {
		        "kb_layout": "us",
		        "sys_enc": "UTF-8",
		        "sys_lang": "en_US.UTF-8"
		    },
		    "mirror_config": {
		        "custom_repositories": [],
		        "custom_servers": [],
		        "mirror_regions": {},
		        "optional_repositories": []
		    },
		    "packages": [ "base-devel" ],
		    "profile_config": {
		        "gfx_driver": null,
		        "greeter": null,
		        "profile": {}
		    },
		    "version": "3.0.9"
		}
	JSON
}

run_archinstall() {
	archinstall \
		--config "$CACHE_DIR/user_configuration.json" \
		--creds "$CACHE_DIR/user_credentials.json" \
		--silent
}

confirm_continue_previous() {
	if exists_previous_state; then
		if gum_confirm_prompt "Continue" "Reset" "Previous installation state detected. Do you want to continue or reset the state and start fresh?"; then
			return
		fi

		reset_state_file
		log_info "Previous installation state reset."
	fi
}

confirm_continue_previous

run_step "Collecting user input" collect_values
run_step "Generating configuration files" generate_config_files
run_step "Running archinstall" run_archinstall

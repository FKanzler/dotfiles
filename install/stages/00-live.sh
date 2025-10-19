#!/usr/bin/env bash

set -euo pipefail

# Stage 00 runs on the live ISO. It collects user input, renders the
# archinstall configuration, executes the installer, and records the
# gathered state for downstream stages.

STATE_FILE=${1:? "State file path required as first argument"}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

# Ensure the tooling we rely on is available before moving further.
require_commands gum archinstall jq curl lsblk awk findmnt openssl lspci

# Allow advanced users to override the mount point when chaining stages manually.
TARGET_ROOT=${TARGET_ROOT:-/mnt}

# Prompt with validation for simple text fields.
collect_input() {
	local prompt=$1
	local placeholder=$2
	local validator=$3
	local value

	while true; do
		value=$(gum input --prompt "$prompt: " --placeholder "$placeholder")
		if [[ -z "$validator" || "$value" =~ $validator ]]; then
			printf '%s\n' "$value"
			return 0
		fi
	done
}

USERNAME=$(collect_input "Username" "Username" '^[a-z_][a-z0-9_-]*[$]?$')

# Ask for the password twice so typos do not silently slip in.
while true; do
	PASSWORD=$(gum input --placeholder "Password" --password)
	CONFIRM=$(gum input --placeholder "Confirm password" --password)
	if [[ -n "$PASSWORD" && "$PASSWORD" == "$CONFIRM" ]]; then
		break
	fi
	log_warn "Passwords do not match, please try again."
done

HOSTNAME=$(collect_input "Hostname" "Hostname" '^[A-Za-z_][A-Za-z0-9_-]*$')

# Default to the detected timezone, fall back to Berlin when offline.
TIMEZONE=$(curl -s https://ipapi.co/timezone || true)
TIMEZONE=${TIMEZONE:-Europe/Berlin}

# Optional Git author information is stored for later stages.
GIT_NAME=$(gum input --placeholder "Git author name (optional)")
GIT_EMAIL=$(gum input --placeholder "Git author email (optional)")

GIT_NAME_JSON="null"
GIT_EMAIL_JSON="null"

if [[ -n "$GIT_NAME" ]]; then
	GIT_NAME_JSON=$(printf '%s' "$GIT_NAME" | jq -Rsa)
fi

if [[ -n "$GIT_EMAIL" ]]; then
	GIT_EMAIL_JSON=$(printf '%s' "$GIT_EMAIL" | jq -Rsa)
fi

# Support shipping dotfiles from an external repository. If the input is blank we
# simply keep using the scripts bundled with this checkout.
CONFIG_REPO_URL=$(gum input --placeholder "Config Git repository URL (optional)")
CONFIG_REPO_JSON="null"
if [[ -n "$CONFIG_REPO_URL" ]]; then
	CONFIG_REPO_JSON=$(printf '%s' "$CONFIG_REPO_URL" | jq -Rsa)
fi

# Display a list of eligible disks, excluding the USB media.
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
		[[ -n "$size" ]] && line="$line ($size)"
		[[ -n "$model" ]] && line="$line - $model"
		options+="$line"$'\n'
	done <<<"$disks"

	local selected
	selected=$(echo "$options" | gum choose --header "Select installation disk")
	echo "$selected" | awk '{print $1}'
}

# Confirm destructive disk selection with the user.
while true; do
	SELECTED_DISK=$(select_disk)
	if [[ -z "$SELECTED_DISK" || ! -b "$SELECTED_DISK" ]]; then
		log_warn "Invalid selection, please choose a disk."
		continue
	fi

	if gum confirm --affirmative "Erase" --negative "Abort" "Erase all data on $SELECTED_DISK and continue?"; then
		break
	fi
done

# Generate a 48-digit numeric recovery key in BitLocker format (8 groups of 6 digits).
generate_recovery_key() {
	# Read exactly 48 digits from /dev/urandom
	local digits
	digits=$(tr -dc '0-9' </dev/urandom | head -c 48)

	# Safety: if for some reason we didn't get 48 digits (very unlikely), pad/regenerate
	if [ "${#digits}" -lt 48 ]; then
		# try again until we have 48
		while [ "${#digits}" -lt 48 ]; do
			digits="${digits}$(tr -dc '0-9' </dev/urandom | head -c $((48 - ${#digits})))"
		done
	fi

	# Format as 8 groups of 6 digits separated by hyphens (BitLocker style)
	echo "${digits}" | sed -E 's/.{6}/&-/g' | sed 's/-$//'
}

while true; do
	ENCRYPTION_KEY=$(generate_recovery_key)
	gum style --foreground=212 "Save this disk encryption recovery key somewhere safe:"
	gum style --foreground=10 --bold --border rounded --padding "1 2" "$ENCRYPTION_KEY"
	if gum confirm --affirmative "Continue" --negative "Generate new key" "Have you written down the recovery key?"; then
		break
	fi
done

# Pre-compute partition sizes that get interpolated into the JSON. Using aligned
# MiB ensures the generated Archinstall plan rounds consistently across runs.
DISK_SIZE=$(lsblk -bdno SIZE "$SELECTED_DISK")
MIB=$((1024 * 1024))
GIB=$((MIB * 1024))
DISK_SIZE_MIB=$((DISK_SIZE / MIB * MIB))
GPT_BACKUP_RESERVE=$((MIB))
BOOT_PARTITION_START=$((MIB))
BOOT_PARTITION_SIZE=$((2 * GIB))
MAIN_PARTITION_START=$((BOOT_PARTITION_SIZE + BOOT_PARTITION_START))
MAIN_PARTITION_SIZE=$((DISK_SIZE_MIB - MAIN_PARTITION_START - GPT_BACKUP_RESERVE))

((MAIN_PARTITION_SIZE >= 12 * GIB)) || abort "Disk is too small. Minimum required is 12 GiB."

KERNEL_PACKAGE="linux"
if lspci -nn 2>/dev/null | grep -q "106b:180[12]"; then
	KERNEL_PACKAGE="linux-t2"
fi

# Archinstall expects hashed passwords and JSON-escaped strings for user credentials.
PASSWORD_HASH=$(openssl passwd -6 "$PASSWORD")

PASSWORD_HASH_ESCAPED=$(printf '%s' "$PASSWORD_HASH" | jq -Rsa)
ENCRYPTION_KEY_ESCAPED=$(printf '%s' "$ENCRYPTION_KEY" | jq -Rsa)
USERNAME_ESCAPED=$(printf '%s' "$USERNAME" | jq -Rsa)

# Clean up any previous runs.
rm -f "$REPO_ROOT/user_credentials.json" "$REPO_ROOT/user_configuration.json" "$REPO_ROOT/install/state.json"

# Write user + encryption credentials for archinstall.
cat <<-JSON >"$REPO_ROOT/user_credentials.json"
	{
	    "encryption_password": $ENCRYPTION_KEY_ESCAPED,
	    "root_enc_password": $PASSWORD_HASH_ESCAPED,
	    "users": [
	        {
	            "enc_password": $PASSWORD_HASH_ESCAPED,
	            "groups": [],
	            "sudo": true,
	            "username": $USERNAME_ESCAPED
	        }
	    ]
	}
JSON

# Render the full archinstall configuration.
cat <<-JSON >"$REPO_ROOT/user_configuration.json"
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
	                "device": "$SELECTED_DISK",
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
	                            "value": $BOOT_PARTITION_SIZE
	                        },
	                        "start": {
	                            "sector_size": { "unit": "B", "value": 512 },
	                            "unit": "B",
	                            "value": $BOOT_PARTITION_START
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
	                            "value": $MAIN_PARTITION_SIZE
	                        },
	                        "start": {
	                            "sector_size": { "unit": "B", "value": 512 },
	                            "unit": "B",
	                            "value": $MAIN_PARTITION_START
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
	            "encryption_password": $ENCRYPTION_KEY_ESCAPED
	        }
	    },
	    "hostname": "$HOSTNAME",
	    "kernels": [ "$KERNEL_PACKAGE" ],
	    "network_config": { "type": "iso" },
	    "ntp": true,
	    "parallel_downloads": 8,
	    "script": null,
	    "services": [],
	    "swap": true,
	    "timezone": "$TIMEZONE",
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

gum style --foreground 3 "Running Archinstall..."

archinstall \
	--config "$REPO_ROOT/user_configuration.json" \
	--creds "$REPO_ROOT/user_credentials.json" \
	--silent

# Persist settings that subsequent stages rely on.
cat <<-JSON >"$STATE_FILE"
	{
	    "username": "$USERNAME",
	    "hostname": "$HOSTNAME",
	    "disk": "$SELECTED_DISK",
	    "timezone": "$TIMEZONE",
	    "target_root": "$TARGET_ROOT",
	    "git": {
	        "name": $GIT_NAME_JSON,
	        "email": $GIT_EMAIL_JSON
	    },
	    "config_repo": $CONFIG_REPO_JSON,
	    "encryption_password": $ENCRYPTION_KEY_ESCAPED
	}
JSON

log_info "Base installation complete. Proceeding with configuration stages."

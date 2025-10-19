#!/usr/bin/env bash

set -euo pipefail

# Stage 00 runs on the live ISO. It collects user input, renders the
# archinstall configuration, executes the installer, and records the
# gathered state for downstream stages.

STATE_FILE=${1:? "State file path required as first argument"}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

# Ensure package manager is available for lightweight helper installs.
require_commands pacman

if ! command -v gum >/dev/null 2>&1; then
	run_step "Installing gum for interactive prompts" pacman -Sy --noconfirm --needed gum
fi

if ! command -v jq >/dev/null 2>&1; then
	run_step "Installing jq for JSON processing" pacman -Sy --noconfirm --needed jq
fi

if ! command -v awk >/dev/null 2>&1; then
	run_step "Installing gawk for text processing" pacman -Sy --noconfirm --needed gawk
fi

# Basic tooling requirements for the live stage.
require_commands gum archinstall jq curl lsblk awk findmnt openssl lspci

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

# Simple cache so repeated runs can reuse previous answers.
CACHE_DIR=${ARCH_BOOTSTRAP_CACHE_DIR:-/var/tmp/arch-bootstrap}
ANSWERS_FILE="$CACHE_DIR/user_inputs.json"
ensure_directory "$CACHE_DIR"

USERNAME=""
PASSWORD_HASH=""
ENCRYPTION_KEY=""
HOSTNAME=""
TIMEZONE=""
CONFIG_REPO_URL=""
GIT_NAME=""
GIT_EMAIL=""
SELECTED_DISK=""
ARCHINSTALL_COMPLETED=0

load_saved_inputs() {
	if [[ ! -f "$ANSWERS_FILE" ]]; then
		return 0
	fi

	USERNAME=$(jq -r '.username // ""' "$ANSWERS_FILE")
	PASSWORD_HASH=$(jq -r '.password_hash // ""' "$ANSWERS_FILE")
	ENCRYPTION_KEY=$(jq -r '.encryption_key // ""' "$ANSWERS_FILE")
	HOSTNAME=$(jq -r '.hostname // ""' "$ANSWERS_FILE")
	TIMEZONE=$(jq -r '.timezone // ""' "$ANSWERS_FILE")
	CONFIG_REPO_URL=$(jq -r '.config_repo // ""' "$ANSWERS_FILE")
	GIT_NAME=$(jq -r '.git_name // ""' "$ANSWERS_FILE")
	GIT_EMAIL=$(jq -r '.git_email // ""' "$ANSWERS_FILE")
	SELECTED_DISK=$(jq -r '.disk // ""' "$ANSWERS_FILE")
	if jq -e '.archinstall_completed == true' "$ANSWERS_FILE" >/dev/null 2>&1; then
		ARCHINSTALL_COMPLETED=1
	fi
	return 0
}

persist_inputs() {
	local tmp
	tmp=$(mktemp)

	jq -n \
		--arg username "$USERNAME" \
		--arg password_hash "$PASSWORD_HASH" \
		--arg encryption_key "$ENCRYPTION_KEY" \
		--arg hostname "$HOSTNAME" \
		--arg timezone "$TIMEZONE" \
		--arg config_repo "$CONFIG_REPO_URL" \
		--arg git_name "$GIT_NAME" \
		--arg git_email "$GIT_EMAIL" \
		--arg disk "$SELECTED_DISK" \
		--argjson completed "$ARCHINSTALL_COMPLETED" \
		'{
			username: (if $username == "" then null else $username end),
			password_hash: (if $password_hash == "" then null else $password_hash end),
			encryption_key: (if $encryption_key == "" then null else $encryption_key end),
			hostname: (if $hostname == "" then null else $hostname end),
			timezone: (if $timezone == "" then null else $timezone end),
			config_repo: (if $config_repo == "" then null else $config_repo end),
			git_name: (if $git_name == "" then null else $git_name end),
			git_email: (if $git_email == "" then null else $git_email end),
			disk: (if $disk == "" then null else $disk end),
			archinstall_completed: $completed
		}' >"$tmp"

	mv "$tmp" "$ANSWERS_FILE"
}

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

load_saved_inputs

USE_SAVED_INPUTS=0
RUN_ARCHINSTALL=1

if [[ -f "$ANSWERS_FILE" ]]; then
	if gum confirm --affirmative "Use saved data" --negative "Enter new values" "Reuse answers from the previous run?"; then
		USE_SAVED_INPUTS=1
		if ((ARCHINSTALL_COMPLETED == 1)); then
			if ! gum confirm --affirmative "Run again" --negative "Skip" "Archinstall already completed. Run it again?"; then
				RUN_ARCHINSTALL=0
			else
				RUN_ARCHINSTALL=1
				ARCHINSTALL_COMPLETED=0
			fi
		fi
	else
		USE_SAVED_INPUTS=0
	fi
fi

if ((USE_SAVED_INPUTS == 0)); then
	USERNAME=$(collect_input "Username" "Username" '^[a-z_][a-z0-9_-]*[$]?$')

	while true; do
		PASSWORD=$(gum input --placeholder "Password" --password)
		CONFIRM=$(gum input --placeholder "Confirm password" --password)
		if [[ -n "$PASSWORD" && "$PASSWORD" == "$CONFIRM" ]]; then
			break
		fi
		log_warn "Passwords do not match, please try again."
	done
	PASSWORD_HASH=$(openssl passwd -6 "$PASSWORD")
	unset PASSWORD CONFIRM

	HOSTNAME=$(collect_input "Hostname" "Hostname" '^[A-Za-z_][A-Za-z0-9_-]*$')

	TIMEZONE=$(curl -s https://ipapi.co/timezone || true)
	TIMEZONE=${TIMEZONE:-Europe/Berlin}

	GIT_NAME=$(gum input --placeholder "Git author name (optional)")
	GIT_EMAIL=$(gum input --placeholder "Git author email (optional)")
	CONFIG_REPO_URL=$(gum input --placeholder "Config Git repository URL (optional)")

	while true; do
		SELECTED_DISK=$(select_disk)
		if [[ -z "$SELECTED_DISK" || ! -b "$SELECTED_DISK" ]]; then
			log_warn "Invalid selection, please choose a disk."
			continue
		fi

		if gum confirm --affirmative "Erase" --negative "Choose again" "Erase all data on $SELECTED_DISK and continue?"; then
			break
		fi
	done

	while true; do
		ENCRYPTION_KEY=$(generate_recovery_key)
		gum style --foreground=212 "Save this disk encryption recovery key somewhere safe:"
		gum style --foreground=10 --bold --border rounded --padding "1 2" "$ENCRYPTION_KEY"
		if gum confirm --affirmative "Continue" --negative "Generate new key" "Have you written down the recovery key?"; then
			break
		fi
	done

	ARCHINSTALL_COMPLETED=0
	persist_inputs
else
	if [[ -z "$USERNAME" || -z "$PASSWORD_HASH" || -z "$ENCRYPTION_KEY" || -z "$HOSTNAME" || -z "$SELECTED_DISK" ]]; then
		abort "Saved answers are incomplete. Please enter new values."
	fi
	if ((RUN_ARCHINSTALL == 1)); then
		ARCHINSTALL_COMPLETED=0
		persist_inputs
	fi
fi

if ((RUN_ARCHINSTALL != 0)); then
	cleanup_previous_install "$SELECTED_DISK"

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

	ARCHINSTALL_COMPLETED=1
	persist_inputs
fi

GIT_NAME_JSON="null"
GIT_EMAIL_JSON="null"
if [[ -n "$GIT_NAME" ]]; then
	GIT_NAME_JSON=$(printf '%s' "$GIT_NAME" | jq -Rsa)
fi
if [[ -n "$GIT_EMAIL" ]]; then
	GIT_EMAIL_JSON=$(printf '%s' "$GIT_EMAIL" | jq -Rsa)
fi

CONFIG_REPO_JSON="null"
if [[ -n "$CONFIG_REPO_URL" ]]; then
	CONFIG_REPO_JSON=$(printf '%s' "$CONFIG_REPO_URL" | jq -Rsa)
fi

ENCRYPTION_KEY_ESCAPED=$(printf '%s' "$ENCRYPTION_KEY" | jq -Rsa)

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

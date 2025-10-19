#!/usr/bin/env bash

# Guard against double inclusion so sourcing is idempotent.
if [[ -n "${_ARCH_BOOTSTRAP_COMMON_SOURCED:-}" ]]; then
	return
fi
readonly _ARCH_BOOTSTRAP_COMMON_SOURCED=1

CACHE_DIR=${ARCH_BOOTSTRAP_CACHE_DIR:-/var/tmp/arch-bootstrap}
STATE_FILE=${ARCH_BOOTSTRAP_STATE_FILE:-$CACHE_DIR/state.json}

INIT_STATE=0

STATE_VALUES=()

COMPLETED_STAGES=()
COMPLETED_SCRIPTS=()
COMPLETED_STEP=0

# ANSI color helpers for readable log lines.
COLOR_RESET=$'\033[0m'
COLOR_INFO=$'\033[1;34m'
COLOR_WARN=$'\033[1;33m'
COLOR_ERROR=$'\033[1;31m'

# Emit an informational message.
log_info() {
	printf '%s[INFO]%s %s\n' "$COLOR_INFO" "$COLOR_RESET" "$*"
}

# Emit a warning message.
log_warn() {
	printf '%s[WARN]%s %s\n' "$COLOR_WARN" "$COLOR_RESET" "$*" >&2
}

# Emit an error message.
log_error() {
	printf '%s[ERR ]%s %s\n' "$COLOR_ERROR" "$COLOR_RESET" "$*" >&2
}

# Stop execution with an error.
abort() {
	log_error "$*"
	exit 1
}

# Ensure each required command exists before continuing.
require_commands() {
	local -a specs=("$@")
	local -a missing_cmds=()
	local -a install_cmds=()
	local -a install_pkgs=()

	for spec in "${specs[@]}"; do
		local cmd pkg
		if [[ "$spec" == *:* ]]; then
			cmd="${spec%%:*}"
			pkg="${spec#*:}"
		else
			cmd="$spec"
			pkg=""
		fi

		if ! command -v "$cmd" >/dev/null 2>&1; then
			if [[ -n "$pkg" ]]; then
				install_cmds+=("$cmd")
				install_pkgs+=("$pkg")
			else
				missing_cmds+=("$cmd")
			fi
		fi
	done

	((${#missing_cmds[@]} == 0 && ${#install_pkgs[@]} == 0)) && return 0

	if ((${#install_pkgs[@]} > 0)) && command -v "pacman" >/dev/null 2>&1; then
		pacman -Syu --noconfirm --needed "${install_pkgs[@]}"

		local -a still_missing_after_install=()
		for i in "${!install_cmds[@]}"; do
			local c="${install_cmds[$i]}"
			if ! command -v "$c" >/dev/null 2>&1; then
				still_missing_after_install+=("$c")
			fi
		done
		if ((${#still_missing_after_install[@]} > 0)); then
			missing_cmds+=("${still_missing_after_install[@]}")
		fi
	fi

	if ((${#missing_cmds[@]} > 0)); then
		abort "Aborting: missing commands: ${missing_cmds[*]}"
	fi

	return 0
}
require_commands() {
	local missing=0

	for cmd in "$@"; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			log_error "Missing required command: $cmd"
			missing=1
		fi
	done

	((missing == 0)) || abort "Aborting because required commands are missing."
}

# Create a directory if it does not already exist.
ensure_directory() {
	local dir=$1
	if [[ ! -d "$dir" ]]; then
		mkdir -p "$dir"
	fi
}

# Create or update a symlink, overwriting existing files.
ensure_symlink() {
	local target=$1
	local link=$2
	if [[ -L "$link" || -e "$link" ]]; then
		rm -rf "$link"
	fi
	ln -snf "$target" "$link"
}

# Query a JSON file using jq and return the raw value.
json_get() {
	local file=$1
	local query=$2
	jq -r "$query" "$file"
}

# Determine the repository root from the helper location.
repo_root() {
	local script_dir
	script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
	printf '%s\n' "$script_dir"
}

# Initialize state variables from the state file.
init_state() {
	if ((INIT_STATE)); then
		return
	fi

	ensure_directory "$CACHE_DIR"

	STATE_VALUES=$(jq -r '.values | to_entries[] | "\(.key)=\(.value)"' "$STATE_FILE" 2>/dev/null || echo "")
	COMPLETED_STAGES=$(jq -r '.stages // [] | .[]' "$STATE_FILE")
	COMPLETED_SCRIPTS=$(jq -r '.scripts // [] | .[]' "$STATE_FILE")
	COMPLETED_STEP=$(jq '.step // 0' "$STATE_FILE")

	INIT_STATE=1
}

# Set a value in the state file.
set_state_value() {
	local key=$1
	local value=$2
	init_state
	STATE_VALUES+=("$key=$value")
	jq --arg key "$key" --arg value "$value" '.values[$key] = $value' "$STATE_FILE"
}

# Retrieve a value from the state file, returning a default if not present.
get_state_value() {
	local key=$1
	local default_value=${2:-"null"}
	init_state
	for entry in "${STATE_VALUES[@]}"; do
		local entry_key=${entry%%=*}
		local entry_value=${entry#*=}
		if [[ "$entry_key" == "$key" ]]; then
			printf '%s\n' "$entry_value"
			return
		fi
	done
	printf '%s\n' "$default_value"
}

# Mark a stage as complete in the state file.
complete_stage() {
	local stage=$1
	init_state
	COMPLETED_STAGES+=("$stage")
	jq --arg stage "$stage" '.stages += [$stage]' "$STATE_FILE"
}

# Check if a stage is marked complete in the state file.
is_stage_completed() {
	local stage=$1
	init_state
	if [[ " ${COMPLETED_STAGES[@]} " =~ " $stage " ]]; then
		return 0
	else
		return 1
	fi
}

# Run a stage if it hasn't been completed.
run_stage() {
	local stage_script=$1
	if is_stage_completed "$(basename "$stage_script")"; then
		log_info "Stage $(basename "$stage_script") already completed; skipping"
		return
	fi
	if [[ ! -f "$stage_script" ]]; then
		abort "Missing stage script: $stage_script"
	fi
	log_info "Executing stage $(basename "$stage_script")"
	bash "$stage_script" "$STATE_FILE"
	complete_stage "$(basename "$stage_script")"
}

# Mark a script as complete in the state file.
complete_script() {
	local script=$1
	init_state
	COMPLETED_SCRIPTS+=("$script")
	jq --arg script "$script" '.scripts += [$script] .step = 0' "$STATE_FILE"
}

# Check if a script is marked complete in the state file.
is_script_completed() {
	local script=$1
	init_state
	if [[ " ${COMPLETED_SCRIPTS[@]} " =~ " $script " ]]; then
		return 0
	else
		return 1
	fi
}

# Run a script if it hasn't been completed.
run_script() {
	local script=$1
	if is_script_completed "$(basename "$script")"; then
		log_info "Script $(basename "$script") already completed; skipping"
		return
	fi
	if [[ ! -f "$script" ]]; then
		abort "Missing script: $script"
	fi
	log_info "Executing script $(basename "$script")"
	bash "$script" "$STATE_FILE"
	complete_script "$(basename "$script")"
}

# Mark a step as complete in the state file.
complete_step() {
	jq --arg step "$CURRENT_STEP" '.step = ($step | tonumber)' "$STATE_FILE"
	COMPLETED_STEP=$((COMPLETED_STEP + 1))
}

is_step_completed() {
	local description=$1
	if ((COMPLETED_STEP >= CURRENT_STEP)); then
		log_info "Step $CURRENT_STEP ($description) already completed; skipping"
		return 0
	else
		log_info "Executing step $CURRENT_STEP ($description)"
		return 1
	fi
}

# Log the action about to run and execute it.
run_step() {
	local description=$1
	shift
	if is_step_completed; then
		log_info "Skipping $description"
		return
	fi
	log_info "$description"
	"$@"
	complete_step
}

# Execute every script in the provided directory in sorted order.
run_scripts_in_dir() {
	local dir=$1

	if [[ ! -d "$dir" ]]; then
		return
	fi

	local script
	while IFS= read -r -d '' script; do
		run_script "$script"
	done < <(find "$dir" -type f -name '*.sh' | sort -z)
}

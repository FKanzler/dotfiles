#!/usr/bin/env bash

# Guard against double inclusion so sourcing is idempotent.
if [[ -n "${_ARCH_BOOTSTRAP_COMMON_SOURCED:-}" ]]; then
	return
fi
readonly _ARCH_BOOTSTRAP_COMMON_SOURCED=1

CACHE_DIR=${ARCH_BOOTSTRAP_CACHE_DIR:-/var/tmp/arch-bootstrap}
STATE_FILE=${STATE_FILE:-${ARCH_BOOTSTRAP_STATE_FILE:-$CACHE_DIR/state.json}}

INIT_STATE=0

STATE_VALUES=()

COMPLETED_STAGES=()
COMPLETED_SCRIPTS=()
COMPLETED_STEP=0
STEP_INDEX=0

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

	if ((${#install_pkgs[@]} > 0)) && command -v pacman >/dev/null 2>&1; then
		pacman -Syu --noconfirm --needed "${install_pkgs[@]}" || abort "Failed to install required packages: ${install_pkgs[*]}"

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

# Ensure the state file exists with the expected schema.
ensure_state_file() {
	ensure_directory "$CACHE_DIR"

	if [[ ! -f "$STATE_FILE" ]]; then
		cat <<'JSON' >"$STATE_FILE"
{
  "stages": [],
  "scripts": [],
  "step": 0,
  "values": {}
}
JSON
	fi
}

# Run a jq mutation against the state file and replace it atomically.
update_state_file() {
	local tmp
	tmp=$(mktemp) || abort "Unable to create temporary file for state update."

	if ! jq "$@" "$STATE_FILE" >"$tmp"; then
		rm -f "$tmp"
		abort "Failed to update state file: $STATE_FILE"
	fi

	mv "$tmp" "$STATE_FILE"
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

	ensure_state_file

	mapfile -t STATE_VALUES < <(jq -r '.values // {} | to_entries[] | "\(.key)=\(.value)"' "$STATE_FILE")
	mapfile -t COMPLETED_STAGES < <(jq -r '.stages // [] | .[]' "$STATE_FILE")
	mapfile -t COMPLETED_SCRIPTS < <(jq -r '.scripts // [] | .[]' "$STATE_FILE")
	COMPLETED_STEP=$(jq -r '.step // 0' "$STATE_FILE")
	STEP_INDEX=0

	INIT_STATE=1
}

# Set a value in the state file.
set_state_value() {
	local key=$1
	local value=$2
	init_state
	local -a updated=()
	for entry in "${STATE_VALUES[@]}"; do
		local entry_key=${entry%%=*}
		if [[ "$entry_key" != "$key" ]]; then
			updated+=("$entry")
		fi
	done
	updated+=("$key=$value")
	STATE_VALUES=("${updated[@]}")
	update_state_file --arg key "$key" --arg value "$value" '
		.values = (.values // {} | .[$key] = $value)
		| setpath(($key | split(".")); $value)'
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
	if ! is_stage_completed "$stage"; then
		COMPLETED_STAGES+=("$stage")
	fi
	update_state_file --arg stage "$stage" '
		.stages = (.stages // [] | if index($stage) == null then . + [$stage] else . end)'
}

# Check if a stage is marked complete in the state file.
is_stage_completed() {
	local stage=$1
	init_state
	for entry in "${COMPLETED_STAGES[@]}"; do
		if [[ "$entry" == "$stage" ]]; then
			return 0
		fi
	done
	return 1
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
	ARCH_BOOTSTRAP_STATE_FILE="$STATE_FILE" bash "$stage_script" "$STATE_FILE"
	complete_stage "$(basename "$stage_script")"
}

# Mark a script as complete in the state file.
complete_script() {
	local script=$1
	init_state
	if ! is_script_completed "$script"; then
		COMPLETED_SCRIPTS+=("$script")
	fi
	update_state_file --arg script "$script" '
		.scripts = (.scripts // [] | if index($script) == null then . + [$script] else . end)
		| .step = 0'
	COMPLETED_STEP=0
	STEP_INDEX=0
}

# Check if a script is marked complete in the state file.
is_script_completed() {
	local script=$1
	init_state
	for entry in "${COMPLETED_SCRIPTS[@]}"; do
		if [[ "$entry" == "$script" ]]; then
			return 0
		fi
	done
	return 1
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
	ARCH_BOOTSTRAP_STATE_FILE="$STATE_FILE" bash "$script" "$STATE_FILE"
	complete_script "$(basename "$script")"
}

# Mark a step as complete in the state file.
complete_step() {
	local step_number=${1:-$STEP_INDEX}
	update_state_file --argjson step "$step_number" '.step = $step'
	COMPLETED_STEP=$step_number
}

# Log the action about to run and execute it.
run_step() {
	local description=$1
	shift
	init_state
	STEP_INDEX=$((STEP_INDEX + 1))
	local step_number=$STEP_INDEX

	if ((step_number <= COMPLETED_STEP)); then
		log_info "Step $step_number ($description) already completed; skipping"
		return
	fi
	log_info "Step $step_number ($description)"
	"$@"
	complete_step "$step_number"
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

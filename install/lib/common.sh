#!/usr/bin/env bash

# Guard against double inclusion so sourcing is idempotent.
if [[ -n "${_ARCH_BOOTSTRAP_COMMON_SOURCED:-}" ]]; then
	return
fi
readonly _ARCH_BOOTSTRAP_COMMON_SOURCED=1

CACHE_DIR=${ARCH_BOOTSTRAP_CACHE_DIR:-/var/tmp/arch-bootstrap}
STATE_FILE=${STATE_FILE:-${ARCH_BOOTSTRAP_STATE_FILE:-$CACHE_DIR/state.json}}
LOG_FILE=${ARCH_BOOTSTRAP_LOG_FILE:-$CACHE_DIR/install.log}

# Create a directory if it does not already exist.
ensure_directory() {
	local dir=$1
	if [[ ! -d "$dir" ]]; then
		mkdir -p "$dir"
	fi
}

ensure_directory "$CACHE_DIR"

if [[ -n "$LOG_FILE" ]]; then
	mkdir -p "$(dirname "$LOG_FILE")"
	if [[ ! -f "$LOG_FILE" ]]; then
		touch "$LOG_FILE"
	fi
	printf '\n%s [INFO] ==== Installer run started (pid=%s) ====\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$$" >>"$LOG_FILE"
fi

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

_log_to_file() {
	local level=$1
	shift
	local message="$*"
	if [[ -n "$LOG_FILE" ]]; then
		printf '%s [%s] %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$level" "$message" >>"$LOG_FILE"
	fi
}

# Emit an informational message.
log_info() {
	_log_to_file "INFO" "$*"
	printf '%s[INFO]%s %s\n' "$COLOR_INFO" "$COLOR_RESET" "$*"
}

# Emit a warning message.
log_warn() {
	_log_to_file "WARN" "$*"
	printf '%s[WARN]%s %s\n' "$COLOR_WARN" "$COLOR_RESET" "$*" >&2
}

# Emit an error message.
log_error() {
	_log_to_file "ERROR" "$*"
	printf '%s[ERR ]%s %s\n' "$COLOR_ERROR" "$COLOR_RESET" "$*" >&2
}

# Stop execution with an error.
abort() {
	log_error "$*"
	if [[ -n "$LOG_FILE" ]]; then
		_log_to_file "ERROR" "Log available at $LOG_FILE"
		printf '%s[ERR ]%s Log available at %s\n' "$COLOR_ERROR" "$COLOR_RESET" "$LOG_FILE" >&2
	fi
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
	if [[ ! -f "$STATE_FILE" ]]; then
		reset_state_file
	fi
}

reset_state_file() {
	cat <<'JSON' >"$STATE_FILE"
{
  "stages": [],
  "scripts": [],
  "step": 0,
  "values": {}
}
JSON
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

# Get the full path to a cached file.
cache_file_path() {
	local filename=$1
	printf '%s/%s\n' "$CACHE_DIR" "$filename"
}

# Get cache dir path
cache_dir_path() {
	printf '%s\n' "$CACHE_DIR"
}

# Query a JSON file using jq and return the raw value.
json_get() {
	local file=$1
	local query=$2
	jq -r "$query" "$file"
}

# Show a gum confirmation prompt and normalize exit handling.
confirm_prompt() {
	local affirmative=$1
	local negative=$2
	local message=$3

	if ! command -v gum >/dev/null 2>&1; then
		abort "gum is required for interactive prompts but is not available."
	fi

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

# Show a gum input prompt and return the value.
input_prompt() {
	local prompt=""
	local placeholder=""
	local validator=""
	local confirm=0
	local password=0
	local optional=0
	local value
	local confirm_value
	local -a gum_args
	local -a confirm_args

	# Backwards compatibility for the old positional signature.
	if (($# > 0)) && [[ "$1" != --* ]]; then
		prompt=$1
		placeholder=${2:-""}
		confirm=${3:-0}
		validator=${4:-""}
		password=${5:-0}
	else
		while (($# > 0)); do
			case "$1" in
			--prompt)
				prompt=$2
				shift 2
				;;
			--placeholder)
				placeholder=$2
				shift 2
				;;
			--validator)
				validator=$2
				shift 2
				;;
			--confirm)
				confirm=1
				shift
				;;
			--password)
				password=1
				shift
				;;
			--optional)
				optional=1
				shift
				;;
			--)
				shift
				break
				;;
			-*)
				abort "Unknown option for input_prompt: $1"
				;;
			*)
				abort "Unexpected argument for input_prompt: $1"
				;;
			esac
		done
	fi

	if [[ -z "$prompt" ]]; then
		abort "input_prompt requires --prompt"
	fi
	if [[ -z "$placeholder" ]]; then
		placeholder="$prompt"
	fi

	while true; do
		gum_args=(gum input --prompt "$prompt: " --placeholder "$placeholder")
		if ((password)); then
			gum_args+=(--password)
		fi
		value=$("${gum_args[@]}")
		local status=$?
		case $status in
		0) ;;
		1)
			continue
			;;
		130)
			abort "Installer cancelled by user."
			;;
		*)
			abort "gum input failed with exit code $status"
			;;
		esac

		if [[ -z "$value" ]]; then
			if ((optional)); then
				printf '%s\n' "$value"
				return 0
			fi
			log_warn "Input is required, please enter a value."
			continue
		fi

		if [[ -n "$validator" && ! "$value" =~ $validator ]]; then
			log_warn "Input does not match required format, please try again. (Expected format: $validator)"
			continue
		fi

		if ((confirm)); then
			confirm_args=(gum input --prompt "Confirm $placeholder: " --placeholder "$placeholder")
			if ((password)); then
				confirm_args+=(--password)
			fi
			confirm_value=$("${confirm_args[@]}")
			status=$?
			case $status in
			0) ;;
			1)
				continue
				;;
			130)
				abort "Installer cancelled by user."
				;;
			*)
				abort "gum input failed with exit code $status"
				;;
			esac
			if [[ "$value" != "$confirm_value" ]]; then
				log_warn "Values do not match, please try again."
				continue
			fi
		fi

		printf '%s\n' "$value"
		return 0
	done
}

# Show a gum selection prompt and return the chosen value.
select_prompt() {
	local header=""
	local allow_empty=0
	local -a options=()

	while (($# > 0)); do
		case "$1" in
		--header)
			header=$2
			shift 2
			;;
		--option)
			options+=("$2")
			shift 2
			;;
		--optional)
			allow_empty=1
			shift
			;;
		--)
			shift
			break
			;;
		-*)
			abort "Unknown option for select_prompt: $1"
			;;
		*)
			options+=("$1")
			shift
			;;
		esac
	done

	while (($# > 0)); do
		options+=("$1")
		shift
	done

	if ! command -v gum >/dev/null 2>&1; then
		abort "gum is required for interactive prompts but is not available."
	fi

	if ((${#options[@]} == 0)); then
		if ((allow_empty)); then
			printf '\n'
			return 0
		fi
		abort "No options provided for selection prompt."
	fi

	local selected
	selected=$(printf '%s\n' "${options[@]}" | gum choose --header "$header")
	local status=$?
	case $status in
	0)
		printf '%s\n' "$selected"
		;;
	130)
		abort "Installer cancelled by user."
		;;
	*)
		if ((allow_empty)); then
			printf '\n'
			return 0
		fi
		abort "gum choose failed with exit code $status"
		;;
	esac
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
	bash "$stage_script"
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
	ARCH_BOOTSTRAP_STATE_FILE="$STATE_FILE" bash "$script"
	complete_script "$(basename "$script")"
}

exists_previous_state() {
	ensure_state_file
	local stage_count
	stage_count=$(jq -r '.stages | length' "$STATE_FILE")
	local script_count
	script_count=$(jq -r '.scripts | length' "$STATE_FILE")
	local step_count
	step_count=$(jq -r '.step' "$STATE_FILE")

	if ((stage_count > 0 || script_count > 0 || step_count > 0)); then
		return 0
	fi
	return 1
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
		log_info "$description already completed; skipping"
		return
	fi
	log_info "$description"
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

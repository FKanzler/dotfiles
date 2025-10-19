#!/usr/bin/env bash

# Guard against double inclusion so sourcing is idempotent.
if [[ -n "${_ARCH_BOOTSTRAP_COMMON_SOURCED:-}" ]]; then
	return
fi
readonly _ARCH_BOOTSTRAP_COMMON_SOURCED=1

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
	local missing=0
	for cmd in "$@"; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			log_error "Missing required command: $cmd"
			missing=1
		fi
	done

	((missing == 0)) || abort "Aborting because required commands are missing."
}

# Log the action about to run and execute it.
run_step() {
	local description=$1
	shift

	log_info "$description"
	"$@"
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

# Execute every script in the provided directory in sorted order.
run_scripts_in_dir() {
	local dir=$1
	local state_file=$2

	if [[ ! -d "$dir" ]]; then
		return
	fi

	local script
	while IFS= read -r -d '' script; do
		log_info "Running $(basename "$script")"
		bash "$script" "$state_file"
	done < <(find "$dir" -maxdepth 1 -type f -name '*.sh' -print0 | sort -z)
}

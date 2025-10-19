#!/usr/bin/env bash

set -euo pipefail

# Set sensible default applications for common MIME types.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

declare -a IMAGE_TYPES=(
	image/png
	image/jpeg
	image/gif
	image/webp
	image/bmp
	image/tiff
)

declare -a VIDEO_TYPES=(
	video/mp4
	video/x-msvideo
	video/x-matroska
	video/x-flv
	video/x-ms-wmv
	video/mpeg
	video/ogg
	video/webm
	video/quicktime
	video/3gpp
	video/3gpp2
	video/x-ms-asf
	video/x-ogm+ogg
	video/x-theora+ogg
	application/ogg
)

refresh_mime_cache() {
	update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
}

set_image_defaults() {
	for mime in "${IMAGE_TYPES[@]}"; do
		xdg-mime default imv.desktop "$mime"
	done
}

set_pdf_and_browser_defaults() {
	xdg-mime default org.gnome.Evince.desktop application/pdf
	xdg-settings set default-web-browser brave.desktop >/dev/null 2>&1 || true
	xdg-mime default brave.desktop x-scheme-handler/http
	xdg-mime default brave.desktop x-scheme-handler/https
}

set_video_defaults() {
	for mime in "${VIDEO_TYPES[@]}"; do
		xdg-mime default mpv.desktop "$mime"
	done
}

run_step "Refreshing MIME cache" refresh_mime_cache
run_step "Setting image viewer defaults" set_image_defaults
run_step "Setting PDF and browser defaults" set_pdf_and_browser_defaults
run_step "Setting video player defaults" set_video_defaults

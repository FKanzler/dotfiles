#!/usr/bin/env bash

set -euo pipefail

# Set sensible default applications for common MIME types.

STATE_FILE=${1:? "State file path required"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$REPO_ROOT/install/lib/common.sh"

# Refresh the MIME cache quietly so xdg-mime queries see the latest desktop files.
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

declare -a image_types=(
	image/png
	image/jpeg
	image/gif
	image/webp
	image/bmp
	image/tiff
)

# Map all common image types to imv. Re-running simply keeps the preferred handler.
for mime in "${image_types[@]}"; do
	xdg-mime default imv.desktop "$mime"
done

xdg-mime default org.gnome.Evince.desktop application/pdf
xdg-settings set default-web-browser brave.desktop >/dev/null 2>&1 || true
xdg-mime default brave.desktop x-scheme-handler/http
xdg-mime default brave.desktop x-scheme-handler/https

declare -a video_types=(
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

# Associate video formats with mpv so playback uses the same player across formats.
for mime in "${video_types[@]}"; do
	xdg-mime default mpv.desktop "$mime"
done

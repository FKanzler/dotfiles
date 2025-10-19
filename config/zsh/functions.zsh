# shellcheck shell=zsh

compress() { tar -czf "${1%/}.tar.gz" "${1%/}"; }
alias decompress='tar -xzf'

iso2sd() {
	if [[ $# -ne 2 ]]; then
		echo "Usage: iso2sd <input_file> <output_device>"
		echo "Example: iso2sd ~/Downloads/archlinux.iso /dev/sda"
		echo
		echo "Available removable devices:"
		lsblk -d -o NAME | grep -E '^sd[a-z]' | awk '{print "/dev/"$1}'
	else
		sudo dd bs=4M status=progress oflag=sync if="$1" of="$2"
		sudo eject "$2"
	fi
}

format-drive() {
	if [[ $# -ne 2 ]]; then
		echo "Usage: format-drive <device> <label>"
		echo "Example: format-drive /dev/sda WorkDisk"
		echo
		echo "Available drives:"
		lsblk -d -o NAME -n | awk '{print "/dev/"$1}'
	else
		echo "WARNING: This will erase all data on $1 and label it '$2'."
		read -r "?Continue? (y/N): " confirm
		if [[ "$confirm" =~ ^[Yy]$ ]]; then
			sudo wipefs -a "$1"
			sudo dd if=/dev/zero of="$1" bs=1M count=100 status=progress
			sudo parted -s "$1" mklabel gpt
			sudo parted -s "$1" mkpart primary ext4 1MiB 100%
			if [[ "$1" == *nvme* ]]; then
				target="${1}p1"
			else
				target="${1}1"
			fi
			sudo mkfs.ext4 -L "$2" "$target"
			echo "Drive $1 formatted and labeled '$2'."
		fi
	fi
}

transcode-video-1080p() {
	ffmpeg -i "$1" -vf scale=1920:1080 -c:v libx264 -preset fast -crf 23 -c:a copy "${1%.*}-1080p.mp4"
}

transcode-video-4k() {
	ffmpeg -i "$1" -c:v libx265 -preset slow -crf 24 -c:a aac -b:a 192k "${1%.*}-optimized.mp4"
}

img2jpg() {
	magick "$1" -quality 95 -strip "${1%.*}.jpg"
}

img2jpg-small() {
	magick "$1" -resize 1080x\> -quality 95 -strip "${1%.*}.jpg"
}

img2png() {
	magick "$1" -strip \
		-define png:compression-filter=5 \
		-define png:compression-level=9 \
		-define png:compression-strategy=1 \
		-define png:exclude-chunk=all \
		"${1%.*}.png"
}

# shellcheck shell=zsh

if [[ -n "${DOTFILES_ZSH_RC_SOURCED:-}" ]]; then
	return
fi
export DOTFILES_ZSH_RC_SOURCED=1

ZSH_CONFIG_DIR="${ZDOTDIR:-$HOME}/.config/zsh"

for segment in environment aliases functions prompt init; do
	segment_file="$ZSH_CONFIG_DIR/${segment}.zsh"
	[[ -f "$segment_file" ]] && source "$segment_file"
done

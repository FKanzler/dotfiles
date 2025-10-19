# shellcheck shell=zsh

if command -v mise >/dev/null 2>&1; then
	eval "$(mise activate zsh)"
fi

if command -v starship >/dev/null 2>&1; then
	eval "$(starship init zsh)"
fi

if command -v zoxide >/dev/null 2>&1; then
	eval "$(zoxide init zsh)"
fi

if command -v fzf >/dev/null 2>&1; then
	[[ -f /usr/share/fzf/completion.zsh ]] && source /usr/share/fzf/completion.zsh
	[[ -f /usr/share/fzf/key-bindings.zsh ]] && source /usr/share/fzf/key-bindings.zsh
fi

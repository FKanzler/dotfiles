# shellcheck shell=zsh

# File system helpers
alias ls='eza -lh --group-directories-first --icons=auto'
alias lsa='ls -a'
alias lt='eza --tree --level=2 --long --icons --git'
alias lta='lt -a'
alias ff="fzf --preview 'bat --style=numbers --color=always {}'"

# Directory navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

function zd() {
	if [[ $# -eq 0 ]]; then
		builtin cd ~ || return
	elif [[ -d $1 ]]; then
		builtin cd "$1" || return
	elif command -v z >/dev/null 2>&1; then
		z "$@" && printf '\uF1E9 ' && pwd || echo "Error: directory not found"
	else
		echo "Error: directory not found"
	fi
}
alias cd='zd'

function open() {
	xdg-open "$@" >/dev/null 2>&1 &
}

# Tools
alias d='docker'
alias r='rails'

# Git helpers
alias g='git'
alias gcm='git commit -m'
alias gcam='git commit -a -m'
alias gcad='git commit -a --amend'

function n() {
	if [[ $# -eq 0 ]]; then
		nvim .
	else
		nvim "$@"
	fi
}

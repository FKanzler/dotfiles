# shellcheck shell=zsh

export ZDOTDIR="${ZDOTDIR:-$HOME}"

HISTDIR="${XDG_STATE_HOME:-$HOME/.local/state}/zsh"
mkdir -p "$HISTDIR"
HISTFILE="$HISTDIR/history"
HISTSIZE=32768
SAVEHIST=$HISTSIZE

setopt APPEND_HISTORY
setopt SHARE_HISTORY
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_REDUCE_BLANKS
setopt EXTENDED_HISTORY

autoload -Uz compinit
if [[ ! -f "$ZDOTDIR/.zcompdump" ]]; then
	compinit -i
else
	compinit -C
fi

if autoload -Uz bashcompinit 2>/dev/null; then
	bashcompinit
fi

typeset -U path PATH
path=("$HOME/.local/bin" $path)

export EDITOR="${EDITOR:-nvim}"
export VISUAL="${VISUAL:-$EDITOR}"
export PAGER="${PAGER:-less}"
export SUDO_EDITOR="$EDITOR"
export BAT_THEME="${BAT_THEME:-ansi}"

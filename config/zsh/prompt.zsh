# shellcheck shell=zsh

setopt PROMPT_SUBST
autoload -Uz colors && colors

function dotfiles_precmd() {
	print -Pn "\e]0;%~\a"
}
precmd_functions+=dotfiles_precmd

PROMPT="%F{cyan}❯%f "
RPROMPT=""

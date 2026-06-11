# config.fish — minimal fish setup for the live/installed CachyOS box.

set -gx EDITOR nvim
set -gx VISUAL nvim

# Friendlier defaults
alias ll 'ls -lAh'
alias g  'git'
alias v  'nvim'

# Show the tailscale IP quickly
alias tsip 'tailscale ip -4'

if status is-interactive
    set fish_greeting "CachyOS — ssh ready, run `claude` for agent-assisted config."
end

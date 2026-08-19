# Configuration

nerimux reads a tmux-style config at startup.

## Path resolution

1. `$NERIMUX_CONF`, if set.
2. `$XDG_CONFIG_HOME/nerimux/nerimux.conf` (default
   `~/.config/nerimux/nerimux.conf`).
3. Your existing tmux config, as a fallback:
   `$XDG_CONFIG_HOME/tmux/tmux.conf`, `~/.config/tmux/tmux.conf`, or
   `~/.tmux.conf`.

A missing file is not an error.

## Syntax

The syntax is tmux's:

```tmux
# prefix and splits
set -g prefix C-a
bind | split-window -h
bind - split-window -v

# status line with format strings
set -g status-left "#[bold]#{session_name} "
set -g status-right "#{pane_current_command} %H:%M"

# conditionals and variables (tmux 3.2+)
%if "#{==:#{host},worklaptop}"
set -g status-style bg=blue
%endif
MYCOLOR=red
set -g message-style "bg=#{MYCOLOR}"

# hooks and shell integration
set-hook -g after-new-window 'display-message "window created"'
if-shell 'test -f ~/.tmux.local' 'source-file ~/.tmux.local'
```

Supported directives include `bind-key`/`unbind-key` (with brace blocks and
`\;` sequences), `set-option` in all scopes with `-a`/`-g`/`-o`/`-w`/`-s`,
`if-shell`, `run-shell`, `source-file`, `set-environment`, `set-hook` (with
`-w`/`-p` object scoping), `%if`/`%elif`/`%else`/`%endif`, `%hidden`, tmux 3.2
variable assignments, line continuations, and tmux quoting/escape rules.

## One deliberate difference: no short aliases

**Only canonical command names are accepted.** Short aliases (`neww`,
`splitw`, `killp`, …) are rejected rather than silently supported, so typos
fail loudly instead of resolving to something unintended.

Spell commands out in configs you share between tmux and nerimux. This is the
single behavioral difference most likely to bite when reusing an existing
`.tmux.conf`; the rest are catalogued in the
[compatibility statement](../reference/compatibility.md).

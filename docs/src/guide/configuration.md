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
# status line with format strings
set-option -g status-left "#[bold]#{session_name} "
set-option -g status-right "#{pane_current_command} %H:%M"

# conditionals and variables (tmux 3.2+)
%if "#{==:#{host},worklaptop}"
set-option -g status-style bg=blue
%endif
MYCOLOR=red
set-option -g message-style "bg=#{MYCOLOR}"

# shell integration
if-shell 'test -f ~/.tmux.local' 'source-file ~/.tmux.local'
```

**Write `set-option`, not `set`.** The directive verbs this parser dispatches
are `set-option`, `set-window-option` and `set-session-option`; the `set` alias
is not among them, and an unrecognized verb is dropped silently rather than
reported. The same applies to key bindings: the parser takes `bind`, `unbind`
and `unbind-all`, not `bind-key`/`unbind-key`. (Key bindings parse but no
longer do anything either — see below.)

Recognized directives: `bind`/`unbind`/`unbind-all` (with brace blocks and
`\;` sequences), `set-option` in all scopes with `-a`/`-g`/`-o`/`-w`/`-s`,
`if-shell`, `run-shell`, `source-file`, `set-environment`, `set-hook` (with
`-w`/`-p` object scoping), `%if`/`%elif`/`%else`/`%endif`, `%hidden`, tmux 3.2
variable assignments, line continuations, and tmux quoting/escape rules.

## What actually takes effect

nerimux became a workspace-only multiplexer: the tmux command dispatch table
and the keystroke pipeline that drove it are gone. The config parser above did
not go with them — `load-config-file` still runs at server startup — but the
directives it parses now split into two groups depending on whether anything
downstream still consumes what they set.

**Still effective** — these reach a live consumer:

- `default-shell` — read by the PTY layer when spawning a pane's shell.
- `status` / status height — read by the status-bar and frame-composition
  renderers.
- `escape-time` — synced into the server options table on every `set`.
- `update-environment` — read when building a new pane's child environment.
- `run-shell` / `if-shell` — still execute real subprocesses through the
  process boundary; nothing about shelling out changed.

**Parsed but inert** — these are accepted, validated, and stored, but nothing
reads the result:

- `bind-key` / `unbind-key` — populate the key-table store (`*key-tables*`)
  exactly as before. Nothing dispatches through that store anymore, because
  the keystroke pipeline that used to look bindings up is gone. A `bind-key`
  line no longer makes a key do anything.
- `prefix` / `prefix2` — set the prefix key-code variables, but nothing reads
  those variables to detect a prefix keystroke anymore.
- `mouse` — the option's runtime side effect still calls
  `*mouse-reporting-hook*` if one is installed, but nothing ever installs it,
  so setting `mouse` has no observable effect.
- `set-hook` — stores hook commands via the command-hook registry, but the
  registry only fires through `*command-hook-runner*`, which is declared and
  exported and never assigned. Hooks are recorded, never run.

This split is a direct consequence of deleting the tmux command table and
keystroke pipeline this session, not a bug in the parser. If a future change
reintroduces a dispatcher, these directives are already wired up to feed it —
only the consumer side needs rebuilding.

## One deliberate difference: no short aliases

**Only canonical command names are accepted.** Short aliases (`neww`,
`splitw`, `killp`, …) are rejected rather than silently supported, so typos
fail loudly instead of resolving to something unintended.

Spell commands out in configs you share between tmux and nerimux. This is the
single behavioral difference most likely to bite when reusing an existing
`.tmux.conf`; the rest are catalogued in the
[compatibility statement](../reference/compatibility.md).

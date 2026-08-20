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
and `unbind-all`, not `bind-key`/`unbind-key`. Both spellings tokenize
without error, and neither is a directive the config layer acts on — but they
are no longer equally quiet about it: `bind`/`unbind`/`unbind-all` are
*recognized* as inert and now warn to `*error-output*` when the config loads
(see below), while `bind-key`/`unbind-key` were never recognized at all and
stay fully silent, the same way `set` does.

Directives that reach a handler: `set-option` in all scopes with
`-a`/`-g`/`-o`/`-w`/`-s`, `if-shell`, `run-shell`, `source-file`,
`set-environment`, `%if`/`%elif`/`%else`/`%endif`, `%hidden`, tmux 3.2 variable
assignments, line continuations, and tmux quoting/escape rules.

`bind`/`unbind`/`unbind-all` and `set-hook` no longer reach a handler at all —
their handlers and the stores behind them were deleted. They still tokenize
(including brace blocks and `\;` sequences) and are then dropped without error;
see below.

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
reads the result. Loading a config that uses one of them now also writes a
one-line warning to `*error-output*` (`%warn-inert-config-directive` in
`config.lisp`, e.g. `nerimux: config directive 'bind' has no effect
(workspace-only build)`); that warning is new, the no-op behavior it
describes is not:

- `bind` / `unbind` / `unbind-all` — the key-table store these wrote into has
  been **deleted**, along with the bind-directive handlers. Such a line now
  matches no handler and falls through to the unrecognized-command path, which
  returns without doing anything. It still parses and still raises nothing; it
  simply no longer writes into a table nobody read.
- `prefix` / `prefix2` — the side-effect handler that armed a key-table entry
  went with the store. `set-option` remains generic, so the line still parses
  and the value is still recorded among the global options; nothing consults it.
- `mouse` — likewise removed from the option side-effect handlers. It had routed
  through `*mouse-reporting-hook*`, which was never assigned, so it was already
  a guaranteed no-op.
- `set-hook` — the command-hook registry it wrote into has been removed, along
  with the directive handler. Firing a stored hook would have meant running a
  tmux command name, and no command dispatcher exists any more, so the feature
  was unwireable rather than merely unwired. The line still parses and is
  ignored. (The unrelated internal Lisp-callback hooks that drive bell/activity
  alerts are a separate registry and still fire.)

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

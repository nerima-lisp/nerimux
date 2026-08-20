# Security model

How to report a vulnerability is covered by the organization-wide
[security policy](https://github.com/nerima-lisp/.github/blob/main/SECURITY.md).
Report suspected vulnerabilities privately through
[GitHub Security Advisories](https://github.com/nerima-lisp/nerimux/security/advisories/new)
rather than opening a public issue, and include reproduction steps and the
platform (OS, SBCL version, terminal).

This page records the part that is specific to nerimux: what the threat model
actually is, so that a reporter can tell a bug from intended behavior.

## The socket directory is the security boundary

The server socket is created in a per-user directory with mode `0700` — under
`$TMUX_TMPDIR`, falling back to the system temp directory — mirroring tmux's
socket model. Anyone who can write to that socket can run commands as the
owning user. The directory permissions, not the protocol, are what confines
this.

## No access control beyond the socket boundary

Earlier versions offered `server-access`, a read-write/read-only ACL command
that governed *other* clients' access. That command is still gone — see
[Compatibility: Removed](compatibility.md#removed) — and nothing replaces
it: any client that reaches the socket gets full read-write capability by
default, with no per-user or per-connection access control the server
itself imposes.

`attach-session -r`, tmux's read-only attach flag, is also gone as a
subcommand, but the capability it exposed came back through a different
door. A global `-r`/`--read-only` flag now sets `*client-read-only*`
(`%apply-global-cli-invocation` in `src/bootstrap/main-startup.lisp`), and
the server enforces it per connection — `client-conn-read-only-p` still
gates key/paste/mouse forwarding to panes in
`src/bootstrap/server-multi-dispatch.lisp`, the same mechanism this page
used to describe as intact-but-unreachable. It is reachable again, but only
as something a client opts into for itself (`nerimux attach -r`); it is not
an access control the socket owner can impose on *other* clients. So it
does not change the previous paragraph's conclusion — the socket's own
permissions remain the whole boundary against a different user.

## Escape-sequence input from panes is untrusted

Programs running inside panes emit bytes that the VT100/ANSI parser consumes.
That input is untrusted and the parser is exercised heavily by the test suite.

Memory-unsafety bugs are not expected, because SBCL is memory-safe. What
remains in scope, and is worth reporting, is state confusion and spoofing — for
example a crafted OSC or DCS sequence that desynchronizes the parser, forges a
prompt mark, or leaks clipboard contents through OSC 52.

## Config files are executed as commands

Loading an untrusted `.tmux.conf`-style file is equivalent to running untrusted
commands: `run-shell`, `if-shell` and `source-file` all execute. This is
intended behavior inherited from tmux, not a vulnerability. Treat a config file
from an untrusted source the way you would treat a shell script from one.

## Supported versions

Only the latest release and the `main` branch receive security fixes.

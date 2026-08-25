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

The server socket is created in a per-user directory with mode `0700` under
`$TMPDIR`, falling back to `/tmp` (`$TMUX_TMPDIR` is not read). Anyone who
can write to that socket can run commands as the owning user. The directory
permissions, not the protocol, are what confines this.

Because that is the whole boundary, it is **verified rather than assumed**.
Before binding, the server `lstat`s the directory and refuses to start unless
it is a real directory (not a symlink), owned by the current uid, and mode
exactly `0700`. Failure is fatal and names the property that failed — the
server does not warn and continue, because continuing would mean serving from
a directory that does not confine anything:

```
nerimux: refusing to start: socket directory /tmp/nerimux-501 has mode 0755,
not the required 0700 -- a group- or world-accessible directory would let
another local user reach the socket
```

`chmod` runs only on a directory nerimux just created, never on one that
already existed. `sb-posix:chmod` follows symlinks and there is no `lchmod`,
so chmod-ing a pre-existing path would let someone who planted a symlink
there redirect the permission change onto a directory of their choosing.

One race is narrowed rather than closed: the check and the later `bind` both
resolve the path by name, so a sufficiently fast local attacker could swap the
directory in between. Closing that needs a pinned directory descriptor and
`fchdir`, which mutates process-wide working directory in a server that spawns
PTY children from several threads — see the note in `%socket-directory`.

## No access control beyond the socket boundary

There is no read-write/read-only ACL over connected clients, and no
read-only attach mode: any client that reaches the socket gets full
read-write capability, with no per-user or per-connection access control
the server itself imposes. The socket's own permissions remain the whole
boundary against a different user.

## Escape-sequence input from panes is untrusted

Programs running inside panes emit bytes that the VT100/ANSI parser consumes.
That input is untrusted and the parser is exercised heavily by the test suite.

Memory-unsafety bugs are not expected, because SBCL is memory-safe. What
remains in scope, and is worth reporting, is state confusion and spoofing — for
example a crafted OSC or DCS sequence that desynchronizes the parser, forges a
prompt mark, or leaks clipboard contents through OSC 52.

## Supported versions

Only the latest release and the `main` branch receive security fixes.

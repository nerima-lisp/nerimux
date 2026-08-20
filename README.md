# nerimux

[![CI](https://github.com/nerima-lisp/nerimux/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/nerima-lisp/nerimux/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Documentation](https://img.shields.io/badge/docs-MkDocs%20Material-0a7a5a)](https://nerima-lisp.github.io/nerimux/)

A workspace-oriented terminal multiplexer written entirely in Common Lisp.
The primary UI navigates an organization → repository → worktree → pane
workspace, with a thin client attached to a headless runtime. The entry
surface is workspace-only — `attach` and `server` are the only commands —
and every verified behavior is pinned by a regression suite that runs
hermetically through Nix.

Full documentation is published at <https://nerima-lisp.github.io/nerimux/>.
The source for that site lives in [docs/src/](docs/src/).

## Quick Start

```bash
nix run github:nerima-lisp/nerimux -- attach

nerimux attach                         # open the workspace overview
nerimux attach organization/repository # focus a repository/worktree
nerimux attach /path/to/worktree       # open a local worktree
```

`attach` auto-starts the headless runtime and connects a thin client. Use
`C-q d` to detach and `C-p` to open the global picker. A selector containing a
slash is resolved as an organization/repository selector or a local worktree
path. `attach` and `server` are the only commands; anything else — including
`nerimux` with no arguments — prints the usage summary and exits non-zero.

nerimux still parses a real `.tmux.conf` — `%if`, `%hidden`, variable
assignments, brace blocks and `source-file` — from `$NERIMUX_CONF`, then
`~/.config/nerimux/nerimux.conf`, then your existing tmux config. `run-shell`,
`if-shell`, `set-environment` and the `set-option` values that drive the
status bar, pane borders, `default-shell` and status height still take
effect. `bind`/`unbind` and `set-hook` lines still parse without error but do
nothing: the key-table store and the command-hook registry they wrote into were
both removed once nothing read them.

## Install

```nix
# flake.nix
inputs.nerimux = {
  url = "github:nerima-lisp/nerimux/v0.1.0";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Note the pinned tag. Consumers inside this org must pin a release tag rather
than follow the default branch.

Nix is the only supported build path: it pins SBCL and every Lisp dependency,
so a build either reproduces exactly or fails loudly. From a checkout,
`nix build .` produces `./result/bin/nerimux`.

## Documentation

- [Getting started](https://nerima-lisp.github.io/nerimux/getting-started/) —
  install, usage, default key bindings, running the suite
- [Configuration](https://nerima-lisp.github.io/nerimux/guide/configuration/) —
  `.tmux.conf` syntax and path resolution
- [Compatibility](https://nerima-lisp.github.io/nerimux/reference/compatibility/) —
  what is implemented, what is deliberately different, where the risk is
- [Architecture](https://nerima-lisp.github.io/nerimux/reference/architecture/) —
  event flow, layering, source layout

## Development

```sh
nix develop          # SBCL with every dependency on the ASDF registry
nix run .#test       # run the test suite
nix flake check      # tests + formatting + docs, the same gate CI uses
nix fmt              # format Nix sources (treefmt)
```

Tests live in `t/` and run under
[cl-weave](https://github.com/nerima-lisp/cl-weave), the org's test framework.
`sbcl --script run-tests.lisp` is the entry point CI and the flake both use;
set `NERIMUX_TEST_SYSTEM` to pick either `nerimux/test` (default) or
`nerimux/dataflow`.

nerimux is the org's L4 application package and its testbed: it runs on twelve
sibling libraries — [cl-cli](https://github.com/nerima-lisp/cl-cli),
[cl-boundary-kit](https://github.com/nerima-lisp/cl-boundary-kit),
[cl-parser-kit](https://github.com/nerima-lisp/cl-parser-kit),
[cl-tty-kit](https://github.com/nerima-lisp/cl-tty-kit),
[cl-process-kit](https://github.com/nerima-lisp/cl-process-kit),
[cl-history-kit](https://github.com/nerima-lisp/cl-history-kit),
[cl-concurrent-kit](https://github.com/nerima-lisp/cl-concurrent-kit),
[cl-regex-kit](https://github.com/nerima-lisp/cl-regex-kit),
[cl-codec-kit](https://github.com/nerima-lisp/cl-codec-kit),
[cl-host-kit](https://github.com/nerima-lisp/cl-host-kit),
[cl-tui-kit](https://github.com/nerima-lisp/cl-tui-kit) and
[cl-vcs-kit](https://github.com/nerima-lisp/cl-vcs-kit).
[cl-dataflow-kit](https://github.com/nerima-lisp/cl-dataflow-kit) is dogfooded
too, but backs the optional `nerimux/dataflow-model` system rather than the
shipped binary.
It has **no external dependencies**: it was the last repository in
the org with any, and the final two (`bordeaux-threads`, `cl-ppcre`) were
replaced by siblings on 2026-08-02. See
[Dogfooded sibling libraries](https://nerima-lisp.github.io/nerimux/guide/sibling-libraries/).

## Contributing

See the org-wide [CONTRIBUTING](https://github.com/nerima-lisp/.github/blob/main/CONTRIBUTING.md)
guide and the [package standard](https://github.com/nerima-lisp/.github/blob/main/PACKAGE_STANDARD.md).

Two rules specific to this repository: the flake only sees git-tracked files,
so a new test file must be `git add`ed before `nix flake check` will run it;
and tests must use the isolation helpers in `t/helpers-isolation.lisp` rather
than touching global session state directly.

## Support

See [SUPPORT](https://github.com/nerima-lisp/.github/blob/main/SUPPORT.md).

## License

MIT. See [LICENSE](LICENSE).

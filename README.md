# cl-tmux

[![CI](https://github.com/nerima-lisp/cl-tmux/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/nerima-lisp/cl-tmux/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Documentation](https://img.shields.io/badge/docs-MkDocs%20Material-0a7a5a)](https://nerima-lisp.github.io/cl-tmux/)

A tmux-compatible terminal multiplexer written entirely in Common Lisp.
cl-tmux reimplements tmux's behavior — commands, options, format strings, copy
mode, hooks, mouse, client/server — on top of SBCL, with no custom C code. It
targets people who want tmux's semantics in a program they can read, extend and
introspect from a REPL; every verified behavior is pinned by a regression suite
of 11,000+ checks that runs hermetically through Nix.

Full documentation is published at <https://nerima-lisp.github.io/cl-tmux/>.
The source for that site lives in [docs/src/](docs/src/).

## Quick Start

```bash
nix run github:nerima-lisp/cl-tmux    # run directly

cl-tmux new-session -s work           # create a session on the server
cl-tmux attach -t work                # attach; C-b d detaches
cl-tmux list-sessions                 # what's running
```

The prefix is `C-b` and the defaults follow tmux. cl-tmux reads a real
`.tmux.conf` — including `%if`, `%hidden`, variable assignments, brace blocks
and `source-file` — from `$CL_TMUX_CONF`, then
`~/.config/cl-tmux/cl-tmux.conf`, then your existing tmux config.

One deliberate difference: only canonical command names are accepted. Short
aliases (`neww`, `splitw`, …) are rejected rather than silently supported, so
typos fail loudly.

## Install

```nix
# flake.nix
inputs.cl-tmux = {
  url = "github:nerima-lisp/cl-tmux/v0.1.0";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Note the pinned tag. Consumers inside this org must pin a release tag rather
than follow the default branch.

Nix is the only supported build path: it pins SBCL and every Lisp dependency,
so a build either reproduces exactly or fails loudly. From a checkout,
`nix build .` produces `./result/bin/cl-tmux`.

## Documentation

- [Getting started](https://nerima-lisp.github.io/cl-tmux/getting-started/) —
  install, usage, default key bindings, running the suite
- [Configuration](https://nerima-lisp.github.io/cl-tmux/guide/configuration/) —
  `.tmux.conf` syntax and path resolution
- [Compatibility](https://nerima-lisp.github.io/cl-tmux/reference/compatibility/) —
  what is implemented, what is deliberately different, where the risk is
- [Architecture](https://nerima-lisp.github.io/cl-tmux/reference/architecture/) —
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
set `CL_TMUX_TEST_SYSTEM` to pick one of `cl-tmux/test` (default),
`cl-tmux/weave` or `cl-tmux/dataflow`.

cl-tmux is the org's L4 application package and its testbed: it runs on ten
sibling libraries — [cl-cli](https://github.com/nerima-lisp/cl-cli),
[cl-boundary-kit](https://github.com/nerima-lisp/cl-boundary-kit),
[cl-dataflow](https://github.com/nerima-lisp/cl-dataflow),
[cl-parser-kit](https://github.com/nerima-lisp/cl-parser-kit),
[cl-tty-kit](https://github.com/nerima-lisp/cl-tty-kit),
[cl-process-kit](https://github.com/nerima-lisp/cl-process-kit),
[cl-history-kit](https://github.com/nerima-lisp/cl-history-kit),
[cl-concurrent-kit](https://github.com/nerima-lisp/cl-concurrent-kit),
[cl-regex-kit](https://github.com/nerima-lisp/cl-regex-kit) — plus
[cl-prolog](https://github.com/nerima-lisp/cl-prolog) for cold-path reasoning
read-models. It has **no external dependencies**: it was the last repository in
the org with any, and the final two (`bordeaux-threads`, `cl-ppcre`) were
replaced by siblings on 2026-08-02. See
[Dogfooded sibling libraries](https://nerima-lisp.github.io/cl-tmux/guide/sibling-libraries/).

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

# nerimux

[![CI](https://github.com/nerima-lisp/nerimux/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/nerima-lisp/nerimux/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Documentation](https://img.shields.io/badge/docs-MkDocs%20Material-0a7a5a)](https://nerima-lisp.github.io/nerimux/)

A workspace-oriented terminal multiplexer written entirely in Common Lisp,
with a [magit](https://magit.vc/)-style keymap. The primary UI is a
three-section repolist — Attention, Active, and Repositories — with a thin
client attached to a headless runtime. The entry surface is workspace-only —
`attach`, `server`, and `kill` are the only commands. The core regression
suite runs hermetically through Nix; live PTY integration is an explicit
host-side check.

Full documentation is published at <https://nerima-lisp.github.io/nerimux/>.
The source for that site lives in [docs/src/](docs/src/).

## Quick Start

```bash
nix run github:nerima-lisp/nerimux              # same as `attach`

nix run github:nerima-lisp/nerimux -- attach
nix run github:nerima-lisp/nerimux -- attach github.com/org/repo
nix run github:nerima-lisp/nerimux -- attach /path/to/worktree
nix run github:nerima-lisp/nerimux -- kill  # stop the server
```

The examples use the flake directly. After `nix build .`, invoke the same
commands with `./result/bin/nerimux`.

`attach` auto-starts the headless runtime and connects a thin client. Running
`nerimux` with no command at all is the same as `attach`; only an
unrecognized command word prints the usage summary and exits non-zero. If the
current directory sits inside a worktree ghq already tracks (a subdirectory
counts too), `attach` opens straight into that worktree's pane instead of the
repolist. Use `C-q d` to detach and `C-p` to open the global picker. A
selector containing a slash is resolved against the ghq catalog — the full
specification, `host/organization/repository` — or against a local worktree
path. `server` runs the headless runtime without attaching a client, and
`kill` stops it.

nerimux reads no configuration file and has no runtime-configurable options.
Every value the workspace UI depends on — shell, `$TERM`, scrollback length,
split ratios, pane limits, and the rest — is a compiled-in constant.

## Install

```nix
# flake.nix
inputs.nerimux = {
  url = "github:nerima-lisp/nerimux/v0.3.0";
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
- [Architecture](https://nerima-lisp.github.io/nerimux/reference/architecture/) —
  event flow, layering, source layout
- [Security model](https://nerima-lisp.github.io/nerimux/reference/security-model/) —
  the socket directory as the trust boundary

## Development

```sh
nix develop          # SBCL with every dependency on the ASDF registry
nix run .#test       # run the test suite (bounded timeout)
CL_WEAVE_TEST_FILTER=renderer nix run .#test  # run matching cl-weave tests
nix build .#coverage-report --no-link --print-build-logs  # strict 100% gate
nix develop --command nerimux-coverage-report  # report-only investigation
nix flake check      # tests + formatting + docs, the same gate CI uses
nix fmt              # format Nix sources (treefmt)
paredit-cli --help   # structural Common Lisp editing in the dev shell
```

Tests live in `tests/` and run under
[cl-weave](https://github.com/nerima-lisp/cl-weave), the org's test framework.
`sbcl --script run-tests.lisp` is the entry point CI and the flake both use;
`NERIMUX_TEST_SYSTEM` selects the system tested and defaults to `nerimux/test`.
Set `CL_WEAVE_TEST_FILTER` to a case-insensitive substring of the cl-weave test
path when iterating on one area of the suite.
The development shell includes `paredit-cli` for syntax-aware editing; use it
for structural transformations before resorting to textual changes. Test and
coverage entry points enforce bounded execution timeouts.
Real-PTY integration cases live in a second suite, `nerimux/pty-test`, run
separately with `nix run .#test-pty` because the hermetic flake gate has no
`/dev/ptmx`. A separate end-to-end smoke script drives the real built binary
under a real PTY; run it with `nix run .#e2e` for the same `/dev/ptmx`
reason.

nerimux is the org's L4 application package and its testbed: it runs on the
sibling libraries — [cl-cli](https://github.com/nerima-lisp/cl-cli),
[cl-date-kit](https://github.com/nerima-lisp/cl-date-kit),
[cl-parser-kit](https://github.com/nerima-lisp/cl-parser-kit),
[cl-tty-kit](https://github.com/nerima-lisp/cl-tty-kit),
[cl-process-kit](https://github.com/nerima-lisp/cl-process-kit),
[cl-concurrent-kit](https://github.com/nerima-lisp/cl-concurrent-kit),
[cl-regex-kit](https://github.com/nerima-lisp/cl-regex-kit),
[cl-codec-kit](https://github.com/nerima-lisp/cl-codec-kit),
[cl-host-kit](https://github.com/nerima-lisp/cl-host-kit),
[cl-tui-kit](https://github.com/nerima-lisp/cl-tui-kit) and
[cl-vcs-kit](https://github.com/nerima-lisp/cl-vcs-kit).
All runtime dependencies are pinned in `flake.nix` and declared explicitly in
`nerimux.asd`; there are no undeclared runtime dependencies. See
[Dogfooded sibling libraries](https://nerima-lisp.github.io/nerimux/guide/sibling-libraries/).

## Contributing

See the org-wide [CONTRIBUTING](https://github.com/nerima-lisp/.github/blob/main/CONTRIBUTING.md)
guide and the [package standard](https://github.com/nerima-lisp/.github/blob/main/PACKAGE_STANDARD.md).

Two rules specific to this repository: the flake only sees git-tracked files,
so a new test file must be `git add`ed before `nix flake check` will run it;
and tests must use the isolation helpers in `tests/helpers-*.lisp` rather than
touching global session state directly.

## Support

See [SUPPORT](https://github.com/nerima-lisp/.github/blob/main/SUPPORT.md).

## License

MIT. See [LICENSE](LICENSE).

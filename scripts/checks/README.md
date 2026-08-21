# Static checks

Three checks that need neither ASDF nor a compile. Each one covers a failure the
test suite cannot report on, because each one breaks the suite itself: a file
that will not read, a manifest that names a file that is not there, a reference
to a symbol its package does not export. In all three cases `nerimux/test` does
not fail a test — it fails to load, and reports nothing about anything.

They are also the only checks available when ASDF cannot load a system at all.
That is not hypothetical; it is how they came to exist.

Run all three from the repository root:

```bash
sbcl --script scripts/checks/read-check.lisp
sbcl --script scripts/checks/manifest-check.lisp
perl scripts/checks/export-check.pl .
```

Each exits non-zero on failure and prints what it checked, so an empty selection
cannot pass for a clean one.

## read-check.lisp — every file still reads

Reads every `.lisp` and `.asd` with `*READ-SUPPRESS*` bound to `T`. Under that
binding the reader tracks list structure, strings, character literals and `#| |#`
blocks, but interns nothing and evaluates no `#.` form — so a file is checked for
balanced delimiters without any package existing and without loading ASDF.
Unbalanced parens surface as `END-OF-FILE`.

This is the guard against the failure mode this repository keeps hitting:
deleting lines from `nerimux.asd`'s `:components` or a `defpackage`'s `:export`
by line number, where a closing paren at the end of a deleted line was also
closing its parent form.

## manifest-check.lisp — the manifest and the tree agree

`system/asdf-test-components.lisp` lists every test file by hand, and
`nerimux.asd` splices that list in at read time. So the manifest and the
directory can disagree in two directions, and they fail in opposite ways:

| | on disk | result |
|---|---|---|
| named in the manifest | absent | ASDF aborts — **the whole suite disappears** |
| not in the manifest | present | silently never loaded — **the tests stop running** |

Checking only the first direction catches a deletion that went too far but not
one that went unnoticed. The second is how a test file becomes decoration.

`t/pty/` is excluded: it belongs to `nerimux/pty-test`, which has its own
component list. `t/e2e/e2e-smoke.lisp` is a known orphan — it is run by hand
against a built binary (see the getting-started guide), not by any ASDF system.

## internal-call-check.pl — every %helper call resolves, with a plausible arity

The cheapest approximation of "it compiles" that needs no compiler. It checks
only names beginning with `%`, the convention for internal helpers, and that
restriction is what makes it sound: a `%name` is always defined in this tree —
never a Common Lisp symbol, never inherited from a sibling, never a stray
variable. So an unresolved `%name` call is a defect rather than a gap in what
the checker knows about the world.

It found one: the layering guard called `%file-text`, whose definition had gone
with the domain/format tests it happened to live in (R2). A guard that cannot
load reports no violations rather than reporting a failure, so nothing else
would have noticed.

Blind spots, shared with the rest of this directory: calls through `apply` or
`funcall`, names built by `intern`, and anything a macro generates. Names
defined inside a `define-*` form are accepted without an arity, because the
macro decides the lambda list and this checker cannot read macros.

## export-check.pl — single-colon references resolve

A `PKG:SYM` reference to a symbol `PKG` does not export is a **read-time** error.
`read-check.lisp` cannot see it, precisely because it reads with `*READ-SUPPRESS*`
so that no package needs to exist.

This collects every `(:export ...)` list from the `defpackage` forms in
`src/bootstrap/package*.lisp` and checks every single-colon reference in `src/`
and `t/` against them.

Double-colon (`PKG::SYM`) is deliberately not checked: it reaches internals on
purpose and is legal whatever the export list says. The layering guard in
`t/unit/bootstrap/system-composition-tests.lisp` is what watches those.

It parses Lisp with a regex, which is only sound because of what it skips:
comments, and strings **across line boundaries**. Dropping the second gives a
false positive on every symbol named in a docstring.

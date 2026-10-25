# Retired: do not reintroduce

The previous keymap used `j` `k` `J` `K` `h` `l` `i`
`o` `d` (view switch) `r` (refresh) `X` (worktree delete) `L` `U` `n`
(worktree create) and `c` (copy mode), plus the `:normal`/`:input`/`:copy`
mode vocabulary itself. None of that survives: `j`/`k` are now `n`/`p`,
`o`/`d` no longer switch views (`C-q w` returns to `repolist` and `q` steps
back), worktree create/delete/lock/unlock moved under the `w` transient,
refresh is `g`, and copy mode is scrollback (`C-q [`).

The later repolist bindings `n` (create a worktree), `p` (prune), `C` (toggle
complete), and `P` (prune all) are retired too. `n` and `p` now move the
selection in both views, `P` opens the Push transient, and the four actions
live at `w n`, `w p`, `w C`, and `w P`.

Two working key bindings (`C-q F`, `C-q C-f`) were also retired outright,
folded into the `f` transient.

;;;; Test isolation helpers for nerimux.
;;;; WITH-ISOLATED-CONFIG (isolated copies of the global/server option tables)
;;;; and WITH-TEMP-CONFIG-FILE (a config-file-on-disk fixture) were removed
;;;; along with the option and config-loading packages in R2 -- there is no
;;;; longer any config or option state to isolate, and no config file format
;;;; to write.  Neither macro had callers outside this file.
;;;; This file is now empty; kept as a load-order placeholder because removing
;;;; it from the ASDF component list is a manifest change out of this file's
;;;; ownership.  See git history for the removed macros.

(in-package #:nerimux/test)

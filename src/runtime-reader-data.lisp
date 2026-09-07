(in-package #:nerimux)

(defvar *reader-scratch-buffer*
  nil
  "Per-reader-thread scratch octet buffer reused by the reader state.")

(defvar *reader-process-generation*
  nil
  "Generation token used to retire an obsolete PTY reader state machine.")

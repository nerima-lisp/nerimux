(in-package #:nerimux/renderer)

(defvar +sgr-copy-mode-match+
  "48;2;241;250;140;38;2;40;42;54"
  "SGR for a copy-mode search match: Dracula yellow background, dark text.")

(defvar +sgr-copy-mode-current-match+
  "48;2;139;233;253;38;2;40;42;54"
  "SGR for the copy-mode search match under the cursor: Dracula cyan
   background, dark text.")

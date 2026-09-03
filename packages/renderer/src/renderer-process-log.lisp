(in-package #:nerimux/renderer)

(defconstant +process-log-max-render-characters+
  4000
  "Hard cap on one entry's OUTPUT before it is even split into lines, applied
   independently of whatever cap the producer (nerimux/vcs:git-write-operation,
   *write-operation-output-max-length*) already used -- this file must not
   assume its caller already bounded the string.")

(defconstant +process-log-max-output-lines+
  20
  "Output lines shown per entry before the remainder is elided.  An ordinary
   git command's output is a handful of lines; this only guards the screen
   against one pathological entry pushing every older entry below the fold.")

(defun %process-log-strip-control-characters (text)
  "TEXT with every control character removed except newline, which
   %PROCESS-LOG-OUTPUT-LINES splits on afterwards.  An unstripped ESC or other
   control code here would let git's own untrusted output inject further escape
   sequences into the frame this file builds -- the same hazard a crafted
   branch name poses elsewhere in this codebase, just arriving through a new
   door (git's stdout/stderr rather than a ref name).

   The range is C0 (below 32) plus DEL (127) plus C1 (128-159), not C0 alone.
   C1 matters because the wire is UTF-8 (INFRASTRUCTURE/NET/PROTOCOL encodes
   with :UTF-8), so U+009B survives transport as its two-byte form and arrives
   here as a single character -- and a terminal that treats decoded C1 as
   8-bit control introducers reads U+009B as CSI, U+009D as OSC and U+0090 as
   DCS. Stripping only C0 blocks the 7-bit `ESC [` spelling of an injection
   while leaving its 8-bit spelling intact, which is the whole attack with one
   byte changed."
  (remove-if
   (lambda (character)
     (let ((code (char-code character)))
       (and (or (< code 32) (<= 127 code 159)) (char/= character #\Newline))))
   text))

(defun %process-log-sanitize-text (text)
  (%process-log-strip-control-characters
   (if (> (length text) +process-log-max-render-characters+)
       (subseq text 0 +process-log-max-render-characters+)
       text)))

(defun %process-log-split-lines (text)
  "TEXT split on #\\Newline.  A local loop rather than a dependency's
   split-string: this file already owns TEXT's only remaining transformation
   (sanitizing it), so pulling in another kit for one more string operation
   would add a dependency edge for no shared behaviour."
  (loop with start = 0
        with length = (length text)
        for newline = (position #\Newline text :start start)
        collect (subseq text start (or newline length))
        while newline
        do (setf start (1+ newline))))

(defun %process-log-output-lines (output)
  "OUTPUT split into sanitized display lines, capped at
   +PROCESS-LOG-MAX-OUTPUT-LINES+ with a trailing elision marker."
  (let* ((clean (%process-log-sanitize-text (or output "")))
         (lines (%process-log-split-lines clean)))
    (if (> (length lines) +process-log-max-output-lines+)
        (append (subseq lines 0 +process-log-max-output-lines+)
                (list
                 (format nil
                         "... ~D more line~:P elided"
                         (- (length lines) +process-log-max-output-lines+))))
        lines)))

(defun %process-log-exit-ok-style ()
  (cl-tui-kit/core:make-style :bold
                              t
                              :foreground
                              (cl-tui-kit/core:rgb-color 80 250 123)))

(defun %process-log-exit-fail-style ()
  (cl-tui-kit/core:make-style :bold
                              t
                              :foreground
                              (cl-tui-kit/core:rgb-color 255 85 85)))

(defun %process-log-command-style ()
  (cl-tui-kit/core:make-style :foreground
                              (cl-tui-kit/core:rgb-color 139 233 253)))

(defun %process-log-output-style ()
  (cl-tui-kit/core:make-style :foreground
                              (cl-tui-kit/core:rgb-color 98 114 164)))

(defun %process-log-separator-style ()
  (cl-tui-kit/core:make-style :foreground (cl-tui-kit/core:rgb-color 68 71 90)))

(defun %process-log-exit-ok-p (exit-status)
  (and (stringp exit-status) (string= exit-status "0")))

(defun %process-log-draw-entry-header (surface row col width entry)
  (destructuring-bind (command exit-status output) entry
    (declare (ignore output))
    (let ((ok-p (%process-log-exit-ok-p exit-status)))
      (cl-tui-kit/core:surface-draw-styled-text surface
                                                col
                                                row
                                                (list
                                                 (cl-tui-kit/core:make-text-span
                                                  (format nil
                                                          "[~A] "
                                                          (%process-log-sanitize-text
                                                           (princ-to-string
                                                            exit-status)))
                                                  :style
                                                  (if ok-p
                                                      (%process-log-exit-ok-style)
                                                      (%process-log-exit-fail-style)))
                                                 (cl-tui-kit/core:make-text-span
                                                  (%process-log-sanitize-text
                                                   (princ-to-string command))
                                                  :style
                                                  (%process-log-command-style)))
                                                :max-width
                                                width))))

(defun %process-log-draw-output-line (surface row col width line)
  (cl-tui-kit/core:surface-draw-styled-text surface
                                            col
                                            row
                                            (list
                                             (cl-tui-kit/core:make-text-span
                                              (format nil "  ~A" line)
                                              :style
                                              (%process-log-output-style)))
                                            :max-width
                                            width))

(defun %process-log-draw-separator (surface row col width)
  (cl-tui-kit/core:surface-draw-styled-text surface
                                            col
                                            row
                                            (list
                                             (cl-tui-kit/core:make-text-span
                                              (make-string width
                                                           :initial-element
                                                           #\─)
                                              :style
                                              (%process-log-separator-style)))
                                            :max-width
                                            width))

(defun %process-log-visible-entries (entries scroll)
  (let* ((count (length entries))
         (scroll (max 0 (min (or scroll 0) (max 0 (1- count))))))
    (nthcdr scroll entries)))

(defun %render-process-log-box (surface rectangle)
  (let ((box
         (cl-tui-kit/widgets:make-box-widget
          (cl-tui-kit/widgets:make-text-widget "" :id :nerimux-process-log-body)
          :id
          :nerimux-process-log-box
          :border-kind
          :single)))
    (cl-tui-kit/widgets:render-widget box surface rectangle)))

(defun render-process-log-to-tui-string (entries rows cols &key scroll)
  "Render ENTRIES -- (COMMAND EXIT-STATUS OUTPUT) tuples, most recent first --
   as the full-screen `$` process log.  A missing/empty ENTRIES renders the
   empty box with a plain \"no commands run yet\" hint rather than nothing,
   the same honesty %RENDER-WORKSPACE-EMPTY-CATALOG-HINT gives the overview."
  (let* ((rows (max 1 rows))
         (cols (max 1 cols))
         (surface (cl-tui-kit/core:make-surface cols rows))
         (rectangle (cl-tui-kit/core:make-rectangle 0 0 cols rows))
         (inner (%box-widget-inner-rectangle rectangle))
         (col (cl-tui-kit/core:rectangle-x inner))
         (width (cl-tui-kit/core:rectangle-width inner))
         (max-row
          (max (cl-tui-kit/core:rectangle-y inner)
               (1-
                (+ (cl-tui-kit/core:rectangle-y inner)
                   (cl-tui-kit/core:rectangle-height inner))))))
    (%render-process-log-box surface rectangle)
    (%stamp-help-view-title surface rectangle "PROCESS LOG")
    (%stamp-help-view-footer surface rectangle "q / Esc close")
    (if (null entries)
        (cl-tui-kit/core:surface-draw-styled-text surface
                                                  col
                                                  (cl-tui-kit/core:rectangle-y
                                                   inner)
                                                  (list
                                                   (cl-tui-kit/core:make-text-span
                                                    "no commands run yet"
                                                    :style
                                                    (%process-log-output-style)))
                                                  :max-width
                                                  width)
        (let ((row (cl-tui-kit/core:rectangle-y inner)))
          (dolist (entry (%process-log-visible-entries entries scroll))
            (when (<= row max-row)
              (%process-log-draw-entry-header surface row col width entry)
              (incf row)
              (dolist (line (%process-log-output-lines (third entry)))
                (when (<= row max-row)
                  (%process-log-draw-output-line surface row col width line)
                  (incf row)))
              (when (<= row max-row)
                (%process-log-draw-separator surface row col width)
                (incf row))))))
    (%surface-to-ansi-frame surface)))

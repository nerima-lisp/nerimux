(in-package #:nerimux/test/renderer)

;;;; renderer tests — part G: direct unit tests for %split-align-attr and
;;;; %status-align-buckets.
;;;;
;;;; These helpers previously had no direct unit tests — they were covered only
;;;; transitively through %compose-aligned-line and #{C:} integration tests.
;;;;
;;;; domain/format (R2.3) is gone, taking nerimux/format::%content-search-
;;;; match-p and its whole #{C:} content-search format directive with it — see
;;;; renderer-format-tests.lisp's header for the deletion list.
;;;; %status-bar-default-segments (R2.2) is gone too, along with the format
;;;; context and status-justify value it used to return: R6.5's status bar is
;;;; composed directly by %status-left-text/%status-middle-text/%status-right-
;;;; text (renderer-statusbar.lisp) instead.
(describe "renderer-suite"

  ;;; ── %split-align-attr ────────────────────────────────────────────────────────
  ;;;
  ;;; %split-align-attr parses the body of a #[…] status block into an align
  ;;; keyword (:left/:centre/:right or NIL) and the remaining non-align attrs as a
  ;;; re-joined comma string (NIL when none survive).  Combined blocks like
  ;;; #[align=right,fg=red] must keep their colour.

  ;; %split-align-attr returns :left for 'align=left' (and its short form 'align=l').
  (it "split-align-attr-left-keyword"
    (multiple-value-bind (align rest)
        (nerimux/renderer::%split-align-attr "align=left")
      (expect (eq :left align))
      (expect (null rest)))
    (multiple-value-bind (align rest)
        (nerimux/renderer::%split-align-attr "align=l")
      (expect (eq :left align))
      (expect (null rest))))

  ;; %split-align-attr returns :centre for align=centre / align=center / align=c.
  (it "split-align-attr-centre-keyword"
    (dolist (body '("align=centre" "align=center" "align=c"))
      (multiple-value-bind (align rest)
          (nerimux/renderer::%split-align-attr body)
        (expect (eq :centre align))
        (expect (null rest)))))

  ;; %split-align-attr returns :right for 'align=right' and 'align=r'.
  (it "split-align-attr-right-keyword"
    (dolist (body '("align=right" "align=r"))
      (multiple-value-bind (align rest)
          (nerimux/renderer::%split-align-attr body)
        (expect (eq :right align))
        (expect (null rest)))))

  ;; %split-align-attr with no align= token returns NIL align and the body as REST.
  (it "split-align-attr-no-align-returns-nil"
    (multiple-value-bind (align rest)
        (nerimux/renderer::%split-align-attr "fg=red")
      (expect (null align))
      (expect (string= "fg=red" rest))))

  ;; %split-align-attr with 'align=right,fg=red' returns :right and 'fg=red'.
  (it "split-align-attr-combined-block-preserves-colour"
    (multiple-value-bind (align rest)
        (nerimux/renderer::%split-align-attr "align=right,fg=red")
      (expect (eq :right align))
      (expect (string= "fg=red" rest))))

  ;; %split-align-attr keeps ALL non-align attrs joined by comma in REST.
  (it "split-align-attr-multiple-style-attrs-preserved"
    (multiple-value-bind (align rest)
        (nerimux/renderer::%split-align-attr "align=centre,fg=blue,bold")
      (expect (eq :centre align))
      (expect (search "fg=blue" rest))
      (expect (search "bold" rest))))

  ;; %split-align-attr with an empty body returns NIL align and NIL rest.
  (it "split-align-attr-empty-body"
    (multiple-value-bind (align rest)
        (nerimux/renderer::%split-align-attr "")
      (expect (null align))
      (expect (null rest))))

  ;;; ── %status-align-buckets ────────────────────────────────────────────────────
  ;;;
  ;;; %status-align-buckets splits a raw status format string into (values LEFT
  ;;; CENTRE RIGHT) sub-strings using #[align=…] markers.  Text before any marker
  ;;; is LEFT; markers switch the current bucket; colour attrs survive within each
  ;;; bucket.

  ;; %status-align-buckets with no #[align=…] puts everything in the left bucket.
  (it "status-align-buckets-no-markers-all-left"
    (multiple-value-bind (left centre right)
        (nerimux/renderer::%status-align-buckets "hello world")
      (expect (string= "hello world" left))
      (expect (string= "" centre))
      (expect (string= "" right))))

  ;; %status-align-buckets splits on #[align=centre] and #[align=right].
  (it "status-align-buckets-basic-three-way-split"
    (multiple-value-bind (left centre right)
        (nerimux/renderer::%status-align-buckets "L#[align=centre]C#[align=right]R")
      (expect (string= "L" left))
      (expect (string= "C" centre))
      (expect (string= "R" right))))

  ;; %status-align-buckets on an empty string returns three empty strings.
  (it "status-align-buckets-empty-string"
    (multiple-value-bind (left centre right)
        (nerimux/renderer::%status-align-buckets "")
      (expect (string= "" left))
      (expect (string= "" centre))
      (expect (string= "" right))))

  ;; A combined #[align=right,fg=red] block switches to RIGHT and emits #[fg=red] there.
  (it "status-align-buckets-combined-block-emits-style-prefix"
    (multiple-value-bind (left centre right)
        (nerimux/renderer::%status-align-buckets "L#[align=right,fg=red]R")
      (expect (string= "L" left))
      (expect (search "fg=red" right))
      (expect (string= "" centre))))

  ;; %status-align-buckets plain text with no markers: everything lands in LEFT.
  (it "status-align-buckets-text-only-in-left"
    (multiple-value-bind (left centre right)
        (nerimux/renderer::%status-align-buckets "abc def")
      (expect (string= "abc def" left))
      (expect (string= "" centre))
      (expect (string= "" right)))))

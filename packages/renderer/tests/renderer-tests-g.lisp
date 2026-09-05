(in-package #:nerimux/test/renderer)

(describe "renderer-suite"


  (it "split-align-attr-left-keyword"
    (multiple-value-bind (align rest)
        (nerimux/renderer::%split-align-attr "align=left")
      (expect (eq :left align))
      (expect (null rest)))
    (multiple-value-bind (align rest)
        (nerimux/renderer::%split-align-attr "align=l")
      (expect (eq :left align))
      (expect (null rest))))

  (it "split-align-attr-centre-keyword"
    (dolist (body '("align=centre" "align=center" "align=c"))
      (multiple-value-bind (align rest)
          (nerimux/renderer::%split-align-attr body)
        (expect (eq :centre align))
        (expect (null rest)))))

  (it "split-align-attr-right-keyword"
    (dolist (body '("align=right" "align=r"))
      (multiple-value-bind (align rest)
          (nerimux/renderer::%split-align-attr body)
        (expect (eq :right align))
        (expect (null rest)))))

  (it "split-align-attr-no-align-returns-nil"
    (multiple-value-bind (align rest)
        (nerimux/renderer::%split-align-attr "fg=red")
      (expect (null align))
      (expect (string= "fg=red" rest))))

  (it "split-align-attr-combined-block-preserves-colour"
    (multiple-value-bind (align rest)
        (nerimux/renderer::%split-align-attr "align=right,fg=red")
      (expect (eq :right align))
      (expect (string= "fg=red" rest))))

  (it "split-align-attr-multiple-style-attrs-preserved"
    (multiple-value-bind (align rest)
        (nerimux/renderer::%split-align-attr "align=centre,fg=blue,bold")
      (expect (eq :centre align))
      (expect (search "fg=blue" rest))
      (expect (search "bold" rest))))

  (it "split-align-attr-empty-body"
    (multiple-value-bind (align rest)
        (nerimux/renderer::%split-align-attr "")
      (expect (null align))
      (expect (null rest))))


  (it "status-align-buckets-no-markers-all-left"
    (multiple-value-bind (left centre right)
        (nerimux/renderer::%status-align-buckets "hello world")
      (expect (string= "hello world" left))
      (expect (string= "" centre))
      (expect (string= "" right))))

  (it "status-align-buckets-basic-three-way-split"
    (multiple-value-bind (left centre right)
        (nerimux/renderer::%status-align-buckets "L#[align=centre]C#[align=right]R")
      (expect (string= "L" left))
      (expect (string= "C" centre))
      (expect (string= "R" right))))

  (it "status-align-buckets-empty-string"
    (multiple-value-bind (left centre right)
        (nerimux/renderer::%status-align-buckets "")
      (expect (string= "" left))
      (expect (string= "" centre))
      (expect (string= "" right))))

  (it "status-align-buckets-combined-block-emits-style-prefix"
    (multiple-value-bind (left centre right)
        (nerimux/renderer::%status-align-buckets "L#[align=right,fg=red]R")
      (expect (string= "L" left))
      (expect (search "fg=red" right))
      (expect (string= "" centre))))

  (it "status-align-buckets-text-only-in-left"
    (multiple-value-bind (left centre right)
        (nerimux/renderer::%status-align-buckets "abc def")
      (expect (string= "abc def" left))
      (expect (string= "" centre))
      (expect (string= "" right)))))

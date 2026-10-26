(in-package #:nerimux/test/renderer)

(describe "renderer-suite/workspace-empty-catalog-guidance"
  (it "shows both ways to add the first repository"
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-string
             nil 24 80 :catalog-empty-hint "/tmp/ghq")))
      (expect (search "ghq get <owner>/<repo>" frame))
      (expect (search ":clone <url>" frame)))))

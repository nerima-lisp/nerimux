(in-package #:nerimux/test)

(describe "runtime state persistence"
  (it "round-trips a reader-safe snapshot"
    (let* ((snapshot
             (nerimux/persistence:make-runtime-snapshot
              :sessions '((:id "session-1" :layout "work"))
              :clients '((:id "client-1" :session "session-1"))
              :worktrees '((:id "worktree-1" :attention (:dirty)))
              :tags '((:name "urgent" :color "red"))
              :notes '((:worktree "worktree-1" :text "inspect"))))
           (serialized (nerimux/persistence:serialize-runtime-snapshot snapshot))
           (restored
             (nerimux/persistence:deserialize-runtime-snapshot serialized)))
      (expect (not (search "#." serialized)))
      (expect (equal (nerimux/persistence:runtime-snapshot->plist snapshot)
                     (nerimux/persistence:runtime-snapshot->plist restored)))))

  (it "rejects reader evaluation and unsupported versions"
    (signals error
      (nerimux/persistence:deserialize-runtime-snapshot
       "(:version 1 :sessions (#.(error \"unsafe\")) :clients () :worktrees () :tags () :notes ())"))
    (signals error
      (nerimux/persistence:deserialize-runtime-snapshot
       "(:version 999 :sessions () :clients () :worktrees () :tags () :notes ())")))

  (it "saves and loads snapshots through the filesystem boundary"
    (let* ((directory (host-kit:temporary-directory))
           (path (merge-pathnames "runtime-state-test.sexp" directory))
           (snapshot
             (nerimux/persistence:make-runtime-snapshot
              :sessions '((:id "session-1")))))
      (unwind-protect
           (progn
             (expect (equal path
                            (nerimux/persistence:save-runtime-snapshot
                             snapshot path)))
             (expect (equal (nerimux/persistence:runtime-snapshot->plist snapshot)
                            (nerimux/persistence:runtime-snapshot->plist
                             (nerimux/persistence:load-runtime-snapshot path)))))
        (host-kit:delete-file-if-exists path))))

  (it "replaces a snapshot without exposing a partial serialization"
    (let* ((directory (host-kit:temporary-directory))
           (path (merge-pathnames "runtime-state-atomic-test.sexp" directory))
           (first-snapshot
             (nerimux/persistence:make-runtime-snapshot
              :sessions '((:id "session-1"))))
           (second-snapshot
             (nerimux/persistence:make-runtime-snapshot
             :sessions '((:id "session-2") (:id "session-3")))))
      (unwind-protect
           (progn
             (nerimux/persistence:save-runtime-snapshot first-snapshot path)
             (nerimux/persistence:save-runtime-snapshot second-snapshot path)
             (expect
              (equal (nerimux/persistence:runtime-snapshot->plist second-snapshot)
                     (nerimux/persistence:runtime-snapshot->plist
                      (nerimux/persistence:load-runtime-snapshot path)))))
        (host-kit:delete-file-if-exists path)))))

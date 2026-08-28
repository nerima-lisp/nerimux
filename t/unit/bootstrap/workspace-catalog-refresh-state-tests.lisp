(in-package #:nerimux/test)

;;;; FR-005: %set-workspace-catalog-refresh-state (server-multi.lisp) took an
;;;; optional STALE-P but no MODE, and always (re-)marked every node
;;;; refreshing unless STALE-P was already true -- so a *successful*
;;;; on-complete callback re-marked every node instead of settling it, and
;;;; the tree-wide "refreshing" label never cleared after a scan that
;;;; succeeded. MODE (:mark / :settle) makes that choice explicit at every
;;;; call site instead of leaving it to STALE-P, which never distinguished
;;;; in-flight from finished in the first place.

(describe "workspace-catalog-refresh-state-suite"

  ;; The low-level function itself: :mark populates *workspace-refreshing-
  ;; ids*, and :settle clears it back out.  Checking the mark actually landed
  ;; first is what keeps the :settle assertion from passing vacuously against
  ;; an already-empty table.
  (it "mark-then-settle-clears-the-refreshing-mark"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let ((nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal)))
        (nerimux::%set-workspace-catalog-refresh-state organizations :mark)
        (expect (plusp (hash-table-count nerimux::*workspace-refreshing-ids*)))
        (nerimux::%set-workspace-catalog-refresh-state organizations :settle)
        (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
        (expect (zerop (hash-table-count nerimux::*workspace-stale-ids*))))))

  ;; :settle :stale-p t moves the node to the stale set instead of merely
  ;; clearing it -- a failed refresh must still show the previous value,
  ;; tagged stale, not silently the same as a clean settle.
  (it "settle-with-stale-p-moves-the-node-to-the-stale-set"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let ((nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal)))
        (nerimux::%set-workspace-catalog-refresh-state organizations :mark)
        (nerimux::%set-workspace-catalog-refresh-state organizations :settle :stale-p t)
        (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
        (expect (plusp (hash-table-count nerimux::*workspace-stale-ids*))))))

  ;; The actual bug this fixes: the on-complete callback %refresh-client-
  ;; picker installs (server-multi-dispatch-picker.lisp) must SETTLE the
  ;; refreshing mark, not re-mark it. This drives that real callback --
  ;; captured from the stubbed nerimux/vcs:refresh-workspace-organizations-
  ;; async call -- rather than calling %set-workspace-catalog-refresh-state
  ;; directly with a hand-picked MODE, so reverting that one call site's
  ;; literal :settle back to :mark (the historical bug) turns this red.
  ;; See CL_WEAVE_TEST_FILTER=refresh-client-picker-on-complete for the
  ;; regression's own filter string.
  (it "refresh-client-picker-on-complete-settles-refreshing-ids-not-re-marks-them"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let ((nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
            (nerimux::*clients* nil)
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* organizations)
            (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
            (refresh-fn (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async))
            (conn (nerimux::%make-client-conn))
            (captured-on-complete nil))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                     (lambda (&key query on-catalog on-complete on-error on-progress
                                callback-dispatch)
                       (declare (ignore query on-error on-progress callback-dispatch))
                       (setf captured-on-complete on-complete)
                       (when on-catalog (funcall on-catalog organizations))))
               (nerimux::%refresh-client-picker conn)
               ;; Sanity: the in-flight mark actually landed somewhere (via
               ;; %refresh-client-picker's own :mark call plus the stubbed
               ;; on-catalog callback's), or the :settle assertion below would
               ;; pass vacuously against an already-empty table.
               (expect (plusp (hash-table-count nerimux::*workspace-refreshing-ids*)))
               (expect captured-on-complete)
               (funcall captured-on-complete organizations)
               (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                refresh-fn)))))

  ;; FR-004b wiring, flagged by test/security review as an untested seam:
  ;; %add-client's own :on-progress callback (server-multi.lisp) is what a
  ;; large ghq root's in-flight scan count reaches the renderer through
  ;; (*workspace-scan-progress*, read by render-workspace-overview-to-
  ;; string's :scan-progress). This drives the REAL %add-client -- not a
  ;; hand-copied reimplementation of its on-progress lambda -- over a real
  ;; (local, hermetic unix-domain) socket, the same connect/accept pattern
  ;; server-multi-tests-loop.lisp already uses, and captures the exact
  ;; closure %add-client passes to the stubbed refresh-workspace-
  ;; organizations-async. Skips (via with-test-listener) only when Unix-
  ;; domain sockets are unavailable in this sandbox, same as every other
  ;; socket-lifecycle test in this suite -- not a gate specific to this test.
  (it "add-client-on-progress-callback-updates-workspace-scan-progress"
    (let ((nerimux::*workspace-catalog-refresh-started-p* nil)
          (nerimux::*workspace-catalog-loaded-p* nil)
          (nerimux::*workspace-scan-progress* nil)
          (nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
          (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
          (nerimux::*clients* nil)
          (nerimux::*dirty* nil)
          (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
          (refresh-fn (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async))
          (captured-on-progress nil))
      (unwind-protect
           (with-test-listener (listener path (%test-socket-path "add-client-on-progress")
                                          :backlog 4)
             (let ((client nil)
                   (server-sock nil))
               (unwind-protect
                    (progn
                      (setf client (nerimux/net:connect-to path)
                            server-sock (nerimux/net:accept-connection listener))
                      (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                            (lambda () t)
                            (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                            (lambda (&key query on-catalog on-complete on-error
                                       on-progress callback-dispatch)
                              (declare (ignore query on-catalog on-complete on-error
                                               callback-dispatch))
                              (setf captured-on-progress on-progress)))
                      (when server-sock
                        (nerimux::%add-client server-sock)))
                 (when client (ignore-errors (nerimux/net:close-socket client)))
                 (when server-sock (ignore-errors (nerimux/net:close-socket server-sock))))))
        (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
              (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async) refresh-fn))
      (expect captured-on-progress)
      (funcall captured-on-progress 7)
      (expect (eql 7 nerimux::*workspace-scan-progress*)))))

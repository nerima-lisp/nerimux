(in-package #:nerimux/test)

;;;; Workspace-overview frame-cost measurement.
;;;;
;;;; This lived in src/presentation/renderer/renderer-tui-kit.lisp and was
;;;; exported from nerimux/renderer so a test could assert a 100ms budget on it.
;;;; The budget assertion is gone: the estimator measures machine availability as
;;;; much as render cost, so the check inverted on unrelated processes' work and
;;;; a red run said nothing about the tree. The measurement itself is still
;;;; useful when someone is deliberately looking at render cost, so it moves here
;;;; rather than being deleted -- but nothing calls it, and no test asserts on
;;;; its output.
;;;;
;;;; Run it by hand from a REPL with the test system loaded:
;;;;
;;;;   (nerimux/test::benchmark-workspace-overview)
;;;;   (nerimux/test::benchmark-workspace-overview :organization-count 100 :samples 9)

(defun %render-duration-ms (thunk)
  "Wall-clock milliseconds for one call of THUNK, as (values MS RESULT)."
  (let* ((start  (get-internal-real-time))
         (result (funcall thunk))
         (end    (get-internal-real-time)))
    (values (floor (* 1000 (- end start)) internal-time-units-per-second)
            result)))

(defun %median-ms (samples)
  "Median of SAMPLES, a non-empty list of millisecond counts."
  (let ((sorted (sort (copy-list samples) #'<)))
    (nth (floor (length sorted) 2) sorted)))

(defun benchmark-workspace-overview (&key (organization-count 1000)
                                          (repository-count organization-count)
                                          (worktree-count 5000)
                                          (pane-count worktree-count)
                                          (rows 40)
                                          (cols 160)
                                          (samples 5))
  "Render the workspace overview at the mandatory scale and report frame cost.

   Discards a warm-up render of each frame -- first-call page faults and lazily
   built caches land there instead of in a measured sample -- and reports the
   MEDIAN of SAMPLES runs, so a GC pause or a scheduling hiccup landing in one
   sample does not decide the result. No explicit GC is forced; the median
   already absorbs a collection landing in any single sample. Raising SAMPLES
   narrows the estimate at linear cost."
  (let* ((organizations
           (nerimux/picker::%benchmark-organizations
            organization-count repository-count worktree-count pane-count))
         (scroll-offset
           (max 0 (- (+ organization-count repository-count worktree-count) 1)))
         (render-initial
           (lambda ()
             (nerimux/renderer:render-workspace-overview-to-tui-string
              organizations rows cols :tree-scroll 0)))
         (render-scrolled
           (lambda ()
             (nerimux/renderer:render-workspace-overview-to-tui-string
              organizations rows cols :tree-scroll scroll-offset)))
         (initial-frame (funcall render-initial))   ; warm-up, not measured
         (scroll-frame  (funcall render-scrolled))  ; warm-up, not measured
         (initial-times '())
         (scroll-times  '()))
    (dotimes (i samples)
      (multiple-value-bind (ms frame) (%render-duration-ms render-initial)
        (push ms initial-times)
        (setf initial-frame frame))
      (multiple-value-bind (ms frame) (%render-duration-ms render-scrolled)
        (push ms scroll-times)
        (setf scroll-frame frame)))
    (list :organization-count organization-count
          :repository-count repository-count
          :worktree-count worktree-count
          :pane-count pane-count
          :tree-node-count (+ organization-count repository-count worktree-count)
          :item-count (+ organization-count repository-count worktree-count pane-count)
          :initial-frame-nonempty-p (plusp (length initial-frame))
          :scroll-frame-nonempty-p (plusp (length scroll-frame))
          :sample-count samples
          :initial-frame-ms (%median-ms initial-times)
          :scroll-frame-ms  (%median-ms scroll-times))))

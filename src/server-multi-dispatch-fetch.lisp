(in-package #:nerimux)

(defun %workspace-fetch-repository (conn)
  "Fetch the selected repository, then refresh status.

A fetch already running for this repository is not started twice; the
caller that finds one in flight is told so and the in-flight fetch's own
completion is what eventually refreshes the picker."
  (let ((repository (%client-selected-repository conn)))
    (cond
      ((not repository)
       (%client-notify conn "fetch requires a selected repository"))
      ((not (nerimux/vcs:vcs-package-available-p))
       (%client-notify conn "VCS unavailable"))
      (t
       (%client-notify conn "fetching...")
       (handler-case (nerimux/vcs:fetch-repository-async repository
                                                         :callback-dispatch
                                                         #'%enqueue-main-thread-callback
                                                         :on-complete
                                                         (lambda (result)
                                                           (if result
                                                               (progn
                                                                 (%refresh-client-picker conn)
                                                                 (%client-notify conn "fetch complete"))
                                                               (%client-notify conn
                                                                               "fetch already in progress")))
                                                         :on-error
                                                         (lambda (condition)
                                                           (%client-notify conn
                                                                           (format nil "fetch failed: ~A"
                                                                                   condition))))
         (error (condition)
           (%client-notify conn (format nil "fetch failed: ~A" condition)))))))
  nil)

(defun %workspace-fetch-organization (conn)
  "Fetch every repository in the selected organization concurrently, then
   refresh status."
  (let ((organization (%client-selected-organization conn)))
    (cond
      ((not organization)
       (%client-notify conn "fetch requires a selected organization"))
      ((not (nerimux/vcs:vcs-package-available-p))
       (%client-notify conn "VCS unavailable"))
      (t
       (%client-notify conn "fetching organization...")
       (handler-case (nerimux/vcs:fetch-organization-async organization
                                                           :callback-dispatch
                                                           #'%enqueue-main-thread-callback
                                                           :on-complete
                                                           (lambda (repositories)
                                                             (if repositories
                                                                 (progn
                                                                   (%refresh-client-picker conn)
                                                                   (%client-notify conn "fetch complete"))
                                                                 (%client-notify conn
                                                                                 "fetch already in progress")))
                                                           :on-error
                                                           (lambda (repository condition)
                                                             (%client-notify
                                                              conn
                                                              (format nil "fetch failed for ~A: ~A"
                                                                      (nerimux/workspace-model:repository-id
                                                                       repository)
                                                                      condition))))
         (error (condition)
           (%client-notify conn (format nil "fetch failed: ~A" condition)))))))
  nil)

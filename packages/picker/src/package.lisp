(defpackage #:nerimux/picker
            (:use #:cl)
            (:documentation
             "APPLICATION layer: a pure global picker projection over organizations,
    repositories, and worktrees.  It owns filtering and selection only; UI and
    command transports remain outside this package.")
            (:export #:picker-item
                     #:picker-item-p
                     #:make-picker-item
                     #:picker-item-id
                     #:picker-item-kind
                     #:picker-item-label
                     #:picker-item-organization
                     #:picker-item-repository
                     #:picker-item-worktree
                     #:picker-item-pane
                     #:picker-item-data
                     #:picker-item-attention-p
                     #:picker-item-row-text
                     #:build-global-picker-items
                     #:filter-global-picker-items
                     #:select-global-picker-item
                     #:benchmark-global-picker
                     #:+picker-regex-query-length-limit+))

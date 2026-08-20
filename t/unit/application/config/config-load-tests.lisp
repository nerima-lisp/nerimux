(in-package #:nerimux/test)

;;;; config directive tests — load strings, streams, files, and config paths
;;;;
;;;; load-from-string-counts-and-applies, load-realistic-config-applies-all-directives,
;;;; load-from-string-multichar-and-quote-key, and load-config-from-stream-applies
;;;; were removed: all asserted key-table effects (lookup-key-binding /
;;;; key-table-lookup / -command), gone with the key-table config subsystem.

;;; Test isolation helpers

(defun config-path (override xdg home)
  "Namestring of the resolved config path for the given env values + HOME
   (HOME a directory pathname)."
  (namestring (nerimux/config::%config-path-from override xdg home)))

(describe "config-directives-suite"

  ;;; config-file-path precedence (pure: %config-path-from)

  ;; %config-path-from: override wins; XDG used when set; ~/.config fallback; empty = unset.
  (it "config-path-table"
    (dolist (c '(("/custom/my.conf" "/x/cfg"  #p"/home/u/" "/custom/my.conf"                  "explicit override wins")
                 (nil               "/x/cfg"  #p"/home/u/" "/x/cfg/nerimux/nerimux.conf"      "XDG set")
                 (nil               "/x/cfg/" #p"/home/u/" "/x/cfg/nerimux/nerimux.conf"      "XDG trailing slash")
                 (nil               nil       #p"/home/u/" "/home/u/.config/nerimux/nerimux.conf" "no XDG fallback")
                 (""                ""        #p"/home/u/" "/home/u/.config/nerimux/nerimux.conf" "empty env = unset")))
      (destructuring-bind (override xdg home expected desc) c
        (declare (ignore desc))
        (expect (string= expected (config-path override xdg home))))))

  ;;; load-config-file

  ;; load-config-file on a non-existent path returns NIL.
  (it "load-config-file-missing-returns-nil"
    (with-isolated-config
      (expect (null (load-config-file #p"/nonexistent/nerimux-xyz.conf"))))))

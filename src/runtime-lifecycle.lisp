(in-package #:nerimux)

(defparameter +runtime-safe-server-name-punctuation+ '(#\- #\_ #\.)
  "Punctuation preserved when a runtime server name becomes a path component.")

(defun %runtime-safe-server-name (name)
  (let ((text (princ-to-string (or name "default"))))
    (let ((result
            (coerce
             (loop for character across text
                   collect
                   (if (or (alphanumericp character)
                           (find character +runtime-safe-server-name-punctuation+
                                 :test #'char=))
                       character
                       #\_))
             'string)))
      (if (string/= result "") result "default"))))

(defun %runtime-state-home ()
  "The state-home DIRECTORY used by %runtime-log-path: $NERIMUX_RUNTIME_STATE
   when set, else $XDG_STATE_HOME, else ~/.local/state/.

   NERIMUX_RUNTIME_STATE names a directory, not a literal file: the caller
   applies its own nerimux/<name>.log suffix on top of it."
  (let ((override (sb-ext:posix-getenv "NERIMUX_RUNTIME_STATE")))
    (if (and override (string/= override ""))
        override
        (let ((xdg (sb-ext:posix-getenv "XDG_STATE_HOME")))
          (if (and xdg (string/= xdg ""))
              xdg
              (namestring
               (merge-pathnames
                ".local/state/"
                (user-homedir-pathname))))))))

(defun %runtime-log-path (name)
  "Resolve the persistent log file path for the auto-started headless server
   running as NAME, following %runtime-state-home's override/XDG resolution
   shape but keyed off an explicit NAME argument instead of the
   *runtime-server-name* special (which is not guaranteed bound in the
   launching/parent process)."
  (merge-pathnames
   (format nil "nerimux/~A.log"
           (%runtime-safe-server-name name))
   (pathname (format nil "~A/"
                     (string-right-trim "/" (%runtime-state-home))))))

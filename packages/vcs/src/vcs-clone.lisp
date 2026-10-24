(in-package #:nerimux/vcs)

(defstruct (%clone-source (:constructor %make-clone-source))
  host
  owner
  repository
  specification
  operand)

(defstruct (clone-result (:constructor %make-clone-result))
  specification
  local-path)

(define-condition clone-error (error)
  ((reason :initarg :reason :reader clone-error-reason))
  (:report (lambda (condition stream)
             (write-string (clone-error-reason condition) stream))))

(defun %clone-fail (reason)
  (error 'clone-error :reason reason))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defconstant +clone-max-source-length+ 4096)
  (defconstant +clone-max-host-length+ 253)
  (defconstant +clone-max-host-label-length+ 63)
  (defconstant +clone-max-path-segment-length+ 255)
  (defconstant +clone-max-repository-length+ 251)
  (defconstant +clone-max-repository-input-length+
    (+ +clone-max-repository-length+ 4)))

(defun %clone-prefix-p (prefix string)
  (and (stringp string)
       (<= (length prefix) (length string))
       (string-equal prefix string :end2 (length prefix))))

(defun %clone-control-or-whitespace-p (character)
  (or (sb-unicode:whitespace-p character)
      (nerimux/text:control-character-p character)))

(defun %clone-text-valid-p (text)
  (and (stringp text)
       (plusp (length text))
       (<= (length text) +clone-max-source-length+)
       (char/= (char text 0) #\-)
       (not (find-if #'%clone-control-or-whitespace-p text))))

(defun %clone-split-path (path)
  (loop with start = 0
        for end = (position #\/ path :start start)
        collect (subseq path start end)
        while end
        do (setf start (1+ end))))

(defun %clone-ascii-alphanumeric-p (character)
  (or (<= (char-code #\0) (char-code character) (char-code #\9))
      (<= (char-code #\a) (char-code character) (char-code #\z))
      (<= (char-code #\A) (char-code character) (char-code #\Z))))

(defun %clone-host-p (host)
  (and (stringp host)
       (plusp (length host))
       (<= (length host) +clone-max-host-length+)
       (not (char= (char host 0) #\-))
       (not (char= (char host 0) #\.))
       (not (char= (char host (1- (length host))) #\.))
       (loop with start = 0
             for end = (position #\. host :start start)
             for label = (subseq host start end)
             always (and (plusp (length label))
                         (<= (length label) +clone-max-host-label-length+)
                         (%clone-ascii-alphanumeric-p (char label 0))
                         (%clone-ascii-alphanumeric-p
                          (char label (1- (length label))))
                         (every (lambda (character)
                                  (or (%clone-ascii-alphanumeric-p character)
                                      (char= character #\-)))
                                label))
             while end
             do (setf start (1+ end)))))

(defun %clone-path-segment-p (segment
                              &optional
                              (maximum +clone-max-path-segment-length+))
  (and (stringp segment)
       (plusp (length segment))
       (<= (length segment) maximum)
       (not (member segment '("." "..") :test #'string=))
       (char/= (char segment 0) #\-)
       (every (lambda (character)
                (or (%clone-ascii-alphanumeric-p character)
                    (member character '(#\- #\_ #\.) :test #'char=)))
              segment)))

(defun %clone-repository-name (name)
  (unless (and (stringp name)
               (plusp (length name))
               (<= (length name) +clone-max-repository-input-length+))
    (%clone-fail "invalid repository path"))
  (let* ((suffix (and (>= (length name) 4)
                      (string-equal ".git" name :start2 (- (length name) 4))))
         (result (if suffix (subseq name 0 (- (length name) 4)) name)))
    (unless (%clone-path-segment-p result +clone-max-repository-length+)
      (%clone-fail "invalid repository path"))
    result))

(defun %clone-source-from-parts (host owner repository operand)
  (unless (and (%clone-host-p host)
               (%clone-path-segment-p owner))
    (%clone-fail "invalid clone host or owner"))
  (let ((name (%clone-repository-name repository))
        (canonical-host (string-downcase host)))
    (%make-clone-source
     :host canonical-host
     :owner owner
     :repository name
     :specification (format nil "~A/~A/~A" canonical-host owner name)
     :operand operand)))

(defun %clone-url-parts (text scheme)
  (let* ((body (subseq text (length scheme)))
         (slash (position #\/ body)))
    (unless slash
      (%clone-fail "clone URL must include an owner and repository"))
    (let* ((authority (subseq body 0 slash))
           (path (subseq body (1+ slash)))
           (at (position #\@ authority))
           (user-info (and at (subseq authority 0 at)))
           (ssh-user-valid-p
             (or (not (string-equal scheme "ssh://"))
                 (not at)
                 (and (plusp (length user-info))
                      (let ((first (char user-info 0)))
                        (or (%clone-ascii-alphanumeric-p first)
                            (char= first #\_)))
                      (every (lambda (character)
                               (or (%clone-ascii-alphanumeric-p character)
                                   (member character '(#\_ #\- #\.) :test #'char=)))
                             user-info)))))
      (when (and (string-equal scheme "https://") at)
        (%clone-fail
         "HTTPS clone URLs must not include credentials; use a credential helper"))
      (when (or (zerop (length authority))
                (find-if (lambda (character)
                           (member character '(#\? #\#) :test #'char=))
                         authority)
                (and at (or (zerop at)
                            (position #\@ authority :start (1+ at))))
                (not ssh-user-valid-p))
        (%clone-fail "invalid clone URL authority"))
      (let* ((host (if at (subseq authority (1+ at)) authority))
             (parts (%clone-split-path path)))
        (unless (and (= (length parts) 2)
                     (every #'%clone-path-segment-p parts))
          (%clone-fail "clone URL must use host/owner/repository"))
        (values host (first parts) (second parts))))))

(defun %parse-clone-source (text)
  (unless (%clone-text-valid-p text)
    (%clone-fail "clone source is empty, option-shaped, or contains whitespace"))
  (cond
    ((%clone-prefix-p "https://" text)
     (multiple-value-bind (host owner repository)
         (%clone-url-parts text "https://")
       (%clone-source-from-parts host owner repository text)))
    ((%clone-prefix-p "ssh://" text)
     (multiple-value-bind (host owner repository)
         (%clone-url-parts text "ssh://")
       (%clone-source-from-parts host owner repository text)))
    ((%clone-prefix-p "git@" text)
     (let* ((colon (position #\: text :start 4))
            (host (and colon (subseq text 4 colon)))
            (parts (and colon (%clone-split-path (subseq text (1+ colon)))))
            (at (position #\@ text :start 4)))
       (unless (and colon
                    (null at)
                    (= (length parts) 2)
                    (every #'%clone-path-segment-p parts))
         (%clone-fail "invalid SSH clone source"))
       (%clone-source-from-parts host (first parts) (second parts) text)))
    (t
     (let ((parts (%clone-split-path text)))
       (unless (and (member (length parts) '(2 3))
                    (every #'%clone-path-segment-p parts))
         (%clone-fail "unsupported clone source format"))
       (if (= (length parts) 2)
           (%clone-source-from-parts "github.com"
                                     (first parts)
                                     (second parts)
                                     (format nil "github.com/~A/~A"
                                             (first parts)
                                             (second parts)))
           (%clone-source-from-parts (first parts)
                                     (second parts)
                                     (third parts)
                                     text))))))


(defun %redact-clone-credentials (text)
  (with-output-to-string (output)
    (loop with cursor = 0
          for scheme = (search "://" text :start2 cursor)
          while scheme
          for authority-start = (+ scheme 3)
          for at = (position #\@ text :start authority-start)
          do (write-string text output :start cursor :end authority-start)
             (if at
                 (progn
                   (write-string "[redacted]@" output)
                   (setf cursor (1+ at)))
                 (progn
                   (write-string text output :start authority-start)
                   (setf cursor (length text))))
          finally (write-string text output :start cursor))))

(defun %clean-clone-error-text (text)
  (let ((clean (with-output-to-string (output)
                 (loop with space-p = nil
                       for character across (%redact-clone-credentials text)
                       do (cond
                            ((sb-unicode:whitespace-p character)
                             (unless space-p (write-char #\Space output))
                             (setf space-p t))
                            ((nerimux/text:control-character-p character)
                             (setf space-p t))
                            (t
                             (write-char character output)
                             (setf space-p nil)))))))
    (let ((trimmed (string-trim (list #\Space) clean)))
      (if (> (length trimmed) 180)
          (subseq trimmed 0 180)
          trimmed))))

(defun %clone-error-reason (stdout stderr status)
  (or (let ((text (%clean-clone-error-text
                   (or (and (stringp stderr) (plusp (length stderr)) stderr)
                       (and (stringp stdout) (plusp (length stdout)) stdout)
                       ""))))
        (and (plusp (length text)) text))
      (format nil "ghq exited with status ~A" status)))

(defun %clone-process-environment (&optional (environment (sb-ext:posix-environ)))
  (let ((updates (list
                  (cons "GIT_ALLOW_PROTOCOL" "https:ssh")
                  (cons "GIT_PROTOCOL_FROM_USER" "0")
                  (cons "GIT_TERMINAL_PROMPT" "0")
                  (cons "GIT_ASKPASS" "true")
                  (cons "SSH_ASKPASS" "true")
                  (cons "GIT_SSH_COMMAND" "ssh -oBatchMode=yes")
                  (cons "GIT_TRACE" "0")
                  (cons "GIT_TRACE_FSMONITOR" "0")
                  (cons "GIT_TRACE_PACK_ACCESS" "0")
                  (cons "GIT_TRACE_PACKFILE" "0")
                  (cons "GIT_TRACE_PACKET" "0")
                  (cons "GIT_TRACE_PERFORMANCE" "0")
                  (cons "GIT_TRACE_REFS" "0")
                  (cons "GIT_TRACE_SETUP" "0")
                  (cons "GIT_TRACE_SHALLOW" "0")
                  (cons "GIT_TRACE_CURL" "0")
                  (cons "GIT_TRACE_CURL_NO_DATA" "0")
                  (cons "GIT_TRACE2" "0")
                  (cons "GIT_TRACE2_EVENT" "0")
                  (cons "GIT_TRACE2_PERF" "0")
                  (cons "GIT_TRACE_REDACT" "1")
                  (cons "GIT_CURL_VERBOSE" "0"))))
    (setf environment
          (remove-if (lambda (entry)
                       (or (%clone-prefix-p "GIT_TRACE" entry)
                           (%clone-prefix-p "GIT_CURL_VERBOSE=" entry)))
                     environment))
    (dolist (update updates environment)
      (let ((prefix (concatenate 'string (car update) "=")))
        (setf environment
              (remove-if (lambda (entry)
                           (%clone-prefix-p prefix entry))
                         environment))
        (push (concatenate 'string prefix (cdr update)) environment)))))

(defun %run-ghq-get (arguments environment)
  (uiop:run-program arguments
                    :environment environment
                    :output :string
                    :error-output :string
                    :ignore-error-status t))

(defun %clone-local-path (root source)
  (concatenate 'string
               (namestring (uiop:ensure-directory-pathname root))
               (%clone-source-host source) "/"
               (%clone-source-owner source) "/"
               (%clone-source-repository source) ".git"))

(defun %clone-target-is-bare-p (path)
  (and (uiop:directory-exists-p path)
       (string= "true"
                (vcs-kit:git-rev-parse-value
                 (vcs-kit:make-repository path)
                 "--is-bare-repository"))))

(defun clone-bare-repository (text)
  (let* ((source (%parse-clone-source text))
         (root (ghq-root-directory)))
    (unless (and (stringp root) (plusp (length root)))
      (%clone-fail "ghq root is unavailable"))
    (let* ((path (%clone-local-path root source))
           (resolved-root (resolve-path-prefix root))
           (resolved-path (resolve-path-prefix path))
           (arguments (list "ghq" "get" "--bare" "--"
                            (%clone-source-operand source))))
      (unless (and resolved-root
                   resolved-path
                   (path-under-directory-p resolved-path resolved-root))
        (%clone-fail "clone destination escapes ghq root"))
      (when (probe-file path)
        (%clone-fail "repository already exists"))
      (handler-case
          (multiple-value-bind (stdout stderr status)
              (%run-ghq-get arguments (%clone-process-environment))
            (unless (eql status 0)
              (%clone-fail (%clone-error-reason stdout stderr status)))
            (unless (%clone-target-is-bare-p path)
              (%clone-fail "ghq did not create a bare repository at the expected path"))
            (%make-clone-result :specification (%clone-source-specification source)
                                :local-path path))
        (clone-error (condition)
          (error condition))
        (error (condition)
          (%clone-fail (%clean-clone-error-text (princ-to-string condition))))))))

(defun clone-bare-repository-async (text &key on-start on-complete on-error
                                              callback-dispatch)
  (cl-concurrent-kit:make-thread
   (lambda ()
     (handler-case
         (let ((source (%parse-clone-source text)))
           (%dispatch-callback callback-dispatch
                               on-start
                               (%clone-source-specification source))
           (%dispatch-callback callback-dispatch
                               on-complete
                               (clone-bare-repository text)))
       (clone-error (condition)
         (%dispatch-callback callback-dispatch on-error condition))
       (error (condition)
         (%dispatch-callback callback-dispatch
                             on-error
                             (make-condition 'clone-error
                                             :reason (%clean-clone-error-text
                                                      (princ-to-string condition)))))))
   :name "nerimux-vcs-clone"))

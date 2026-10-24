(in-package #:nerimux/test/vcs)

(defvar *clone-fixture-counter* 0)

(defun %clone-source-rejected-p (text)
  (handler-case
      (progn
        (nerimux/vcs::%parse-clone-source text)
        nil)
    (nerimux/vcs:clone-error () t)))

(defun %clone-test-environment (name value
                                     &optional
                                     (environment (sb-ext:posix-environ)))
  (let ((prefix (concatenate 'string name "=")))
    (cons (concatenate 'string prefix value)
          (remove-if (lambda (entry)
                       (and (>= (length entry) (length prefix))
                            (string= prefix entry :end2 (length prefix))))
                     environment))))

(defun %clone-test-environment-with-updates (environment updates)
  (reduce (lambda (current update)
            (%clone-test-environment (car update) (cdr update) current))
          updates
          :initial-value environment))

(defun %call-with-clone-test-environment (root environment function)
  (let ((original-environment-function
         (symbol-function 'nerimux/vcs::%clone-process-environment)))
    (with-stubbed-fdefinition
     ((nerimux/vcs:ghq-root-directory
       (lambda () root))
      (nerimux/vcs::%clone-process-environment
       (lambda (&optional (base-environment environment))
         (funcall original-environment-function base-environment))))
     (funcall function))))

(defun %clone-attempt (source root environment)
  (%call-with-clone-test-environment
   root
   environment
   (lambda ()
     (handler-case
         (values (nerimux/vcs:clone-bare-repository source) nil)
       (nerimux/vcs:clone-error (condition)
         (values nil condition))))))

(defun %fresh-clone-fixture-directory ()
  (merge-pathnames
   (format nil
           "nerimux-clone-test-~D-~D-~D/"
           (get-universal-time)
           (sb-posix:getpid)
           (incf *clone-fixture-counter*))
   (host-kit:temporary-directory)))

(defun %call-with-local-bare-clone-source (function)
  (let* ((base (%fresh-clone-fixture-directory))
         (checkout (merge-pathnames "checkout/" base))
         (source (merge-pathnames "source.git/" base)))
    (unwind-protect
         (progn
           (ensure-directories-exist checkout)
           (uiop:run-program
            (list "git" "init" "--initial-branch=main" (namestring checkout))
            :output :string
            :error-output :string)
           (uiop:run-program
            (list "git" "-C" (namestring checkout)
                  "-c" "user.name=Test"
                  "-c" "user.email=test@example.invalid"
                  "-c" "commit.gpgsign=false"
                  "-c" "core.hooksPath=/dev/null"
                  "commit" "--allow-empty" "-m" "fixture")
            :output :string
            :error-output :string)
           (uiop:run-program
            (list "git" "clone" "--bare" (namestring checkout) (namestring source))
            :output :string
            :error-output :string)
           (funcall function base source))
      (when (probe-file base)
        (uiop:delete-directory-tree base :validate t)))))

(describe "vcs clone source validation"
  (it "returns the normalized host, owner, repository, and operand for supported forms"
    (dolist (case '(("https://GitHub.com/owner/repository" "github.com" "owner" "repository" "https://GitHub.com/owner/repository")
                    ("git@github.com:owner/repository.git" "github.com" "owner" "repository" "git@github.com:owner/repository.git")
                    ("ssh://git@github.com/owner/repository" "github.com" "owner" "repository" "ssh://git@github.com/owner/repository")
                    ("owner/repository" "github.com" "owner" "repository" "github.com/owner/repository")
                    ("gitlab.example.com/owner/repository.git" "gitlab.example.com" "owner" "repository" "gitlab.example.com/owner/repository.git")))
      (destructuring-bind (text host owner repository operand) case
        (let ((source (nerimux/vcs::%parse-clone-source text)))
          (expect (string= host (nerimux/vcs::%clone-source-host source)))
          (expect (string= owner (nerimux/vcs::%clone-source-owner source)))
          (expect (string= repository (nerimux/vcs::%clone-source-repository source)))
          (expect (string= operand (nerimux/vcs::%clone-source-operand source))))))

  (it "rejects HTTPS credentials with credential-helper guidance"
    (dolist (text '("https://user:password@github.com/owner/repository" "https://token@github.com/owner/repository"))
      (let ((reason (handler-case
                        (progn (nerimux/vcs::%parse-clone-source text) nil)
                      (nerimux/vcs:clone-error (condition)
                        (nerimux/vcs:clone-error-reason condition)))))
        (expect (and reason (search "credential helper" reason)))
        (expect (not (search "password" (or reason ""))))
        (expect (not (search "token" (or reason "")))))))

  (it "rejects local filesystem paths"
    (dolist (path '("/tmp/source.git" "../source.git" "./source.git" "file:///tmp/source.git"))
      (expect (%clone-source-rejected-p path))))

  (it "rejects option-shaped inputs, unsupported transports, and invalid paths"
    (dolist (source '("-u" "--upload-pack" "ext::sh -c command" "fd::/tmp/source.git"
                      "git://github.com/owner/repository" "ftp://github.com/owner/repository"
                      "-host/owner/repository" "host/-owner/repository" "host/-repository"
                      "host/../repository" "host/owner/.." "host/owner/%2e%2e"
                      "host/ownér/repository" "git@host:-x" "https://-host/owner/repository"
                      "git@-host:owner/repository" "https://host/owner/repository with-space"
                      "https://alice?token=marker@example.invalid/owner/repository"
                      "https://alice#token=marker@example.invalid/owner/repository"
                      "ssh://-oProxyCommand=sh$IFS-c$IFSid;@github.com/owner/repository"))
      (expect (%clone-source-rejected-p source)))
    (expect (%clone-source-rejected-p
             (concatenate 'string "https://host/owner/repository" (string #\Tab) "name")))
    (expect (%clone-source-rejected-p
             (concatenate 'string "https://host/owner/repository" (string (code-char 27)) "[31m"))))

  (it "caps URL, host, owner, and repository lengths before accepting them"
    (let* ((label-63 (make-string 63 :initial-element #\a))
           (label-62 (make-string 62 :initial-element #\b))
           (host-over-maximum (format nil "~A.~A.~A.~A" label-63 label-63 label-63 label-62))
           (label-over-maximum (make-string 64 :initial-element #\a)))
      (expect (%clone-source-rejected-p
               (concatenate 'string "https://github.com/owner/"
                            (make-string 4100 :initial-element #\a))))
      (expect (%clone-source-rejected-p (format nil "~A/owner/repository" host-over-maximum)))
      (expect (%clone-source-rejected-p
               (format nil "~A.example/owner/repository" label-over-maximum)))
      (expect (%clone-source-rejected-p
               (format nil "github.com/~A/repository" (make-string 256 :initial-element #\o))))
      (expect (%clone-source-rejected-p
               (format nil "github.com/owner/~A" (make-string 252 :initial-element #\r))))
      (expect (%clone-source-rejected-p
               (format nil "github.com/owner/~A" (make-string 256 :initial-element #\r))))))))

(describe "vcs clone command construction"
  (it "keeps the source after an option boundary and restricts Git transports"
    (let ((arguments nil)
          (environment nil))
      (with-stubbed-fdefinition
          ((nerimux/vcs:ghq-root-directory
             (lambda () "/tmp/nerimux-clone-command-test/"))
           (nerimux/vcs::%clone-target-is-bare-p
             (lambda (path)
               (declare (ignore path))
               t))
           (nerimux/vcs::%run-ghq-get
             (lambda (argv env)
               (setf arguments argv
                     environment env)
               (values "" "" 0))))
        (nerimux/vcs:clone-bare-repository "https://github.com/owner/repository")
        (expect (equal arguments
                       '("ghq" "get" "--bare" "--"
                         "https://github.com/owner/repository")))
        (expect (member "GIT_ALLOW_PROTOCOL=https:ssh" environment :test #'string=))
        (expect (member "GIT_PROTOCOL_FROM_USER=0" environment :test #'string=))
        (expect (member "GIT_TERMINAL_PROMPT=0" environment :test #'string=)))))

  (it "rejects HTTPS credentials before starting ghq"
    (let ((ghq-started nil)
          (reason nil))
      (with-stubbed-fdefinition
          ((nerimux/vcs::%run-ghq-get
             (lambda (arguments environment)
               (declare (ignore arguments environment))
               (setf ghq-started t)
               (values "" "" 0))))
        (dolist (text '("https://user:password@github.com/owner/repository"
                        "https://token@github.com/owner/repository"))
          (setf reason
                (handler-case
                    (progn
                      (nerimux/vcs:clone-bare-repository text)
                      nil)
                  (nerimux/vcs:clone-error (condition)
                    (nerimux/vcs:clone-error-reason condition))))))
      (expect (not ghq-started))
      (expect (and reason (search "credential helper" reason)))
      (expect (not (search "password" (or reason ""))))
      (expect (not (search "token" (or reason ""))))))

  (it "replaces inherited transport and trace settings with safe values"
    (let* ((inherited (list
                       "GIT_ALLOW_PROTOCOL=ext:file"
                       "GIT_PROTOCOL_FROM_USER=1"
                       "GIT_TRACE=/tmp/nerimux-trace-test.log"
                       "GIT_TRACE_CURL=/tmp/nerimux-trace-curl.log"
                       "GIT_TRACE_REDACT=false"
                       "GIT_CURL_VERBOSE=1"))
           (environment (nerimux/vcs::%clone-process-environment inherited)))
      (dolist (entry inherited)
        (expect (not (member entry environment :test #'string=))))
      (dolist (entry '("GIT_ALLOW_PROTOCOL=https:ssh"
                       "GIT_PROTOCOL_FROM_USER=0"
                       "GIT_TERMINAL_PROMPT=0"
                       "GIT_TRACE=0"
                       "GIT_TRACE_CURL=0"
                       "GIT_TRACE_REDACT=1"
                       "GIT_CURL_VERBOSE=0"))
        (expect (member entry environment :test #'string=)))))

  (it "redacts URL credentials in error text"
    (let ((reason
            (nerimux/vcs::%clone-error-reason
             ""
             "fatal: https://alice:very-secret@example.invalid/owner/repo"
             128)))
      (expect (search "[redacted]@example.invalid/owner/repo" reason))
      (expect (not (search "alice" reason)))
      (expect (not (search "very-secret" reason))))))
(describe "vcs clone transport policy"
  (it "blocks inherited URL rewrites to file and ext despite protocol allow settings"
    (%call-with-local-bare-clone-source
     (lambda (base source)
       (let* ((source-url "https://example.invalid/owner/repository")
              (file-root (merge-pathnames "ghq-file-blocked/" base))
              (control-root (merge-pathnames "ghq-file-control/" base))
              (ext-root (merge-pathnames "ghq-ext-blocked/" base))
              (file-config (merge-pathnames "rewrite-file.config" base))
              (ext-config (merge-pathnames "rewrite-ext.config" base))
              (file-target
                (string-right-trim "/"
                                   (concatenate 'string "file://" (namestring source))))
              (ext-helper (merge-pathnames "ext-helper" base))
              (ext-marker (merge-pathnames "ext-helper-ran" base)))
         (ensure-directories-exist file-root)
         (ensure-directories-exist control-root)
         (ensure-directories-exist ext-root)
         (flet ((write-rule (path protocol target)
                  (with-open-file (stream path :direction :output
                                          :if-exists :supersede
                                          :if-does-not-exist :create)
                    (format stream
                            "[protocol ~S]~%    allow = always~%[url ~S]~%    insteadOf = ~S~%"
                            protocol target source-url)))
                (environment-for (root config &optional updates)
                  (%clone-test-environment-with-updates
                   (%clone-test-environment-with-updates
                    (sb-ext:posix-environ)
                    (list (cons "GIT_CONFIG_NOSYSTEM" "1")
                          (cons "GIT_CONFIG_GLOBAL" (namestring config))
                          (cons "GIT_CONFIG_COUNT" "0")
                          (cons "GHQ_ROOT" (namestring root))))
                   updates)))
           (write-rule file-config "file" file-target)
           (with-open-file (stream ext-helper :direction :output
                                   :if-exists :supersede
                                   :if-does-not-exist :create)
             (format stream "#!/bin/sh~%: > \"$NMX_TEST_EXT_MARKER\"~%exit 1~%"))
           (uiop:run-program (list "chmod" "+x" (namestring ext-helper)))
           (write-rule ext-config "ext" (format nil "ext::~A" (namestring ext-helper)))
           (multiple-value-bind (result condition)
               (%clone-attempt source-url (namestring file-root)
                               (environment-for file-root file-config))
             (let ((reason (and condition
                                (nerimux/vcs:clone-error-reason condition))))
               (expect (null result))
               (expect (and (typep condition 'nerimux/vcs:clone-error)
                            (stringp reason)
                            (plusp (length reason))))))
           (let* ((control-environment
                    (nerimux/vcs::%clone-process-environment
                     (environment-for control-root file-config)))
                  (control-environment
                    (%clone-test-environment-with-updates
                     control-environment
                     (list (cons "GIT_ALLOW_PROTOCOL" "https:ssh:file")
                           (cons "GIT_PROTOCOL_FROM_USER" "1")))))
             (multiple-value-bind (stdout stderr status)
                 (nerimux/vcs::%run-ghq-get
                  (list "ghq" "get" "--bare" "--" source-url)
                  control-environment)
               (declare (ignore stdout stderr))
               (expect (= status 0))))
           (multiple-value-bind (result condition)
               (%clone-attempt
                source-url
                (namestring ext-root)
                (%clone-test-environment
                 "NMX_TEST_EXT_MARKER"
                 (namestring ext-marker)
                 (environment-for ext-root ext-config)))
             (let ((reason (and condition
                                (nerimux/vcs:clone-error-reason condition))))
               (expect (null result))
               (expect (and (typep condition 'nerimux/vcs:clone-error)
                            (stringp reason)
                            (plusp (length reason))))
               (expect (not (probe-file ext-marker))))
             (let ((control-root (merge-pathnames "ghq-ext-control/" base)))
               (ensure-directories-exist control-root)
               (let* ((control-environment
                        (nerimux/vcs::%clone-process-environment
                         (%clone-test-environment
                          "NMX_TEST_EXT_MARKER"
                          (namestring ext-marker)
                          (environment-for control-root ext-config))))
                      (control-environment
                        (%clone-test-environment-with-updates
                         control-environment
                         (list (cons "GIT_ALLOW_PROTOCOL" "https:ssh:ext")
                               (cons "GIT_PROTOCOL_FROM_USER" "1")))))
                 (multiple-value-bind (stdout stderr status)
                     (nerimux/vcs::%run-ghq-get
                      (list "ghq" "get" "--bare" "--" source-url)
                      control-environment)
                   (declare (ignore stdout stderr status))
                   (expect (probe-file ext-marker))))))))))))

(describe "vcs clone asynchronous callbacks"
  (it "emits a canonical repository specification before successful completion"
    (let ((events nil))
      (with-stubbed-fdefinition
          ((nerimux/vcs:clone-bare-repository
             (lambda (text)
               (declare (ignore text))
               (nerimux/vcs::%make-clone-result
                :specification "example.invalid/owner/repository"
                :local-path "/tmp/repository.git"))))
        (sb-thread:join-thread
         (nerimux/vcs:clone-bare-repository-async
          "https://example.invalid/owner/repository"
          :on-start (lambda (specification)
                      (push (list :start specification) events))
          :on-complete (lambda (result)
                         (push (list :complete result) events))))
        (setf events (nreverse events))
        (expect (eq :start (first (first events))))
        (expect (string= "example.invalid/owner/repository"
                         (second (first events))))
        (expect (eq :complete (first (second events)))))))

  (it "passes a failure condition to the error callback"
    (let ((error-condition nil))
      (with-stubbed-fdefinition
          ((nerimux/vcs:clone-bare-repository
             (lambda (text)
               (declare (ignore text))
               (error 'nerimux/vcs:clone-error :reason "remote rejected clone"))))
        (sb-thread:join-thread
         (nerimux/vcs:clone-bare-repository-async
          "owner/repository"
          :on-error (lambda (condition)
                      (setf error-condition condition))))
        (expect (typep error-condition 'nerimux/vcs:clone-error))
        (expect (string= "remote rejected clone"
                         (nerimux/vcs:clone-error-reason error-condition)))))))

(describe "vcs test-only local clone source"
  (it "uses a test-side parser replacement to exercise a local bare clone"
    (%call-with-local-bare-clone-source
     (lambda (base source)
       (let* ((root (merge-pathnames "ghq-root/" base))
              (root-string (namestring root))
              (expected-path
                (concatenate 'string root-string
                             "github.com/owner/repository.git"))
              (environment
                (%clone-test-environment-with-updates
                 (sb-ext:posix-environ)
                 (list (cons "GHQ_ROOT" root-string)
                       (cons "GIT_CONFIG_NOSYSTEM" "1")
                       (cons "GIT_CONFIG_GLOBAL" "/dev/null")
                       (cons "GIT_CONFIG_COUNT" "0"))))
              (original-environment-function
                (symbol-function 'nerimux/vcs::%clone-process-environment)))
         (ensure-directories-exist root)
         (with-stubbed-fdefinition
             ((nerimux/vcs:ghq-root-directory
                (lambda () root-string))
              (nerimux/vcs::%parse-clone-source
                (lambda (text)
                  (declare (ignore text))
                  (nerimux/vcs::%make-clone-source
                   :host "github.com"
                   :owner "owner"
                   :repository "repository"
                   :specification "github.com/owner/repository"
                   :operand (concatenate 'string "file://" (namestring source)))))
              (nerimux/vcs::%clone-process-environment
                (lambda (&optional (base-environment environment))
                  (%clone-test-environment-with-updates
                   (funcall original-environment-function base-environment)
                   (list (cons "GIT_ALLOW_PROTOCOL" "https:ssh:file")
                         (cons "GIT_PROTOCOL_FROM_USER" "1")))))
              (nerimux/vcs::%run-ghq-get
                (lambda (arguments child-environment)
                  (expect
                   (equal arguments
                          (list "ghq" "get" "--bare" "--"
                                (concatenate 'string "file://" (namestring source)))))
                  (ensure-directories-exist (pathname expected-path))
                  (uiop:run-program
                   (list "git" "clone" "--bare" (namestring source) expected-path)
                   :environment child-environment
                   :output :string
                   :error-output :string
                   :ignore-error-status t))))
           (let* ((result (nerimux/vcs:clone-bare-repository "fixture/local-repository"))
                  (path (nerimux/vcs:clone-result-local-path result)))
             (expect (string= expected-path path))
             (expect (nerimux/vcs::%clone-target-is-bare-p path)))))))))

(describe "clone control validation"
  (it "rejects bidi controls in clone input"
    (dolist (code
             (append
              (list #x061c #x200e #x200f)
              (loop for code from #x202a to #x202e collect code)
              (loop for code from #x2066 to #x2069 collect code)))
      (expect (nerimux/vcs::%clone-control-or-whitespace-p
               (code-char code))))))

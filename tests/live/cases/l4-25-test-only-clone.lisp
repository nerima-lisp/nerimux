(in-package #:nerimux/vcs)

(progn
  (defun %l4-25-source-path ()
    (let* ((root (sb-ext:posix-getenv "GHQ_ROOT"))
           (root-path (and root (pathname root))))
      (unless
          (and root-path
               (uiop:absolute-pathname-p root-path)
               (uiop:directory-exists-p root-path))
        (%clone-fail "test-only clone binary requires an absolute GHQ_ROOT"))
      (let* ((root-directory
              (uiop:ensure-directory-pathname (truename root-path)))
             (fixture-directory
              (uiop:pathname-parent-directory-pathname root-directory))
             (source-path (merge-pathnames "source.git" fixture-directory)))
        (unless
            (string= "F-clone-src"
                     (car (last (pathname-directory fixture-directory))))
          (%clone-fail
           "test-only clone binary requires the F-clone-src fixture"))
        (unless (uiop:directory-exists-p source-path)
          (%clone-fail "F-clone-src/source.git is unavailable"))
        (multiple-value-bind (stdout stderr status)
            (uiop:run-program
             (list "git"
                   "-C"
                   (namestring source-path)
                   "rev-parse"
                   "--is-bare-repository")
             :environment
             (%clone-process-environment)
             :output
             :string
             :error-output
             nil
             :ignore-error-status
             t)
          (declare (ignore stderr))
          (unless
              (and (eql status 0)
                   (= (length stdout) 5)
                   (string= "true" (subseq stdout 0 4)))
            (%clone-fail
             "F-clone-src/source.git must be a local bare repository")))
        (string-right-trim "/" (namestring (truename source-path))))))
  (defun %parse-clone-source (text)
    (unless (and (stringp text) (string= text (%l4-25-source-path)))
      (%clone-fail
       "test-only clone binary accepts only the absolute F-clone-src/source.git path"))
    (%make-clone-source :host
                        "github.com"
                        :owner
                        "fixture"
                        :repository
                        "clone-source"
                        :specification
                        "github.com/fixture/clone-source"
                        :operand
                        text))
  (defun %clone-process-environment (&optional
                                     (environment (sb-ext:posix-environ)))
    (append
     (remove-if
      (lambda (entry)
        (or (%clone-prefix-p "GIT_" entry)
            (%clone-prefix-p "SSH_ASKPASS=" entry)))
      environment)
     (list "GIT_ALLOW_PROTOCOL=file"
           "GIT_PROTOCOL_FROM_USER=1"
           "GIT_CONFIG_NOSYSTEM=1"
           "GIT_CONFIG_GLOBAL=/dev/null"
           "GIT_CONFIG_COUNT=0"
           "GIT_TERMINAL_PROMPT=0"
           "GIT_ASKPASS=true"
           "SSH_ASKPASS=true")))
  (defun %run-ghq-get (arguments environment)
    (unless
        (and (listp arguments)
             (equal arguments
                    (list "ghq" "get" "--bare" "--" (%l4-25-source-path))))
      (%clone-fail
       "test-only clone binary rejected a non-fixture clone command"))
    (let* ((source (%parse-clone-source (fifth arguments)))
           (destination (%clone-local-path (ghq-root-directory) source)))
      (uiop:run-program
       (list "git"
             "clone"
             "--bare"
             "--local"
             (%clone-source-operand source)
             destination)
       :environment
       (%clone-process-environment environment)
       :output
       nil
       :error-output
       nil
       :ignore-error-status
       t))))

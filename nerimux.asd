;;; This form comes FIRST, before any other form. ASDF binds *package* to
;;; ASDF-USER only for a file it loads itself; read any other way — a REPL
;;; `load`, an editor evaluating the buffer, flake.nix parsing :version — the
;;; file is read in whatever package happens to be current, and an unqualified
;;; `defsystem` then fails to read at all. Saying it makes the file
;;; self-contained. See PACKAGE_STANDARD.md "asd の書き方".
(in-package #:asdf-user)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (load (merge-pathnames
         "system/asdf-test-components.lisp"
         (uiop:pathname-directory-pathname
          (or *load-truename*
              *load-pathname*
              (error "Cannot locate nerimux.asd while loading test components."))))))

;;; Register every packages/<name>/nerimux-<name>.asd before the systems below
;;; name them in :depends-on.
;;;
;;; ASDF's :central-registry finds a .asd only in a directory registered
;;; directly; it does not recurse, and run-tests.lisp deliberately empties the
;;; source registry so no machine-global tree is scanned. Without this, every
;;; unit below resolves to "system not found".
;;;
;;; This covers the `nerimux' entry point only. Loading a unit directly --
;;; (asdf:load-system "nerimux-terminal") -- never reads this file, because ASDF
;;; resolves a primary system from the .asd named after it. That path is served
;;; by pushing each packages/<name>/ onto the central registry, which
;;; run-tests.lisp and flake.nix do. The two are different entry points, not two
;;; spellings of one.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((here (uiop:pathname-directory-pathname
               (or *load-truename*
                   *load-pathname*
                   (error "Cannot locate nerimux.asd while registering packages/.")))))
    (dolist (asd (directory (merge-pathnames "packages/*/nerimux-*.asd" here)))
      (let ((name (pathname-name asd)))
        (unless (asdf:find-system name nil)
          (load asd))))))

(defsystem "nerimux"
  :description "A git-worktree workspace multiplexer in Common Lisp"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  ;; Single source of truth for the version: flake.nix reads this form and
  ;; release.yml refuses to publish a tag that disagrees with it.
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  ;; NO EXTERNAL (non-org) DEPENDENCIES. Every name below is a nerima-lisp
  ;; sibling, so this system now satisfies DEPENDENCY_POLICY.md's default rule
  ;; outright rather than through the grandfather clause it used to rely on, and
  ;; CODING_STANDARD.md's "外部依存を持つのは nerimux の1リポジトリだけです" no
  ;; longer describes any repository in the org.
  ;;
  ;; Four external dependencies were removed across the 2026-08-01/02 sweep, each
  ;; replaced by an org sibling rather than by hand-written code:
  ;;   * cffi              -> cl-process-kit (select(2)), cl-tty-kit (ioctl
  ;;                          TIOCSWINSZ, read(2)) and sb-posix (kill(2)). This
  ;;                          also FIXED a live bug: the old ioctl went through a
  ;;                          fixed cffi prototype, which misfires on the arm64
  ;;                          variadic ABI, so pane resize was a silent no-op on
  ;;                          Apple Silicon.
  ;;   * babel             -> cl-codec-kit, a from-scratch, babel-API-compatible
  ;;                          codec with no dependencies of its own, which
  ;;                          cl-tty-kit and cl-process-kit already use. Call
  ;;                          sites went through cl-host-kit for one day before
  ;;                          being re-pointed here; cl-host-kit remains a
  ;;                          dependency, but for pathname/string ops only.
  ;;   * bordeaux-threads  -> cl-concurrent-kit. Portability was the whole point
  ;;                          of bordeaux-threads and ADR-0048 makes the org
  ;;                          SBCL-only, so it was buying nothing. Note
  ;;                          WITH-TIMEOUT's shape differs (see below).
  ;;   * cl-ppcre          -> cl-regex-kit. This one is NOT behaviour-preserving:
  ;;                          cl-regex-kit is RE2/Rust-style with no
  ;;                          backreferences and no lookaround. That is a
  ;;                          deliberate trade, and it moves nerimux CLOSER to
  ;;                          upstream tmux, which compiles #{m/r:} and #{s///}
  ;;                          patterns with regcomp()+REG_EXTENDED — POSIX ERE,
  ;;                          which has neither construct either.
  :depends-on (:cl-date-kit      ; exact elapsed-time values for deadline APIs
               :cl-concurrent-kit ; threads, locks, condvars and preemptive deadlines
               :cl-regex-kit     ; regex engine behind copy-mode search/highlight and picker query matching
               :cl-cli           ; startup argv/flag parsing (main-startup-flags)
               :cl-parser-kit    ; commands-tokenizer combinator rewrite
               :cl-tty-kit       ; PTY spawn/raw-mode/fd-io, ioctl window size, colour downsampling
               :cl-process-kit   ; select(2)/wait-for-input over raw fds (PTY readiness poll)
               :cl-codec-kit     ; string<->octet UTF-8 codec (protocol, PTY, OSC payloads)
               :cl-host-kit      ; split-string, used by the OSC rgb: colour parser
               :cl-tui-kit/ansi  ; headless surface/backend rendering for per-client frames
               :cl-tui-kit/layout ; geometry and viewport layout for client frames
               :cl-tui-kit/widgets ; widget rendering for client frames
               :cl-vcs-kit       ; ghq/repository/worktree discovery
               ;; In-repo units, one ASDF system per packages/<name>/. Each
               ;; declares its own dependencies, so a reference that crosses a
               ;; unit boundary without an edge here fails to load rather than
               ;; failing a test.
               "nerimux-text"
               "nerimux-version"
               "nerimux-ports"
               "nerimux-pty"
               "nerimux-net"
               "nerimux-input"
               "nerimux-terminal"
               "nerimux-model"
               "nerimux-picker"
               "nerimux-vcs")
  :components
  ((:module "src"
    :serial t
     :components
     ;; commands context: what is left of the pane/window operations, plus the
     ;; copy-mode cluster.  commands-core loads first, then copy-mode, then the
     ;; two survivors split back to root via :pathname.  The tmux command
     ;; implementations this directory was built for (commands.lisp,
     ;; commands-shell, commands-keys, commands-keys-data, commands-capture-pane)
     ;; went with the command table that called them.
     ((:module "application/commands"
      :serial t
      :components
      ((:file "package")
       (:file "commands-core")))
     (:module "application/commands/copy-mode"
      :serial t
      :components
      ((:file "commands-copy-mode")      ; copy-mode core: enter/exit, scroll, prompts, selection state
       (:file "commands-copy-mode-cursor") ; cursor movement and viewport edge scrolling
       (:file "commands-copy-mode-selection") ; selection bounds and text extraction helpers
       (:file "commands-copy-mode-clip") ; rectangle selection text, yank, copy-pipe, append-selection
       (:file "commands-copy-mode-virtual") ; virtual-row helpers shared by search and selection
       (:file "commands-copy-mode-search"))) ; search-forward/backward, search-next/prev
     (:module "application-commands-2"
      :pathname "application/commands"
      :serial t
      :components
       ((:file "commands-tokenizer")))   ; shell-style command-string tokeniser
     (:module "presentation/renderer"
      :serial t
      :components
      ((:file "package")
       (:file "renderer-format-definitions") ; compile-time ANSI fact-table constructors
       (:file "renderer-format")     ; ANSI primitives (shared by both paths below)
       ;; The theme palette loads right after the ANSI primitives so both the
       ;; workspace frame and the pane compositor can reference its constants.
       (:file "renderer-style-data") ; declarative style/SGR/border-charset dispatch tables
       (:file "renderer-style")     ; theme palette + fixed SGR constants
       ;; Workspace presentation helpers and tree projection depend on no pane
       ;; compositor; their order here states that boundary.
       (:file "renderer-workspace-status-title") ; shared status/title labels
       (:file "renderer-workspace-command-line") ; command completion footer
       (:file "renderer-workspace-tree") ; shared tree data projection
       (:file "renderer-workspace")  ; workspace frame (plain ANSI)
       (:file "renderer-pane-selection") ; selection bounds helpers
       (:file "renderer-statusbar-layout"); status bar layout helpers (needed by renderer-pane-copy-mode-overlay below)
       (:file "renderer-pane-search")    ; pane content search match ranges
       (:file "renderer-pane-copy-mode-overlay")      ; copy-mode position-banner overlay rendering
       (:file "renderer-pane")           ; pane cell rendering (selection, copy-mode highlights)
       (:file "renderer-borders")        ; split-tree separators + pane border rendering
       (:file "renderer-statusbar")      ; status bar composition
       (:file "renderer-compose-protocols") ; terminal protocol toggles
       (:file "renderer-compose-overlay")   ; cursor placement for the active pane
       (:file "renderer-compose-effects")   ; bell / cursor / queue drain effects
       (:file "renderer-compose")        ; PANE frame compositing + entry points
       (:file "renderer-tui-kit-frame-grid") ; ANSI frame decoding into a fixed grid
       (:file "renderer-tui-kit-widgets") ; workspace tree and picker widgets
       (:file "renderer-tui-kit")       ; headless surface conversion and entry points
       (:file "renderer-tui-kit-confirm-view") ; confirmation data and rendering
       (:file "renderer-tui-kit-help") ; full-screen key reference, now reached from the `?` transient
       ;; The three magit-alignment views. All three need the tui-kit surface
       ;; helpers (%SURFACE-TO-ANSI-FRAME, %BOX-WIDGET-INNER-RECTANGLE), so they
       ;; load after renderer-tui-kit; transient comes before the status view
       ;; because the status frame draws the transient panel into its own
       ;; bottom region.
       (:file "renderer-tui-kit-transient") ; magit transient, drawn as an expanded key panel
       (:file "renderer-process-log")       ; `$` full-screen git process log (FR-011)
       (:file "renderer-workspace-status"))) ; magit-style per-worktree status view (FR-003)
     ;; Everything left in src/bootstrap/ now shares one real ASDF module,
     ;; matching the directory name exactly -- no :pathname override needed
     ;; (W6). It loads last because "nerimux" needs every other package
     ;; declared first (renderer, input, and commands included), which used
     ;; to be true only because package.lisp loaded all nine package
     ;; fragments upfront regardless of where their own code lived.
     (:module "bootstrap"
      :serial t
      :components
      ((:file "package")             ; nerimux (BOOTSTRAP layer, needs everything)
       ;; target resolution is a "nerimux"-package service (W4-prep found it was
       ;; never really part of nerimux/model despite living in that directory);
       ;; moved here from domain/model now that its true package's declaration
       ;; also lives here.
       (:file "target")              ; session/window/pane target resolution (-t flag)
       (:file "server-dispatch-macros") ; declarative rule-table macros (moved out of package.lisp, W6)
       (:file "runtime")              ; shared state + channel sync + SIGWINCH
       (:file "runtime-reader")       ; PTY reader CPS state machine
       (:file "session-registry")  ; lookup for the one session the server owns
       (:file "server")
       (:file "workspace-window") ; workspace window creation
       (:file "server-multi-dispatch") ; shared multi-client handlers
       (:file "server-multi-dispatch-prefix") ; C-q workspace actions
       (:file "server-multi-workspace-selection") ; workspace catalog selection logic
       (:file "server-multi-dispatch-picker") ; picker/tree selection
       (:file "server-multi-dispatch-command-workspace") ; workspace UI helpers
       (:file "server-multi-dispatch-command-worktree") ; worktree operations
       (:file "server-multi-command-input-primitives") ; payload predicates and decoding
       ;; Before the keymap: %HANDLE-CLIENT-UI-KEY-PAYLOAD calls
       ;; %OPEN-CLIENT-TRANSIENT for every transient key. A forward call would
       ;; only warn at compile time, but a warning is not what catches a
       ;; misspelled name here -- an undefined function fails at runtime, and a
       ;; transient key that silently does nothing looks like an unbound key.
       (:file "server-multi-dispatch-transient") ; magit transient state and key handling
       (:file "server-multi-dispatch-command-input") ; client input and command entry
       (:file "server-multi-dispatch-tree-filter") ; tree-filter input mode
       (:file "server-multi-dispatch-command") ; final command dispatcher
       (:file "server-multi-state") ; mutable multi-client and workspace state
       (:file "server-multi")  ; multi-client client registry + dispatch helpers
       (:file "server-multi-render") ; client geometry and frame broadcast
       (:file "server-multi-loop") ; multi-client select-multiplexed serve loop
       (:file "runtime-lifecycle") ; per-server state directory and log path
       (:file "client")
       (:file "main-startup-flags") ; global cl-cli flag definitions
       (:file "main-startup-socket") ; socket discovery + server auto-start helpers
       (:file "main-startup-commands") ; attach/version/usage handlers + mode table
       (:file "main-startup"))))))
  ;; Build a standalone binary: (asdf:make :nerimux)
  :build-operation "program-op"
  :build-pathname "nerimux"
  :entry-point "nerimux:main"
  :in-order-to ((test-op (test-op "nerimux/test"))))

(cl-user::define-system-with-nerimux-test-components "nerimux/test"
  :description "Test suite for nerimux, authored natively in cl-weave"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  ;; Each unit's test system is named here so loading "nerimux/test" registers
  ;; every unit's suites in the same image. cl-weave's registry is global, so
  ;; RUN-TESTS then reports one total across the root suites and the units --
  ;; the split changes where a test file lives, not how many run.
  :depends-on ("nerimux" (:version "cl-weave" "1.3.0")
               "nerimux-text/test"
               "nerimux-ports/test"
               "nerimux-pty/test"
               "nerimux-net/test"
               "nerimux-input/test"
               "nerimux-terminal/test"
               "nerimux-model/test"
               "nerimux-picker/test"
               "nerimux-vcs/test")
  :perform (test-op (op c)
             (declare (ignore op c))
             (funcall (find-symbol "RUN-TESTS" (find-package "NERIMUX/TEST")))))


;; The real-PTY suite, split out of nerimux/test by R9.2.
;;
;; `nix flake check` builds in a sandbox with no /dev/ptmx, so every case that
;; forks a shell under a pseudo-terminal used to guard itself with a skip and
;; report a pass for work it never did. Moving them here makes the main suite's
;; green mean one thing and this suite's green mean another, instead of one
;; number covering both.
;;
;; Run with: nix run .#test-pty   (or (asdf:test-system "nerimux/pty-test"))
(defsystem "nerimux/pty-test"
  :description "Real-PTY suite for nerimux: every case that forks a shell under a pseudo-terminal."
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  :depends-on ("nerimux" (:version "cl-weave" "1.3.0"))
  :pathname "tests/pty"
  :serial t
  :components ((:file "package")
               (:file "helpers")
               (:file "pty-unit-tests")
               (:file "pty-integration-tests")
               (:file "pane-tests-geometry-pty")
               (:file "pane-tests-ops-pty")
               (:file "window-tests-c-pty")
               (:file "window-tests-pane-ops")
               (:file "window-tests-split-math-pty")
               (:file "session-lifecycle-tests")
               (:file "server-command-tests")
               (:file "server-client-cps-pty-tests")
               (:file "server-multi-command-client-pty-tests")
               (:file "entry"))
  :perform (test-op (op c)
             (declare (ignore op c))
             (funcall (find-symbol "RUN-PTY-TESTS" (find-package "NERIMUX/PTY-TEST")))))

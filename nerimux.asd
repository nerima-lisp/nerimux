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
               :cl-vcs-kit)      ; ghq/repository/worktree discovery
  :components
  ((:module "src"
    :serial t
     :components
     ((:module "bootstrap-packages"
       :pathname "bootstrap"
       :serial t
       :components ((:file "package")))  ; loads package-* fragments; defines all packages
     ;; Foundation: depends on nothing, so it loads before every layer that calls
     ;; it.  Placement is load-bearing -- domain/terminal calls
     ;; parse-integer-or-nil and used to be compiled before the file defining it.
     (:module "domain/text"
      :serial t
      :components ((:file "text-parse")))
     (:module "domain/ports"
      :serial t
      :components
      ((:file "posix-port")
       (:file "pty-port")))   ; port abstractions (load before infrastructure adapters)
     (:module "infrastructure/pty"
      :serial t
      :components
       ((:file "pty-ffi")       ; FFI declarations and platform constants
       (:file "pty-rawmode")   ; terminal raw mode management
       (:file "pty")))         ; PTY lifecycle + install-pty-port adapter (references nerimux/ports vars)
     (:module "infrastructure/net"
      :serial t
      :components
      ((:file "protocol-command")  ; wire constants and command payload codec
       (:file "protocol")
       (:file "transport")
       (:file "net")))
     (:module "domain/terminal"
      :serial t
      :components
      ((:file "cell")         ; immutable cell type, char-width table
       (:file "screen-data")  ; declarative screen slots and defaults
       (:file "screen")       ; screen construction and grid helpers
       (:file "screen-metadata") ; screen capture/palette metadata mutation helpers
       (:file "screen-resize") ; screen resize logic; depends on metadata reset helpers
       (:file "screen-logic") ; screen mutation helpers (LOGIC layer): screen-clear-dirty, screen-consume-bell, screen-drain-queue, reset-sgr-pen
       (:file "scroll")    ; row helpers + scroll-up/down + decstbm (loads before cursor/erase/edit)
       (:file "erase")     ; erase-region, erase-display, erase-line rule tables
       (:file "edit")      ; delete/insert chars+lines (uses %copy-row, %clear-row from scroll)
       (:file "cursor")    ; cursor movement (uses scroll-up-one)
       (:file "char-write-definitions") ; DEC graphics facts and character-width classification
       (:file "char-write-cells") ; combining and wide/normal cell placement
       (:file "char-write") ; charset, wrap, and insert-mode writing flow
       (:file "modes-alt-screen") ; DEC modes — alt-screen enter/exit helpers (part I)
       (:file "modes-dec-pm-definitions") ; compile-time DEC PM rule table
       (:file "modes-cursor-save") ; DECSC/DECRC cursor save-restore + DECSCUSR shape
       (:file "modes-reset")       ; reset-terminal-modes + RIS/DECSTR/DECALN
       (:file "modes-charset-definitions") ; compile-time G0..G3 slot fact table
       (:file "modes-charset")     ; G0..G3 charset designation/invocation logic
       (:file "modes-ansi-sm-rm-definitions") ; compile-time ANSI SM/RM rule table
       (:file "screen-projection") ; copy-mode scrollback viewport cell projection
       (:file "screen-osc-state")  ; focus reports, BEL, title stack, OSC title/colour state
       (:file "sgr-definitions") ; attribute helpers and compile-time SGR rule table
       (:file "sgr-colors")      ; extended-colour parameter decoding
       (:file "sgr")             ; SGR application flow
       (:file "sgr-report")      ; pen-to-SGR status-report encoding
       (:file "csi-replies-definitions") ; compile-time reply fact-table constructors
       (:file "csi-replies")    ; CSI reply-queue helpers (DSR/DA/CPR/DECRQM/XTWINOPS); loads before csi
       (:file "csi-parameters") ; CSI parameter-to-domain-value translation
       (:file "csi-dispatch")   ; DEFINE-CSI-RULES macro that emits EXECUTE-CSI
       (:file "csi")            ; cursor, screen-edit, and SGR rules
       (:file "csi-device-rules") ; reports, tabulation, and private-mode rules
       (:file "csi-extended-rules") ; rectangular and extended-control rules
       (:file "csi-compose")    ; compose rule sets into EXECUTE-CSI
       (:file "parser-dcs")    ; DCS passthrough/XTGETTCAP/DECRQSS helpers (loads before parser)
       (:file "parser-core")   ; parser byte predicates + Prolog-like DEFINE-STATE macro
       (:file "parser-csi")    ; CSI continuation builder and byte-class predicates
       (:file "parser-utf8")   ; UTF-8 continuation builder and byte predicates
       (:file "parser")        ; named CPS state-machine skeleton
       (:file "parser-osc-clipboard") ; OSC 52 Base64 helpers + clipboard callback
       (:file "parser-osc-uri")       ; OSC 7/8 URI decoding helpers
       (:file "parser-osc-color")      ; OSC color and palette helpers
       (:file "parser-osc-dispatch")   ; OSC command parsing + dispatch rules
       (:file "parser-osc")            ; OSC accumulator + dispatcher state machine
       (:file "emulator")))
     (:module "domain/model"
      :serial t
      :components
      ((:file "organization")      ; ghq organization aggregate
       (:file "repository")        ; ghq repository aggregate
       (:file "worktree")           ; worktree aggregate and relationships
       (:file "pane-core")         ; leaf PTY data and feed helpers
       (:file "pane-geometry")     ; geometry update + PTY/screen resize helpers
       (:file "layout")            ; tree structure (uses pane-reposition)
       (:file "layout-visitor")    ; declarative layout traversal macros
       (:file "layout-persistence") ; layout string serialization
       (:file "layout-geometry")    ; rectangle assignment + resize helpers (uses pane-id, pane-x/y/w/h)
       (:file "window-definitions") ; window records and pane-numbering constants
       (:file "window-core")        ; window selection and split behavior
       (:file "window-tree")        ; tree mutation + relayout/remove helpers
       (:file "window-operations")  ; window resize/rotate/zoom (uses window + layout helpers)
       (:file "window-neighbor") ; directional pane navigation (uses window-panes)
       (:file "session")             ; session lifecycle: struct + windows + touch + all-panes
       (:file "session-environment-process")   ; update-env defaults + process env helpers
       (:file "session-environment-overlay")    ; session overlay tables and env access
       (:file "session-environment-child")      ; child env snapshot assembly
       (:file "pane-spawn")))                   ; PTY-backed pane factory + respawn
     (:module "infrastructure/vcs"
     :serial t
     :components
       ((:file "vcs")
     (:file "vcs-async-operations")
     (:file "vcs-worktree-operations")
     (:file "vcs-fetch")))
     (:module "application/picker"
      :serial t
      :components
      ((:file "global-picker")
       ))       ; pure picker + measurement fixture
     ;; target resolution is a domain/model service; placed in the model directory
     ;; via :pathname so its load slot (after format) stays byte-identical.
     (:module "domain-model-target"
      :pathname "domain/model"
      :serial t
      :components
      ((:file "target")))   ; session/window/pane target resolution (-t flag)
     ;; commands context: what is left of the pane/window operations, plus the
     ;; copy-mode cluster.  commands-core loads first, then copy-mode, then the
     ;; two survivors split back to root via :pathname.  The tmux command
     ;; implementations this directory was built for (commands.lisp,
     ;; commands-shell, commands-keys, commands-keys-data, commands-capture-pane)
     ;; went with the command table that called them.
     (:module "application/commands"
      :serial t
      :components
      ((:file "commands-core")))
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
      ((:file "renderer-format-definitions") ; compile-time ANSI fact-table constructors
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
       (:file "renderer-tui-kit-confirm-view"))) ; confirmation data and rendering
     (:module "infrastructure/input"
      :serial t
      :components
      ((:file "input")))
     (:module "bootstrap-runtime"
      :pathname "bootstrap"
      :serial t
      :components
      ((:file "runtime")              ; shared state + channel sync + SIGWINCH
       (:file "runtime-reader")))     ; PTY reader CPS state machine
     (:module "bootstrap-server"
      :pathname "bootstrap"
      :serial t
      :components
      ((:file "session-registry")  ; lookup for the one session the server owns
       (:file "server")
       (:file "workspace-window") ; workspace window creation
       (:file "server-multi-dispatch") ; shared multi-client handlers
       (:file "server-multi-dispatch-prefix") ; C-q workspace actions
       (:file "server-multi-workspace-selection") ; workspace catalog selection logic
       (:file "server-multi-dispatch-picker") ; picker/tree selection
       (:file "server-multi-dispatch-command-workspace") ; workspace UI helpers
       (:file "server-multi-dispatch-command-worktree") ; worktree operations
       (:file "server-multi-command-input-primitives") ; payload predicates and decoding
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
  :depends-on ("nerimux" (:version "cl-weave" "1.3.0"))
  :perform (test-op (op c)
             (declare (ignore op c))
             (funcall (find-symbol "RUN-TESTS" (find-package "NERIMUX/TEST")))))

(defsystem "nerimux/vcs-test"
  :description "Focused VCS infrastructure tests for nerimux"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  :depends-on ("nerimux" (:version "cl-weave" "1.3.0"))
  :pathname "t"
  :serial t
  :components ((:file "package")
               (:file "suite")
               (:file "helpers-process-fixtures")
               (:module "unit/infrastructure/vcs"
                :serial t
                :components ((:file "vcs-tests")
                             (:file "vcs-fetch-dedup-tests")
                             (:file "vcs-worktree-path-tests")
                             (:file "vcs-operations-tests")
                             (:file "vcs-async-operations-tests"))))
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
  :pathname "t/pty"
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

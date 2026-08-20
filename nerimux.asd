;;; This form comes FIRST, before any other form. ASDF binds *package* to
;;; ASDF-USER only for a file it loads itself; read any other way — a REPL
;;; `load`, an editor evaluating the buffer, flake.nix parsing :version — the
;;; file is read in whatever package happens to be current, and an unqualified
;;; `defsystem` then fails to read at all. Saying it makes the file
;;; self-contained. See PACKAGE_STANDARD.md "asd の書き方".
(in-package #:asdf-user)

#.(progn
    (load (merge-pathnames "system/asdf-test-components.lisp" *load-truename*))
    nil)

(defsystem "nerimux"
  :description "A tmux-compatible terminal multiplexer in Common Lisp"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  ;; Single source of truth for the version: flake.nix reads this form and
  ;; release.yml refuses to publish a tag that disagrees with it.
  :version "0.2.0"
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
  :depends-on (:cl-concurrent-kit ; threads, locks, condvars and preemptive deadlines
               :cl-regex-kit     ; regex engine behind the format #{m/r:...} and #{s///:} modifiers
               :cl-cli           ; startup argv/flag parsing (main-startup-flags)
               :cl-boundary-kit  ; process boundary for run-shell/if-shell
               :cl-parser-kit    ; commands-tokenizer combinator rewrite
               :cl-tty-kit       ; PTY spawn/raw-mode/fd-io, ioctl window size, colour downsampling
               :cl-process-kit   ; timeout-guarded subprocess run, and select(2) over raw fds
               :cl-history-kit   ; command-prompt history store + recall navigation (runtime-history)
               :cl-codec-kit     ; string<->octet UTF-8 codec (protocol, PTY, OSC payloads)
               :cl-host-kit      ; pathname/string host ops (split-string, directory helpers)
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
     (:module "application/config"
      :serial t
      :components
      ((:file "config")
       (:file "config-tokenizer")    ; config tokenizer + key/command parse tables
         (:file "config-directives-macro")   ; generic directive-dispatch macro infra + posix/tilde/flag helpers
         (:file "config-directives-bind-sequences") ; semicolon splitting for directive payloads
         (:file "config-directives-set")     ; fixed-arity table + set-option flag handling/routing
       (:file "config-option-side-effects") ; option runtime side effects
       (:file "config-directives-runtime-services") ; shared shell execution services
       (:file "config-directives-environment") ; set-environment handler
       (:file "config-directives-if-shell") ; if-shell handler
       (:file "config-directives-run-shell") ; run-shell handler
       (:file "config-directives-source-file") ; source-file handler
       (:file "config-loader")        ; directive dispatch + comment stripping + apply-config-line
       (:file "config-preprocessor")  ; %if/%elif/%else/%endif state machine + brace/continuation joining
       (:file "config-paths")))       ; config-file path resolution + load-config-file
     (:module "domain/ports"
      :serial t
      :components
      ((:file "posix-port")
       (:file "pty-port")
       (:file "vcs-port")))   ; port abstractions (load before infrastructure adapters)
     (:module "infrastructure/pty"
      :serial t
      :components
      ((:file "pty-ffi")       ; FFI declarations and platform constants
       (:file "pty-rawmode")   ; terminal raw mode management
       (:file "pty")))         ; PTY lifecycle + install-pty-port adapter (references nerimux/ports vars)
     (:module "infrastructure/net"
      :serial t
      :components
      ((:file "protocol")
       (:file "protocol-command")  ; +msg-command+ payload codec (same package as protocol)
       (:file "transport")
       (:file "net")))
     (:module "domain/terminal"
      :serial t
      :components
      ((:file "cell")         ; immutable cell type, char-width table
       (:file "screen")       ; screen struct (DATA layer): defstruct, grid helpers
       (:file "screen-metadata") ; screen capture/palette metadata mutation helpers
       (:file "screen-resize") ; screen resize logic; depends on metadata reset helpers
       (:file "screen-logic") ; screen mutation helpers (LOGIC layer): screen-clear-dirty, screen-consume-bell, screen-drain-queue, reset-sgr-pen
       (:file "scroll")    ; row helpers + scroll-up/down + decstbm (loads before cursor/erase/edit)
       (:file "erase")     ; erase-region, erase-display, erase-line rule tables
       (:file "edit")      ; delete/insert chars+lines (uses %copy-row, %clear-row from scroll)
       (:file "cursor")    ; cursor movement (uses scroll-up-one)
       (:file "char-write") ; combining chars, DEC graphics, wide/normal cell writes (uses cursor-down/scroll, insert-chars)
       (:file "modes-alt-screen") ; DEC modes — alt-screen enter/exit helpers (part I)
       (:file "modes-dec-pm")     ; DEC modes — DEC PM rule-table macro + dispatch table (part II)
       (:file "modes-cursor-save") ; DECSC/DECRC cursor save-restore + DECSCUSR shape
       (:file "modes-reset")       ; reset-terminal-modes + RIS/DECSTR/DECALN
       (:file "modes-charset")     ; G0..G3 charset designation/invocation rule table
       (:file "modes-ansi-sm-rm")  ; ANSI (non-private) SM/RM rule table
       (:file "screen-projection") ; copy-mode scrollback viewport cell projection
       (:file "screen-osc-state")  ; focus reports, BEL, title stack, OSC title/colour state
       (:file "sgr")
       (:file "csi-replies")    ; CSI reply-queue helpers (DSR/DA/CPR/DECRQM/XTWINOPS); loads before csi
       (:file "csi-parameters") ; CSI parameter-to-domain-value translation
       (:file "csi-dispatch")   ; DEFINE-CSI-RULES macro that emits EXECUTE-CSI
       (:file "csi")            ; declarative CSI action rule table
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
       (:file "layout")            ; tree structure + traversal (uses pane-reposition)
       (:file "layout-persistence") ; layout string serialization
       (:file "layout-geometry")    ; rectangle assignment + resize helpers (uses pane-id, pane-x/y/w/h)
       (:file "window-core")        ; window struct + core ops (split/constants)
       (:file "window-tree")        ; tree mutation + relayout/remove helpers
       (:file "window-operations")  ; window resize/rotate/zoom (uses window + layout helpers)
       (:file "window-neighbor") ; directional pane navigation (uses window-panes)
       (:file "window-layout")   ; named layouts (apply-named-layout, uses window accessors)
       (:file "session")             ; session lifecycle: struct + windows + touch + all-panes
       (:file "session-environment-process")   ; update-env defaults + process env helpers
       (:file "session-environment-overlay")    ; session overlay tables and env access
       (:file "session-environment-child")      ; child env snapshot assembly
       (:file "pane-spawn")))                   ; PTY-backed pane factory + respawn
     (:module "domain/persistence"
      :serial t
      :components
      ((:file "runtime-state")))                ; versioned reader-safe runtime snapshot
     (:module "infrastructure/vcs"
      :serial t
      :components
      ((:file "vcs")))             ; optional cl-vcs-kit adapter
     (:module "domain/format"
      :serial t
      :components
      ((:file "format-helpers")    ; tmux-style format: pure data helpers + shorthand/arithmetic tables
       (:file "format-strftime")   ; strftime support (#{t:format}): %strftime-letter-p + formatting engine
       (:file "format-modifiers")  ; value-modifiers (#{b:}/#{d:}/#{=N:}/#{pN:}/#{s///:}/#{q:}/#{E:})
       (:file "format-search")     ; glob/regex matching + pane content search (#{m:}/#{m/r:}/#{C:})
       (:file "format-operators")  ; comparison and logical operators (#{==:}/#{!=:}/#{||:}/#{&&:})
       (:file "format-iteration")  ; W:/S:/P: window/session/pane iteration expanders
       (:file "format-shell-command") ; bounded shell-command port for #(command) expansion
       (:file "format-delimiters") ; delimiter scanning plus #[...] and #(command) ports
       (:file "format-brace")      ; core #{...} modifier/operator expansion
       (:file "format-engine")     ; CPS processor and expand-format public entry points
       (:file "format-context-os-probe") ; OS probes (pgrep/ps/lsof/proc) for pane_current_command/pane_current_path
       (:file "format-context-screen") ; pane-geometry/screen/client section builders (mechanical getter tables)
       (:file "format-context")))  ; context builder: model objects → expand-format plist
     (:module "domain/repository"
      :serial t
      :components
      ((:file "session-repository"))) ; Repository pattern: session store protocol + *session-repo* var
     (:module "application/picker"
      :serial t
      :components
      ((:file "global-picker")))                 ; pure organization/repository/worktree picker
     ;; target resolution is a domain/model service; placed in the model directory
     ;; via :pathname so its load slot (after format) stays byte-identical.
     (:module "domain-model-target"
      :pathname "domain/model"
      :serial t
      :components
      ((:file "target")))   ; session/window/pane target resolution (-t flag)
     (:module "domain/options"
      :serial t
      :components
      ((:file "options")             ; global option registry: hash-tables + define-option-table macros
       (:file "options-registry-data") ; define-tmux-options/define-server-options DATA tables
       (:file "options-scope")  ; scope dispatch + array-name parsing + spec lookup + presence predicates
       (:file "options-api")    ; type coercions, define-option-accessor, public get/set API, scoped overrides
       (:file "options-display"))) ; option display/rendering helpers (show-options, show-option-values)
     (:module "domain/buffer"
      :serial t
      :components
      ((:file "buffer")))   ; paste-buffer ring (uses options for buffer-limit)
     (:module "domain/hooks"
      :serial t
      :components
      ((:file "hooks")))    ; user-defined hook registry
     (:module "presentation/prompt"
      :serial t
      :components
      ((:file "prompt")
       (:file "overlay")))              ; overlay, popup, menu state (read by renderer-compose-overlay and the visual-bell transient)
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
       ((:file "commands-pipe-pane")     ; pipe-pane process I/O lifecycle
        (:file "commands-tokenizer")))   ; shell-style command-string tokeniser
     (:module "presentation/renderer"
      :serial t
      :components
      ((:file "renderer-format")     ; ANSI primitives (shared by both paths below)
       ;; The workspace views depend on renderer-format and nothing else in this
       ;; module; loading them here, ahead of the pane compositor, states that.
       (:file "renderer-workspace")  ; workspace tree + attention views (plain ANSI)
       (:file "renderer-style-data") ; declarative style/SGR/border-charset dispatch tables
       (:file "renderer-style")     ; style-string parsing + SGR emission logic
       (:file "renderer-pane-selection") ; selection bounds helpers
       (:file "renderer-pane-clock")     ; big digits + display-panes clock overlay
       (:file "renderer-statusbar-layout"); status bar layout helpers (needed by renderer-pane-copy-mode-overlay below)
       (:file "renderer-pane-search")    ; pane content search match ranges
       (:file "renderer-pane-copy-mode-overlay")      ; copy-mode position-banner overlay rendering
       (:file "renderer-pane-copy-mode-line-number")  ; copy-mode line-number gutter rendering
       (:file "renderer-pane")           ; pane cell rendering (selection, copy-mode highlights)
       (:file "renderer-borders")        ; split-tree separators + pane border rendering
       (:file "renderer-overlay")        ; popup and menu box-drawing
       (:file "renderer-statusbar")      ; status bar composition
       (:file "renderer-compose-protocols") ; terminal protocol toggles
       (:file "renderer-compose-overlay")   ; overlay rendering + mouse mode sequences
       (:file "renderer-compose-effects")   ; bell / cursor / queue drain effects
       (:file "renderer-compose")        ; PANE frame compositing + entry points
       (:file "renderer-tui-kit")        ; headless cl-tui-kit surface/backend adapter
       (:file "renderer")))         ; documentation stub (intentionally empty)
     (:module "infrastructure/input"
      :serial t
      :components
      ((:file "input")))
     (:module "bootstrap-runtime"
      :pathname "bootstrap"
      :serial t
      :components
      ((:file "runtime")              ; shared state + channel sync + SIGWINCH
       (:file "runtime-history")      ; message log + prompt history
       (:file "runtime-reader-alerts") ; remain-on-exit banner + alert-action helpers
       (:file "runtime-reader")       ; PTY reader CPS state machine
       (:file "runtime-timer")))      ; status interval timer, lock-after-time, monitor-silence
     ;; dispatch context, subdivided into cohesive sub-areas. Load order is
     ;; byte-identical to the old flat module; handlers split early (support)
     ;; / late (rest) via the :pathname trick (dispatch-handlers-2).
 ; copy-mode table, format helpers, new-session, named-command table (loads dispatch-command-specs* fragments)
 ; shared prompt/menu helpers for dispatch handlers
 ; *arg-command-table* + %run-command-tokens + %run-command-line
 ; paste-buffer command handler helpers
     (:module "bootstrap-server"
      :pathname "bootstrap"
      :serial t
      :components
      ((:file "session-registry")  ; session registry + group management
       (:file "server")
       (:file "workspace-window") ; workspace window creation
       (:file "server-multi-dispatch") ; multi-client attach/resize/key/command handlers
       (:file "server-multi")  ; multi-client client registry + dispatch helpers
       (:file "server-multi-loop") ; multi-client select-multiplexed serve loop
       (:file "runtime-lifecycle") ; atomic runtime snapshot restore/save hooks
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

(defsystem "nerimux/test"
  :description "Test suite for nerimux, authored natively in cl-weave"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.2.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  :depends-on ("nerimux" "cl-weave")
  ;; The component tree is ~295 files, so it lives in system/ and is spliced in
  ;; at read time by the #. form at the top of this file. The list itself is a
  ;; single (:module "t" ...) rooted at the standard test directory.
  :components #.(symbol-value (find-symbol "*NERIMUX-TEST-COMPONENTS*" :cl-user))
  ;; Run with: (asdf:test-system "nerimux")
  ;; Not HOST-KIT:SYMBOL-CALL: a .asd is read before :depends-on is ever
  ;; consulted, so a CL-HOST-KIT-prefixed token here would be a read-time
  ;; PACKAGE-DOES-NOT-EXIST error regardless of what the system depends on.
  ;; FIND-SYMBOL/FIND-PACKAGE/FUNCALL are CL, always present.
  :perform (test-op (op c)
             (funcall (find-symbol "RUN-TESTS" (find-package "NERIMUX/TEST")))))

;; The cold-path read-model below is an OPTIONAL system, not part of core
;; `nerimux'.  It has no call site anywhere in src/ outside its own directory, so
;; carrying it in core bought nothing at runtime while forcing cl-dataflow-kit
;; into the shipped binary's dependency closure.  It stays in-tree because
;; nerimux is the org's L4 testbed and this is how cl-dataflow-kit gets
;; dogfooded; it is simply not loaded by `(asdf:load-system "nerimux")'.
;;
;; Its sibling, nerimux/reasoning (cl-prolog-kit), was RETIRED: it existed only
;; to project nerimux/config's key-table store into Prolog facts, and that store
;; was deleted once nothing read it.  With no facts left to project there was
;; nothing to narrow it to, so the system and its cl-weave suite went together.
;;
;; Naming: the source system could not reuse "nerimux/dataflow" — that name is
;; already taken by the cl-weave TEST system below, and renaming it would break
;; the documented NERIMUX_TEST_SYSTEM values in README.md and run-tests.lisp.
;; Hence nerimux/dataflow-model (source) alongside nerimux/dataflow (test).

(defsystem "nerimux/dataflow-model"
  :description "cl-dataflow-kit copy-mode lifecycle read-model."
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.2.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  :depends-on ("nerimux" "cl-dataflow-kit")
  :pathname "src/dataflow"
  :serial t
  :components ((:file "package")
               (:file "copy-mode-lifecycle")))

;; cl-weave regression suite for the cl-dataflow-kit copy-mode lifecycle
;; read-model (src/dataflow/).
;; Run with: (asdf:test-system :nerimux/dataflow)
(defsystem "nerimux/dataflow"
  :description "cl-weave suite for the nerimux cl-dataflow-kit copy-mode lifecycle read-model."
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.2.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  :depends-on ("nerimux" "nerimux/dataflow-model" "cl-weave" "cl-dataflow-kit")
  :pathname "t/dataflow"
  :serial t
  :components ((:file "package")
               (:file "copy-mode-lifecycle-tests")
               (:file "entry"))
  :perform (test-op (op c)
             (declare (ignore op c))
             (unless (funcall (find-symbol "RUN-DATAFLOW-TESTS" (find-package "NERIMUX/DATAFLOW-TESTS")))
               (error "nerimux cl-dataflow-kit suite failed."))))

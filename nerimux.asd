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
      ((:file "config-key-table-store") ; key-table storage primitives (bind/unbind/lookup)
       (:file "config")
       (:file "config-tokenizer")    ; config tokenizer + key/command parse tables
         (:file "config-directives-macro")   ; generic directive-dispatch macro infra + posix/tilde/flag helpers
         (:file "config-directives-bind-sequences") ; brace/semicolon splitting for bind payloads
         (:file "config-directives-bind-parse") ; bind-key argument parsing + command resolution
         (:file "config-directives-bind-dispatch") ; bind/unbind directive dispatch
         (:file "config-directives-set")     ; fixed-arity table + set-option flag handling/routing
       (:file "config-option-side-effects") ; option runtime side effects + set-hook directive
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
      ((:file "pty-port")
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
       (:file "overlay")))              ; overlay, popup, menu state (used by dispatch/events/renderer)
     ;; commands context: general pane/window ops + the cohesive copy-mode
     ;; cluster (its own sub-area). commands-core loads first, then copy-mode,
     ;; then commands/commands-keys-data/commands-tokenizer/commands-keys/
     ;; commands-shell (split back to root via :pathname).
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
       (:file "commands-copy-mode-word") ; word/WORD motion helpers shared by navigation/search
       (:file "commands-copy-mode-nav-line") ; line-start/end, cursor-jump macros, scroll wrappers
       (:file "commands-copy-mode-nav-select") ; begin-line-selection
       (:file "commands-copy-mode-nav-paragraph") ; paragraph boundaries
       (:file "commands-copy-mode-nav-jump") ; jump-to-char and goto-line commands
       (:file "commands-copy-mode-nav-copy") ; copy-end-of-line, copy-line helpers
       (:file "commands-copy-mode-clip") ; rectangle selection text, yank, copy-pipe, append-selection
       (:file "commands-copy-mode-virtual") ; virtual-row helpers shared by search/brackets
       (:file "commands-copy-mode-brackets") ; bracket matching commands
       (:file "commands-copy-mode-search"))) ; search-forward/backward, search-next/prev
     (:module "application-commands-2"
      :pathname "application/commands"
      :serial t
      :components
      ((:file "commands")               ; shared command execution helpers
       (:file "commands-capture-pane")  ; capture-pane snapshot/rendering
       (:file "commands-pipe-pane")     ; pipe-pane process I/O lifecycle
       (:file "commands-keys-data")      ; send-keys key-name data tables
       (:file "commands-tokenizer")      ; shell-style command-string tokeniser
       (:file "commands-keys")           ; send-keys key-name translation logic
       (:file "commands-shell")))        ; run-shell / if-shell subprocess execution
     (:module "presentation/renderer"
      :serial t
      :components
      ((:file "renderer-format")     ; ANSI primitives
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
       (:file "renderer-compose")        ; session frame compositing + entry points
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
     (:module "application/dispatch/core"
      :serial t
      :components
      ((:file "dispatch-core")            ; cyclic navigation primitives
       (:file "dispatch-core-overlays")   ; overlay rendering helpers
       (:file "dispatch-core-targets")    ; target-string resolution helpers
       (:file "dispatch-core-context")    ; target/session guard macros + active context
       (:file "dispatch-core-hooks")      ; command-hook dispatch helpers
       (:file "dispatch-core-window-cmds") ; window/pane/split command factories
       (:file "dispatch-core-focus")      ; focus event delivery helpers
       (:file "dispatch-core-pane-ops")   ; pane, layout, and window-list helpers
       (:file "dispatch-core-commands"))) ; copy-mode table, format helpers, new-session, named-command table (loads dispatch-command-specs* fragments)
     (:module "application/dispatch/handlers"
      :serial t
      :components
      ((:file "dispatch-handlers-support"))) ; shared prompt/menu helpers for dispatch handlers
     (:module "application/dispatch/commands"
      :serial t
      :components
      ((:file "dispatch-commands-input")    ; shared flag parser and command-input macros
       (:file "dispatch-commands-target")   ; shared target resolution helpers
       (:file "dispatch-commands-prompt")   ; command-prompt substitution/CPS helpers
       (:file "dispatch-commands")          ; display/prompt/pane %cmd-* handlers
       (:file "dispatch-commands-flag-accessors") ; generated command flag accessors
       (:file "dispatch-commands-buffer")   ; paste-buffer %cmd-* handlers
       (:file "dispatch-commands-buffer-ui") ; popup/menu/confirm/list-keys %cmd-* handlers
       (:file "dispatch-commands-copy-mode-entry") ; copy-mode entry %cmd-* handler
       (:file "dispatch-commands-option-scope-facts") ; set-option scope accessor facts
       (:file "dispatch-commands-option")   ; set-option (CPS) + show-options %cmd-*
       (:file "dispatch-commands-option-pane") ; rename/select %cmd-* handlers (loads option-pane-window/pane fragments)
       (:file "dispatch-commands-lifecycle") ; kill/link/unlink/swap/move/source-file %cmd-*
       (:file "dispatch-commands-pane-layout-facts") ; select-layout canonical facts
       (:file "dispatch-commands-pane")   ; layout/window/pane helpers + *key-table*
       (:file "dispatch-commands-session-service") ; session switching/destruction services
       (:file "dispatch-commands-client-session") ; switch/attach/detach %cmd-* handlers
       (:file "dispatch-commands-session-create") ; new-session %cmd-* handler
       (:file "dispatch-commands-session-destroy") ; kill-session %cmd-* handler
       (:file "dispatch-commands-window-resize") ; resize-window %cmd-* handler
       (:file "dispatch-commands-pane-x-facts") ; copy-mode -X canonical fact tables
       (:file "dispatch-commands-pane-x") ; send-keys -X dispatch logic
       (:file "dispatch-commands-shell")   ; run-shell and if-shell %cmd-* handlers
       (:file "dispatch-commands-capture-pane") ; capture-pane %cmd-* handler
       (:file "dispatch-commands-pane-ops") ; resize/join/break/clear/rotate %cmd-* handlers
       (:file "dispatch-commands-list-data") ; *command-usage-table* pure data (canonical-name → usage-flags)
       (:file "dispatch-commands-list-registry") ; list-commands registry projection
       (:file "dispatch-commands-list-overlay") ; list overlay presentation helpers
       (:file "dispatch-commands-list-query") ; list read-model queries and formatters
       (:file "dispatch-commands-list-parser") ; list-* tmux-compatible arg parser
       (:file "dispatch-commands-list")    ; list-sessions/windows/panes/clients %cmd-* handlers
       (:file "dispatch-commands-list-commands") ; list-commands + wait-for arg parsing/handlers
       (:file "dispatch-commands-auto")   ; window-nav/session-mgmt %cmd-* (find-window, refresh/lock, hooks, bind)
       (:file "dispatch-commands-auto-env") ; show-environment/set-environment helpers + %cmd-* handlers
       (:file "dispatch-commands-auto-pane") ; pane input/prefix runtime commands %cmd-* (send-keys, send-prefix)
       (:file "dispatch-commands-auto-pane-process") ; pane process/pipe runtime commands %cmd-* (respawn, pipe-pane)
       (:file "dispatch-commands-server") ; server-access ACL
       (:file "dispatch-commands-server-customize") ; customize-mode tree browser
       (:file "dispatch-commands-runner"))) ; *arg-command-table* + %run-command-tokens + %run-command-line
     (:module "dispatch-handlers-2"
      :pathname "application/dispatch/handlers"
      :serial t
      :components
      ((:file "dispatch-prefix")          ; prefix-key dispatcher, reached from presentation/events
       (:file "dispatch-handlers")        ; command handler rule table part I (detach through wait-for)
       (:file "dispatch-handlers-copy-mode") ; copy-mode command handler rule table
       (:file "dispatch-handlers-b-menu") ; popup/menu overlays
       (:file "dispatch-handlers-b-server") ; server/env/prompt-history handlers
       (:file "dispatch-handlers-b-prompt") ; prompt-driven dispatch handlers
       (:file "dispatch-handlers-b")     ; command handler rule table part II (break/join through mark/layout)
       (:file "dispatch-handlers-b-tail") ; session/window/misc handlers
       (:file "dispatch-handlers-buffer"))) ; paste-buffer command handler helpers
     (:module "presentation/events"
      :serial t
      :components
      ((:file "events-constants")  ; VT100 / mouse / CSI byte constants (pure data, no logic)
       (:file "events-core")
       (:file "events-loop-bindings") ; extended prefix key-binding table installation
       (:file "events-mouse-status") ; status bar mouse handling
       (:file "events-mouse-state") ; mouse dispatch dynamic state and pure counters
       (:file "events-mouse-layout") ; pane-border hit testing and drag resize
       (:file "events-mouse-bindings") ; mouse key names, actions, and context
       (:file "events-mouse-passthrough") ; pane X10/SGR mouse passthrough
       (:file "events-mouse-actions") ; built-in mouse actions
       (:file "events-mouse-dispatch") ; mouse event dispatch coordinator
       (:file "events-overlay-pager") ; overlay pager escape handler
       (:file "events-key-names") ; arrow/key-name fact tables and CSI-u parsing
       (:file "events-key-bindings") ; key-table lookup and binding execution
       (:file "events-keystroke-escape")  ; escape decoder coordinator + CSI-u helpers
       (:file "events-keystroke-escape-mouse") ; X10/SGR mouse escape parsing
       (:file "events-keystroke-escape-prompt") ; prompt-local ESC sequences
       (:file "events-keystroke-escape-keys") ; SS3 / CSI-tilde key-name resolution
       (:file "events-keystroke-state") ; shared dynamic state and escape-buffer utility
       (:file "events-keystroke-menu") ; active menu key dispatch rules
       (:file "events-keystroke-copy-mode") ; copy-mode digit prefix and table dispatch
       (:file "events-keystroke") ; CPS ground-state coordinator
       (:file "events-prefix-csi-continuation") ; post-prefix CSI/SS3 CPS continuation
       (:file "events-keystroke-repeat-states") ; prefix/root repeat CPS states
       (:file "events-loop-timers") ; CPS process-byte + escape/repeat timer plumbing + synchronize-panes
       (:file "events-loop")))
     (:module "bootstrap-server"
      :pathname "bootstrap"
      :serial t
      :components
      ((:file "session-registry")  ; session registry + group management
       (:file "server")
       (:file "server-multi-dispatch") ; multi-client attach/resize/key/command handlers
       (:file "server-multi")  ; multi-client client registry + dispatch helpers
       (:file "server-multi-loop") ; multi-client select-multiplexed serve loop
       (:file "runtime-lifecycle") ; atomic runtime snapshot restore/save hooks
       (:file "client-command") ; command-client I/O helpers
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

;; The two cold-path read-models below are OPTIONAL systems, not part of core
;; `nerimux'.  Neither has a single call site anywhere in src/ outside its own
;; directory, so carrying them in core bought nothing at runtime while forcing
;; cl-prolog-kit and cl-dataflow-kit into the shipped binary's dependency
;; closure.  They stay in-tree because nerimux is the org's L4 testbed and these
;; are how cl-prolog-kit and cl-dataflow-kit get dogfooded; they are simply no
;; longer loaded by `(asdf:load-system "nerimux")'.
;;
;; Naming: the source systems could not reuse "nerimux/dataflow" — that name was
;; already taken by the cl-weave TEST system below, and renaming it would break
;; the documented NERIMUX_TEST_SYSTEM values in README.md and run-tests.lisp.
;; Hence nerimux/dataflow-model (source) alongside nerimux/dataflow (test).

(defsystem "nerimux/reasoning"
  :description "Prolog-backed cold-path reasoning read-model (keys, commands)."
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.2.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  ;; Needs the whole `nerimux' system, not just nerimux/config: command-rulebase
  ;; reaches *COMMAND-USAGE-TABLE* out of the NERIMUX package with find-symbol,
  ;; which no compiler-visible edge records.  This :depends-on is the only thing
  ;; guaranteeing that symbol exists by the time the rulebase runs.
  :depends-on ("nerimux" "cl-prolog-kit")
  :pathname "src/reasoning"
  :serial t
  :components ((:file "package")
               (:file "key-rulebase")
               (:file "key-tables")
               (:file "command-rulebase")))

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

;; cl-weave regression suite for the reasoning read-model.  It exercises the
;; reasoning API through custom cl-weave matchers and reuses cl-prolog-kit's own
;; cl-weave bridge (`cl-prolog-kit/weave:deftest-queries') for raw Prolog queries.
;; Run with: (asdf:test-system :nerimux/weave)
(defsystem "nerimux/weave"
  :description "cl-weave suite for the nerimux Prolog reasoning read-model."
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.2.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  :depends-on ("nerimux" "nerimux/reasoning" "cl-weave" "cl-prolog-kit" "cl-prolog-kit/weave")
  :pathname "t/weave"
  :serial t
  :components ((:file "package")
               (:file "support")
               (:file "matchers")
               (:file "key-reasoning-tests")
               (:file "entry"))
  :perform (test-op (op c)
             (declare (ignore op c))
             (unless (funcall (find-symbol "RUN-WEAVE-TESTS" (find-package "NERIMUX/WEAVE-TESTS")))
               (error "nerimux cl-weave suite failed."))))

;; cl-weave regression suite for the cl-dataflow-kit copy-mode lifecycle
;; read-model (src/dataflow/), mirroring nerimux/weave above.
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

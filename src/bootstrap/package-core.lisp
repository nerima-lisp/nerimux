(defpackage #:cl-tmux/config
  (:use #:cl)
  (:documentation
   "APPLICATION layer: everything that turns a .tmux.conf into runtime state.  Two
    concerns share the package because the config file is the only writer of the
    second: directive loading (tokenizer, %if/%elif preprocessor, source-file
    recursion, set-option routing) and the key-table store that maps a key in a
    named table to the command string it runs.")
  (:export
   #:+prefix-key-code+
   #:+ctrl-mask+
   ;; Standard key-table name constants
   #:+table-prefix+
   #:+table-root+
   #:+table-copy-mode+
   #:+table-copy-mode-vi+
   #:*default-shell*
   #:*status-height*
   #:+pty-buf-size+
   #:+max-scrollback-lines+
   #:+poll-timeout-us+
   #:+accept-timeout-us+
   #:+pty-poll-timeout-us+
   #:define-initial-key-bindings
   #:lookup-key-binding
   #:describe-key-bindings
   #:describe-key-bindings-for-table
   #:describe-key-bindings-for-key
   ;; Key-table system
   #:*key-tables*
   #:ensure-key-table
   #:key-table-bind
   #:describe-key-binding-notes
   #:key-display-string
   #:key-table-unbind
   #:key-table-lookup
   #:key-table-command
   #:key-table-repeatable-p
   #:key-table-note
   #:copy-mode-count-command-p
   #:initialize-default-key-tables
   #:load-config-file
   #:load-config-from-stream
   #:load-config-from-string
   #:source-files
   #:apply-config-directive
   #:apply-option-side-effects
   #:config-file-path
   ;; -f startup-flag override (set by the cl-cli global-option parser in
   ;; main-startup-flags.lisp), consulted first by config-file-path.
   #:*config-file-override*
   ;; cl-boundary-kit process boundary shared by config-time shell directives
   ;; and run-shell/if-shell (commands-shell.lisp); see
   ;; config-directives-runtime-services.lisp.
   #:*process-boundary*
   ;; %if condition evaluator hook (set by top-level package)
   #:*config-condition-evaluator*
   ;; Mouse-reporting callback hook (set by orchestrate/events-loop layer)
   #:*mouse-reporting-hook*
   ;; Dynamic prefix key (primary and secondary)
   #:*prefix-key-code*
   #:*prefix2-key-code*
   #:%parse-prefix-key
   ;; ORCHESTRATE-layer shell initializer
   #:init-default-shell
   ;; Lazy SB-POSIX symbol lookup (shared with cl-tmux/model's process
   ;; environment helpers, which used to carry their own identical copy)
   #:find-posix-function))

;; No :import-from for the sibling kits: every descriptor-level operator in
;; src/infrastructure/pty/ is written qualified (cl-tty-kit:, process-kit:,
;; sb-posix:), which is what makes the system-call surface legible. This used to
;; say the same about cffi:, which cl-tmux no longer depends on.
(defpackage #:cl-tmux/pty
  (:use #:cl)
  (:documentation
   "INFRASTRUCTURE layer: the pseudo-terminal device itself.  Forks a shell under a
    PTY, moves octets across the master fd, drives termios raw mode and TIOCSWINSZ
    geometry, and multiplexes readiness with select(2) — cl-tmux needs to poll PTY,
    socket, and stdin fds together, which is the one libc call sb-posix does not
    expose.  Supplies the concrete adapters that install-pty-port stores into
    cl-tmux/ports.")
  (:export
   ;; PTY lifecycle
   #:forkpty-with-shell    ; (rows cols) → (values master-fd child-pid slave-path)
   #:pty-write             ; (fd data)   — write octets/string to PTY
   #:pty-read-blocking     ; (fd size)   → octet-vector or nil on EOF
   #:pty-read-blocking-into ; (fd buffer) → octet-vector or nil; reuses BUFFER
   #:pty-close             ; (fd pid)
   #:pty-child-exit-status ; (fd &optional timeout) → (values code :exited|:signaled) or NIL
   #:set-pty-size          ; (fd rows cols)
   ;; Terminal raw mode
   #:enable-raw-mode!      ; (fd)
   #:disable-raw-mode!     ; (fd)
   ;; Multiplexed I/O
   #:select-fds            ; (fds timeout-us) → ready-fd-list
   ;; Terminal geometry
   #:terminal-size         ; () → (values rows cols)
   #:+default-term-rows+   ; fallback terminal rows when ioctl fails/is unavailable
   #:+default-term-cols+   ; fallback terminal columns when ioctl fails/is unavailable
   ;; Port adapter (installs cl-tmux/ports vars at server startup)
   #:install-pty-port))

;;; ── Client/server wire protocol ──────────────────────────────────────────

(defpackage #:cl-tmux/protocol
  (:use #:cl)
  (:documentation
   "INFRASTRUCTURE layer: the client/server wire format, as a pure codec.  Encodes
    and decodes the frames a detached client exchanges with the server — keystrokes
    and resizes upstream, rendered frames downstream — plus the delimiter-separated
    command payload.  Deliberately holds no sockets and no global state, so the
    format is unit-testable without a server; the I/O sits in cl-tmux/transport.")
  (:export
   ;; Message type tags + header size
   #:+msg-attach+ #:+msg-key+ #:+msg-resize+ #:+msg-detach+ #:+msg-frame+ #:+msg-bye+
   #:+msg-command+ #:+msg-reply+
   #:+header-size+
   ;; Frame layout constants
   #:+payload-length-offset+
   #:+attach-flag-read-only+
   #:+attach-flags-offset+
   #:+cols-offset-in-size-payload+
   ;; Frame codec
   #:encode-frame #:decode-frame
   ;; Typed message constructors
   #:msg-attach #:msg-key #:msg-resize #:msg-detach #:msg-frame #:msg-bye
   #:msg-command #:msg-reply #:decode-attach-flags
   ;; Command message codec (protocol-command.lisp, same package)
   #:+field-delimiter+
   #:encode-command-payload #:decode-command-payload #:target-field-p
   ;; Command payload helpers — exported as stable API so tests use single-colon access
   #:split-on-nul-bytes #:command-name-to-string
   #:assemble-command-fields #:encode-fields-to-buffer
   ;; Payload decoders + octet helpers
   #:decode-size #:decode-text #:to-octets
   ;; Integer codec helpers (exported so tests can use single-colon access)
   #:u16-octets #:u32-octets #:u16-octets-pair #:read-u16 #:read-u32))

;;; ── Client/server stream transport ───────────────────────────────────────

(defpackage #:cl-tmux/transport
  (:use #:cl)
  ;; Four names out of the codec's forty: the header size and payload-length
  ;; offset needed to know how much to read, the length decoder, and DECODE-FRAME.
  ;; Everything else in cl-tmux/protocol is for packet authors, not for the pipe.
  (:import-from #:cl-tmux/protocol
                #:+header-size+
                #:+payload-length-offset+
                #:read-u32
                #:decode-frame)
  (:documentation
   "INFRASTRUCTURE layer: the impure shell around the cl-tmux/protocol codec.  Moves
    whole frames across any binary stream — a socket stream in production, a
    temp-file stream in tests — under a wall-clock budget that keeps a hung peer
    from blocking a reader forever.  Does no framing of its own.")
  (:export
   #:send-frame            ; (stream octets)          — write one frame + flush
   #:read-frame            ; (stream) → (values type payload) or NIL at EOF
   #:with-incoming-frame)) ; macro — read + Prolog-dispatch one frame from a stream

(defpackage #:cl-tmux/net
  (:use #:cl)
  (:documentation
   "INFRASTRUCTURE layer: the Unix-domain socket underneath detach-attach.  Thin
    wrappers over sb-bsd-sockets so the server and client loops speak in terms of
    make-listener / accept-connection / connect-to and a binary stream rather than
    the raw contrib API, and so tests can ask whether the transport is available at
    all before exercising it.")
  (:export
   #:make-listener #:accept-connection #:connect-to
   #:socket-stream #:socket-fd #:close-socket
   #:unix-socket-available-p))

;;; ── Terminal sub-packages ────────────────────────────────────────────────

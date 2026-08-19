(in-package #:nerimux/test)

;;;; Dispatch coverage for format variables.

(describe "dispatch-suite"

  ;; #{session_grouped}/#{session_group_size}/#{session_group_list} expand from
  ;; the group registry; ungrouped sessions report 0/empty.
  (it "session-group-format-vars"
    (let ((nerimux::*session-groups* nil))
      (with-fake-session (s1)
        (with-fake-session (s2)
          (setf (nerimux/model:session-name s1) "ga"
                (nerimux/model:session-name s2) "gb")
          (flet ((expand (spec sess)
                   (nerimux/format:expand-format
                    spec (nerimux/format:format-context-from-session
                          sess (nerimux/model:session-active-window sess) nil))))
            (expect (string= "0" (expand "#{session_grouped}" s1)))
            (nerimux::server-new-session-in-group s2 s1)
            (expect (string= "1" (expand "#{session_grouped}" s1)))
            (expect (string= "2" (expand "#{session_group_size}" s1)))
            (let ((names (expand "#{session_group_list}" s1)))
              (expect (and (search "ga" names) (search "gb" names)))))))))

  ;; #{pane_start_command}/#{pane_start_path} expand from the pane spawn record;
  ;; #{socket_path} is empty in standalone mode and reflects the bound socket.
  (it "pane-start-and-socket-format-vars"
    (with-fake-session (s)
      (let* ((win  (nerimux/model:session-active-window s))
             (pane (nerimux/model:window-active-pane win)))
        (setf (nerimux/model:pane-start-command pane) "htop"
              (nerimux/model:pane-start-path pane) "/tmp/start-here")
        (flet ((expand (spec)
                 (nerimux/format:expand-format
                  spec (nerimux/format:format-context-from-session s win pane))))
          (expect (string= "htop" (expand "#{pane_start_command}")))
          (expect (string= "/tmp/start-here" (expand "#{pane_start_path}")))
          (let ((nerimux::*bound-socket-path* nil))
            (expect (string= "" (expand "#{socket_path}"))))
          (let ((nerimux::*bound-socket-path* "/tmp/nerimux-1/x.sock"))
            (expect (string= "/tmp/nerimux-1/x.sock" (expand "#{socket_path}"))))))))

  ;; #{window_stack_index} reflects the session MRU stack; refresh-client -f
  ;; sets #{client_flags} ('!' removes).
  (it "window-stack-index-and-client-flags-vars"
    (with-fake-session (s :nwindows 2)
      (let* ((wins (nerimux/model:session-windows s))
             (w0 (first wins)) (w1 (second wins)))
        (nerimux/model:session-select-window s w0)
        (nerimux/model:session-select-window s w1)
        (flet ((expand (spec win)
                 (nerimux/format:expand-format
                  spec (nerimux/format:format-context-from-session s win nil))))
          (expect (string= "0" (expand "#{window_stack_index}" w1)))
          (expect (string= "1" (expand "#{window_stack_index}" w0)))
          (let ((nerimux::*client-flags* nil))
            (nerimux::%cmd-refresh-client-arg s '("-f" "no-output,read-only"))
            (expect (string= "no-output,read-only"
                             (expand "#{client_flags}" w1)))
            (nerimux::%cmd-refresh-client-arg s '("-f" "!read-only"))
            (expect (string= "no-output" (expand "#{client_flags}" w1)))))))))

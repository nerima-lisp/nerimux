(in-package #:nerimux/terminal/parser)

(defun make-osc-st-k (buffer &optional raw-buffer)
  "Return a continuation waiting for the backslash of ESC \\ (String Terminator).
   BUFFER is the accumulated OSC payload so far.
   On backslash: dispatch the payload and return ground-state.
   On any other byte: return ground-state without dispatching (malformed ST)."
  (lambda (screen-arg byte)
    (declare (type screen screen-arg)
             (type (unsigned-byte 8) byte))
    (when (= byte #x5C)
      (when raw-buffer
        (vector-push-extend byte raw-buffer))
      (%dispatch-osc screen-arg buffer raw-buffer))
    #'ground-state))

(defun make-osc-k (buffer &optional raw-buffer)
  "Return a continuation that accumulates OSC payload bytes into BUFFER.
   Dispatches to %DISPATCH-OSC on BEL (#x07) or the start of ESC \\ termination."
  (lambda (screen-arg byte)
    (declare (type screen screen-arg) (type (unsigned-byte 8) byte))
    (cond
      ((= byte #x07)
       (when raw-buffer
         (vector-push-extend byte raw-buffer))
       (%dispatch-osc screen-arg buffer raw-buffer)
       #'ground-state)
      ((= byte #x1B)
       (when raw-buffer
         (vector-push-extend byte raw-buffer))
       (make-osc-st-k buffer raw-buffer))
      (t
       (vector-push-extend byte buffer)
       (when raw-buffer
         (vector-push-extend byte raw-buffer))
       (make-osc-k buffer raw-buffer)))))

(in-package #:nerimux/terminal/parser)

(define-state ground-state (screen byte)
  (#x1B  #'escape-state)
  (#x0D  (cursor-cr screen) #'ground-state)
  (#x0A  (cursor-nl screen) #'ground-state)        ; LF — +CR under LNM (mode 20)
  (#x0B  (cursor-nl screen) #'ground-state)        ; VT treated as LF
  (#x0C  (cursor-nl screen) #'ground-state)        ; FF treated as LF
  (#x08  (cursor-bs screen) #'ground-state)
  (#x09  (cursor-ht screen) #'ground-state)
  (#x07  (set-bell-pending screen)
         #'ground-state)                           ; BEL — set pending flag
  (#x7F  #'ground-state)                           ; DEL — ignore
  (#x0E  (invoke-charset screen :g1) #'ground-state) ; SO — invoke G1 (locking shift out)
  (#x0F  (invoke-charset screen :g0) #'ground-state) ; SI — invoke G0 (locking shift in)
  (printable-ascii-p
   (write-char-at-cursor screen (code-char byte))
   #'ground-state)
  (utf8-lead-p
   (multiple-value-bind (code-point-accumulator continuation-bytes-remaining)
       (utf8-lead-decode byte)
     (make-utf8-k code-point-accumulator continuation-bytes-remaining)))
  ((>= byte #x80)
   (write-codepoint screen #xFFFD)
   #'ground-state)
  (t #'ground-state))

(define-state escape-state (screen byte)
  (#x5B  (make-csi-k '() nil nil))                ; ESC [ → CSI
  (#x5D  #'osc-state)                              ; ESC ] → OSC
  (#x50  (make-dcs-k))                             ; ESC P → DCS (passthrough tag or discard)
  (#x4D  (cursor-ri screen)    #'ground-state)    ; ESC M → RI
  (#x63  (ris-action screen)   #'ground-state)    ; ESC c → RIS
  (#x37  (save-cursor screen)    #'ground-state)  ; ESC 7 → DECSC
  (#x38  (restore-cursor screen) #'ground-state)  ; ESC 8 → DECRC
  (#x44  (cursor-lf  screen)     #'ground-state)  ; ESC D → IND (index: down, no CR)
  (#x45  (cursor-nel screen)     #'ground-state)  ; ESC E → NEL (next line: CR+LF)
  (#x48  (set-tab-stop screen)   #'ground-state)  ; ESC H → HTS (set tab stop)
  (#x28  (make-charset-designator-k :g0))          ; ESC ( → designate G0
  (#x29  (make-charset-designator-k :g1))          ; ESC ) → designate G1
  (#x2A  (make-charset-designator-k :g2))          ; ESC * → designate G2
  (#x2B  (make-charset-designator-k :g3))          ; ESC + → designate G3
  (#x6E  (invoke-charset screen :g2) #'ground-state)             ; ESC n → LS2
  (#x6F  (invoke-charset screen :g3) #'ground-state)             ; ESC o → LS3
  (#x4E  (setf (screen-single-shift screen) :g2) #'ground-state) ; ESC N → SS2
  (#x4F  (setf (screen-single-shift screen) :g3) #'ground-state) ; ESC O → SS3
  (#x20  (make-ignore-final-byte-k))               ; ESC SP <f> → S7C1T/S8C1T/ANSI level
  (#x25  (make-ignore-final-byte-k))               ; ESC % <f> → charset selection (UTF-8)
  (#x23  (make-hash-line-size-k))                  ; ESC # → DEC line-size selector
  (t     #'ground-state))

(define-state osc-state (screen byte)
  (#x07  #'ground-state)                           ; bare BEL with empty payload
  (#x1B  #'osc-st-state)                           ; possible ST = ESC \ with empty payload
  (t     (let ((payload-buffer (make-array 64
                                           :element-type '(unsigned-byte 8)
                                           :fill-pointer 0
                                           :adjustable t)))
           (vector-push-extend byte payload-buffer)
           (make-osc-k payload-buffer))))

(define-state osc-st-state (screen byte)
  (#x5C  #'ground-state)                           ; \ → ST confirmed (empty payload)
  (t     #'osc-state))

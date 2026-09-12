(in-package #:nerimux/renderer)

(defstruct transient-view
  "One open transient menu. ARGUMENTS is a list of (KEY FLAG DESCRIPTION
   ACTIVE-P TRANSIENT-KEY) and ACTIONS a list of (KEY DESCRIPTION HANDLER) --
   one element longer, in both cases, than the contract's documented (KEY FLAG
   DESCRIPTION ACTIVE-P) / (KEY DESCRIPTION) shape. This renderer only ever
   reads the first four / first two elements positionally (see the drawing
   helpers below), so the trailing element -- the flag's owning transient key,
   and the action's dispatch HANDLER, respectively -- rides along harmlessly
   for server-multi-dispatch-transient.lisp, which needs it to persist toggle
   state and run an action without a second lookup, and has no other slot to
   keep it in without a new cross-package export."
  (title "" :type string)
  (subtitle nil)
  (arguments nil :type list)
  (actions nil :type list))

(defun %transient-title-style ()
  (cl-tui-kit/core:make-style :bold
                              t
                              :foreground
                              (cl-tui-kit/core:rgb-color 139 233 253)))

(defun %transient-subtitle-style ()
  (cl-tui-kit/core:make-style :foreground
                              (cl-tui-kit/core:rgb-color 98 114 164)))

(defun %transient-section-style ()
  (cl-tui-kit/core:make-style :bold
                              t
                              :foreground
                              (cl-tui-kit/core:rgb-color 189 147 249)))

(defun %transient-key-style ()
  (cl-tui-kit/core:make-style :foreground
                              (cl-tui-kit/core:rgb-color 139 233 253)))

(defun %transient-argument-active-style ()
  (cl-tui-kit/core:make-style :foreground
                              (cl-tui-kit/core:rgb-color 80 250 123)))

(defun %transient-argument-inactive-style ()
  (cl-tui-kit/core:make-style :foreground
                              (cl-tui-kit/core:rgb-color 98 114 164)))

(defun %transient-pad (text width)
  "TEXT padded with spaces to WIDTH display columns.  Never truncates -- every
   text this is called on is already sized into WIDTH by the column-width
   helpers below, so a shortfall here would signal a computation bug rather
   than genuinely overlong content."
  (let ((pad (- width (%display-width text))))
    (if (plusp pad)
        (concatenate 'string text (make-string pad :initial-element #\Space))
        text)))

(defun %transient-column-width (texts gutter)
  (+ gutter (reduce #'max texts :key #'%display-width :initial-value 0)))

(defun %transient-argument-key-text (entry)
  (format nil "-~C" (first entry)))

(defun %transient-action-key-text (entry)
  (string (first entry)))

(defun %transient-action-key-width (actions)
  (%transient-column-width (mapcar #'%transient-action-key-text actions) 3))

(defun %transient-action-cell-width (actions)
  "Display columns one action cell needs: its key column plus the widest
   description, with the gutter that separates two cells."
  (+ 2
     (%transient-action-key-width actions)
     (%transient-column-width (mapcar #'second actions) 0)))

(defun %transient-action-columns (actions width)
  "Action cells side by side in WIDTH -- two when both fit, otherwise one."
  (if (and (> (length actions) 1)
           (<= (* 2 (%transient-action-cell-width actions)) width))
      2
      1))

(defun %transient-action-row-count (actions width)
  (ceiling (length actions) (%transient-action-columns actions width)))

(defun %transient-draw-title-line (surface row col width view title-line-p)
  "The panel's first line: the title with its subtitle beside it, or -- when
   the panel's own border already carries the title -- the subtitle alone."
  (let ((spans
         (append
          (when title-line-p
            (list
             (cl-tui-kit/core:make-text-span (transient-view-title view)
                                             :style
                                             (%transient-title-style))))
          (when (transient-view-subtitle view)
            (list
             (cl-tui-kit/core:make-text-span
              (if title-line-p
                  (format nil "  ~A" (transient-view-subtitle view))
                  (transient-view-subtitle view))
              :style
              (%transient-subtitle-style)))))))
    (cl-tui-kit/core:surface-draw-styled-text surface
                                              col
                                              row
                                              spans
                                              :max-width
                                              width)))

(defun %transient-draw-section-heading (surface row col width text)
  (cl-tui-kit/core:surface-draw-styled-text surface
                                            col
                                            row
                                            (list
                                             (cl-tui-kit/core:make-text-span
                                              text
                                              :style
                                              (%transient-section-style)))
                                            :max-width
                                            width))

(defun %transient-draw-argument-row (surface row
                                             col
                                             width
                                             entry
                                             key-width)
  "ENTRY is (KEY FLAG DESCRIPTION ACTIVE-P . REST) -- see TRANSIENT-VIEW's
   docstring for why a longer list is fine here: DESCRIPTION (third) is what
   is shown, FLAG (second) is what server-multi-dispatch-transient.lisp
   assembles into the actual git argument list. Magit shows an argument's
   state by colour alone, so an active one is highlighted rather than tagged
   with a checkbox."
  (let* ((key-text (%transient-argument-key-text entry))
         (description (third entry))
         (active-p (fourth entry)))
    (cl-tui-kit/core:surface-draw-styled-text surface
                                              col
                                              row
                                              (list
                                               (cl-tui-kit/core:make-text-span
                                                (%transient-pad key-text
                                                                key-width)
                                                :style
                                                (%transient-key-style))
                                               (cl-tui-kit/core:make-text-span
                                                description
                                                :style
                                                (if active-p
                                                    (%transient-argument-active-style)
                                                    (%transient-argument-inactive-style))))
                                              :max-width
                                              width)))

(defun %transient-draw-action-row (surface row col width entry key-width)
  "ENTRY is (KEY DESCRIPTION . REST) -- REST is the dispatch HANDLER, unread
   here; see TRANSIENT-VIEW's docstring."
  (let ((key-text (%transient-action-key-text entry))
        (description (second entry)))
    (cl-tui-kit/core:surface-draw-styled-text surface
                                              col
                                              row
                                              (list
                                               (cl-tui-kit/core:make-text-span
                                                (%transient-pad key-text
                                                                key-width)
                                                :style
                                                (%transient-key-style))
                                               (cl-tui-kit/core:make-text-span
                                                description))
                                              :max-width
                                              width)))

(defun transient-view-height (transient-view &optional (title-line-p t) (width 0))
  "Rows TRANSIENT-VIEW wants: the title/subtitle line, an optional Arguments
   heading + one row per argument, the Actions heading + one row per action,
   and a trailing \"q back\" line. TITLE-LINE-P NIL is the bordered-panel
   caller, whose border carries the title: that line is then kept only for a
   subtitle. WIDTH is the width the actions get, which decides whether they
   are laid out in one column or two; the default 0 is the one-column answer.
   The caller clamps this against what the frame can spare, and
   RENDER-TRANSIENT-PANEL clips whatever does not fit."
  (+ (if (or title-line-p (transient-view-subtitle transient-view))
         1
         0)
     (if (transient-view-arguments transient-view)
         (1+ (length (transient-view-arguments transient-view)))
         0)
     1
     (%transient-action-row-count (transient-view-actions transient-view)
                                  width)
     1))

(defun render-transient-panel (surface rectangle transient-view
                                       &optional (title-line-p t))
  "Draw TRANSIENT-VIEW into RECTANGLE, top to bottom, clipping (rather than
   scrolling or erroring) once RECTANGLE runs out of rows -- same policy as
   %DRAW-HELP-VIEW-SECTION. This is the panel body only: no border, no
   background fill of its own, so it composes with whatever the caller
   already put on the surface around RECTANGLE. TITLE-LINE-P NIL suppresses
   the title line for a caller whose border carries the title instead."
  (let* ((x (cl-tui-kit/core:rectangle-x rectangle))
         (y (cl-tui-kit/core:rectangle-y rectangle))
         (width (cl-tui-kit/core:rectangle-width rectangle))
         (max-row (1- (+ y (cl-tui-kit/core:rectangle-height rectangle))))
         (arguments (transient-view-arguments transient-view))
         (actions (transient-view-actions transient-view))
         (row y))
    (flet ((room-p ()
             (<= row max-row))
           (heading-width ()
             (max 0 (- width 1)))
           (item-width ()
             (max 0 (- width 2))))
      (when (and (room-p)
                 (or title-line-p (transient-view-subtitle transient-view)))
        (%transient-draw-title-line surface
                                    row
                                    (1+ x)
                                    (heading-width)
                                    transient-view
                                    title-line-p)
        (incf row))
      (when arguments
        (when (room-p)
          (%transient-draw-section-heading surface
                                           row
                                           (1+ x)
                                           (heading-width)
                                           "Arguments")
          (incf row))
        (let ((key-width
               (%transient-column-width
                (mapcar #'%transient-argument-key-text arguments)
                2)))
          (dolist (entry arguments)
            (when (room-p)
              (%transient-draw-argument-row surface
                                            row
                                            (+ x 2)
                                            (item-width)
                                            entry
                                            key-width)
              (incf row)))))
      (when (room-p)
        (%transient-draw-section-heading surface
                                         row
                                         (1+ x)
                                         (heading-width)
                                         "Actions")
        (incf row))
      (let* ((key-width (%transient-action-key-width actions))
             (cell-width (%transient-action-cell-width actions))
             (line-count (%transient-action-row-count actions (item-width))))
        (loop for entry in actions
              for index from 0
              for column = (floor index line-count)
              for line = (+ row (mod index line-count))
              do (when (<= line max-row)
                   (%transient-draw-action-row surface
                                               line
                                               (+ x 2 (* column cell-width))
                                               (max 0
                                                    (- (item-width)
                                                       (* column cell-width)))
                                               entry
                                               key-width)))
        (incf row line-count))
      (when (room-p)
        (cl-tui-kit/core:surface-draw-styled-text surface
                                                  (1+ x)
                                                  row
                                                  (list
                                                   (cl-tui-kit/core:make-text-span
                                                    "q"
                                                    :style
                                                    (%transient-key-style))
                                                   (cl-tui-kit/core:make-text-span
                                                    " back"))
                                                  :max-width
                                                  (heading-width))))))

(defun render-transient-panel-to-tui-string (transient-view rows
                                                            cols
                                                            &optional
                                                            base-frame)
  "TRANSIENT-VIEW as a bordered panel anchored at the frame's bottom edge,
   tall enough for its content and no taller, labelled with the transient's
   own title. BASE-FRAME, when the caller passes the frame of the view the
   transient was opened from, stays visible above the panel; without it the
   rows above the panel are blank."
  (let* ((rows (max 1 rows))
         (cols (max 1 cols))
         (surface (%panel-base-surface base-frame rows cols))
         (rectangle
          (%bottom-panel-rectangle rows
                                   cols
                                   (transient-view-height transient-view
                                                          nil
                                                          (- cols 4)))))
    (render-transient-panel surface
                            (%draw-panel-frame surface
                                               rectangle
                                               (transient-view-title
                                                transient-view))
                            transient-view
                            nil)
    (%surface-to-ansi-frame surface)))

(defstruct (read-view (:constructor make-read-view (title content)))
  title
  content
  (offset 0 :type fixnum)
  query
  widget)

(defun %read-view-widget (view rows cols)
  (let ((widget (or (read-view-widget view)
                    (setf (read-view-widget view)
                          (cl-tui-kit/widgets:make-text-view-widget
                           (read-view-content view)
                           :wrap-p nil
                           :offset (read-view-offset view)
                           :focusable-p nil
                           :semantic-role :document)))))
    (setf (cl-tui-kit/widgets:text-view-widget-text widget)
          (read-view-content view))
    (cl-tui-kit/widgets:widget-layout
     widget
     (cl-tui-kit/core:make-rectangle 0
                                     0
                                     (max 1 cols)
                                     (max 1 (- rows 2))))
    widget))

(defun read-view-scroll-by (view rows cols amount)
  (let ((widget (%read-view-widget view rows cols)))
    (cl-tui-kit/widgets:text-view-widget-scroll-by widget amount)
    (setf (read-view-offset view)
          (cl-tui-kit/widgets:text-view-widget-offset widget))))

(defun read-view-find (view rows cols query)
  (let ((widget (%read-view-widget view rows cols)))
    (cl-tui-kit/widgets:text-view-widget-find widget query)
    (setf (read-view-query view) query
          (read-view-offset view)
          (cl-tui-kit/widgets:text-view-widget-offset widget))))

(defun %read-view-footer (view)
  (if (read-view-query view)
      (format nil "/~A  j/k move  C-u/C-d half page  q close"
              (read-view-query view))
      "j/k move  C-u/C-d half page  / search  q close"))

(defun %prompt-placeholder-style ()
  (cl-tui-kit/core:make-style :foreground
                              (cl-tui-kit/core:rgb-color 98 114 164)))

(defun %draw-prompt-widget (surface rectangle widget)
  "Render WIDGET into RECTANGLE. With nothing typed yet the cursor cell sits
   at column 0, where cl-tui-kit's input widget draws it over the
   placeholder's first character and its textarea draws no placeholder at
   all, so the placeholder is (re)drawn one column right of the cursor."
  (cl-tui-kit/widgets:render-widget widget surface rectangle)
  (let ((placeholder
         (and (zerop (length (cl-tui-kit/widgets:input-widget-value widget)))
              (cl-tui-kit/widgets:input-widget-placeholder widget))))
    (when (plusp (length placeholder))
      (cl-tui-kit/core:surface-draw-text surface
                                         (1+ (cl-tui-kit/core:rectangle-x
                                              rectangle))
                                         (cl-tui-kit/core:rectangle-y rectangle)
                                         placeholder
                                         :style
                                         (%prompt-placeholder-style)
                                         :max-width
                                         (max 0
                                              (1-
                                               (cl-tui-kit/core:rectangle-width
                                                rectangle)))))))

(defun %draw-read-view-search-panel (surface rows cols search-widget)
  "The read view's search box: a bottom panel holding the query line the user
   types into and the keys that end it."
  (let* ((inner (%panel-text-rectangle
                 (%draw-panel-frame surface
                                    (%bottom-panel-rectangle rows cols 2)
                                    "Search")))
         (col (cl-tui-kit/core:rectangle-x inner))
         (row (cl-tui-kit/core:rectangle-y inner))
         (width (cl-tui-kit/core:rectangle-width inner)))
    (%draw-prompt-widget surface
                         (cl-tui-kit/core:make-rectangle col row width 1)
                         search-widget)
    (cl-tui-kit/core:surface-draw-text surface
                                       col
                                       (1+ row)
                                       "Enter accept  Esc cancel"
                                       :max-width
                                       width)))

(defun render-read-view-to-tui-string (view rows cols &optional search-widget)
  (let* ((rows (max 4 rows))
         (cols (max 1 cols))
         (surface (cl-tui-kit/core:make-surface cols rows))
         (rectangle (cl-tui-kit/core:make-rectangle 0 0 cols rows))
         (content-rectangle
           (cl-tui-kit/core:make-rectangle 0 0 cols (max 1 (- rows 2))))
         (widget (%read-view-widget view rows cols)))
    (let ((box (cl-tui-kit/widgets:make-box-widget
                widget
                :id :nerimux-read-view-box
                :border-kind :single)))
      (cl-tui-kit/widgets:render-widget box surface content-rectangle))
    (%stamp-panel-title surface rectangle (read-view-title view))
    (if search-widget
        (%draw-read-view-search-panel surface rows cols search-widget)
        (cl-tui-kit/core:surface-draw-text surface
                                             1
                                             (1- rows)
                                             (%read-view-footer view)
                                             :max-width
                                             (max 0 (- cols 2))))
    (setf (read-view-offset view)
          (cl-tui-kit/widgets:text-view-widget-offset widget))
    (%surface-to-ansi-frame surface)))

(defun %text-prompt-widget-rows (widget)
  "Rows the prompt gives its editor: a multiline message needs room to read
   back what was typed, a one-line answer does not."
  (if (typep widget 'cl-tui-kit/widgets:textarea-widget)
      5
      1))

(defun %text-prompt-hint (widget)
  (if (typep widget 'cl-tui-kit/widgets:textarea-widget)
      "C-s submit  Enter newline  Esc cancel"
      "Enter submit  Esc cancel"))

(defun render-text-prompt-to-tui-string (title widget rows cols
                                               &optional base-frame messages)
  "The prompt as a bordered panel anchored at the frame's bottom edge: the
   editor, then, when MESSAGES has one, the newest notification, then the
   keys that end it. BASE-FRAME, when the caller passes the frame of the
   view that asked, stays visible above the panel.
   The panel carries the message strip itself because it covers the row the
   repolist and status frames draw theirs on: `value required', raised by
   submitting the prompt empty, is a refusal of the key just pressed and was
   landing underneath the panel that refused it."
  (let* ((rows (max 1 rows))
         (cols (max 1 cols))
         (surface (%panel-base-surface base-frame rows cols))
         (widget-rows (%text-prompt-widget-rows widget))
         (message (first messages))
         (inner
          (%panel-text-rectangle
           (%draw-panel-frame surface
                              (%bottom-panel-rectangle rows
                                                       cols
                                                       (+ widget-rows
                                                          (if message 2 1)))
                              title)))
         (col (cl-tui-kit/core:rectangle-x inner))
         (row (cl-tui-kit/core:rectangle-y inner))
         (width (cl-tui-kit/core:rectangle-width inner)))
    (%draw-prompt-widget surface
                         (cl-tui-kit/core:make-rectangle col
                                                         row
                                                         width
                                                         widget-rows)
                         widget)
    (when message
      (cl-tui-kit/core:surface-draw-text surface
                                         col
                                         (+ row widget-rows)
                                         (%message-strip-text message width)
                                         :max-width
                                         width))
    (cl-tui-kit/core:surface-draw-text surface
                                       col
                                       (+ row widget-rows (if message 1 0))
                                       (%text-prompt-hint widget)
                                       :max-width
                                       width)
    (%surface-to-ansi-frame surface)))

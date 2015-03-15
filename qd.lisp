;;;; qd.lisp

(defpackage #:scalpl.qd
  (:use #:cl #:chanl #:anaphora #:local-time #:scalpl.util #:scalpl.exchange #:scalpl.actor))

(in-package #:scalpl.qd)

(defun asset-funds (asset funds)
  (aif (find asset funds :key #'asset) (scaled-quantity it) 0))

;;;
;;;  ENGINE
;;;

(defclass supplicant (parent)
  ((gate :initarg :gate) fee (market :initarg :market :reader market)
   (placed :initform nil :initarg :placed)
   (response :initform (make-instance 'channel))
   (balance-tracker :initarg :balance-tracker)
   ;; TODO (lictor :initarg :lictor)
   (order-slots :initform 40 :initarg :order-slots)))

(defun offers-spending (ope asset)
  (remove asset (slot-value ope 'placed)
          :key #'consumed-asset :test-not #'eq))

(defun balance-guarded-place (ope offer)
  (with-slots (gate placed order-slots balance-tracker) ope
    (let ((asset (consumed-asset offer)))
      (when (and (>= (asset-funds asset (slot-reduce balance-tracker balances))
                     (reduce #'+ (mapcar #'volume (offers-spending ope asset))
                             :initial-value (volume offer)))
                 (> order-slots (length placed)))
        (awhen1 (post-offer gate offer) (push it placed))))))

(defmethod execute ((supplicant supplicant) (command cons))
  (with-slots (gate response placed) supplicant
    (send response
          (ecase (car command)
            (offer (balance-guarded-place supplicant (cdr command)))
            (cancel (awhen1 (cancel-offer gate (cdr command))
                      (setf placed (remove (cdr command) placed))))))))

(defmethod initialize-instance :after ((supp supplicant) &key)
  (adopt supp (setf (slot-value supp 'fee)
                    (make-instance 'fee-tracker :delegates (list supp))))#|
  (adopt supp (setf (slot-value supp 'lictor)
                    (make-instance 'execution-tracker :delegates `(,supp))))|#)

(defmethod christen ((supplicant supplicant) (type (eql 'actor)))
  (format nil "~A" (name (slot-value supplicant 'gate))))

(defmethod christen ((supplicant supplicant) (type (eql 'task)))
  (format nil "~A supplicant" (name supplicant)))

(defun ope-placed (ope)
  (with-slots (placed) (slot-value ope 'supplicant)
    (let ((all (sort (copy-list placed) #'< :key #'price)))
      (flet ((split (sign)
               (remove sign all :key (lambda (x) (signum (price x))))))
        ;;       bids       asks
        (values (split 1) (split -1))))))

;;; response: placed offer if successful, nil if not
(defun ope-place (ope offer)
  (with-slots (control response) ope
    (send control (cons 'offer offer)) (recv response)))

;;; response: trueish = offer no longer placed, nil = unknown badness
(defun ope-cancel (ope offer)
  (with-slots (control response) (slot-value ope 'supplicant)
    (send control (cons 'cancel offer)) (recv response)))

(defclass ope-filter ()
  ((bids       :initarg :bids       :initform ())
   (asks       :initarg :asks       :initform ())
   (market     :initarg :market     :initform (error "must link market"))
   (supplicant :initarg :supplicant :initform (error "must link supplicant"))
   (frequency  :initarg :frequency  :initform 1/7) ; TODO: push depth deltas
   (lictor     :initarg :lictor     :initform (error "must link lictor"))
   (rudder     :initarg :rudder     :initform '(() . ()))
   (book-cache :initform nil)
   fee thread))

;;; TODO: deal with partially completed orders
(defun ignore-offers (open mine &aux them)
  (dolist (offer open (nreverse them))
    (aif (find (price offer) mine :test #'= :key #'price)
         (let ((without-me (- (volume offer) (volume it))))
           (setf mine (remove it mine))
           (unless (< without-me 0.001)
             (push (make-instance 'offer :market (slot-value offer 'market)
                                  :price (price offer)
                                  :volume without-me)
                   them)))
         (push offer them))))

;;; needs to do three different things
;;; 1) ignore-offers - fishes offers from linked supplicant
;;; 2) profitable spread - already does (via ecase spaghetti)
;;; 3) profit vs recent cost basis - done, shittily - TODO parametrize depth

(defun ope-filter-loop (ope)
  (with-slots (market book-cache bids asks frequency) ope
    (let ((book (recv (slot-reduce market book-tracker output))))
      (unless (eq book book-cache)
        (with-slots (placed) (slot-value ope 'supplicant)
          (setf book-cache book
                bids (ignore-offers (cdar book) placed)
                asks (ignore-offers (cddr book) placed)))))
    (sleep frequency)))

(defmethod shared-initialize :around ((ope ope-filter) (slots t) &key)
  (call-next-method)                    ; this is an after-after method...
  (with-slots (fee thread market) ope
    (when (or (not (slot-boundp ope 'thread))
              (eq :terminated (task-status thread)))
      (setf thread
            (pexec (:name (concatenate
                           'string "qdm-preα ope filter for " (name market)))
              (loop (ope-filter-loop ope)))))))

(defclass ope-prioritizer ()
  ((next-bids :initform (make-instance 'channel))
   (next-asks :initform (make-instance 'channel))
   (response :initform (make-instance 'channel))
   (supplicant :initarg :supplicant) thread
   (frequency :initarg :frequency :initform 1/7)))

(defun prioriteaze (ope target placed &aux to-add (excess placed))
  (flet ((place (new) (ope-place (slot-value ope 'supplicant) new)))
    (macrolet ((frob (add pop)
                 `(let* ((n (max (length ,add) (length ,pop)))
                         (m (- n (ceiling (log (1+ (random (1- (exp n)))))))))
                    (macrolet ((wrap (a . b) `(awhen (nth m ,a) (,@b it))))
                      (wrap ,pop ope-cancel ope) (wrap ,add place)))))
      (aif (dolist (new target (sort to-add #'< :key #'price))
             (aif (find (price new) excess :key #'price :test #'=)
                  (setf excess (remove it excess)) (push new to-add)))
           (frob it excess) (if excess (frob nil excess) ; yuck
                                (and target placed (frob target placed)))))))

;;; receives target bids and asks in the next-bids and next-asks channels
;;; sends commands in the control channel through #'ope-place
;;; sends completion acknowledgement to response channel
(defun ope-prioritizer-loop (ope)
  (with-slots (next-bids next-asks response frequency) ope
    (multiple-value-bind (next source)
        (recv (list next-bids next-asks) :blockp nil)
      (multiple-value-bind (placed-bids placed-asks) (ope-placed ope)
        (if (null source) (sleep frequency)
            ((lambda (side) (send response (prioriteaze ope next side)))
             (if (eq source next-bids) placed-bids placed-asks)))))))

(defun profit-margin (bid ask &optional (bid-fee 0) (ask-fee 0))
  (abs (if (= bid-fee ask-fee 0) (/ ask bid)
           (/ (* ask (- 1 (/ ask-fee 100)))
              (* bid (+ 1 (/ bid-fee 100)))))))

(defun dumbot-offers (foreigners       ; w/ope-filter to avoid feedback
                      resilience       ; scalar•asset target offer depth to fill
                      funds            ; scalar•asset target total offer volume
                      epsilon          ; scalar•asset size of smallest order
                      max-orders       ; target amount of offers
                      magic            ; if you have to ask, you'll never know
                      &aux (acc 0) (share 0) (others (copy-list foreigners))
                        (asset (consumed-asset (first others))))
  (do* ((remaining-offers others (rest remaining-offers))
        (processed-tally    0    (1+   processed-tally)))
       ((or (null remaining-offers)  ; EITHER: processed entire order book
            (and (> acc resilience)  ;     OR: (   BOTH: processed past resilience
                 (> processed-tally max-orders))) ; AND: processed enough orders )
        (flet ((pick (count offers)
                 (sort (subseq* (sort (or (subseq offers 0 (1- processed-tally))
                                          (warn "~&FIXME: GO DEEPER!~%") offers)
                                      #'> :key (lambda (x) (volume (cdr x))))
                               0 count) #'< :key (lambda (x) (price (cdr x)))))
               (offer-scaler (total bonus count)
                 (lambda (order &aux (vol (* funds (/ (+ bonus (car order))
                                                      (+ total (* bonus count))))))
                   (with-slots (market price) (cdr order)
                     (make-instance 'offer :market market :price (1- price)
                                    :volume vol :given (cons-aq* asset vol))))))
          (let* ((target-count (min (floor (/ funds epsilon 4/3)) ; ygni! wut?
                                    max-orders processed-tally))
                 (chosen-stairs         ; the (shares . foreign-offer)s to fight
                  (if (>= magic target-count) (pick target-count others)
                      (cons (first others) (pick (1- target-count) (rest others)))))
                 (total-shares (reduce #'+ (mapcar #'car chosen-stairs)))
                 ;; we need the smallest order to be epsilon
                 (e/f (/ epsilon funds))
                 (bonus (if (>= 1 target-count) 0
                            (/ (- (* e/f total-shares) (caar chosen-stairs))
                               (- 1 (* e/f target-count))))))
            (break-errors (not division-by-zero) ; dbz = no funds left, no biggie
              (mapcar (offer-scaler total-shares bonus target-count)
                      chosen-stairs)))))
    ;; TODO - use a callback for liquidity distribution control
    (with-slots (volume) (first remaining-offers)
      (push (incf share (* 4/3 (incf acc volume))) (first remaining-offers)))))

(defclass ope-scalper ()
  ((input :initform (make-instance 'channel))
   (output :initform (make-instance 'channel))
   (supplicant :initarg :supplicant)
   (filter :initarg :filter)
   (epsilon :initform 0.001 :initarg :epsilon)
   (count :initform 30 :initarg :offer-count)
   (magic :initform 3 :initarg :magic-count)
   (spam :initform nil :initarg :spam)
   prioritizer thread))

(defun ope-sprinner (offers funds count magic bases punk dunk book)
  (if (or (null bases) (zerop count) (null offers)) offers
      (destructuring-bind (top . offers) offers
        (multiple-value-bind (bases vwab cost)
            ;; what appears to be the officer, problem?
            ;; (bases-without bases (given top)) fails, because bids are `viqc'
            (bases-without bases (cons-aq* (consumed-asset top) (volume top)))
          (flet ((profit (o)
                   (funcall punk (1- (price o)) (price vwab) (cdar funds))))
            (signal "~4,2@$ ~A ~D ~V$ ~V$" (profit top) top (length bases)
                    (decimals (market vwab)) (scaled-price vwab)
                    (decimals (asset cost)) (scaled-quantity cost))
            (let ((book (rest (member 0 book :test #'< :key #'profit))))
              (if (plusp (profit top))
                  `(,top ,@(ope-sprinner offers `((,(- (caar funds) (volume top))
                                                    . ,(cdar funds)))
                                         (1- count) magic bases punk dunk book))
                  (ope-sprinner (funcall dunk book funds count magic) funds
                                count magic `((,vwab ,(aq* vwab cost) ,cost)
                                              ,@bases) punk dunk book))))))))

(defun ope-logger (ope)
  (lambda (log) (awhen (slot-value ope 'spam) (format t "~&~A ~A~%" it log))))

(defun ope-spreader (book resilience funds epsilon side ope)
  (flet ((dunk (book funds count magic)
           (and book (dumbot-offers book resilience (caar funds)
                                    epsilon count magic))))
    (with-slots (count magic cut) ope
      (awhen (dunk book funds (/ count 2) magic)
        (ope-sprinner it funds (/ count 2) magic
                      (getf (slot-reduce ope filter lictor bases)
                            (asset (given (first it))))
                      (destructuring-bind (bid . ask)
                          (recv (slot-reduce ope supplicant fee output))
                        (macrolet ((punk (&rest args)
                                     `(lambda (price vwab inner-cut)
                                        (- (* 100 (1- (profit-margin ,@args)))
                                           inner-cut))))
                          (ccase side   ; give ☮ a chance!
                            (bids (punk price vwab bid))
                            (asks (punk vwab  price 0 ask)))))
                      #'dunk book)))))

(defun ope-scalper-loop (ope)
  (with-slots (input output filter prioritizer epsilon) ope
    (destructuring-bind (primary counter resilience ratio) (recv input)
      (with-slots (next-bids next-asks response) prioritizer
        (macrolet ((do-side (amount side chan epsilon)
                     `(let ((,side (copy-list (slot-value filter ',side))))
                        (unless (or (actypecase ,amount (number (zerop it))
                                               (cons (zerop (caar it))))
                                    (null ,side))
                          (send ,chan (handler-bind
                                          ((simple-condition (ope-logger ope)))
                                        (ope-spreader ,side resilience ,amount
                                                      ,epsilon ',side ope)))
                          (recv response)))))
          (do-side counter bids next-bids
                   (* epsilon (abs (price (first bids))) (max ratio 1)
                      (expt 10 (- (decimals (market (first bids)))))))
          (do-side primary asks next-asks (* epsilon (max (/ ratio) 1))))))
    (send output nil)))

(defmethod shared-initialize :after ((prioritizer ope-prioritizer) (slots t) &key)
  (with-slots (thread) prioritizer
    (when (or (not (slot-boundp prioritizer 'thread))
              (eq :terminated (task-status thread)))
      (setf thread (pexec (:name "qdm-preα ope prioritizer")
                     (loop (ope-prioritizer-loop prioritizer)))))))

(defmethod shared-initialize :after
    ((ope ope-scalper) (slots t) &key gate market balance-tracker lictor)
  (with-slots (filter prioritizer supplicant) ope
    (if (slot-boundp ope 'supplicant) (reinitialize-instance supplicant)
        (setf supplicant (make-instance 'supplicant :gate gate :market market
                                        :placed (placed-offers gate)
                                        :balance-tracker balance-tracker)))
    (if (slot-boundp ope 'prioritizer)
        (reinitialize-instance prioritizer    :supplicant supplicant)
        (setf prioritizer
              (make-instance 'ope-prioritizer :supplicant supplicant)))
    (if (slot-boundp ope 'filter) (reinitialize-instance filter)
        (setf filter (make-instance 'ope-filter :market market
                                    :lictor lictor :supplicant supplicant)))))

(defmethod shared-initialize :around ((ope ope-scalper) (slots t) &key)
  (call-next-method)                    ; another after-after method...
  (with-slots (thread) ope
    (when (or (not (slot-boundp ope 'thread))
              (eq :terminated (task-status thread)))
      (setf thread (pexec (:name "qdm-preα ope scalper")
                     (loop (ope-scalper-loop ope)))))))

;;;
;;; ACCOUNT TRACKING
;;;

(defclass account-tracker ()
  ((gate :initarg :gate)
   (treasurer :initarg :treasurer)
   (ope :initarg :ope)
   (lictor :initarg :lictor)))

(defmethod vwap ((tracker account-tracker) &rest keys)
  (apply #'vwap (slot-value tracker 'lictor) keys))

(defmethod shared-initialize :after
    ((tracker account-tracker) (names t) &key market)
  (with-slots (lictor treasurer gate ope) tracker
    (if (slot-boundp tracker 'lictor) (reinitialize-instance lictor)
        (setf lictor (make-instance 'execution-tracker :market market :gate gate)))
    (if (slot-boundp tracker 'treasurer) (reinitialize-instance treasurer)
        (setf treasurer (make-instance 'balance-tracker :gate gate)))
    (unless (slot-boundp tracker 'ope)
      (setf ope (make-instance 'ope-scalper :lictor lictor :gate gate
                               :balance-tracker treasurer :market market)))))

(defclass maker ()
  ((market :initarg :market :reader market)
   (fund-factor :initarg :fund-factor :initform 1)
   (resilience-factor :initarg :resilience :initform 1)
   (targeting-factor :initarg :targeting :initform (random 1.0))
   (skew-factor :initarg :skew-factor :initform 1)
   (cut :initform 0)
   (control :initform (make-instance 'channel))
   (account-tracker :initarg :account-tracker)
   (name :initarg :name :accessor name)
   (snake :initform (list 15 "ZYXWVUSRQPONMGECA" "zyxwvusrqponmgeca"))
   (last-report :initform nil)
   thread))

(defmethod print-object ((maker maker) stream)
  (print-unreadable-object (maker stream :type t :identity nil)
    (write-string (name maker) stream)))

(defun profit-snake (lictor length positive-chars negative-chars
                     &aux (trades (slot-value lictor 'trades)))
  (flet ((depth-profit (depth)
           (flet ((vwap (side) (vwap lictor :type side :depth depth)))
             (dbz-guard (* 100 (1- (profit-margin (vwap "buy") (vwap "sell")))))))
         (side-last (side) (find side trades :key #'direction :test #'string-equal))
         (chr (chrs fraction &aux (length (length chrs)))
           (char chrs (1- (ceiling (* length fraction))))))
    (let* ((min-sum (loop for trade in trades for volume = (net-volume trade)
                       if (string-equal (direction trade) "buy")
                       sum volume into buy-sum else sum volume into sell-sum
                       finally (return (min buy-sum sell-sum))))
           (min-last (apply 'min (mapcar 'volume (mapcar #'side-last '("buy" "sell")))))
           (scale (expt (/ min-sum min-last) (/ length))))
      (with-output-to-string (out)
        (let* ((dps (loop for i to length collect (depth-profit (/ min-sum (expt scale i)))))
               (highest (reduce #'max (remove-if #'minusp dps) :initial-value 0))
               (lowest  (reduce #'min (remove-if #'plusp  dps) :initial-value 0)))
          (format out "~4@$" (depth-profit min-sum))
          (dolist (dp dps (format out "~4@$" (depth-profit min-last)))
            (format out "~C" (case (round (signum dp))
                               (+1 (chr positive-chars (/ dp highest)))
                               (-1 (chr negative-chars (/ dp lowest)))))))))))

(defun makereport (maker fund rate btc doge investment risked skew)
  (with-slots (name market account-tracker snake last-report) maker
    (let ((new-report (list fund rate btc doge investment risked skew)))
      (if (equal last-report new-report) (return-from makereport)
          (setf last-report new-report)))
    (labels ((sastr (side amount &optional model) ; TODO factor out aqstr
               (format nil "~V,,V$" (decimals (slot-value market side))
                       (if model (length (sastr side model)) 0) amount)))
      ;; FIXME: modularize all this decimal point handling
      ;; we need a pprint-style ~/aq/ function, and pass it aq objects!
      ;; time, total, primary, counter, invested, risked, risk bias, pulse
      (format t "~&~A ~A~{ ~A~} ~2,2$% ~2,2$% ~2,2@$ ~A~%"
              name (subseq (princ-to-string (now)) 11 19)
              (mapcar #'sastr '(primary counter primary counter)
                      `(,@#1=`(,fund ,(* fund rate)) ,btc ,doge) `(() () ,@#1#))
              (* 100 investment) (* 100 risked) (* 100 skew)
              (apply 'profit-snake (slot-value account-tracker 'lictor) snake))))
  (force-output))

(defun %round (maker)
  (with-slots (fund-factor resilience-factor targeting-factor skew-factor
               market name account-tracker cut) maker
    ;; Get our balances
    (with-slots (sync) (slot-reduce account-tracker treasurer)
      (recv (send sync sync)))          ; excellent!
    (let* ((trades (slot-reduce market trades-tracker trades))
           ;; TODO: split into primary resilience and counter resilience
           (resilience (* resilience-factor (reduce #'max (mapcar #'volume trades))))
           (balances (slot-reduce account-tracker treasurer balances))
           (doge/btc (vwap (slot-reduce market trades-tracker) :depth 50 :type :buy)))
      (flet ((total-of (btc doge) (+ btc (/ doge doge/btc))))
        (let* ((total-btc (asset-funds (primary market) balances))
               (total-doge (asset-funds (counter market) balances))
               (total-fund (total-of total-btc total-doge)))
          ;; history, yo!
          ;; this test originated in a harried attempt at bugfixing an instance
          ;; of Maybe, where the treasurer reports zero balances when the http
          ;; request (checking for balance changes) fails; due to use of aprog1
          ;; when the Right Thing™ is awhen1. now that the bug's killed better,
          ;; Maybe thru recognition, the test remains; for when you lose the bug
          ;; don't lose the lesson, nor the joke.
          (unless (zerop total-fund)
            (let* ((investment (dbz-guard (/ total-btc total-fund)))
                   (btc  (* fund-factor total-btc investment targeting-factor))
                   (doge (* fund-factor total-doge
                            (- 1 (* investment targeting-factor))))
                   (skew (/ doge btc doge/btc)))
              ;; report funding
              (makereport maker total-fund doge/btc total-btc total-doge investment
                          (dbz-guard (/ (total-of    btc  doge) total-fund))
                          (dbz-guard (/ (total-of (- btc) doge) total-fund)))
              (send (slot-reduce account-tracker ope input)
                    (list `((,btc . ,(* cut (1+ (/ (log skew) skew-factor)))))
                          `((,doge . ,(* cut (1+ (/ (- (log skew)) skew-factor)))))
                          resilience (expt skew skew-factor)))
              (recv (slot-reduce account-tracker ope output)))))))))

(defmethod shared-initialize :after ((maker maker) (names t) &key gate)
  (with-slots (market account-tracker thread) maker
    (ensure-tracking market)
    (if (slot-boundp maker 'account-tracker)
        (reinitialize-instance account-tracker :market market)
        (setf account-tracker
              (make-instance  'account-tracker :gate gate :market market)))
    (when (or (not (slot-boundp maker 'thread))
              (eq :terminated (task-status thread)))
      (setf thread
            (pexec
                (:name (concatenate 'string "qdm-preα " (name market))
                 :initial-bindings `((*read-default-float-format* double-float)))
              ;; TODO: just pexec anew each time...
              ;; you'll understand what you meant someday, right?
              (loop (%round maker)))))))

(defun pause-maker (maker) (send (slot-value maker 'control) '(pause)))

(defun reset-the-net (maker &key (revive t) (delay 5))
  (mapc 'kill (mapcar 'task-thread (pooled-tasks)))
  #+ (or)
  (flet ((ensure-death (list)
           (let ((thread (reduce #'slot-value list :initial-value maker)))
             (tagbody
                (if (eq :terminated (task-status thread)) (go end)
                    (kill (task-thread thread)))
              loop
                (if (eq :terminated (task-status thread)) (go end) (go loop))
              end))))
    (mapc #'ensure-death
          `((thread)
            (account-tracker gate thread)
            (account-tracker ope scalper)
            (account-tracker ope prioritizer)
            (account-tracker ope supplicant thread)
            (account-tracker ope scalper)
            (account-tracker worker)
            (account-tracker updater)
            (account-tracker lictor worker)
            (account-tracker lictor updater)
            (fee-tracker thread))))
  #+sbcl (sb-ext:gc :full t)
  (when revive
    (dolist (actor
              (list (slot-reduce maker market)
                    (slot-reduce maker account-tracker gate)
                    (slot-reduce maker account-tracker treasurer)
                    (slot-reduce maker account-tracker ope filter lictor)
                    (slot-reduce maker account-tracker ope)
                    maker))
      (sleep delay)
      (reinitialize-instance actor))))

(defmacro define-maker (name &rest keys
                        &key market gate
                          ;; just for interactive convenience
                          fund-factor targeting resilience account-tracker)
  (declare (ignore fund-factor targeting resilience account-tracker))
  (dolist (key '(:market :gate)) (remf keys key))
  `(defvar ,name (make-instance 'maker :market ,market :gate ,gate
                                :name ,(string-trim "*+<>" name)
                                ,@keys)))

(defun current-depth (maker)
  (with-slots (resilience-factor market) maker
    (with-slots (trades) (slot-value market 'trades-tracker)
      (* resilience-factor (reduce #'max (mapcar #'volume trades))))))

(defun trades-profits (trades)
  (flet ((side-sum (side asset)
           (reduce #'aq+ (mapcar asset (remove side trades :key #'direction
                                               :test-not #'string-equal)))))
    (let ((aq1 (aq- (side-sum "buy"  #'taken) (side-sum "sell" #'given)))
          (aq2 (aq- (side-sum "sell" #'taken) (side-sum "buy"  #'given))))
      (ecase (- (signum (quantity aq1)) (signum (quantity aq2)))
        (0 (values nil aq1 aq2))
        (-2 (values (aq/ (- (conjugate aq1)) aq2) aq2 aq1))
        (+2 (values (aq/ (- (conjugate aq2)) aq1) aq1 aq2))))))

(defun performance-overview (maker &optional depth)
  (with-slots (account-tracker market) maker
    (flet ((funds (symbol)
             (asset-funds symbol (slot-reduce account-tracker treasurer balances)))
           (total (btc doge)
             (+ btc (/ doge (vwap market :depth 50 :type :buy))))
           (vwap (side)
             (vwap account-tracker :type side :market market :depth depth)))
      (let* ((trades (slot-reduce account-tracker ope filter lictor trades))
             (uptime (timestamp-difference (now) (timestamp (first (last trades)))))
             (updays (/ uptime 60 60 24))
             (volume (or depth (reduce #'+ (mapcar #'volume trades))))
             (profit (* volume (1- (profit-margin (vwap "buy") (vwap "sell"))) 1/2))
             (total (total (funds (primary market)) (funds (counter market)))))
        (format t "~&Been up              ~7@F days,~
                   ~%traded               ~7@F coins,~
                   ~%profit               ~7@F coins,~
                   ~%portfolio flip per   ~7@F days,~
                   ~%avg daily profit:    ~4@$%~
                   ~%estd monthly profit: ~4@$%~%"
                updays volume profit (/ (* total updays 2) volume)
                (/ (* 100 profit) updays total) ; ignores compounding, too high!
                (/ (* 100 profit) (/ updays 30) total))))))

(defgeneric print-book (book &key count prefix)
  (:method ((maker maker) &rest keys)
    (macrolet ((path (&rest path)
                 `(apply #'print-book (slot-reduce maker ,@path) keys)))
      ;; TODO: interleaving
      (path account-tracker ope)
      (path market book-tracker)))
  (:method ((ope ope-scalper) &rest keys)
    (apply #'print-book (multiple-value-call 'cons (ope-placed ope)) keys))
  (:method ((tracker book-tracker) &rest keys)
    (apply #'print-book     (recv   (slot-value tracker 'output))    keys))
  (:method ((book cons) &key count prefix)
    (destructuring-bind (bids . asks) book
      (flet ((width (side)
               (reduce 'max (mapcar 'length (mapcar 'princ-to-string side))
                       :initial-value 0)))
        (do ((bids bids (rest bids)) (bw (width bids))
             (asks asks (rest asks)) (aw (width asks)))
            ((or (and (null bids) (null asks))
                 (and (numberp count) (= -1 (decf count)))))
          (format t "~&~@[~A ~]~V@A || ~V@A~%"
                  prefix bw (first bids) aw (first asks)))))))

(defmethod describe-object ((maker maker) (stream t))
  (with-slots (ope lictor) (slot-reduce maker account-tracker)
    (print-book ope) (performance-overview maker)
    (multiple-value-call 'format t "~@{~A~#[~:; ~]~}" (name maker)
                         (trades-profits (slot-reduce lictor trades)))))

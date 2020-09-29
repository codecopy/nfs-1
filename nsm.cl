;; -*- mode: common-lisp -*-
;; See the file LICENSE for the full license governing this code.

;; This file implements the Network Status Monitor (NSM) protocol. 
;; Ref: http://www.opengroup.org/onlinepubs/009629799/chap11.htm

(in-package :nsm)

(sunrpc:def-rpc-program (NSM 100024 :port *nsm-port*)
  (
   (1 ;; version
     (0 sm-null void void)
     (1 sm-stat sm-name sm-stat-res)
     (2 sm-mon mon sm-stat-res)
     (3 sm-unmon mon-id sm-stat)
     (4 sm-unmon-all my-id sm-stat)
     (5 sm-simu-crash void void)
     (6 sm-notify stat-chge void)
   )
  ))

;; As defined by the "spec" (C702.PDF), even number means down and odd number means up.
(defvar *nsm-state* 0) ;; down

(defstruct nsm-monitor
  host ;; string
  requestor ;; string 
  prog
  vers
  proc
  priv ;; usb8
  ;; As defined by the "spec" (C702.PDF), even number means down and odd number means up.
  state
  )

(defun nsm-monitor-to-string (obj)
  (format nil "[Monitor ~a (Callback: ~a, Prg: ~a, V: ~a, Proc: ~a)]"
	  (nsm-monitor-host obj)
	  (nsm-monitor-requestor obj)
	  (nsm-monitor-prog obj)
	  (nsm-monitor-vers obj)
	  (nsm-monitor-proc obj)))

(defvar *nsm-monitored-hosts* nil)
(defvar *nsm-callbacks-list* nil)
(defvar *nsm-our-name* nil)

(defparameter *nsm-state-file* "sys:nsm-state")
(defparameter *nsm-callback-retry-interval* 10) ;; seconds
(defparameter *nsm-notify-retry-interval* 10) ;; seconds
(defvar *nsm-state-lock* (mp:make-process-lock))

;;;;;;;;;

;; called from def-rpc-program-main macro via intern/funcall
(defun NSM-init ()
  (mp:process-run-function "nsm callback retry loop" 
    #'sm-callback-retry-loop)
  (nsm-load-state) 
  (nsm-advance-state)
  ;; Let folks know that we're back.
  (nsm-notify-peers)) 

(defun nsm-save-state ()
  (mp:with-process-lock (*nsm-state-lock*)
    (let ((tmpfile (concatenate 'string *nsm-state-file* ".tmp")))
      (with-open-file (f tmpfile :direction :output
		       :if-exists :supersede)
	(write (list *nsm-state* *nsm-monitored-hosts*) :stream f)
	;; Ensure that everything is flushed to the file before we 
	;; call fsync.
	(finish-output f)
	(excl.osi:fsync f))
      ;; New state file has been prepared.  Move it into place.
      (user::my-rename (translate-logical-pathname tmpfile)
		       (translate-logical-pathname *nsm-state-file*)))))

;; Reads the NSM state file and returns two values:
;; 1) The 'state' (an integer.  See *nsm-state* early in this file)
;; 2) A list of nsm-monitor structs.
;; If the NSM state file does not exist, returns nil.
;; This function will signal an error if there are problems reading
;; the state file.
(defun read-nsm-state-file-1 ()
  (with-open-file (f *nsm-state-file* :if-does-not-exist nil)
    (when f
      (destructuring-bind (state monitored-hosts)
	  (read f)
	;; Make sure everything looks legit
	(check-type state integer)
	(check-type monitored-hosts list)
	(dolist (mon monitored-hosts)
	  (assert (typep mon 'nsm-monitor)))
	;; Looks good.
	
	(values state monitored-hosts)))))

;; Reads the NSM state file and returns two values:
;; 1) The 'state' (an integer.  See *nsm-state* early in this file)
;; 2) A list of nsm-monitor structs.
;; If there are problems reading the state file, a notification and
;; hexdump will be logged, the broken file will be moved out of the
;; way, and initial values will be returned.
(defun read-nsm-state-file ()
  (multiple-value-bind (state monitored-hosts)
      (handler-case (read-nsm-state-file-1)
	(error (c)
	  (let ((hexdump-size 100) ;; bytes
		(filename (translate-logical-pathname *nsm-state-file*))
		(broken-filename (translate-logical-pathname (merge-pathnames nsm::*nsm-state-file* (make-pathname :type "broken"))))
		(*print-right-margin* 200))
	    (user::logit-stamp "While reading ~a, caught error: ~a~%"
			       filename
			       c)
	    (user::logit-stamp "Hexdump of the first ~a bytes of the file:~%~a~%"
			       hexdump-size
			       (user::hexdump-file filename hexdump-size :stream nil))
	    (user::logit-stamp "Renaming ~a to ~a and starting fresh.~%"
			       filename broken-filename)
	    ;; my-rename will overwrite an existing destination file.
	    (user::my-rename filename broken-filename)
	    nil)))
    (if* state
       then (values state monitored-hosts)
       else ;; Something wasn't right (missing or corrupt state file).
	    ;; Return initial values.
	    (values -1 nil))))

(defun nsm-load-state ()
  (mp:with-process-lock (*nsm-state-lock*)
    (multiple-value-setq (*nsm-state* *nsm-monitored-hosts*)
      (read-nsm-state-file))
    (dolist (mon *nsm-monitored-hosts*)
      (let ((priv (nsm-monitor-priv mon)))
	(if priv
	    (setf (nsm-monitor-priv mon)
	      (coerce priv 'user::ausb8)))))))
      

(defun nsm-advance-state ()
  (mp:with-process-lock (*nsm-state-lock*)
    (incf *nsm-state*)
    ;; As defined by the "spec" (C702.PDF), even number means down and odd number means up.
    ;; We want to indicate an 'up' state here.
    (until (and (oddp *nsm-state*) (> *nsm-state* 0))
      (incf *nsm-state*))
    ;; Make sure it remains a signed-positive.
    (if (> *nsm-state* #.(1- (expt 2 31)))
	(setf *nsm-state* 1))
    (if *nsm-debug* (user::logit-stamp "NSM: New state: ~d~%" *nsm-state*))
    (nsm-save-state)))

(defun nsm-log-status (status)
  (user::logit "==> ~a~%"
	 (case status
	   (#.*stat-fail* "FAIL")
	   (#.*stat-succ* "SUCC")
	   (t (format nil "~a" status)))))

(defun nsm-convert-mon-id (mon-id &key priv)
  (let* ((priv (if priv (opaque-data priv)))
	 (name (mon-id-mon-name mon-id)) ;; host to monitor
	 (my-id (mon-id-my-id mon-id))
	 (callback-host (my-id-my-name my-id))
	 (callback-prog (my-id-my-prog my-id))
	 (callback-vers (my-id-my-vers my-id))
	 (callback-proc (my-id-my-proc my-id)))
    (make-nsm-monitor :host name
		      :requestor callback-host
		      :prog callback-prog
		      :vers callback-vers
		      :proc callback-proc
		      :priv priv)))

;; Call with lock held.
(defun nsm-find-entry (mon-id)
  (let ((host (nsm-monitor-host mon-id))
	(requestor (nsm-monitor-requestor mon-id))
	(prog (nsm-monitor-prog mon-id))
	(vers (nsm-monitor-vers mon-id))
	(proc (nsm-monitor-proc mon-id)))
    (dolist (entry *nsm-monitored-hosts*)
      (if (and (string= (nsm-monitor-host entry) host)
	       (string= (nsm-monitor-requestor entry) requestor)
	       (= (nsm-monitor-prog entry) prog)
	       (= (nsm-monitor-vers entry) vers)
	       (= (nsm-monitor-proc entry) proc))
	  (return entry)))))

;; Returns a list of matches
(defun nsm-find-entry-by-my-id (requestor prog vers proc)
  (let (res)
    (dolist (entry *nsm-monitored-hosts*)
      (if (and (string= (nsm-monitor-requestor entry) requestor)
	       (= (nsm-monitor-prog entry) prog)
	       (= (nsm-monitor-vers entry) vers)
	       (= (nsm-monitor-proc entry) proc))
	  (push entry res)))
    res))

;;;;;;;;;;; Procedures

(defun sm-null (arg vers peer cbody)
  (declare (ignore arg vers cbody))
  (if *nsm-debug*
      (user::logit-stamp "NSM: ~a: NULL~%" (sunrpc:peer-dotted peer))))

;; in: sm-name, out: sm-stat-res
(defun sm-stat (arg vers peer cbody)
  (declare (ignore vers cbody))
  (let ((name (sm-name-mon-name arg))
	(status #.*stat-fail*))
    (if *nsm-debug*
	(user::logit-stamp "NSM: ~a: STAT (~a) " (sunrpc:peer-dotted peer) name))
    
    ;; This is what linux does.
    (if (ignore-errors (socket:lookup-hostname name))
	(setf status #.*stat-succ*))

    (if *nsm-debug*
	(nsm-log-status status))

    (mp:with-process-lock (*nsm-state-lock*)
      (make-sm-stat-res :res-stat status
			:state *nsm-state*))))

;; in: mon, out: sm-stat-res
(defun sm-mon  (arg vers peer cbody)
  (declare (ignore vers cbody))
  (let* ((mon-id (mon-mon-id arg))
	 (struct (nsm-convert-mon-id mon-id :priv (mon-priv arg)))
	 (status #.*stat-fail*))
    
    (if *nsm-debug*
	(user::logit-stamp "NSM: ~a: MON ~a~%" (sunrpc:peer-dotted peer)
	       (nsm-monitor-to-string struct)))

    (mp:with-process-lock (*nsm-state-lock*)
      (if* (sunrpc:local-peer-p peer)
	 then (if* (member struct *nsm-monitored-hosts* :test #'equalp)
		 then (if *nsm-debug*
			  (user::logit-stamp "NSM: ==> Already monitored.~%"))
		 else (push struct *nsm-monitored-hosts*)
		      (nsm-save-state)
		      (if *nsm-debug*
			  (user::logit-stamp "NSM: ==> Adding entry to monitor list.~%")))
	      (setf status #.*stat-succ*)
	 else (user::logit-stamp "NSM: ==> Rejecting non-local request.~%"))
      
      (when *nsm-debug*
	(user::logit-stamp "NSM: ")
	(nsm-log-status status))
      
      (make-sm-stat-res :res-stat status
			:state *nsm-state*))))
    
;; in: mon-id, out: sm-stat
(defun sm-unmon  (arg vers peer cbody)
  (declare (ignore vers cbody))
  (let ((struct (nsm-convert-mon-id arg)))
    
    (if *nsm-debug*
	(user::logit-stamp "NSM: ~a: UNMON ~a~%" (sunrpc:peer-dotted peer)
	       (nsm-monitor-to-string struct)))
    
    (mp:with-process-lock (*nsm-state-lock*)
      (if* (sunrpc:local-peer-p peer)
	 then (let ((entry (nsm-find-entry struct)))
		(if* entry
		   then (if *nsm-debug*
			    (user::logit-stamp "NSM: ==> Removing entry from monitor list.~%"))
			(setf *nsm-monitored-hosts* 
			  (delete entry *nsm-monitored-hosts*))
			(nsm-save-state)
		   else (if *nsm-debug*
			    (user::logit-stamp "NSM: ==> No matching entry (probably a dupe)~%"))))
	 else (if *nsm-debug*
		  (user::logit-stamp "NSM: ==> Ignoring non-local request~%")))
      
      (make-sm-stat :state *nsm-state*))))


;; in: my-id, out: sm-stat
(defun sm-unmon-all  (arg vers peer cbody)
  (declare (ignore vers cbody))
  (let ((requestor (my-id-my-name arg))
	(prog (my-id-my-prog arg))
	(vers (my-id-my-vers arg))
	(proc (my-id-my-proc arg)))
    
    (if *nsm-debug*
	(user::logit-stamp "~
NSM: ~a: UNMON_ALL Requestor: ~a, Prog: ~a, V: ~a, Proc: ~a~%"
		     (sunrpc:peer-dotted peer)
		     requestor prog vers proc))
    
    (mp:with-process-lock (*nsm-state-lock*)
      (when (sunrpc:local-peer-p peer)
	(let ((entries (nsm-find-entry-by-my-id requestor prog vers proc)))
	  (when entries
	    (dolist (entry entries)
	      (if *nsm-debug*
		  (user::logit-stamp "NSM: Removing ~a from monitor list.~%" 
			 (nsm-monitor-to-string entry)))
	      (setf *nsm-monitored-hosts* 
		(delete entry *nsm-monitored-hosts*)))
	    (nsm-save-state))))
      
      (make-sm-stat :state *nsm-state*))))
	

;; in: void, out: void
(defun sm-simu-crash  (arg vers peer cbody)
  (declare (ignore arg vers cbody))
  (if *nsm-debug*
      (user::logit-stamp "NSM: ~a: SIMU_CRASH~%" (sunrpc:peer-dotted peer)))
  
  (mp:with-process-lock (*nsm-state-lock*)
    (when (sunrpc:local-peer-p peer)
      (nsm-advance-state) ;; auto-saves
      (nsm-notify-peers))))

;; in: stat-chge, out: void
(defun sm-notify  (arg vers peer cbody)
  "Clients call this to notify us that they rebooted."
  (declare (ignore vers cbody))
  (let* ((host (stat-chge-mon-name arg))
	 (newstate (stat-chge-state arg))
	 (dotted (sunrpc:peer-dotted peer)))
	
    (if *nsm-debug*
	(user::logit-stamp "NSM: ~a: NOTIFY (~a, ~a)~%" 
	       dotted host newstate))
    
    ;; Set up to notify interested parties (if the status actually changed)
    (mp:with-process-lock (*nsm-state-lock*)
      (dolist (entry *nsm-monitored-hosts*)
	(when (and (string= (nsm-monitor-host entry) dotted)
		   (not (equal (nsm-monitor-state entry) newstate)))
	  (if *nsm-debug*
	      (user::logit-stamp "NSM: ==> Adding ~a to callback list.~%" 
		     (nsm-monitor-to-string entry)))
	  (setf (nsm-monitor-state entry) newstate)
	  (push entry *nsm-callbacks-list*))))))

;; Returns t if we got a reply of some sort.
;; called by sm-callback-retry-loop
(defun sm-do-callback (entry)
  (handler-case 
      (sunrpc:with-rpc-client (cli (nsm-monitor-requestor entry)
				   (nsm-monitor-prog entry)
				   (nsm-monitor-vers entry)
				   :udp)
	(sunrpc:callrpc cli (nsm-monitor-proc entry) 
			#'xdr-nsm-callback-status ;; inproc      
			(make-nsm-callback-status 
			 :mon-name (nsm-monitor-host entry)
			 :state (nsm-monitor-state entry)
			 :priv (nsm-monitor-priv entry))))
    (error (c)
      (if *nsm-debug*
	  (user::logit-stamp "NSM: Error while sending callback ~a: ~a~%"
		       (nsm-monitor-to-string entry) c))
      nil)
    (:no-error (results)
      (declare (ignore results))
      t)))
	       

(defun sm-callback-retry-loop ()
  (loop
    ;; Make a copy of the list before traversing it.  That way we can
    ;; release the lock while we process the callbacks.  If we don't,
    ;; we could get into a deadlock if the callback procedures make
    ;; additional NSM calls.
    
    (let (entries completed)
      (mp:with-process-lock (*nsm-state-lock*)
	(setf entries (copy-list *nsm-callbacks-list*)))
      
      (dolist (entry entries)
	(when (sm-do-callback entry)
	  (if *nsm-debug*
	      (user::logit-stamp "NSM: Callback ~a completed.~%" 
		     (nsm-monitor-to-string entry)))
	  (push entry completed)))
      
      (mp:with-process-lock (*nsm-state-lock*)
	(dolist (entry completed)
	  (setf *nsm-callbacks-list* (delete entry *nsm-callbacks-list*)))))
    
    (sleep *nsm-callback-retry-interval*)))

;; Called by NSM-init and sm-simu-crash
(defun nsm-notify-peers ()
  (mp:with-process-lock (*nsm-state-lock*)
    (when *nsm-monitored-hosts*
      (when (null *nsm-our-name*)
	(setf *nsm-our-name* (excl.osi:gethostname)))
  
      (let ((entries *nsm-monitored-hosts*))
	(setf *nsm-monitored-hosts* nil)
	(nsm-save-state)
    
	(dolist (entry entries)
	  (if *nsm-debug*
	      (user::logit-stamp "~
NSM: Notifying ~a of our new state.~%" 
		     (nsm-monitor-host entry)))
	
	  (mp:process-run-function 
	      (format nil "~
NSM notifying ~a of new state" (nsm-monitor-host entry))
	    #'nsm-notify-peer (nsm-monitor-host entry) *nsm-state*))))))

(defun nsm-notify-peer (host state)
  ;; XXX -- When should we give up?
  (loop
    (handler-case 
	(sunrpc:with-rpc-client (cli host #.*sm-prog* #.*sm-vers* :udp)
	  (call-sm-notify-1 cli (make-stat-chge :mon-name *nsm-our-name*
						:state state)))
      (error (c)
	(if *nsm-debug*
	    (user::logit-stamp "NSM: Error while sending notify to ~a: ~a~%"
		   host c)))
      (:no-error (results)
	(declare (ignore results))
	(if *nsm-debug*
	    (user::logit-stamp "NSM: Successfully notified ~a of our new state.~%" host))
	(return-from nsm-notify-peer)))
    
    (sleep *nsm-notify-retry-interval*)))

(eval-when (compile load eval)
  (export '(NSM)))

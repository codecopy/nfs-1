;; -*- mode: common-lisp -*-
;; See the file LICENSE for the full license governing this code.

(in-package :sunrpc)

(eval-when (compile)
  (declaim (optimize (speed 3) (safety 1))))

(eval-when (compile load eval)
;; Large enough to allow for 64KB read/writes in NFS V3.
(defconstant *rpc-buffer-size* (* 70 1024))
)

(defstruct rpc-peer
  type
  socket
  addr
  port
  fragments) ;; for TCP peers

(defmacro peer-dotted (peer)
  `(socket:ipaddr-to-dotted (rpc-peer-addr ,peer)))

(defmacro local-peer-p (peer)
  `(socket:ipaddr-equalp (rpc-peer-addr ,peer)
			 #.(socket:dotted-to-ipaddr "127.0.0.1")))

(defparameter *rpc-debug* nil)
 
;; See if this can be sped up and simplified by using BSWAP (if duane
;; gets it to me)
(defun read-int-from-stream (stream)
  (declare (optimize (speed 3)))
  (let* ((vec (make-array 1 :element-type '(signed-byte 32)))
	 (res (read-vector vec stream :endian-swap :network-order)))
    (declare 
     (dynamic-extent vec)
     (type (simple-array (signed-byte 32) (*)) vec)
     (type (unsigned-byte 8) res))
    (if (= res 0)        
        (return-from read-int-from-stream nil));; indicate EOF
    (if (/= res 4)
	(error "Incomplete read during read-int-from-stream"))
    (aref vec 0)))


(defun read-record (stream buffer)
  (handler-case 
      (let ((size (read-int-from-stream stream)))
	(if (null size)
	    (return-from read-record nil)) ;; indicate EOF
	;; The 32-bit word that is sent by the client is unsigned.
	;; If the high bit is set, it means "last fragment".
	;; read-int-from-stream returns the signed representation
	;; so if the number is negative, the high bit is set.
	(when (>= size 0)
	  (error "read-record: Fragments aren't handled yet"))
	(setf size (logand size #x7fffffff))
	(if (> size (length buffer))
	    (error "read-record: Record is too big for the buffer! (~D > ~D)"
		   size (length buffer)))
	;;(logit "Message is ~d bytes~%" size)
	(read-complete-vector buffer stream size))
    (socket-error (c)
      (if *rpc-debug* (user::logit-stamp "~a~%" c))
      nil)
    (t (c)
      (user::logit-stamp "read-record got error ~A~%Returning nil~%" c)
      nil)))

(defun read-complete-vector (vec stream end)
  (declare
   (optimize (speed 3))
   (type fixnum end))
  (let ((pos 0))
    (declare (type fixnum pos))
    (while (/= pos end)
      (setf pos (read-vector vec stream :start pos :end end))))
  vec)
  

;;; Used by with-good-reply-msg
(defun verbose-accept-stat (code)
  "Translates an enum accept_stat into a string"
  (case code
    ;; These 5 are defined by rfc1057 (1988)
    (#.*success*
     "success")
    (#.*prog-unavail*
     "program unavailable")
    (#.*prog-mismatch*
     "program version mismatch")
    (#.*proc-unavail*
     "procedure unavailable")
    (#.*garbage-args*
     "garbage arguments")
    ;; This one showed up in rfc1831 (1995)
    (#.*system-err*
     "system error")
    ;; Hmmm
    (t
     (format nil "<Unrecognized enum accept_stat = ~a>" code))))

;; returns rpc-msg struct.
(defun rpc-get-reply (peer &key buffer)
  (when (null buffer)
    (setf buffer (make-array #.*rpc-buffer-size* 
			     :element-type '(unsigned-byte 8))))

  (xdr-rpc-msg 
   (ecase (rpc-peer-type peer)
     (:datagram
      (multiple-value-bind (vec count)
	  (socket:receive-from (rpc-peer-socket peer) 
			       (length buffer)
			       :buffer buffer)
	(create-xdr :vec vec :size count)))
     (:stream
      (create-xdr :vec (read-record (rpc-peer-socket peer) buffer))))))
	

;; Sanity checking routine for programs that just want to fail if a
;; reply is bogus for some reason.
(defmacro with-good-reply-msg ((msg expected-xid xdrsym) &body body)
  (let ((m (gensym))
	(xid (gensym))
	(thing (gensym)))
    `(let ((,m ,msg)
	   (,xid ,expected-xid))
       (if (/= (rpc-msg-xid ,m) ,xid)
	   (error "Got XID ~D but expected ~D" (rpc-msg-xid ,m) ,xid))
       (let ((,thing (rpc-msg-body ,m))) ;; rpc-msg-body-u
	 (if (/= *reply* (rpc-msg-body-u-mtype ,thing))
	     (error "Message was not of reply type (got type ~d instead)"
		    (rpc-msg-body-u-mtype ,thing)))
	 (setf ,thing (rpc-msg-body-u-rbody ,thing)) ;; reply-body
	 (if (/= *msg-accepted* (reply-body-stat ,thing))
	     (error "Message was denied"))
	 (setf ,thing (reply-body-areply ,thing)) ;; accepted-reply
	 (setf ,thing (accepted-reply-reply-data ,thing)) ;; accepted-reply-reply-data-u
	 (if (/= *success* (accepted-reply-reply-data-u-stat ,thing))
	     (error "Reply status: ~A (code: ~D)" 
		    (verbose-accept-stat 
		     (accepted-reply-reply-data-u-stat ,thing))
		    (accepted-reply-reply-data-u-stat ,thing)))
	 
	 (let ((,xdrsym (car (accepted-reply-reply-data-u-results ,thing))))
	   ,@body)))))

(defun rpc-send (xdr peer)
  (declare (optimize (speed 3)))
  (let ((sock (rpc-peer-socket peer)))
    (ignore-errors 
     (ecase (rpc-peer-type peer)
       (:stream
	(let ((sizevec (make-array 1 :element-type '(signed-byte 32)))
 	      (size (xdr-size xdr)))
 	  (declare (dynamic-extent sizevec)
 		   ((integer 0 128000) size))
	  ;; Sets the high bit (which indicates last fragment)
 	  (setf (aref sizevec 0) (+ -2147483648 size))
 	  (write-vector sizevec sock :endian-swap :network-order)
 	  (write-vector (xdr-vec xdr) sock :end size)
 	  (force-output sock)))
       (:datagram
	(rpc-send-udp xdr peer))))))

;; Convert to a macro?
(defun rpc-send-udp (xdr peer)
  (declare (optimize (speed 3) (safety 0) (debug 0)))
  (socket:send-to (rpc-peer-socket peer)
		  (xdr-vec xdr) 
		  (xdr-size xdr) 
		  :remote-host (rpc-peer-addr peer)
		  :remote-port (rpc-peer-port peer)))

(defun set-fragment-len (vec value)
  (declare (optimize (speed 3) (safety 0) (debug 0))
	   (fixnum value)
	   ((simple-array (unsigned-byte 8) (*)) vec))
  (setf (aref vec 0) (logior #x80 (ash value -24)))
  (setf (aref vec 1) (logand #xff (ash value -16)))
  (setf (aref vec 2) (logand #xff (ash value -8)))
  (setf (aref vec 3) (logand #xff value)))

;;(setf comp::*hack-compiler-output* '(set-fragment-len-bswap))

#+ignore
(eval-when (compile)
  (setq comp::*assemble-function-body*
    '((set-fragment-len-bswap . "set-fragment-len-bswap.lap"))))

;; This doesn't seem to have a significant effect on Allegro NFS
;; performance
(defun set-fragment-len-bswap (vec value)
  (declare (optimize (speed 3) (safety 0) (debug 0))
	   ((integer 0 128000) value)
	   ((simple-array (signed-byte 32) (*)) vec))
  (setf (aref vec 0) (+ #x-80000000 value))
  t)

;; Caller has left space at the beginning of xdr's vec for the
;; fragment size info.
(defun rpc-send-tcp-x (xdr peer)
  (declare (optimize (speed 3) (safety 0) (debug 0)))
  (let ((len (xdr-size xdr))
	(vec (xdr-vec xdr))
	(sock (rpc-peer-socket peer)))
    (set-fragment-len vec (- len 4))
    (write-vector vec sock :end len)
    (finish-output sock)))

(defparameter *nullauth* (make-opaque-auth :flavor *auth-null* 
					   :body #()))

(defparameter *nullverf* (make-opaque-auth :flavor *auth-null* 
					   :body #()))

(defmacro with-rpc-reply ((xdr peer xid) &body body)
  (let ((xdrbuf (gensym))
	(tcp (gensym))
	(xpeer (gensym)))
    `(let* ((,xdrbuf (make-array #.*rpc-buffer-size* 
				 :element-type '(unsigned-byte 8)))
	    (,xdr (create-xdr :direction :build :vec ,xdrbuf))
	    (,xpeer ,peer)
	    (,tcp (eq (rpc-peer-type ,xpeer) :stream)))
       (declare 
	(dynamic-extent ,xdrbuf))
       
       (if ,tcp
	   (setf (xdr-pos ,xdr) 4)) ;; leave space for size info
       (xdr-unsigned-int ,xdr ,xid)
       (xdr-int ,xdr #.*reply*)
       ,@body
       
       (if* ,tcp
	  then (rpc-send-tcp-x ,xdr ,xpeer)				  
	  else (rpc-send-udp ,xdr ,xpeer)))))

(defmacro with-accepted-reply ((xdr peer xid verf) &body body)
  `(with-rpc-reply (,xdr ,peer ,xid)
     (xdr-int ,xdr #.*msg-accepted*)
     (xdr-opaque-auth ,xdr ,verf)
     ,@body))

(defmacro with-denied-reply ((xdr peer xid) &body body)
  `(with-rpc-reply (,xdr ,peer ,xid)
     (xdr-int ,xdr #.*msg-denied*)
     ,@body))

;; denied (rejected) replies include: rpc_mismatch and auth_error

(defun send-rpc-mismatch-reply (peer xid low high)
  (with-denied-reply (xdr peer xid)
    (xdr-int xdr #.*rpc-mismatch*)
    (xdr-unsigned-int xdr low)
    (xdr-unsigned-int xdr high)))

(defun send-auth-error-reply (peer xid stat)
  (with-denied-reply (xdr peer xid)
    (xdr-int xdr #.*rpc-mismatch*)
    (xdr-int xdr stat)))

;; accepted but unsuccessful reply types include:
;; prog_mismatch, prog_unavail, proc_unavail, garbage_args

(defun send-prog-mismatch-reply (peer xid verf low high)
  (with-accepted-reply (xdr peer xid verf)
    (xdr-int xdr #.*prog-mismatch*)
    (xdr-unsigned-int xdr low)
    (xdr-unsigned-int xdr high)))

(defun send-prog-unavail-reply (peer xid verf)
  (with-accepted-reply (xdr peer xid verf)
    (xdr-int xdr #.*prog-unavail*)))
  
(defun send-proc-unavail-reply (peer xid verf)
  (with-accepted-reply (xdr peer xid verf)
    (xdr-int xdr #.*proc-unavail*)))

(defun send-garbage-args-reply (peer xid verf)
  (with-accepted-reply (xdr peer xid verf)
    (xdr-int xdr #.*garbage-args*)))


;; accepted and succesful reply

(defmacro with-successful-reply ((xdr peer xid verf) &body body)
  `(with-accepted-reply (,xdr ,peer ,xid ,verf)
     (xdr-int ,xdr #.*success*)
     ,@body))

;; Assumes UDP.  Returns the number of xdr bytes required for
;; a successful reply.
(defun compute-successful-reply-overhead ()
  (with-successful-reply (xdr (make-rpc-peer) 0 *nullverf*)
    (return-from compute-successful-reply-overhead
      (xdr-pos xdr))))

(defparameter *successful-reply-overhead* nil)

(defun get-successful-reply-overhead ()
  (or *successful-reply-overhead*
      (setf *successful-reply-overhead* (compute-successful-reply-overhead))))

;;;; client stuff

(defun rpc-connect-to-peer (host port proto)
  (let* ((type (ecase proto
		 (:tcp 
		  :stream)
		 (:udp
		  :datagram)))
	 (socket (socket:make-socket 
		  :type type
		  :remote-host host 
		  :remote-port port)))
    (make-rpc-peer :type type 
		   :socket socket 
		   :addr (socket:remote-host socket)
		   :port port)))

(defun rpc-disconnect (peer)
  (close (rpc-peer-socket peer))) 

(defmacro with-rpc-peer ((peer host port proto) &body body)
  `(let (,peer)
     (unwind-protect
	 (progn
	   (setf ,peer (rpc-connect-to-peer ,host ,port ,proto))
	   ,@body)
       (if ,peer
	   (rpc-disconnect ,peer)))))

;; called by callrpc
(defun rpc-send-call (peer xid prog vers proc auth verf data)
  ;; Construct rpc_msg
  (let ((xdr (create-xdr :direction :build)))
    (xdr-unsigned-int xdr xid)
    (xdr-unsigned-int xdr #.*call*) ;; msg_type mtype
    ;; call body
    (xdr-unsigned-int xdr 2) ;; rpc vers
    (xdr-unsigned-int xdr prog) 
    (xdr-unsigned-int xdr vers)
    (xdr-unsigned-int xdr proc)
    (xdr-opaque-auth xdr auth)
    (xdr-opaque-auth xdr verf)
    (xdr-xdr xdr data)
    (rpc-send xdr peer)))

(defstruct rpc-client
  peer
  prog
  vers
  xdr
  auth)

(defun rpc-client-create (host prog vers proto &key port uid gid gids)
  (let ((port (or port (portmap-getport host prog vers proto)))
	(auth *nullauth*))
    (if (= port 0)
	(error "program not registered"))

    (when (or uid gid gids)
      (if (not (and uid gid))
	  (error "If one of uid, gid, or gids is specified, then uid and gid must be specified"))
      
      (let ((x (create-xdr :direction :build)))
	(xdr-auth-unix 
	 x 
	 (make-auth-unix 
	  :stamp 
	  (excl.osi:universal-to-unix-time (get-universal-time))
	  :machinename (excl.osi:gethostname)
	  :uid uid
	  :gid gid
	  :gids gids))
	(setf auth (make-opaque-auth :flavor *auth-unix*
				     :body (xdr-get-vec x)))))
    
    (make-rpc-client :peer (rpc-connect-to-peer host port proto)
		     :prog prog
		     :vers vers
		     :xdr (create-xdr :direction :build)
		     :auth auth)))

(defun rpc-client-close (cli)
  (rpc-disconnect (rpc-client-peer cli)))

(defmacro with-rpc-client ((cli host prog vers proto 
			    &key port uid gid gids) 
			   &body body)
  `(let ((,cli (rpc-client-create ,host ,prog ,vers ,proto 
				  :port ,port :uid ,uid
				  :gid ,gid :gids ,gids)))
     (unwind-protect (progn ,@body)
       (rpc-client-close ,cli))))

;; On success, returns the results of the remote procedure call, post-
;; processed by 'outproc' (if provided).  If 'outproc' is not provided
;; then an xdr struct is returned.
(defun callrpc (cli proc inproc in &key (retries 3)
					(timeout 5)
					outproc
					no-reply) ;; don't wait for a reply
  (let* ((peer (rpc-client-peer cli))
	 (xdr (rpc-client-xdr cli))
	 (prog (rpc-client-prog cli))
	 (vers (rpc-client-vers cli))
	 (auth (rpc-client-auth cli))
	 (xid (random #.(expt 2 32))))
    
    (xdr-flush xdr)

    (if inproc
	(funcall inproc xdr in))

    (dotimes (i retries) 
      (rpc-send-call peer xid prog vers proc auth *nullverf* xdr)
      
      (if no-reply
	  (return-from callrpc t))
	
      (let ((msg (mp:with-timeout (timeout :timeout)
		   (rpc-get-reply peer))))
	(if (not (eq msg :timeout))
	    (with-good-reply-msg (msg xid results)
	      (return-from callrpc 
		(if outproc
		    (funcall outproc results)
		  results))))))
      
    (error "rpc call failed (no response)")))

(defun protocol-to-string (proto)
  (if* (or (eq proto :udp) (eql proto #.portmap:*ipproto-udp*))
     then "UDP"
   elseif (or (eq proto :tcp) (eql proto #.portmap:*ipproto-tcp*))
     then "TCP"
     else (format nil "~a" proto)))

(defun proto-to-number (proto)
  (if* (numberp proto)
     then proto
   elseif (keywordp proto)
     then (ecase proto
	    (:tcp 
	     #.portmap:*ipproto-tcp*)
	    (:udp
	     #.portmap:*ipproto-udp*))
     else (error "Unrecognized protocol: ~s" proto)))

(defmacro with-portmapper ((cli host) &body body)
  `(with-rpc-client (,cli ,host #.portmap:*pmap-prog* #.portmap:*pmap-vers* 
			  :udp :port #.portmap:*pmap-port*)
     ,@body))

;; Portmapper client function
(defun portmap-getport (host prog vers proto)
  (with-portmapper (cli host)
    (portmap:call-pmapproc-getport-2 
     cli 
     (portmap:make-mapping :prog prog 
			   :vers vers 
			   :prot (proto-to-number proto)
			   :port 0))))

(defun portmap-set (prog vers proto port)
  (with-portmapper (cli "127.0.0.1")
    (portmap:call-pmapproc-set-2 
     cli
     (portmap:make-mapping :prog prog
			   :vers vers
			   :prot (proto-to-number proto)
			   :port port))))

(defun portmap-unset (prog vers)
  (with-portmapper (cli "127.0.0.1")
    (portmap:call-pmapproc-unset-2 
     cli
     (portmap:make-mapping :prog prog
			   :vers vers
			   :prot 0
			   :port 0))))

(eval-when (compile load eval)
  (export '(callrpc portmap-getport portmap-set portmap-unset
	    send-rpc-mismatch-reply  send-prog-unavail-reply
	    send-proc-unavail-reply send-prog-mismatch-reply
	    rpc-peer-addr with-successful-reply
	    protocol-to-string with-rpc-client callrpc
	    *nullverf* peer-dotted local-peer-p
	    rpc-client-create
	    get-successful-reply-overhead
	    ))
  (provide 'sunrpc))



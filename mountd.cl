;; -*- mode: common-lisp -*-
;; See the file LICENSE for the full license governing this code.

(in-package :mount)

(sunrpc:def-rpc-program (MNT 100005 :port *mountd-port-number*)
    (
     (1 ;; version
      (0 mountproc-null void void)
      (1 mountproc-mnt dirpath fhstatus)
      (2 mountproc-dump void mountlist)
      (3 mountproc-umnt dirpath void)
      (4 mountproc-umntall void void)
      (5 mountproc-export void exports)
      (6 mountproc-exportall void exports)
      )
     (2 ;; version
      (0 mountproc-null void void)
      (1 mountproc-mnt dirpath fhstatus)
      (2 mountproc-dump void mountlist)
      (3 mountproc-umnt dirpath void)
      (4 mountproc-umntall void void)
      (5 mountproc-export void exports)
      (6 mountproc-exportall void exports)
      (7 mountproc-pathconf dirpath ppathcnf)
      )
     (3 ;; version
      (0 mountproc3-null void void)
      (1 mountproc3-mnt dirpath mountres3)
      (2 mountproc3-dump void mountlist)
      (3 mountproc3-umnt dirpath void)
      (4 mountproc3-umntall void void)
      (5 mountproc3-export void exports)
      )
     ))


(defparameter *mounts* nil)

;;; Override the automatically generated xdr-fhandle* functions.
(without-redefinition-warnings 
 (defun xdr-fhandle (xdr &optional arg)
   (user::xdr-fhandle xdr 2 arg))
 
 (defun xdr-fhandle3 (xdr &optional arg)
   (user::xdr-fhandle xdr 3 arg)))

;;;; Procedures

(defun mountproc-null (arg vers peer cbody)
  (declare (ignore arg cbody))
  (if *mountd-debug* 
      (user::logit-stamp "MNT~a: ~a: NULL~%" vers (sunrpc:peer-dotted peer))))

(defun mountproc3-null (arg vers peer cbody)
  (mountproc-null arg vers peer cbody))

;; Note that DIRPATH is allowed to name a file or directory beneath an export.
(defun mountproc-mnt-common (dirpath vers peer)
  "Returns the file handle (fh struct) corresponding to DIRFH if 
   successful.  Otherwise returns an NFS error code"
  (if *mountd-debug* 
      (user::logit-stamp "MNT~d: ~a: MOUNT ~a "
			 vers (sunrpc:peer-dotted peer) dirpath))
  (multiple-value-bind (exp tail) 
      (user::locate-nearest-export-by-nfs-path dirpath)
    (if* (null exp)
       then (if *mountd-debug* (user::logit "==> Denied (no such export).~%"))
	    gen-nfs:*nfserr-noent*
     elseif (not (user::export-host-access-allowed-p 
		  exp (sunrpc:rpc-peer-addr peer)))
       then (if *mountd-debug* 
		(user::logit "==> Denied (host not allowed).~%"))
	    gen-nfs:*nfserr-acces*
       else (let ((fh (user::get-fhandle-for-path tail exp)))
	      (if* fh
		 then (if *mountd-debug* (user::logit "==> Accepted.~%"))
		      (pushnew (list (sunrpc:rpc-peer-addr peer) dirpath) 
			       *mounts* 
			       :test #'equalp)
		      fh
		 else (if *mountd-debug* (user::logit "==> Not found.~%"))
		      gen-nfs:*nfserr-noent*)))))

(defun mountproc-mnt (dirpath vers peer cbody)
  (declare (ignore cbody))
  (let ((fh (mountproc-mnt-common dirpath vers peer)))
    (if* (numberp fh)
       then (make-fhstatus :fhs-status fh) ;; error code
       else (make-fhstatus :fhs-status 0 :fhs-fhandle fh))))

(defun mountproc3-mnt (dirpath vers peer cbody)
  (declare (ignore cbody))
  (let ((fh (mountproc-mnt-common dirpath vers peer)))
    (if* (numberp fh)
       then (make-mountres3 :fhs-status fh) ;; error code
       else (make-mountres3 :fhs-status *mnt3-ok* 
			    :mountinfo 
			    (make-mountres3-ok :fhandle fh
					       :auth-flavors 
					       (list sunrpc:*auth-unix*))))))

(defun mountproc-dump (arg vers peer cbody)
  (declare (ignore arg cbody))
  (if *mountd-debug* 
      (user::logit-stamp "MNT~d: ~a: DUMP~%" vers (sunrpc:peer-dotted peer)))
  (let (res)
    (dolist (pair *mounts*)
      (setf res 
	(make-mountbody :ml-hostname (socket:ipaddr-to-dotted (first pair))
			:ml-directory (second pair)
			:ml-next res)))
    res))

(defun mountproc3-dump (arg vers peer cbody)
  (mountproc-dump arg vers peer cbody))

(defun mountproc-umnt (dirpath vers peer cbody)
  (declare (ignore cbody))
  (if *mountd-debug* 
      (user::logit-stamp "MNT~d: ~a: UMOUNT ~a~%" vers (sunrpc:peer-dotted peer) dirpath))
  (setf *mounts* 
    (delete (list (sunrpc:rpc-peer-addr peer) dirpath) 
	    *mounts*
	    :test #'equalp)))

(defun mountproc3-umnt (dirpath vers peer cbody)
  (mountproc-umnt dirpath vers peer cbody))

(defun mountproc-umntall (arg vers peer cbody)
  (declare (ignore arg cbody))
  (if *mountd-debug* 
      (user::logit-stamp "MNT~d: ~a: UMOUNT ALL~%" vers (sunrpc:peer-dotted peer)))
  (setf *mounts* 
    (delete (sunrpc:rpc-peer-addr peer) *mounts* :key #'first)))

(defun mountproc3-umntall (arg vers peer cbody)
  (mountproc-umntall arg vers peer cbody))

(defun mountproc-export (arg vers peer cbody)
  (declare (ignore arg cbody))

  (when mount:*showmount-disabled*
    (when *mountd-debug* 
      (user::logit-stamp "MNT~d: ~A: EXPORT is disabled via config.~%" vers (sunrpc:peer-dotted peer)))
    (return-from mountproc-export))

  (if *mountd-debug* 
      (user::logit-stamp "MNT~d: ~a: EXPORT~%" vers (sunrpc:peer-dotted peer))) 

  (let (res)
    (user::do-exports (export-name export)
      (setf res  
        (make-exportnode 
         :ex-dir export-name
         :ex-groups (let (grp)
                      (dolist (g (user::nfs-export-hosts-allow export))
                        (setf grp
                          (make-groupnode
                           :gr-name (user::network-address-to-printable-string g)
                           :gr-next grp))))
         :ex-next res)))
    res))

(defun mountproc3-export (arg vers peer cbody)
  (mountproc-export arg vers peer cbody))

(defun mountproc-exportall (arg vers peer cbody)
  (mountproc-export arg vers peer cbody))

(defconstant *pc-error* 0)
(defconstant *pc-link-max* 1)
(defconstant *pc-max-canon* 2)
(defconstant *pc-max-input* 3)
(defconstant *pc-name-max* 4)
(defconstant *pc-path-max* 5)
(defconstant *pc-pipe-buf* 6)
(defconstant *pc-no-trunc* 7)
(defconstant *pc-vdisable* 8)
(defconstant *pc-chown-restricted* 9)

(defun mountproc-pathconf (dirpath vers peer cbody)
  (declare (ignore cbody))
  (if* *mountd-debug*
     then (user::logit-stamp "MNT~d: ~a: PATHCONF ~a~%" vers (sunrpc:peer-dotted peer) dirpath))
  
  ;; Return information in the same way that Solaris 9 does
  (make-ppathcnf :pc-link-max 1023 ;; NTFS limit
		 :pc-max-canon 0 :pc-max-input 0
		 :pc-name-max 255 :pc-path-max 255
		 :pc-pipe-buf 0 :pc-vdisable 0 :pc-xxx 0
		 :pc-mask (list 
			   (logior 
			    ;; Indicate which fields are invalid
			    (ash 1 *pc-max-canon*)
			    (ash 1 *pc-max-input*)
			    (ash 1 *pc-pipe-buf*)
			    (ash 1 *pc-vdisable*)
			    ;; And indicate behavior
			    (ash 1 *pc-no-trunc*)
			    (ash 1 *pc-chown-restricted*))
			   0)))

;;;;;;;;;;;;;;;;;;;;

(eval-when (compile load eval)
  (export '(*mountd-debug* *mountd-port-number* MNT)))
	    

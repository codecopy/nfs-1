;; -*- mode: common-lisp -*-
;;
;; Copyright (C) 2001 Franz Inc, Berkeley, CA.  All rights reserved.
;; Copyright (C) 2002-2005 Franz Inc, Oakland, CA.  All rights reserved.
;;
;; This code is free software; you can redistribute it and/or
;; modify it under the terms of the version 2.1 of
;; the GNU Lesser General Public License as published by 
;; the Free Software Foundation, as clarified by the Franz
;; preamble to the LGPL found in
;; http://opensource.franz.com/preamble.html.
;;
;; This code is distributed in the hope that it will be useful,
;; but without any warranty; without even the implied warranty of
;; merchantability or fitness for a particular purpose.  See the GNU
;; Lesser General Public License for more details.
;;
;; Version 2.1 of the GNU Lesser General Public License can be
;; found at http://opensource.franz.com/license.html.
;; If it is not present, you can access it from
;; http://www.gnu.org/copyleft/lesser.txt (until superseded by a newer
;; version) or write to the Free Software Foundation, Inc., 59 Temple
;; Place, Suite 330, Boston, MA  02111-1307  USA
;;
;; $Id: main.cl,v 1.24 2007/05/04 01:02:30 dancy Exp $

(eval-when (compile eval load) (require :ntservice))

(in-package :user)

(defparameter *pmap-process* nil)
(defparameter *mountd-process* nil)
(defparameter *nfsd-process* nil)
(defparameter *nsm-process* nil)
(defparameter *nlm-process* nil)

;;#+nfs-debug (eval-when (eval load) (require :trace))

(defun ping-nfsd ()
  (multiple-value-bind (res error)
      (ignore-errors 
       (sunrpc:with-rpc-client (cli "127.0.0.1" gen-nfs:*nfs-program* 2 :udp)
	 (gen-nfs:call-nfsproc-null-2 cli nil)))
    (declare (ignore res))
    (if (not error)
	t)))

(defun check-nfs-already-running ()
  (if (ping-nfsd)
      (bailout "~
An NFS server is already running on this machine.  Aborting.~%")))

(defun startem (&rest args)
  (declare (ignore args)
	   (special nlm:*nlm-gate*))
  ;;#+nfs-debug (trace stat)
  (setup-logging)
  (logit-stamp "Allegro NFS Server version ~A initializing...~%" 
	 *nfsd-long-version*)
  (logit-stamp "Built with Allegro CL ~a~%" (lisp-implementation-version))
  (check-nfs-already-running)
  (setf *pmap-process* 
    (mp:process-run-function "portmapper" #'portmap:portmapper))
  (mp:process-wait "Waiting for portmapper to start" 
		   #'mp:gate-open-p portmap:*pmap-gate*)
  (setf *mountd-process* 
    (mp:process-run-function "mountd" #'mount:MNT))
  (mp:process-wait "Waiting for mountd to start" 
		   #'mp:gate-open-p mount:*mountd-gate*)
  (setf *nsm-process* (mp:process-run-function "nsm" #'nsm:NSM))
  (mp:process-wait "Waiting for nsm to start" 
		   #'mp:gate-open-p nsm:*nsm-gate*)
  (setf *nlm-process* (mp:process-run-function "nlm" #'nlm:NLM))
  (mp:process-wait "Waiting for nlm to start" 
		   #'mp:gate-open-p nlm:*nlm-gate*)
  (setf *nfsd-process* (mp:process-run-function "nfsd" #'nfsd)))

(defvar *shutting-down* (mp:make-gate nil))

(defun stopem ()
  (logit-stamp "Stopping NFS server...")
  (when *nlm-process* (ignore-errors (mp:process-kill *nlm-process*)))
  (when *nsm-process* (ignore-errors (mp:process-kill *nsm-process*)))
  (when *nfsd-process* (ignore-errors (mp:process-kill *nfsd-process*)))
  (when *mountd-process* (ignore-errors (mp:process-kill *mountd-process*)))
  (when *pmap-process* (ignore-errors (mp:process-kill *pmap-process*)))
  (mp:open-gate *shutting-down*)
  ;; Allow `mainloop' process to see the open gate.
  (sleep 1))

(defun mainloop ()
  (console-control :close :hide)
  (mp:process-wait "waiting for shutdown"
		   #'mp:gate-open-p *shutting-down*)
  (logit-stamp "done."))

(defun debugmain ()
  (setf *configfile* "nfs.cfg")
  (read-nfs-cfg *configfile*)
  (setf mount:*mountd-debug* t)
  (setf *nfs-debug* t)
  (setf portmap:*portmap-debug* t)
  ;;(setf *rpc-debug* t)
  (setf nsm:*nsm-debug* t)
  (setf nlm:*nlm-debug* t)
  (startem))

(defvar *service-name* "nfs")

(defun main (&rest args)
  (setf *global-gc-behavior* :auto)
  
  (flet ((tnserver ()
	   #+nfs-telnet-server
	   (progn
	     (logit-stamp "Starting telnet server on port 1234~%")
	     (start-telnet-server :port 1234))))
    (let ((exepath (if (first args) (first args) "nfs.exe"))
	  quiet)
      (setf *configfile* (merge-pathnames "nfs.cfg" exepath))
      (pop args) ;; program name

      #+nfs-demo (demoware-setup)
    
      (if (member "/quiet" args :test #'string=)
	  (setf quiet t))
      (setf args (remove "/quiet" args :test #'string=))

      (dolist (arg args)
	(cond
	 ((string= arg "/install")
	  (create-service exepath))
	 ((string= arg "/remove")
	  (delete-service))
	 ((string= arg "/start")
	  (start-service))
	 ((string= arg "/stop")
	  (stop-service))
	 ((string= arg "/service")
	  (setf *program-mode* :service)	  
	  (read-nfs-cfg *configfile*)
	  (tnserver)
	  (ntservice:execute-service *service-name*
				     #'mainloop 
				     :init #'startem
				     :stop #'stopem)
	  ;; just in case
	  (exit 0))
	 ((string= arg "/console")
	  (console quiet))
	 (t
	  (logit "Ignoring unrecognized command line argument: ~A~%" arg))))
    
      ;; If there were any switches, exit now.
      (when args
	(exit (if quiet 0 1)))

      ;; standalone execution.
      (read-nfs-cfg *configfile*)
      (startem)
      (tnserver)
      (mainloop))))

;; XXXX FIXME XXXXX
;; Temporary until the function is updated in the Allegro NFS build
;; lisp.

(in-package :ntservice)

(eval-when (compile eval)
(defconstant STANDARD_RIGHTS_REQUIRED #x000F0000)

(defconstant SC_MANAGER_CONNECT             #x0001)
(defconstant SC_MANAGER_CREATE_SERVICE      #x0002)
(defconstant SC_MANAGER_ENUMERATE_SERVICE   #x0004)
(defconstant SC_MANAGER_LOCK                #x0008)
(defconstant SC_MANAGER_QUERY_LOCK_STATUS   #x0010)
(defconstant SC_MANAGER_MODIFY_BOOT_CONFIG  #x0020)

(defconstant SC_MANAGER_ALL_ACCESS
    (logior STANDARD_RIGHTS_REQUIRED
            SC_MANAGER_CONNECT
            SC_MANAGER_CREATE_SERVICE
            SC_MANAGER_ENUMERATE_SERVICE
            SC_MANAGER_LOCK
            SC_MANAGER_QUERY_LOCK_STATUS
            SC_MANAGER_MODIFY_BOOT_CONFIG))

(defconstant SERVICE_WIN32_OWN_PROCESS      #x00000010)
(defconstant SERVICE_WIN32_SHARE_PROCESS    #x00000020)
(defconstant SERVICE_WIN32
    (logior SERVICE_WIN32_OWN_PROCESS SERVICE_WIN32_SHARE_PROCESS))
(defconstant SERVICE_INTERACTIVE_PROCESS    #x00000100)


(defconstant SERVICE_BOOT_START             #x00000000)
(defconstant SERVICE_SYSTEM_START           #x00000001)
(defconstant SERVICE_AUTO_START             #x00000002)
(defconstant SERVICE_DEMAND_START           #x00000003)
(defconstant SERVICE_DISABLED               #x00000004)

(defconstant SERVICE_ERROR_IGNORE           #x00000000)
(defconstant SERVICE_ERROR_NORMAL           #x00000001)
(defconstant SERVICE_ERROR_SEVERE           #x00000002)
(defconstant SERVICE_ERROR_CRITICAL         #x00000003)


)

(defun create-service (name displaystring cmdline
                       &key (start :manual)
                            (interact-with-desktop t)			
                            (username 0) ;; LocalSystem        
                            (password ""))
  (with-sc-manager (schandle nil nil #.SC_MANAGER_ALL_ACCESS)
    (multiple-value-bind (res err)
        (CreateService
         schandle
         name
         displaystring
         STANDARD_RIGHTS_REQUIRED
         (logior #.SERVICE_WIN32_OWN_PROCESS
                 (if interact-with-desktop #.SERVICE_INTERACTIVE_PROCESS 0))
         (case start
           (:auto #.SERVICE_AUTO_START)
           (:manual #.SERVICE_DEMAND_START)
           (t (error "create-service: Unrecognized start type: ~S" start)))
         #.SERVICE_ERROR_NORMAL
         cmdline
         0 ;; no load order group
         0 ;; no tag identifier
         0 ;; no dependencies
         username
         password)
      (if (/= res 0)
          (CloseServiceHandle res))
      (if (zerop res)
          (values nil err)
        (values t res)))))

(in-package :user)

(defun create-service (path)
  (multiple-value-bind (success code)
      (ntservice:create-service
       *service-name* 
       "Allegro NFS Server" 
       (format nil "~A /service" path)
       :start :auto
       :interact-with-desktop nil)
    (if* success
       then (format t "NFS service successfully installed.~%")
       else (format t "NFS service installation failed: ~A"
		    (ntservice:winstrerror code)))))

(defun delete-service ()
  (multiple-value-bind (success err place)
      (ntservice:delete-service *service-name*)
    (if* success
       then (format t "NFS service successfully uninstalled.~%")
       else (format t "NFS service deinstallation failed.~%(~A) ~A"
		    place (ntservice:winstrerror err)))))



(defun start-service ()
  (multiple-value-bind (success err place)
      (ntservice:start-service *service-name*)
    (if* success
       then (format t "NFS service started.~%")
       else (start-stop-service-err "start" err place))))

(defun stop-service ()
  (multiple-value-bind (success err place)
      (ntservice:stop-service *service-name*)
    (if* success
       then (format t "NFS service stopped.~%")
       else (start-stop-service-err "stop" err place))))

(defun start-stop-service-err (op err place)
  (format t "Failed to ~a NFS service: ~@[(~a): ~]~a~%" 
	  op place (if* (numberp err)
		      then (ntservice:winstrerror err)
		      else err))
  (finish-output))


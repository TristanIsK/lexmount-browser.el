;;; http-test.el --- Real HTTP transport journey -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Run only against the local fixture created by http-fixture.py.
;;; Code:
(require 'package)
(setq package-user-dir (expand-file-name ".deps" default-directory))
(package-initialize)
(add-to-list 'load-path default-directory)
(require 'lexmount-browser)
(require 'ert)

(defun lexmount-browser-test-wait (predicate)
  "Wait at most five seconds for PREDICATE."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

;; Batch Emacs has no command-loop idle periods. Schedule idle work normally.
(cl-letf (((symbol-function 'run-with-idle-timer) #'run-at-time))
(let ((lexmount-browser-auth-resource
       (format "http://127.0.0.1:%s/mcp" (getenv "LEXMOUNT_FIXTURE_PORT")))
      (lexmount-browser-auth--token "fixture-token")
      (lexmount-browser-auth--expires (+ (float-time) 3600))
      (mcp-server-wait-initial-time 0))
  (unwind-protect
      (progn
        (call-interactively #'lexmount-browser-connect)
        (lexmount-browser-test-wait (lambda () lexmount-browser--connection))
        (call-interactively #'lexmount-browser-create)
        (lexmount-browser-test-wait (lambda () (not lexmount-browser--busy)))
        (should (equal lexmount-browser--session-id "fixture-browser"))
        (lexmount-browser-open-url "https://example.com")
        (lexmount-browser-test-wait (lambda () (not lexmount-browser--busy)))
        (call-interactively #'lexmount-browser-read)
        (lexmount-browser-test-wait (lambda () (not lexmount-browser--busy)))
        (should (equal (buffer-string) "Example Domain"))
        (call-interactively #'lexmount-browser-screenshot)
        (lexmount-browser-test-wait (lambda () (not lexmount-browser--busy)))
        (should (equal lexmount-browser--image "PNG"))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
          (call-interactively #'lexmount-browser-close))
        (lexmount-browser-test-wait (lambda () (not lexmount-browser--busy)))
        (should-not lexmount-browser--session-id))
    (lexmount-browser--disconnect))))
;;; http-test.el ends here

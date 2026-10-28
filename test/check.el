;;; check.el --- Run package quality checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Compile source and check package metadata and documentation.
;;; Code:
(require 'package)
(setq package-user-dir (expand-file-name ".deps" default-directory))
(package-initialize)
(add-to-list 'load-path default-directory)
(require 'bytecomp)
(require 'checkdoc)
(require 'package-lint)
(setq byte-compile-error-on-warn t)
(dolist (file '("lexmount-browser-auth.el" "lexmount-browser.el"))
  (unless (byte-compile-file file) (error "Compilation failed: %s" file))
  (checkdoc-file file))
(when (get-buffer checkdoc-diagnostic-buffer)
  (with-current-buffer checkdoc-diagnostic-buffer
    (unless (= (buffer-size) 0)
      (princ (buffer-string))
      (error "Documentation check failed"))))
(with-temp-buffer
  (insert-file-contents "lexmount-browser.el")
  (emacs-lisp-mode)
  (let ((errors (package-lint-buffer)))
    (when errors (error "Package lint failed: %S" errors))))
(load (expand-file-name "test/lexmount-browser-test.el") nil t)
(ert-run-tests-batch-and-exit)
;;; check.el ends here

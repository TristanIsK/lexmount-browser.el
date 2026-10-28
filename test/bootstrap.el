;;; bootstrap.el --- Install test dependencies -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Download dependencies into a repository-local package directory.
;;; Code:
(require 'package)
(setq package-user-dir (expand-file-name ".deps" default-directory)
      package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                         ("melpa" . "https://melpa.org/packages/")))
(package-initialize)
(package-refresh-contents)
(dolist (dependency '(mcp package-lint))
  (unless (package-installed-p dependency)
    (package-install dependency)))
;;; bootstrap.el ends here

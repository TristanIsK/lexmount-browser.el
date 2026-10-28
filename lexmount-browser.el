;;; lexmount-browser.el --- Use the LexMount cloud browser -*- lexical-binding: t; -*-

;; Copyright (C) 2026 TristanIsK
;; Author: TristanIsK <286724608+TristanIsK@users.noreply.github.com>
;; Assisted-by: Codex:GPT-6
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (mcp "0.1.0"))
;; Keywords: tools, comm
;; URL: https://github.com/TristanIsK/lexmount-browser.el
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Interactive cloud browsing over the LexMount MCP service.
;; Requires a LexMount account and available service quota.
;; Start with `lexmount-browser-login', then `lexmount-browser-create'.
;; In a session buffer: o opens a URL, r reads page text, s captures a
;; screenshot, v opens the remote view, and k closes the remote session.
;; q only hides the buffer.  It does not close the remote browser.
;; Tokens remain in memory and are discarded by `lexmount-browser-logout'.
;; This package connects to the global service at browser.lexmount.com.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'mcp)
(require 'subr-x)
(require 'lexmount-browser-auth)

(defgroup lexmount-browser nil
  "Interactive LexMount cloud browsing."
  :group 'applications :prefix "lexmount-browser-")

(defcustom lexmount-browser-timeout 90
  "Seconds to wait for an MCP request before reporting an unknown result."
  :type 'natnum :group 'lexmount-browser)

(defvar lexmount-browser--connection nil "Current initialized MCP connection.")
(defvar lexmount-browser--tools nil "Names of tools advertised by the server.")
(defvar lexmount-browser--generation 0 "Generation of the current identity.")
(defvar lexmount-browser--connect-timer nil "MCP connection watchdog timer.")
(defvar lexmount-browser--connecting nil "Non-nil while MCP initializes.")
(defconst lexmount-browser--server-name "lexmount-browser"
  "Dedicated name in the MCP connection registry.")
(defvar-local lexmount-browser--session-id nil "Remote session for this buffer.")
(defvar-local lexmount-browser--owner nil "Identity generation for this buffer.")
(defvar-local lexmount-browser--busy nil "Non-nil while a session request runs.")
(defvar-local lexmount-browser--image nil "Most recent screenshot bytes.")
(defvar-local lexmount-browser--status "Ready" "Status shown in the header.")

(defvar lexmount-browser-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "o") #'lexmount-browser-open-url)
    (define-key map (kbd "r") #'lexmount-browser-read)
    (define-key map (kbd "s") #'lexmount-browser-screenshot)
    (define-key map (kbd "w") #'lexmount-browser-save-screenshot)
    (define-key map (kbd "v") #'lexmount-browser-view)
    (define-key map (kbd "g") #'lexmount-browser-status)
    (define-key map (kbd "k") #'lexmount-browser-close)
    map)
  "Keymap for `lexmount-browser-mode'.")

(define-derived-mode lexmount-browser-mode special-mode "LexMount"
  "Display a remote browser session and its results.
\{lexmount-browser-mode-map}"
  (setq-local header-line-format
              '(:eval (format "LexMount | %s | %s"
                              (or lexmount-browser--session-id "no session")
                              lexmount-browser--status))))

(defun lexmount-browser--display (text)
  "Replace the current session buffer contents with TEXT."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert text)
    (goto-char (point-min))))

(defun lexmount-browser--text (result)
  "Collect MCP text blocks in RESULT."
  (mapconcat (lambda (item) (or (plist-get item :text) ""))
             (seq-filter (lambda (item) (equal (plist-get item :type) "text"))
                         (plist-get result :content)) "\n\n"))

(defun lexmount-browser--data (result)
  "Read structured data in RESULT without evaluating server text."
  (or (plist-get result :structuredContent)
      (condition-case nil
          (json-parse-string (lexmount-browser--text result)
                             :object-type 'plist :array-type 'list
                             :null-object nil :false-object :json-false)
        (json-parse-error nil))))

(defun lexmount-browser--disconnect ()
  "Invalidate outstanding callbacks and detach the MCP transport."
  (cl-incf lexmount-browser--generation)
  (when (timerp lexmount-browser--connect-timer)
    (cancel-timer lexmount-browser--connect-timer))
  (setq lexmount-browser--connect-timer nil)
  (when (gethash lexmount-browser--server-name mcp-server-connections)
    (mcp-stop-server lexmount-browser--server-name)
    (remhash lexmount-browser--server-name mcp-server-connections))
  (setq lexmount-browser--connection nil lexmount-browser--tools nil
        lexmount-browser--connecting nil)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'lexmount-browser-mode)
        (setq lexmount-browser--busy nil
              lexmount-browser--status "Disconnected; remote session may still be active")))))

;;;###autoload
(defun lexmount-browser-logout ()
  "Forget local credentials and disconnect.
Remote browser sessions remain active; close them before logging out."
  (interactive)
  (lexmount-browser--disconnect)
  (lexmount-browser-auth-forget)
  (message "LexMount credentials forgotten; remote sessions were not closed"))

;;;###autoload
(defun lexmount-browser-login ()
  "Authorize LexMount in the system browser, then connect to MCP."
  (interactive)
  (lexmount-browser--disconnect)
  (lexmount-browser-auth-login #'lexmount-browser-connect))

;;;###autoload
(defun lexmount-browser-connect ()
  "Connect using this Emacs process's LexMount authorization."
  (interactive)
  (lexmount-browser-auth-token)
  (when lexmount-browser--connecting (user-error "LexMount is already connecting"))
  (when lexmount-browser--connection (user-error "LexMount is already connected"))
  (setq lexmount-browser--connecting t)
  (let* ((generation lexmount-browser--generation)
         (failed (lambda (&rest _ignored)
                   (when (= generation lexmount-browser--generation)
                     (lexmount-browser--disconnect)
                     (message "LexMount connection failed; run lexmount-browser-login again")))))
    (setq lexmount-browser--connect-timer
          (run-at-time lexmount-browser-timeout nil failed))
    (condition-case err
        (mcp-connect-server
         lexmount-browser--server-name :url lexmount-browser-auth-resource
         :token #'lexmount-browser-auth-token :timeout lexmount-browser-timeout
         :initial-callback
         (lambda (connection)
           (when (= generation lexmount-browser--generation)
             (mcp-async-list-tools
              connection
              (lambda (conn tools)
                (when (= generation lexmount-browser--generation)
                  (cancel-timer lexmount-browser--connect-timer)
                  (setq lexmount-browser--connection conn
                        lexmount-browser--connecting nil
                        lexmount-browser--connect-timer nil
                        lexmount-browser--tools
                        (mapcar (lambda (tool) (plist-get tool :name)) tools))
                  (message "LexMount connected; run lexmount-browser-create")))
              failed)))
         :error-callback failed)
      (error (funcall failed) (signal (car err) (cdr err))))))

(defun lexmount-browser--ready (&optional session)
  "Check connection and, when SESSION is non-nil, buffer ownership."
  (lexmount-browser-auth-token)
  (unless lexmount-browser--connection
    (user-error "Run lexmount-browser-login and wait for the connection"))
  (when session
    (unless (and lexmount-browser--session-id
                 (eq lexmount-browser--owner lexmount-browser--generation))
      (user-error "Select a session for the current login with lexmount-browser-attach")))
  (when lexmount-browser--busy (user-error "A request is still pending in this buffer")))

(defun lexmount-browser--resolve (specific group operation args)
  "Resolve SPECIFIC or GROUP with OPERATION and ARGS from discovery."
  (cond
   ((member specific lexmount-browser--tools) (cons specific args))
   ((member group lexmount-browser--tools)
    (cons group (append (list :operation operation) args)))
   (t (user-error "The server does not advertise %s or %s" specific group))))

(defun lexmount-browser--call (specific group operation args callback)
  "Call SPECIFIC or GROUP OPERATION with ARGS, then CALLBACK.
Preserve the originating buffer and identity.  Never retry a tool call."
  (let* ((call (lexmount-browser--resolve specific group operation args))
         (buffer (current-buffer)) (generation lexmount-browser--generation)
         completed timer
         (failure
          (lambda ()
            (unless completed
              (setq completed t)
              (when (timerp timer) (cancel-timer timer))
              (when (and (buffer-live-p buffer) (= generation lexmount-browser--generation))
                (with-current-buffer buffer
                  (setq lexmount-browser--busy nil
                        lexmount-browser--status "Result uncertain; inspect session before retrying")
                  (lexmount-browser--display
                   "The request failed or timed out. It may have completed remotely.\nUse g to inspect this session, or lexmount-browser-list to recover a created session.\nNo operation was retried.\n")))))))
    (setq lexmount-browser--busy t lexmount-browser--status "Request pending"
          timer (run-at-time lexmount-browser-timeout nil failure))
    (condition-case nil
        (mcp-async-call-tool
         lexmount-browser--connection (car call) (cdr call)
         (lambda (result)
           (unless completed
             (setq completed t)
             (cancel-timer timer)
             (when (= generation lexmount-browser--generation)
               (if (not (buffer-live-p buffer))
                   (message "LexMount result arrived after its buffer closed; use lexmount-browser-list")
                 (with-current-buffer buffer
                   (setq lexmount-browser--busy nil)
                   (if (eq t (plist-get result :isError))
                       (progn (setq lexmount-browser--status "Server reported an error")
                              (lexmount-browser--display (lexmount-browser--text result)))
                     (condition-case nil
                         (progn (setq lexmount-browser--status "Ready")
                                (funcall callback result))
                       (error (setq lexmount-browser--status "Response could not be displayed")
                              (lexmount-browser--display (lexmount-browser--text result))))))))))
         (lambda (_code _message) (funcall failure)))
      (error (funcall failure)))))

(defun lexmount-browser--buffer (name)
  "Open a new NAME buffer owned by the current identity."
  (pop-to-buffer (generate-new-buffer name))
  (lexmount-browser-mode)
  (setq lexmount-browser--owner lexmount-browser--generation))

;;;###autoload
(defun lexmount-browser-create ()
  "Create a remote browser session and display its dedicated buffer."
  (interactive)
  (lexmount-browser--ready)
  (lexmount-browser--buffer "*LexMount session*")
  (lexmount-browser--call
   "browser_session_create" "session" "create" '(:wait_for_ready t)
   (lambda (result)
     (let ((id (plist-get (lexmount-browser--data result) :session_id)))
       (unless (and (stringp id) (not (string-empty-p id)))
         (error "No session identifier returned"))
       (setq lexmount-browser--session-id id)
       (rename-buffer (format "*LexMount %s*" id) t)
       (lexmount-browser--display
        (concat "Session created.\n\no: open URL   r: read text   s: screenshot\nv: remote view   g: status   k: close session\n\n"
                (lexmount-browser--text result)))))))

;;;###autoload
(defun lexmount-browser-list ()
  "List remote sessions to find or recover an existing browser."
  (interactive)
  (lexmount-browser--ready)
  (lexmount-browser--buffer "*LexMount sessions*")
  (lexmount-browser--call
   "browser_sessions_list" "session" "list" '(:page 1 :page_size 100)
   (lambda (result)
     (lexmount-browser--display
      (concat "First page (up to 100 sessions). Attach an ID with lexmount-browser-attach.\n\n"
              (lexmount-browser--text result))))))

;;;###autoload
(defun lexmount-browser-attach (id)
  "Attach to the existing remote session ID after verifying access."
  (interactive "sLexMount session ID: ")
  (lexmount-browser--ready)
  (when (string-empty-p id) (user-error "A session ID is required"))
  (lexmount-browser--buffer (format "*LexMount %s*" id))
  (lexmount-browser--call
   "browser_session_get" "session" "get" (list :session_id id)
   (lambda (result)
     (let ((data (lexmount-browser--data result)))
       (unless (equal id (plist-get data :session_id))
         (error "Session response did not match"))
       (unless (equal "closed" (plist-get data :status))
         (setq lexmount-browser--session-id id))
       (lexmount-browser--display (lexmount-browser--text result))))))

(defun lexmount-browser-open-url (url)
  "Navigate this remote session to URL."
  (interactive "sOpen URL: ")
  (lexmount-browser--ready t)
  (unless (member (url-type (url-generic-parse-url url)) '("https" "http"))
    (user-error "Enter an HTTP or HTTPS URL"))
  (lexmount-browser--call
   "browser_open_url" "navigate" "open_url"
   (list :session_id lexmount-browser--session-id :url url)
   (lambda (result)
     (setq lexmount-browser--image nil)
     (lexmount-browser--display (lexmount-browser--text result)))))

(defun lexmount-browser-read ()
  "Read visible page body text into this session buffer."
  (interactive)
  (lexmount-browser--ready t)
  (lexmount-browser--call
   "browser_page_text" "read" "get_text"
   (list :session_id lexmount-browser--session-id :selector "body" :max_chars 50000)
   (lambda (result)
     (lexmount-browser--display
      (or (plist-get (lexmount-browser--data result) :text)
          (lexmount-browser--text result))))))

(defun lexmount-browser-screenshot ()
  "Capture a PNG screenshot; display it when Emacs supports images."
  (interactive)
  (lexmount-browser--ready t)
  (lexmount-browser--call
   "browser_screenshot" "output" "screenshot"
   (list :session_id lexmount-browser--session-id)
   (lambda (result)
     (let ((image (seq-find (lambda (item)
                             (and (equal (plist-get item :type) "image")
                                  (equal (plist-get item :mimeType) "image/png")))
                           (plist-get result :content))))
       (unless image (error "No PNG image returned"))
       (setq lexmount-browser--image (base64-decode-string (plist-get image :data)))
       (lexmount-browser--display "Screenshot captured. Press w to save the PNG.\n\n")
       (when (and (display-images-p) (image-type-available-p 'png))
         (let ((inhibit-read-only t))
           (goto-char (point-max))
           (insert-image (create-image lexmount-browser--image 'png t))))))))

(defun lexmount-browser-save-screenshot (file)
  "Save the latest screenshot to FILE, asking before overwriting."
  (interactive "FSave PNG to: ")
  (unless lexmount-browser--image (user-error "Capture a screenshot first"))
  (when (or (not (file-exists-p file)) (yes-or-no-p (format "Overwrite %s? " file)))
    (let ((coding-system-for-write 'binary))
      (write-region lexmount-browser--image nil file nil 'silent))
    (message "Screenshot saved to %s" file)))

(defun lexmount-browser-status ()
  "Read this session's current remote status."
  (interactive)
  (lexmount-browser--ready t)
  (lexmount-browser--call
   "browser_session_get" "session" "get" (list :session_id lexmount-browser--session-id)
   (lambda (result)
     (when (equal "closed" (plist-get (lexmount-browser--data result) :status))
       (setq lexmount-browser--session-id nil lexmount-browser--status "Closed"))
     (lexmount-browser--display (lexmount-browser--text result)))))

(defun lexmount-browser-view ()
  "Open this session's live view in the system browser for manual input."
  (interactive)
  (lexmount-browser--ready t)
  (lexmount-browser--call
   "browser_session_get" "session" "get" (list :session_id lexmount-browser--session-id)
   (lambda (result)
     (let* ((data (lexmount-browser--data result))
            (url (or (plist-get data :live_view_url) (plist-get data :inspect_url))))
       (unless (and (stringp url) (equal (url-type (url-generic-parse-url url)) "https"))
         (error "No HTTPS browser view URL returned"))
       (browse-url url)
       (lexmount-browser--display
        "Remote view opened. Finish manual input there, then press r to read fresh page text.\n")))))

(defun lexmount-browser-close ()
  "Close this buffer's remote browser after confirmation."
  (interactive)
  (lexmount-browser--ready t)
  (when (yes-or-no-p (format "Close remote browser %s? " lexmount-browser--session-id))
    (lexmount-browser--call
     "browser_session_close" "session" "close" (list :session_id lexmount-browser--session-id)
     (lambda (result)
       (unless (eq t (plist-get (lexmount-browser--data result) :ok))
         (error "Close not confirmed"))
       (setq lexmount-browser--session-id nil lexmount-browser--status "Close accepted")
       (lexmount-browser--display (lexmount-browser--text result))))))

(provide 'lexmount-browser)
;;; lexmount-browser.el ends here

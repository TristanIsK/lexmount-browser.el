;;; lexmount-browser-auth.el --- LexMount browser authorization -*- lexical-binding: t; -*-

;; Copyright (C) 2026 TristanIsK
;; Author: TristanIsK <286724608+TristanIsK@users.noreply.github.com>
;; Assisted-by: Codex:GPT-6
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

;; Public-client OAuth with PKCE for the global LexMount service.
;; Tokens stay in memory.  Expired credentials require a new login.
;; The server currently advertises authorization_code, not refresh_token.

;;; Code:

(require 'browse-url)
(require 'json)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'url-util)

(defconst lexmount-browser-auth-resource
  "https://browser.lexmount.com/chatgpt-app/mcp"
  "Global LexMount MCP resource.")
(defconst lexmount-browser-auth--issuer "https://browser.lexmount.com"
  "Expected authorization server origin.")
(defconst lexmount-browser-auth-client-id
  "https://raw.githubusercontent.com/TristanIsK/lexmount-browser.el/main/oauth-client.json"
  "Public OAuth client metadata document.")
(defconst lexmount-browser-auth--redirect "http://127.0.0.1:8976/oauth/callback"
  "Registered loopback callback URI.")
(defvar lexmount-browser-auth--token nil "Current in-memory access token.")
(defvar lexmount-browser-auth--expires 0 "Access token expiry as epoch seconds.")
(defvar lexmount-browser-auth--server nil "Pending loopback listener.")
(defvar lexmount-browser-auth--timer nil "Pending login timeout timer.")
(defvar lexmount-browser-auth--state nil "Pending OAuth state.")
(defvar lexmount-browser-auth--verifier nil "Pending PKCE verifier.")
(defvar lexmount-browser-auth--token-url nil "Discovered token endpoint.")
(defvar lexmount-browser-auth--callback nil "Successful login callback.")

(defun lexmount-browser-auth-token ()
  "Return a valid access token, or signal that login is required."
  (unless (and lexmount-browser-auth--token
               (< (+ (float-time) 30) lexmount-browser-auth--expires))
    (user-error "Run M-x lexmount-browser-login to authorize LexMount"))
  lexmount-browser-auth--token)

(defun lexmount-browser-auth--encode (pairs)
  "Encode string PAIRS as an application/x-www-form-urlencoded body."
  (mapconcat (lambda (pair)
               (concat (url-hexify-string (car pair)) "="
                       (url-hexify-string (cdr pair)))) pairs "&"))

(defun lexmount-browser-auth--https-endpoint (url)
  "Validate URL as an HTTPS endpoint on the expected issuer."
  (let ((parsed (and (stringp url) (url-generic-parse-url url))))
    (unless (and parsed (equal (url-type parsed) "https")
                 (equal (url-host parsed) "browser.lexmount.com")
                 (= (url-port parsed) 443)
                 (not (url-user parsed)) (not (url-password parsed))
                 (not (url-target parsed)))
      (error "Unexpected LexMount OAuth endpoint")))
  url)

(defun lexmount-browser-auth--json (url &optional form)
  "Read a JSON response from HTTPS URL, posting FORM when provided.
Do not follow redirects or include response bodies in error messages."
  (lexmount-browser-auth--https-endpoint url)
  (let* ((url-request-method (if form "POST" "GET"))
         (url-request-extra-headers
          (append '(("Accept" . "application/json"))
                  (when form '(("Content-Type" . "application/x-www-form-urlencoded")))))
         (url-request-data (when form (lexmount-browser-auth--encode form)))
         (url-max-redirections 0)
         (url-privacy-level 'paranoid)
         (url-automatic-caching nil)
         (url-show-status nil)
         (buffer (url-retrieve-synchronously url t t 20)))
    (unless buffer (error "LexMount OAuth request timed out"))
    (unwind-protect
        (with-current-buffer buffer
          (unless (and (boundp 'url-http-response-status)
                       (= url-http-response-status 200))
            (error "LexMount OAuth request failed (HTTP %s)"
                   (if (boundp 'url-http-response-status) url-http-response-status "unknown")))
          (goto-char (point-min))
          (unless (re-search-forward "\r?\n\r?\n" nil t)
            (error "Invalid OAuth HTTP response"))
          (json-parse-buffer :object-type 'plist :array-type 'list
                             :null-object nil :false-object :json-false))
      (kill-buffer buffer))))

(defun lexmount-browser-auth--random ()
  "Return 256 bits of operating-system randomness through OpenSSL."
  (unless (executable-find "openssl")
    (user-error "Install OpenSSL and make openssl available in exec-path"))
  (with-temp-buffer
    (unless (and (eq 0 (call-process "openssl" nil t nil "rand" "-hex" "32"))
                 (string-match-p "\\`[0-9a-f]\\{64\\}\\'"
                                 (string-trim (buffer-string))))
      (error "OpenSSL could not generate secure OAuth randomness"))
    (string-trim (buffer-string))))

(defun lexmount-browser-auth--base64url (bytes)
  "Encode BYTES using unpadded URL-safe base64."
  (string-replace "/" "_" (string-replace "+" "-"
    (replace-regexp-in-string "=+\\'" "" (base64-encode-string bytes t)))))

(defun lexmount-browser-auth-cancel ()
  "Cancel a pending login and close its listener."
  (interactive)
  (when (timerp lexmount-browser-auth--timer)
    (cancel-timer lexmount-browser-auth--timer))
  (when (process-live-p lexmount-browser-auth--server)
    (delete-process lexmount-browser-auth--server))
  (setq lexmount-browser-auth--server nil lexmount-browser-auth--timer nil
        lexmount-browser-auth--state nil lexmount-browser-auth--verifier nil
        lexmount-browser-auth--token-url nil lexmount-browser-auth--callback nil))

(defun lexmount-browser-auth-forget ()
  "Forget credentials and cancel pending authorization."
  (lexmount-browser-auth-cancel)
  (setq lexmount-browser-auth--token nil lexmount-browser-auth--expires 0))

(defun lexmount-browser-auth--query (target)
  "Parse an OAuth callback TARGET, rejecting duplicate parameters."
  (unless (string-prefix-p "/oauth/callback?" target)
    (error "Unexpected OAuth callback path"))
  (let ((pairs (url-parse-query-string (substring target (length "/oauth/callback?"))))
        seen)
    (dolist (pair pairs)
      (when (or (member (car pair) seen) (/= (length pair) 2))
        (error "Duplicate OAuth callback parameter"))
      (push (car pair) seen))
    pairs))

(defun lexmount-browser-auth--exchange (code verifier token-url callback)
  "Exchange CODE and VERIFIER at TOKEN-URL, then invoke CALLBACK."
  (condition-case nil
      (let* ((reply (lexmount-browser-auth--json
                     token-url
                     `(("grant_type" . "authorization_code")
                       ("client_id" . ,lexmount-browser-auth-client-id)
                       ("redirect_uri" . ,lexmount-browser-auth--redirect)
                       ("resource" . ,lexmount-browser-auth-resource)
                       ("code" . ,code) ("code_verifier" . ,verifier))))
             (token (plist-get reply :access_token))
             (seconds (plist-get reply :expires_in)))
        (unless (and (stringp token) (not (string-empty-p token))
                     (equal (downcase (or (plist-get reply :token_type) "")) "bearer")
                     (numberp seconds) (> seconds 30))
          (error "Invalid token response"))
        (setq lexmount-browser-auth--token token
              lexmount-browser-auth--expires (+ (float-time) seconds))
        (funcall callback))
    (error (message "LexMount authorization failed; run lexmount-browser-login again"))))

(defun lexmount-browser-auth--filter (process chunk)
  "Handle a loopback HTTP callback from PROCESS with CHUNK."
  (let ((request (concat (or (process-get process 'request) "") chunk)))
    (process-put process 'request request)
    (cond
     ((> (length request) 8192) (delete-process process))
     ((string-match "\r\n\r\n" request)
      (let ((status "400 Bad Request")
            (body "Invalid callback. Return to Emacs.")
            exchange)
        (condition-case nil
            (progn
              (unless (string-match "\\`GET \\([^ ]+\\) HTTP/1\\.[01]\r\n" request)
                (error "Invalid callback request"))
              (let* ((query (lexmount-browser-auth--query (match-string 1 request)))
                     (state (cadr (assoc "state" query)))
                     (code (cadr (assoc "code" query))))
                (unless (and lexmount-browser-auth--state
                             (equal state lexmount-browser-auth--state))
                  (error "Invalid OAuth state"))
                (if (assoc "error" query)
                    (progn (lexmount-browser-auth-cancel)
                           (setq body "Authorization declined. Return to Emacs."))
                  (unless (and (stringp code) (not (string-empty-p code)))
                    (error "Missing authorization code"))
                  (setq exchange (list code lexmount-browser-auth--verifier
                                       lexmount-browser-auth--token-url
                                       lexmount-browser-auth--callback)
                        status "200 OK" body "Authorization received. Return to Emacs.")
                  (lexmount-browser-auth-cancel))))
          (error nil))
        (process-send-string process
                             (format "HTTP/1.1 %s\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n%s"
                                     status (string-bytes body) body))
        (delete-process process)
        (when exchange
          (apply #'lexmount-browser-auth--exchange exchange)))))))

(defun lexmount-browser-auth-login (callback)
  "Start browser authorization and invoke CALLBACK on success."
  (lexmount-browser-auth-forget)
  (let* ((resource (lexmount-browser-auth--json
                    (concat lexmount-browser-auth--issuer
                            "/chatgpt-app/.well-known/oauth-protected-resource")))
         (metadata (lexmount-browser-auth--json
                    (concat lexmount-browser-auth--issuer
                            "/.well-known/oauth-authorization-server")))
         (authorize (lexmount-browser-auth--https-endpoint
                     (plist-get metadata :authorization_endpoint)))
         (token-url (lexmount-browser-auth--https-endpoint
                     (plist-get metadata :token_endpoint))))
    (unless (and (equal (plist-get resource :resource) lexmount-browser-auth-resource)
                 (member lexmount-browser-auth--issuer (plist-get resource :authorization_servers))
                 (equal (plist-get metadata :issuer) lexmount-browser-auth--issuer)
                 (member "S256" (plist-get metadata :code_challenge_methods_supported))
                 (eq t (plist-get metadata :client_id_metadata_document_supported)))
      (user-error "LexMount OAuth discovery is incompatible with this package"))
    (condition-case err
        (progn
          (setq lexmount-browser-auth--state
                (lexmount-browser-auth--random)
                lexmount-browser-auth--verifier
                (lexmount-browser-auth--random)
                lexmount-browser-auth--callback callback
                lexmount-browser-auth--token-url token-url
                lexmount-browser-auth--server
                (make-network-process :name "lexmount-browser-oauth" :server t
                                      :host "127.0.0.1" :service 8976
                                      :family 'ipv4 :noquery t :coding 'binary
                                      :filter #'lexmount-browser-auth--filter)
                lexmount-browser-auth--timer
                (run-at-time 300 nil
                             (lambda ()
                               (lexmount-browser-auth-cancel)
                               (message "LexMount login timed out; run lexmount-browser-login again"))))
          (browse-url
           (concat authorize "?"
                   (lexmount-browser-auth--encode
                    `(("response_type" . "code")
                      ("client_id" . ,lexmount-browser-auth-client-id)
                      ("redirect_uri" . ,lexmount-browser-auth--redirect)
                      ("resource" . ,lexmount-browser-auth-resource)
                      ("scope" . "browser.session:create")
                      ("state" . ,lexmount-browser-auth--state)
                      ("code_challenge_method" . "S256")
                      ("code_challenge" . ,(lexmount-browser-auth--base64url
                                             (secure-hash 'sha256 lexmount-browser-auth--verifier nil nil t)))))))
          (message "Authorize LexMount in your browser; the callback waits for five minutes"))
      (error (lexmount-browser-auth-cancel) (signal (car err) (cdr err))))))

(provide 'lexmount-browser-auth)
;;; lexmount-browser-auth.el ends here

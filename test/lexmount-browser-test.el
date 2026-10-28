;;; lexmount-browser-test.el --- Package regression tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; ERT regressions for identity, tool contracts, and OAuth callback handling.
;;; Code:
(require 'ert)
(require 'lexmount-browser)

(defmacro lexmount-browser-test--connected (&rest body)
  "Run BODY with isolated credentials and a session buffer."
  (declare (indent 0) (debug t))
  `(let ((lexmount-browser-auth--token "fixture-token")
         (lexmount-browser-auth--expires (+ (float-time) 3600))
         (lexmount-browser--connection 'fixture-connection)
         (lexmount-browser--tools '("session" "navigate" "read" "output"))
         (lexmount-browser--generation 7))
     (with-temp-buffer
       (lexmount-browser-mode)
       (setq lexmount-browser--owner 7 lexmount-browser--session-id "session-a")
       ,@body)))

(ert-deftest lexmount-browser-test-pkce-rfc7636 ()
  (should (equal
           (lexmount-browser-auth--base64url
            (secure-hash 'sha256 "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk" nil nil t))
           "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")))

(ert-deftest lexmount-browser-test-random-fails-closed ()
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
    (should-error (lexmount-browser-auth--random) :type 'user-error)))

(ert-deftest lexmount-browser-test-random-size ()
  (let ((a (lexmount-browser-auth--random)) (b (lexmount-browser-auth--random)))
    (should (= 64 (length a)))
    (should-not (equal a b))))

(ert-deftest lexmount-browser-test-discovery-origin ()
  (dolist (url '("http://browser.lexmount.com/oauth/token"
                 "https://evil.example/oauth/token"
                 "https://browser.lexmount.com.evil.example/oauth/token"
                 "https://user@browser.lexmount.com/oauth/token"
                 "https://browser.lexmount.com:9443/oauth/token"))
    (should-error (lexmount-browser-auth--https-endpoint url)))
  (should (lexmount-browser-auth--https-endpoint "https://browser.lexmount.com/oauth/token")))

(ert-deftest lexmount-browser-test-expired-token ()
  (let ((lexmount-browser-auth--token "expired") (lexmount-browser-auth--expires 1))
    (should-error (lexmount-browser-auth-token) :type 'user-error)))

(ert-deftest lexmount-browser-test-callback-duplicates ()
  (should-error (lexmount-browser-auth--query "/oauth/callback?state=a&state=b&code=c"))
  (should-error (lexmount-browser-auth--query "/other?state=a&code=c"))
  (should (equal (cadr (assoc "code" (lexmount-browser-auth--query
                                     "/oauth/callback?state=a&code=a%2Bb"))) "a+b")))

(ert-deftest lexmount-browser-test-callback-state-and-once ()
  (let ((lexmount-browser-auth--state "expected")
        (lexmount-browser-auth--verifier "verifier")
        (lexmount-browser-auth--token-url "https://browser.lexmount.com/oauth/token")
        (lexmount-browser-auth--callback #'ignore)
        (lexmount-browser-auth--server nil) (lexmount-browser-auth--timer nil)
        (requests (make-hash-table)) sent exchanges)
    (cl-letf (((symbol-function 'process-get) (lambda (p _) (gethash p requests)))
              ((symbol-function 'process-put) (lambda (p _ v) (puthash p v requests)))
              ((symbol-function 'process-send-string) (lambda (_ s) (push s sent)))
              ((symbol-function 'delete-process) #'ignore)
              ((symbol-function 'process-live-p) (lambda (_) nil))
              ((symbol-function 'lexmount-browser-auth--exchange)
               (lambda (&rest values) (push values exchanges))))
      (lexmount-browser-auth--filter 'bad "GET /oauth/callback?state=wrong&code=x HTTP/1.1\r\n\r\n")
      (should (string-prefix-p "HTTP/1.1 400" (car sent)))
      (should (equal lexmount-browser-auth--state "expected"))
      (should-not exchanges)
      (lexmount-browser-auth--filter 'good "GET /oauth/callback?state=expected&code=ok HTTP/1.1\r\n")
      (should-not exchanges)
      (lexmount-browser-auth--filter 'good "\r\n")
      (should (= 1 (length exchanges)))
      (should (equal (caar exchanges) "ok"))
      (should-not lexmount-browser-auth--state)
      (lexmount-browser-auth--filter 'replay "GET /oauth/callback?state=expected&code=ok HTTP/1.1\r\n\r\n")
      (should (= 1 (length exchanges))))))

(ert-deftest lexmount-browser-test-token-exchange-contract ()
  (let (captured success lexmount-browser-auth--token (lexmount-browser-auth--expires 0))
    (cl-letf (((symbol-function 'lexmount-browser-auth--json)
               (lambda (_ form)
                 (setq captured form)
                 '(:access_token "fixture" :token_type "Bearer" :expires_in 3600))))
      (lexmount-browser-auth--exchange "code" "verifier"
                                      "https://browser.lexmount.com/oauth/token"
                                      (lambda () (setq success t)))
      (should success)
      (should (equal (cdr (assoc "resource" captured)) lexmount-browser-auth-resource))
      (should (equal (cdr (assoc "code_verifier" captured)) "verifier"))
      (should-not (assoc "client_secret" captured))
      (should (equal (lexmount-browser-auth-token) "fixture")))))

(ert-deftest lexmount-browser-test-tool-discovery-parity ()
  (let ((lexmount-browser--tools '("browser_session_create" "session")))
    (should (equal (lexmount-browser--resolve "browser_session_create" "session" "create" '(:wait_for_ready t))
                   '("browser_session_create" :wait_for_ready t))))
  (let ((lexmount-browser--tools '("session")))
    (should (equal (lexmount-browser--resolve "browser_session_create" "session" "create" '(:wait_for_ready t))
                   '("session" :operation "create" :wait_for_ready t))))
  (let ((lexmount-browser--tools nil))
    (should-error (lexmount-browser--resolve "missing" "session" "create" nil))))

(ert-deftest lexmount-browser-test-identity-isolation ()
  (lexmount-browser-test--connected
    (setq lexmount-browser--owner 6)
    (should-error (lexmount-browser-read) :type 'user-error)))

(ert-deftest lexmount-browser-test-request-body ()
  (lexmount-browser-test--connected
    (cl-letf (((symbol-function 'mcp-async-call-tool)
               (lambda (_ tool arguments success _failure)
                 (should (equal tool "read"))
                 (should (equal arguments '(:operation "get_text" :session_id "session-a" :selector "body" :max_chars 50000)))
                 (funcall success '(:structuredContent (:text "Example Domain"))))))
      (call-interactively #'lexmount-browser-read)
      (should (equal (buffer-string) "Example Domain"))
      (should-not lexmount-browser--busy))))

(ert-deftest lexmount-browser-test-server-error-not-success ()
  (lexmount-browser-test--connected
    (cl-letf (((symbol-function 'mcp-async-call-tool)
               (lambda (_ _tool _arguments success _failure)
                 (funcall success '(:isError t :content [(:type "text" :text "Denied")])))))
      (lexmount-browser-read)
      (should (equal (buffer-string) "Denied"))
      (should (equal lexmount-browser--session-id "session-a"))
      (should-not lexmount-browser--busy))))

(ert-deftest lexmount-browser-test-origin-buffer ()
  (lexmount-browser-test--connected
    (let ((origin (current-buffer)) callback)
      (cl-letf (((symbol-function 'mcp-async-call-tool)
                 (lambda (_ _tool _arguments success _failure) (setq callback success))))
        (lexmount-browser-read)
        (with-temp-buffer
          (insert "Other buffer")
          (funcall callback '(:structuredContent (:text "Result")))
          (should (equal (buffer-string) "Other buffer")))
        (should (equal (with-current-buffer origin (buffer-string)) "Result"))))))

(ert-deftest lexmount-browser-test-old-identity-callback ()
  (lexmount-browser-test--connected
    (let (callback)
      (cl-letf (((symbol-function 'mcp-async-call-tool)
                 (lambda (_ _tool _arguments success _failure) (setq callback success))))
        (lexmount-browser-read)
        (cl-incf lexmount-browser--generation)
        (funcall callback '(:structuredContent (:text "Old identity data")))
        (should-not (string-match-p "Old identity" (buffer-string)))))))

(ert-deftest lexmount-browser-test-timeout-never-retries-or-applies-late-result ()
  (lexmount-browser-test--connected
    (let (timeout callback (calls 0))
      (cl-letf (((symbol-function 'run-at-time) (lambda (_ _repeat fn) (setq timeout fn) 'fake-timer))
                ((symbol-function 'cancel-timer) #'ignore)
                ((symbol-function 'mcp-async-call-tool)
                 (lambda (_ _tool _arguments success _failure)
                   (cl-incf calls) (setq callback success))))
        (lexmount-browser-read)
        (funcall timeout)
        (should-not lexmount-browser--busy)
        (should (string-match-p "may have completed remotely" (buffer-string)))
        (funcall callback '(:structuredContent (:text "Late success")))
        (should-not (string-match-p "Late success" (buffer-string)))
        (should (= calls 1))))))

(ert-deftest lexmount-browser-test-pending-guard ()
  (lexmount-browser-test--connected
    (setq lexmount-browser--busy t)
    (should-error (lexmount-browser-read) :type 'user-error)))

(ert-deftest lexmount-browser-test-invalid-navigation ()
  (lexmount-browser-test--connected
    (should-error (lexmount-browser-open-url "file:///etc/passwd") :type 'user-error)))

(ert-deftest lexmount-browser-test-screenshot-content-shape ()
  (lexmount-browser-test--connected
    (cl-letf (((symbol-function 'mcp-async-call-tool)
               (lambda (_ _tool _arguments success _failure)
                 (funcall success '(:structuredContent (:mime_type "image/png")
                                    :content [(:type "image" :mimeType "image/png" :data "UE5H")]))))
              ((symbol-function 'display-images-p) (lambda () nil)))
      (lexmount-browser-screenshot)
      (should (equal lexmount-browser--image "PNG"))
      (should (string-match-p "Press w" (buffer-string))))))

(ert-deftest lexmount-browser-test-close-failure-preserves-session ()
  (lexmount-browser-test--connected
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t))
              ((symbol-function 'mcp-async-call-tool)
               (lambda (_ _tool _arguments success _failure)
                 (funcall success '(:isError t :content [(:type "text" :text "Close failed")])))))
      (lexmount-browser-close)
      (should (equal lexmount-browser--session-id "session-a")))))

(ert-deftest lexmount-browser-test-close-success-clears-session ()
  (lexmount-browser-test--connected
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t))
              ((symbol-function 'mcp-async-call-tool)
               (lambda (_ _tool _arguments success _failure)
                 (funcall success '(:structuredContent (:ok t))))))
      (lexmount-browser-close)
      (should-not lexmount-browser--session-id))))

(provide 'lexmount-browser-test)
;;; lexmount-browser-test.el ends here

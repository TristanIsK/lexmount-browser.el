# Validation record

Date: 2026-10-28. Implementation commit: 6b80382addeec9264b203c480c759a56868e0a08.

- Local macOS Emacs 31.1: 20 ERT regressions passed; byte compilation with warnings
  as errors, checkdoc, and package-lint passed.
- Local HTTP fixture: public commands use the real MELPA mcp.el transport to
  initialize, discover tools, create a session, navigate, read, capture an image,
  and close. The fixture asserts bearer authentication, MCP session headers and
  tool request shapes. Batch Emacs idle timers are scheduled as ordinary timers
  because batch mode has no interactive idle command loop.
- GitHub Actions: Emacs 30.2 and 31.1 passed for the implementation commit.
  https://github.com/TristanIsK/lexmount-browser.el/actions/runs/40648277334
- MELPA package-build: fetched the public repository, built the recipe archive,
  and included only the two source files and generated package metadata.
- Clean package-install-file: installed the archive and the MCP dependency in an
  isolated Emacs package directory; login and create commands loaded correctly.
- Production: the public OAuth client metadata was recognized; the human user
  approved the client. Emacs performed PKCE token exchange, MCP initialization
  and discovery, browser creation, navigation to example.com, text extraction,
  PNG screenshot capture, and close. The screenshot was visually inspected.
- Closing evidence: the Emacs close command received success. An immediate status
  check did not satisfy the closed-state assertion. A subsequent read through the
  installed LexMount MCP connection confirmed status `closed`. Do not describe
  immediate close acknowledgement as proof that termination has completed.

The first live text assertion expected an obsolete example.com heading. Actual
text extraction succeeded; the assertion was corrected to match observed page
content. The service client's implementation did not need a change for this.

## Boundaries

This is an initial preview, not a mature release or a guarantee covering every
website. Windows, SSH callback forwarding, and interactive image rendering in a
graphical Emacs build were not tested. PNG bytes were captured and inspected
outside the terminal Emacs. The system-browser live-view command was not manually exercised on a signed-in
third-party website; only its underlying session transport was verified. Token refresh is intentionally unsupported until
the service advertises that grant. Browser sessions require explicit closure.

No LexMount backend, gateway, web UI, or CLI/runtime source was changed.

MELPA has not accepted or published the package. The current submission template
requires at least one month of public maintenance, and the human maintainer must
review AI-assisted code. The repository was created on 2026-10-28; 2026-11-28 is
the earliest calendar eligibility date, not an acceptance promise.

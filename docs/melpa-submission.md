# MELPA submission preparation

Do not submit this draft until at least one month of public maintenance has
elapsed and the human maintainer has reviewed the package. Earliest calendar
eligibility: 2026-11-28, based on repository creation on 2026-10-28.

Source of the maintenance requirement:
https://github.com/melpa/melpa/blob/master/.github/PULL_REQUEST_TEMPLATE.md

Recheck the current template and CONTRIBUTING.org at submission time, rerun
checks against the latest commit, and rebuild/install the recipe before marking
the corresponding items complete. Copy recipes/lexmount-browser into a branch
of a fork of melpa/melpa, then open one recipe PR.

Suggested title: Add recipe for lexmount-browser

## Brief summary of what the package does

Interactive Emacs commands for the LexMount cloud browser: OAuth PKCE login,
remote session creation and attachment, navigation, page-text extraction, PNG
screenshots, system-browser live view, and explicit session closure. Uses the
existing mcp package for transport. Adds service-specific interactive workflows
and authentication rather than duplicating a general MCP client or AI assistant.

## Direct link to the package repository

https://github.com/TristanIsK/lexmount-browser.el

## Your association with the package

Repository owner and maintainer. Initial implementation assisted by Codex (GPT-6).

## Relevant communications with the upstream package maintainer

None needed; submitted by the package maintainer.

## Checklist to complete at submission time

- [x] The package is released under GPL-3.0-or-later.
- [ ] The human maintainer has read the current CONTRIBUTING.org.
- [x] AI assistance is disclosed using Assisted-by source headers.
- [ ] The package has been maintained in a public repository for at least one month.
- [ ] The human maintainer has thoroughly reviewed the AI-assisted implementation.
- [ ] The latest package-lint has been rerun against the submission commit.
- [ ] The submission commit byte-compiles cleanly.
- [ ] checkdoc passes on the submission commit.
- [ ] The recipe has been rebuilt and installed from the submission commit.

Initial automated and live evidence is recorded in VALIDATION.md; that evidence
must not be presented as validation of future commits.

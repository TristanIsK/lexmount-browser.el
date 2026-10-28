EMACS ?= emacs

.PHONY: bootstrap check http-test
bootstrap:
	$(EMACS) -Q --batch -l test/bootstrap.el

check:
	$(EMACS) -Q --batch -l test/check.el

http-test:
	python3 test/http-fixture.py

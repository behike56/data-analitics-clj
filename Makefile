SHELL := /bin/sh

.DEFAULT_GOAL := check

CLOJURE_PATHS := data-analitics-clj/src statistics/src data-analitics-clj/test
WORKFLOW_PATH := .github/workflows
WORKFLOW_FILES := $(wildcard $(WORKFLOW_PATH)/*.yaml $(WORKFLOW_PATH)/*.yml)
REQUIRED_TOOLS := java clojure clj-kondo cljfmt actionlint zizmor

.PHONY: check check-workflows check-clojure doctor versions deps lint format-check format test smoke actionlint zizmor

check: doctor check-workflows check-clojure

check-workflows: actionlint zizmor

check-clojure: deps lint format-check test smoke

doctor:
	@missing=0; \
	for tool in $(REQUIRED_TOOLS); do \
		if command -v "$$tool" >/dev/null 2>&1; then \
			printf '%-12s %s\n' "$$tool" "$$(command -v "$$tool")"; \
		else \
			printf '%-12s %s\n' "$$tool" "missing"; \
			missing=1; \
		fi; \
	done; \
	if [ "$$missing" -ne 0 ]; then \
		printf '\nInstall the missing tools before running the quality checks.\n'; \
		exit 1; \
	fi

versions: doctor
	java -version
	clojure -Sdescribe
	clj-kondo --version
	cljfmt --version
	actionlint -version
	zizmor --version

deps:
	clojure -Spath

lint:
	clj-kondo --lint data-analitics-clj/src
	clj-kondo --lint statistics/src
	clj-kondo --lint data-analitics-clj/test
	clj-kondo --lint deps.edn

format-check:
	cljfmt check $(CLOJURE_PATHS)

format:
	cljfmt fix $(CLOJURE_PATHS)

test:
	clojure -X:test

smoke:
	clojure -M -e "(require 'core 'plot 'statistics.core)"

actionlint:
	actionlint $(WORKFLOW_FILES)

zizmor:
	zizmor --no-online-audits $(WORKFLOW_PATH)

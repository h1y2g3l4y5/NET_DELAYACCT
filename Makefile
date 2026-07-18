# SPDX-License-Identifier: GPL-2.0-only
#
# Top-level convenience Makefile for NET_DELAYACCT
#
# Variables:
#   LINUX_SRC  Path to a checked-out linux-6.6 source tree (for checkpatch).
#   CC         Compiler override (e.g. CC=ccache gcc).
#   V          Set to 1 for verbose builds.

TOOL_DIR := userspace/get_sockdelays
TOOL_BIN := $(TOOL_DIR)/get_sockdelays
PATCH_DIR := kernel-patches

LINUX_SRC ?=
CC ?= gcc

.DEFAULT_GOAL := help

.PHONY: help tool checkpatch clean test

help:
	@echo "NET_DELAYACCT convenience targets:"
	@echo "  make tool                 Build the userspace get_sockdelays tool"
	@echo "  make checkpatch           Run scripts/checkpatch.pl on kernel-patches/*.patch"
	@echo "                            (requires LINUX_SRC=/path/to/linux-6.6)"
	@echo "  make test                 Run tests under tests/"
	@echo "  make clean                Remove build artifacts"
	@echo ""
	@echo "Variables:"
	@echo "  LINUX_SRC=<path>          linux-6.6 source tree (for checkpatch)"
	@echo "  CC=<compiler>             Compiler override (default: gcc)"
	@echo "  V=1                       Verbose build"

tool: $(TOOL_BIN)

# Delegate to the tool's own Makefile if present; otherwise this is a stub
# that real sources will hook into once implemented.
$(TOOL_BIN):
	@if [ -f "$(TOOL_DIR)/Makefile" ]; then \
		$(MAKE) -C "$(TOOL_DIR)" CC="$(CC)" V=$(V); \
	else \
		echo "[$(TOOL_DIR)/Makefile not found yet — tool source is a placeholder.]"; \
		echo "Add the get_sockdelays sources and a Makefile under $(TOOL_DIR)/."; \
		exit 1; \
	fi

checkpatch:
	@if [ -z "$(LINUX_SRC)" ]; then \
		echo "ERROR: set LINUX_SRC=/path/to/linux-6.6" >&2; \
		exit 1; \
	fi
	@fail=0; \
	if ! command -v perl >/dev/null 2>&1; then \
		echo "ERROR: perl is required to run checkpatch.pl" >&2; exit 1; \
	fi; \
	patches=$$(ls $(PATCH_DIR)/*.patch 2>/dev/null); \
	if [ -z "$$patches" ]; then \
		echo "No .patch files found in $(PATCH_DIR)/, nothing to check."; \
		exit 0; \
	fi; \
	for p in $$patches; do \
		echo "==> checkpatch $$p"; \
		if ! perl "$(LINUX_SRC)/scripts/checkpatch.pl" --no-tree --strict -f "$$p"; then \
			fail=1; \
		fi; \
	done; \
	exit $$fail

test:
	@echo "Running tests under tests/ (placeholder)..."
	@if [ -d tests/func ] && [ -n "$$(ls -A tests/func 2>/dev/null)" ]; then \
		$(MAKE) -C tests/func test || exit 1; \
	else \
		echo "tests/func is empty — no functional tests to run yet."; \
	fi
	@if [ -d tests/perf ] && [ -n "$$(ls -A tests/perf 2>/dev/null)" ]; then \
		$(MAKE) -C tests/perf test || exit 1; \
	else \
		echo "tests/perf is empty — no performance tests to run yet."; \
	fi

clean:
	@rm -f $(TOOL_BIN)
	@if [ -f "$(TOOL_DIR)/Makefile" ]; then \
		$(MAKE) -C "$(TOOL_DIR)" clean; \
	fi
	@find tests -name '*.log' -o -name '*.tap' -o -name '*.xml' 2>/dev/null | \
		while read f; do rm -f "$$f"; done
	@echo "cleaned."

# SPDX-License-Identifier: GPL-2.0-only
#
# Build the delayacct_path_test helper used by run-tests.sh (Test 19-21).
# This program covers splice/zerocopy/corked paths that iperf3 cannot trigger.
#
# Variables:
#   CC     compiler (default: gcc, may be wrapped with ccache)
#   V      set to 1 for verbose builds
#
# 静态链接优先（方便打包进 initramfs，无需拖依赖库）；若静态 libc 不可用则回退动态链接。

CC      ?= gcc
CFLAGS  ?= -O2 -g -Wall -Wextra -std=gnu11
CFLAGS  += -D_GNU_SOURCE
LDFLAGS ?=
LDLIBS  ?=

BIN     := delayacct_path_test
SRC     := delayacct_path_test.c

.PHONY: all clean

all: $(BIN)

# 尝试静态链接；失败则回退动态链接
$(BIN): $(SRC)
	@echo "  CC+LD   $@"
	@if $(CC) $(CFLAGS) -static $(LDFLAGS) -o $@ $< $(LDLIBS) 2>/dev/null; then \
		echo "  (static linked)"; \
	else \
		$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $< $(LDLIBS); \
		echo "  (dynamic linked)"; \
	fi

clean:
	rm -f $(BIN)

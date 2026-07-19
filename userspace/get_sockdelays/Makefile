# SPDX-License-Identifier: GPL-2.0-only
#
# Build the get_sockdelays userspace tool.
#
# Variables:
#   CC   compiler (default: gcc, may be wrapped with ccache)
#   V    set to 1 for verbose builds

CC      ?= gcc
CFLAGS  ?= -O2 -g -Wall -Wextra -Wno-unused-parameter -std=gnu11
CFLAGS  += -D_GNU_SOURCE
LDFLAGS ?=
LDLIBS  ?= -lmnl

BIN     := get_sockdelays
SRC     := get_sockdelays.c
OBJ     := $(SRC:.c=.o)
DEPS    := $(OBJ:.o=.d)

.PHONY: all clean install

all: $(BIN)

$(BIN): $(OBJ)
	@echo "  LD      $@"
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

%.o: %.c
	@echo "  CC      $@"
	$(CC) $(CFLAGS) -MMD -MP -c -o $@ $<

-include $(DEPS)

install: $(BIN)
	install -m 0755 $(BIN) $(DESTDIR)/usr/local/bin/

clean:
	rm -f $(BIN) $(OBJ) $(DEPS)

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# netns-isolation.sh - Verify netns isolation for get_sockdelays
#
# Tests that the kernel netns filtering (issue 2.2.1) correctly
# isolates socket visibility between network namespaces.
#
# Test cases:
#   1. get_sockdelays inside netns sees only its own sockets
#   2. get_sockdelays inside netns does NOT leak init-netns sockets
#
# Prerequisites:
#   - CONFIG_NET_NS=y
#   - iproute2 (ip netns)
#   - nc (netcat)
#   - get_sockdelays binary in PATH

set -euo pipefail

source "$(dirname "$0")/test_helper.sh"

BINARY="get_sockdelays"
NS_NAME="delayacct_test_ns"
NS_PID=""
TMPFILE=""
LFILE=""

cleanup() {
	kill "$NS_PID" 2>/dev/null || true
	ip netns del "$NS_NAME" 2>/dev/null || true
	rm -f "$TMPFILE" "$LFILE"
}
trap cleanup EXIT

# ----------------------------------------------------------------------
# Test 1: create a listener in a fresh netns, query it from inside,
# and verify it appears
# ----------------------------------------------------------------------
test_netns_own_socket_visible() {
	local header="test_netns_own_socket_visible"
	begin_test "$header"

	TMPFILE=$(mktemp)
	LFILE=$(mktemp)

	ip netns add "$NS_NAME"
	ip netns exec "$NS_NAME" ip link set lo up

	# Start listener inside the netns
	ip netns exec "$NS_NAME" nc -l -p 9876 >/dev/null 2>&1 &
	NS_PID=$!
	sleep 1

	# Extract inode from the netns's own /proc
	local inode
	inode=$(ip netns exec "$NS_NAME" sh -c \
		"ls -l /proc/$NS_PID/fd/ | grep -o 'socket:\[[0-9]*\]'" 2>/dev/null | \
		head -1 | grep -o '[0-9]*')
	if [ -z "$inode" ]; then
		fail_test "$header" "failed to extract socket inode in netns"
		return
	fi

	# Query from inside the netns
	ip netns exec "$NS_NAME" "$BINARY" -i "$inode" >"$LFILE" 2>/dev/null
	if grep -q "PID" "$LFILE" && grep -q "$inode" "$LFILE"; then
		pass_test "$header" "netns-local socket visible"
	else
		fail_test "$header" "netns-local socket NOT visible (got: $(cat "$LFILE"))"
	fi

	kill "$NS_PID" 2>/dev/null || true
	ip netns del "$NS_NAME"
}

# ----------------------------------------------------------------------
# Test 2: start a listener in init netns, query from inside a netns,
# and verify it does NOT leak
# ----------------------------------------------------------------------
test_netns_no_cross_ns_leak() {
	local header="test_netns_no_cross_ns_leak"
	begin_test "$header"

	TMPFILE=$(mktemp)
	LFILE=$(mktemp)

	# Start listener in init netns
	nc -l -p 9877 >/dev/null 2>&1 &
	local INIT_PID=$!
	sleep 1

	# Get its inode in the init netns
	local inode
	inode=$(ls -l /proc/$INIT_PID/fd/ | grep -o 'socket:\[[0-9]*\]' | \
		head -1 | grep -o '[0-9]*')
	if [ -z "$inode" ]; then
		kill "$INIT_PID" 2>/dev/null || true
		fail_test "$header" "failed to extract init-netns socket inode"
		return
	fi

	# Create a separate netns
	ip netns add "$NS_NAME"
	ip netns exec "$NS_NAME" ip link set lo up

	# Query the init-netns inode FROM the netns — must be -ENOENT
	ip netns exec "$NS_NAME" "$BINARY" -i "$inode" >"$LFILE" 2>&1 || true
	if grep -qi "no such" "$LFILE" || ! grep -q "$inode" "$LFILE"; then
		pass_test "$header" "init-netns socket correctly hidden"
	else
		fail_test "$header" "init-netns socket LEAKED into netns (got: $(cat "$LFILE"))"
	fi

	kill "$INIT_PID" 2>/dev/null || true
	ip netns del "$NS_NAME"
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
main() {
	echo "=== netns isolation tests ==="
	echo ""

	run_test test_netns_own_socket_visible
	run_test test_netns_no_cross_ns_leak

	print_summary
}

main "$@"

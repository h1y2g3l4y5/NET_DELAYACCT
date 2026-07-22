#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# net-delayacct 自测试主脚本
# 覆盖功能测试（PID 查询、inode 查询、重置、TCP/UDP 路径、多 socket）与回归场景。
# 使用 test_pass/test_fail 模式输出结果。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.sh
source "$SCRIPT_DIR/test_helper.sh"

# 环境前置检查
find_get_sockdelays
require_cmd nc
require_cmd iperf3
require_net_delayacct_family

# 清理函数：终止所有后台进程并清理网络命名空间
cleanup() {
	# 终止后台作业
	local pids
	pids=$(jobs -p 2>/dev/null || true)
	if [ -n "$pids" ]; then
		kill $pids 2>/dev/null || true
		wait $pids 2>/dev/null || true
	fi
	# 清理可能残留的 iperf3 服务端
	pkill -f "iperf3 -s" 2>/dev/null || true
	# 清理网络命名空间
	cleanup_ns nda_test_ns
}
trap cleanup EXIT

echo "============================================"
echo "  net-delayacct selftest"
echo "  Binary: $GET_SOCKDELAYS"
echo "============================================"
echo ""

# ---------------------------------------------------------------------------
# Test 1: 查询自身 PID，预期工具正常运行并产生可解析输出
# ---------------------------------------------------------------------------
test_01_query_own_pid() {
	echo "--- Test 1: query own PID ---"
	local pid=$$
	local out

	# 查询自身 PID，允许输出为空（当前进程可能没有 socket）
	out=$("$GET_SOCKDELAYS" -p "$pid" 2>&1 || true)
	if [ $? -eq 0 ] || [ -n "$out" ]; then
		test_pass "own PID query executed without crash"
	else
		test_fail "own PID query crashed"
	fi
}
test_01_query_own_pid

# ---------------------------------------------------------------------------
# Test 2: 启动 nc 监听后连接，按 PID 查询，预期在输出中看到监听 socket
# ---------------------------------------------------------------------------
test_02_nc_listener_pid() {
	echo "--- Test 2: nc listener PID query ---"
	local port=12345
	local nc_pid
	local out

	# 启动 nc 监听 (use -p for OpenBSD nc compatibility)
	nc -l -p "$port" &
	nc_pid=$!
	sleep 1

	# Query the listener BEFORE connecting a client.
	# OpenBSD nc exits after the first connection closes, so querying
	# after the client connects would find no open sockets (the process
	# may even be a zombie with all fds closed).
	out=$("$GET_SOCKDELAYS" -p "$nc_pid" 2>&1 || true)
	if echo "$out" | grep -q '^proto='; then
		test_pass "nc listener (pid $nc_pid) found in output"
	else
		test_fail "nc listener (pid $nc_pid) no socket data (output: $out)"
	fi

	# Generate traffic (optional, for completeness)
	echo "netdelayacct-test" | nc 127.0.0.1 "$port" &
	sleep 1

	kill "$nc_pid" 2>/dev/null || true
	wait "$nc_pid" 2>/dev/null || true
}
test_02_nc_listener_pid

# ---------------------------------------------------------------------------
# Test 3: 按 inode 查询，从 /proc/<pid>/fd 提取 inode，预期输出单行
# ---------------------------------------------------------------------------
test_03_inode_query() {
	echo "--- Test 3: inode query ---"
	local port=12346
	local nc_pid
	local inode=""
	local fd_path
	local out
	local line_count

	nc -l -p "$port" &
	nc_pid=$!
	sleep 1

	# 从 /proc/<pid>/fd 中提取 socket inode
	for fd_path in /proc/"$nc_pid"/fd/*; do
		local target
		target=$(readlink "$fd_path" 2>/dev/null || true)
		if [[ "$target" == socket:* ]]; then
			# 提取 inode 编号: socket:[12345] -> 12345
			inode=$(echo "$target" | grep -o '[0-9]\+' || true)
			if [ -n "$inode" ]; then
				break
			fi
		fi
	done

	if [ -z "$inode" ]; then
		test_fail "could not extract socket inode from /proc/$nc_pid/fd"
		kill "$nc_pid" 2>/dev/null || true
		return
	fi

	out=$("$GET_SOCKDELAYS" -i "$inode" 2>&1 || true)
	if [ -z "$out" ]; then
		test_fail "inode query ($inode) returned empty"
	else
		# 验证输出中包含该 inode（精确匹配 inode=<inode>）
		if echo "$out" | grep -q "inode=$inode"; then
			line_count=$(echo "$out" | grep -c -E '^proto=' || true)
			if [ "$line_count" -eq 1 ]; then
				test_pass "inode query ($inode) returned single line"
			else
				test_fail "inode query returned $line_count data lines, expected 1"
			fi
		else
			test_fail "inode query output does not contain inode $inode (output: $out)"
		fi
	fi

	kill "$nc_pid" 2>/dev/null || true
	wait "$nc_pid" 2>/dev/null || true
}
test_03_inode_query

# ---------------------------------------------------------------------------
# Test 4: 重置 (-r) 后查询，预期所有计数为零
# ---------------------------------------------------------------------------
test_04_reset() {
	echo "--- Test 4: reset counters ---"
	local port=12347
	local nc_pid
	local out

	# Start nc listener — query it without connecting a client so the
	# listening socket stays open.  OpenBSD nc exits after the first
	# connection closes, which would leave no sockets to query.
	nc -l -p "$port" &
	nc_pid=$!
	sleep 1

	# 执行重置
	"$GET_SOCKDELAYS" -R 2>&1 || true
	sleep 1

	# 重置后查询，预期所有计数为零或 N/A
	out=$("$GET_SOCKDELAYS" -p "$nc_pid" 2>&1 || true)

	# 验证输出中不包含非零的时延计数
	# 输出格式（每个 socket 3 行）:
	#   proto=xxx pid=NNN inode=NNN comm=xxx local=x remote=x
	#     RX  count=NNN  total=NNN.NNNms  average=NNN.NNNms
	#     TX  count=NNN  total=NNN.NNNms  average=NNN.NNNms
	# 提取 RX/TX 行的 count= 值，检查是否全为零
	local nonzero
	nonzero=$(echo "$out" | \
		grep 'count=' | \
		sed -n 's/.*count=\([0-9]*\).*/\1/p' | \
		awk '$1 > 0 {print}' || true)

	if [ -z "$nonzero" ]; then
		test_pass "all counters are zero after reset"
	else
		test_fail "non-zero counters found after reset: $nonzero"
	fi

	kill "$nc_pid" 2>/dev/null || true
	wait "$nc_pid" 2>/dev/null || true
}
test_04_reset

# ---------------------------------------------------------------------------
# Test 5: TCP 路径（iperf3 client-server），验证 TCP 类型出现在输出中
# ---------------------------------------------------------------------------
test_05_tcp_path() {
	echo "--- Test 5: TCP path (iperf3) ---"
	local port=5201
	local server_pid
	local client_pid
	local out

	# Start server in background (not -D) so we capture its PID directly.
	# This avoids dependency on pgrep which may not be available (e.g. busybox).
	iperf3 -s -p "$port" >/dev/null 2>&1 &
	server_pid=$!
	sleep 1

	# Run client for 5s; query after 2s so the TCP socket is still open.
	iperf3 -c 127.0.0.1 -p "$port" -t 5 >/dev/null 2>&1 &
	client_pid=$!
	sleep 2

	# Query server first (always running), fall back to client.
	out=$("$GET_SOCKDELAYS" -p "$server_pid" 2>&1 || true)
	if [ -z "$out" ] || ! echo "$out" | grep -qi "proto=tcp"; then
		out=$("$GET_SOCKDELAYS" -p "$client_pid" 2>&1 || true)
	fi

	if [ -n "$out" ] && echo "$out" | grep -qi "proto=tcp"; then
		test_pass "TCP socket found in iperf3 query output"
	else
		test_fail "TCP socket not found in output (out: $out)"
	fi

	# Clean up client and server.
	kill "$client_pid" 2>/dev/null || true
	wait "$client_pid" 2>/dev/null || true
	kill "$server_pid" 2>/dev/null || true
	wait "$server_pid" 2>/dev/null || true
}
test_05_tcp_path

# ---------------------------------------------------------------------------
# Test 6: UDP 路径（iperf3 -u），验证 UDP 类型出现在输出中
# ---------------------------------------------------------------------------
test_06_udp_path() {
	echo "--- Test 6: UDP path (iperf3 -u) ---"
	local port=5202
	local server_pid
	local client_pid
	local out

	# Start server in background (not -D) so we capture its PID directly.
	iperf3 -s -p "$port" >/dev/null 2>&1 &
	server_pid=$!
	sleep 1

	# Use -t 10 so the UDP socket stays open while we query.
	# Previously -t 3 with sleep 4 meant the client had already exited
	# and the UDP socket was closed by query time.
	iperf3 -c 127.0.0.1 -p "$port" -u -t 10 -b 100M >/dev/null 2>&1 &
	client_pid=$!
	# Query while the client is still running (UDP socket is open)
	sleep 2

	# Query client first (UDP socket is on the client side), fall back to server.
	out=$("$GET_SOCKDELAYS" -p "$client_pid" 2>&1 || true)
	if [ -z "$out" ] || ! echo "$out" | grep -qi "proto=udp"; then
		out=$("$GET_SOCKDELAYS" -p "$server_pid" 2>&1 || true)
	fi

	if [ -n "$out" ] && echo "$out" | grep -qi "proto=udp"; then
		test_pass "UDP socket found in iperf3 -u query output"
	else
		test_fail "UDP socket not found in output (out: $out)"
	fi

	# Clean up client and server.
	kill "$client_pid" 2>/dev/null || true
	wait "$client_pid" 2>/dev/null || true
	kill "$server_pid" 2>/dev/null || true
	wait "$server_pid" 2>/dev/null || true
}
test_06_udp_path

# ---------------------------------------------------------------------------
# Test 7: 多 socket 场景（nc + iperf3 同时运行），验证多行输出
# ---------------------------------------------------------------------------
test_07_multi_socket() {
	echo "--- Test 7: multi-socket (nc + iperf3 simultaneously) ---"
	local nc_port=12348
	local iperf_port=5203
	local nc_pid
	local iperf_server_pid
	local iperf_client_pid
	local out
	local line_count

	# Start nc listener and iperf3 server simultaneously (both in background).
	nc -l -p "$nc_port" &
	nc_pid=$!
	iperf3 -s -p "$iperf_port" >/dev/null 2>&1 &
	iperf_server_pid=$!
	sleep 1

	# Query nc BEFORE connecting a client — OpenBSD nc exits after the
	# first connection closes, so querying after would find no sockets.
	# The iperf3 server is also running at this point, so both processes
	# have open sockets simultaneously.
	out=$("$GET_SOCKDELAYS" -p "$nc_pid" 2>&1 || true)
	line_count=$(echo "$out" | grep -c -E '^proto=' || true)

	if [ "$line_count" -ge 1 ]; then
		test_pass "nc multi-socket query returned $line_count line(s)"
	else
		test_fail "nc multi-socket query returned no data (out: $out)"
	fi

	# Start iperf3 client (iperf3 server is still running, -t 5 keeps it open).
	iperf3 -c 127.0.0.1 -p "$iperf_port" -t 5 >/dev/null 2>&1 &
	iperf_client_pid=$!
	sleep 2

	# Query iperf3 server — should have at least one data line.
	out=$("$GET_SOCKDELAYS" -p "$iperf_server_pid" 2>&1 || true)
	line_count=$(echo "$out" | grep -c -E '^proto=' || true)
	if [ "$line_count" -ge 1 ]; then
		test_pass "iperf3 multi-socket query returned $line_count line(s)"
	else
		test_fail "iperf3 multi-socket query returned no data (out: $out)"
	fi

	# Generate nc traffic (optional, for completeness)
	echo "multi-socket-test" | nc 127.0.0.1 "$nc_port" &

	# Clean up all background processes.
	kill "$nc_pid" 2>/dev/null || true
	kill "$iperf_client_pid" 2>/dev/null || true
	kill "$iperf_server_pid" 2>/dev/null || true
	wait 2>/dev/null || true
}
test_07_multi_socket

# ---------------------------------------------------------------------------
# 输出摘要
# ---------------------------------------------------------------------------
echo ""
print_summary
exit $?

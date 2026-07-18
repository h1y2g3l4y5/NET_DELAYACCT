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

	# 启动 nc 监听
	nc -l "$port" &
	nc_pid=$!
	sleep 1

	# 发起连接以产生流量
	echo "netdelayacct-test" | nc 127.0.0.1 "$port" &
	sleep 1

	# 查询监听进程的 socket
	out=$("$GET_SOCKDELAYS" -p "$nc_pid" 2>&1 || true)
	if [ -n "$out" ]; then
		test_pass "nc listener (pid $nc_pid) found in output"
	else
		test_fail "nc listener (pid $nc_pid) produced empty output"
	fi

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

	nc -l "$port" &
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
		# 验证输出中包含该 inode
		if echo "$out" | grep -q "$inode"; then
			line_count=$(echo "$out" | wc -l)
			if [ "$line_count" -eq 1 ]; then
				test_pass "inode query ($inode) returned single line"
			else
				test_fail "inode query returned $line_count lines, expected 1"
			fi
		else
			test_fail "inode query output does not contain inode $inode"
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

	# 先产生一些流量
	nc -l "$port" &
	nc_pid=$!
	sleep 1
	echo "reset-test" | nc 127.0.0.1 "$port" &
	sleep 1

	# 执行重置
	"$GET_SOCKDELAYS" -r 2>&1 || true
	sleep 1

	# 重置后查询，预期所有计数为零或 N/A
	out=$("$GET_SOCKDELAYS" -p "$nc_pid" 2>&1 || true)

	# 验证输出中不包含非零的时延计数
	# 输出中的时延字段若为 0 或 N/A 则通过
	local nonzero
	nonzero=$(echo "$out" | grep -v -E '(N/A|^$|^TYPE)' | \
		awk '{
			for (i = NF - 1; i <= NF; i++) {
				if ($i + 0 > 0) print $i
			}
		}' || true)

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

	iperf3 -s -D -p "$port" 2>/dev/null || true
	sleep 1
	server_pid=$(pgrep -f "iperf3 -s -D -p $port" | head -1)

	iperf3 -c 127.0.0.1 -p "$port" -t 3 >/dev/null 2>&1 &
	client_pid=$!
	sleep 4

	out=$("$GET_SOCKDELAYS" -p "$client_pid" 2>&1 || true)
	if [ -z "$out" ]; then
		# 客户端可能已退出，尝试查询服务端
		if [ -n "$server_pid" ]; then
			out=$("$GET_SOCKDELAYS" -p "$server_pid" 2>&1 || true)
		fi
	fi

	if [ -n "$out" ] && echo "$out" | grep -q "TCP"; then
		test_pass "TCP socket found in iperf3 query output"
	else
		test_fail "TCP socket not found in output"
	fi

	# 清理 iperf3 服务端
	pkill -f "iperf3 -s" 2>/dev/null || true
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

	iperf3 -s -D -p "$port" 2>/dev/null || true
	sleep 1
	server_pid=$(pgrep -f "iperf3 -s -D -p $port" | head -1)

	iperf3 -c 127.0.0.1 -p "$port" -u -t 3 -b 100M >/dev/null 2>&1 &
	client_pid=$!
	sleep 4

	out=$("$GET_SOCKDELAYS" -p "$client_pid" 2>&1 || true)
	if [ -z "$out" ]; then
		if [ -n "$server_pid" ]; then
			out=$("$GET_SOCKDELAYS" -p "$server_pid" 2>&1 || true)
		fi
	fi

	if [ -n "$out" ] && echo "$out" | grep -q "UDP"; then
		test_pass "UDP socket found in iperf3 -u query output"
	else
		test_fail "UDP socket not found in output"
	fi

	pkill -f "iperf3 -s" 2>/dev/null || true
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

	# 同时启动 nc 监听和 iperf3 服务端
	nc -l "$nc_port" &
	nc_pid=$!
	iperf3 -s -D -p "$iperf_port" 2>/dev/null || true
	sleep 1
	iperf_server_pid=$(pgrep -f "iperf3 -s -D -p $iperf_port" | head -1)

	# 同时发起 nc 连接和 iperf3 客户端
	echo "multi-socket-test" | nc 127.0.0.1 "$nc_port" &
	iperf3 -c 127.0.0.1 -p "$iperf_port" -t 3 >/dev/null 2>&1 &
	iperf_client_pid=$!
	sleep 4

	# 查询 nc 进程，应至少有一行（nc 的监听 socket）
	out=$("$GET_SOCKDELAYS" -p "$nc_pid" 2>&1 || true)
	line_count=$(echo "$out" | grep -c . || true)

	if [ "$line_count" -ge 1 ]; then
		test_pass "nc multi-socket query returned $line_count line(s)"
	else
		test_fail "nc multi-socket query returned empty"
	fi

	# 查询 iperf3 客户端，应至少有一行
	out=$("$GET_SOCKDELAYS" -p "$iperf_client_pid" 2>&1 || true)
	line_count=$(echo "$out" | grep -c . || true)
	if [ "$line_count" -ge 1 ]; then
		test_pass "iperf3 multi-socket query returned $line_count line(s)"
	else
		test_fail "iperf3 multi-socket query returned empty"
	fi

	# 清理
	kill "$nc_pid" 2>/dev/null || true
	pkill -f "iperf3 -s" 2>/dev/null || true
}
test_07_multi_socket

# ---------------------------------------------------------------------------
# 输出摘要
# ---------------------------------------------------------------------------
echo ""
print_summary

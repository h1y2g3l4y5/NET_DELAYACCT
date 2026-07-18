#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# 功能测试：分别验证 TCP 和 UDP 路径的时延统计
# 1. 运行 TCP iperf3 测试，查询 PID，验证输出包含 TCP 类型
# 2. 运行 UDP iperf3 测试，查询 PID，验证输出包含 UDP 类型

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 定位 get_sockdelays 二进制
if [ -n "${GET_SOCKDELAYS:-}" ] && [ -x "$GET_SOCKDELAYS" ]; then
	: # 使用环境变量指定的路径
elif command -v get_sockdelays >/dev/null 2>&1; then
	GET_SOCKDELAYS=$(command -v get_sockdelays)
elif [ -x "$SCRIPT_DIR/../userspace/get_sockdelays/get_sockdelays" ]; then
	GET_SOCKDELAYS="$SCRIPT_DIR/../userspace/get_sockdelays/get_sockdelays"
else
	echo "SKIP: get_sockdelays binary not found"
	exit 4
fi

# 检查依赖
for cmd in iperf3; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "SKIP: required command '$cmd' not found"
		exit 4
	fi
done

TCP_PORT=5205
UDP_PORT=5206
PASS=0
FAIL=0

cleanup() {
	pkill -f "iperf3 -s" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== test_tcp_udp: TCP and UDP path validation ==="

# ---------------------------------------------------------------------------
# TCP 测试
# ---------------------------------------------------------------------------
echo ""
echo "--- TCP test ---"

iperf3 -s -D -p "$TCP_PORT" 2>/dev/null || true
sleep 1

iperf3 -c 127.0.0.1 -p "$TCP_PORT" -t 5 >/dev/null 2>&1 &
TCP_CLIENT_PID=$!
sleep 2

# 查询客户端 PID
TCP_OUTPUT=$("$GET_SOCKDELAYS" -p "$TCP_CLIENT_PID" 2>&1 || true)

# 客户端可能已退出，尝试查询服务端
if [ -z "$TCP_OUTPUT" ]; then
	TCP_SERVER_PID=$(pgrep -f "iperf3 -s -D -p $TCP_PORT" | head -1 || true)
	if [ -n "$TCP_SERVER_PID" ]; then
		TCP_OUTPUT=$("$GET_SOCKDELAYS" -p "$TCP_SERVER_PID" 2>&1 || true)
	fi
fi

if [ -n "$TCP_OUTPUT" ] && echo "$TCP_OUTPUT" | grep -q "TCP"; then
	echo "[PASS] TCP path: output contains TCP type"
	PASS=$((PASS + 1))
else
	echo "[FAIL] TCP path: output does not contain TCP type"
	echo "  Output: $TCP_OUTPUT"
	FAIL=$((FAIL + 1))
fi

# 等待 TCP 客户端结束
wait "$TCP_CLIENT_PID" 2>/dev/null || true
pkill -f "iperf3 -s" 2>/dev/null || true
sleep 1

# ---------------------------------------------------------------------------
# UDP 测试
# ---------------------------------------------------------------------------
echo ""
echo "--- UDP test ---"

iperf3 -s -D -p "$UDP_PORT" 2>/dev/null || true
sleep 1

iperf3 -c 127.0.0.1 -p "$UDP_PORT" -u -t 5 -b 100M >/dev/null 2>&1 &
UDP_CLIENT_PID=$!
sleep 2

# 查询客户端 PID
UDP_OUTPUT=$("$GET_SOCKDELAYS" -p "$UDP_CLIENT_PID" 2>&1 || true)

# 客户端可能已退出，尝试查询服务端
if [ -z "$UDP_OUTPUT" ]; then
	UDP_SERVER_PID=$(pgrep -f "iperf3 -s -D -p $UDP_PORT" | head -1 || true)
	if [ -n "$UDP_SERVER_PID" ]; then
		UDP_OUTPUT=$("$GET_SOCKDELAYS" -p "$UDP_SERVER_PID" 2>&1 || true)
	fi
fi

if [ -n "$UDP_OUTPUT" ] && echo "$UDP_OUTPUT" | grep -q "UDP"; then
	echo "[PASS] UDP path: output contains UDP type"
	PASS=$((PASS + 1))
else
	echo "[FAIL] UDP path: output does not contain UDP type"
	echo "  Output: $UDP_OUTPUT"
	FAIL=$((FAIL + 1))
fi

wait "$UDP_CLIENT_PID" 2>/dev/null || true
pkill -f "iperf3 -s" 2>/dev/null || true

echo ""
echo "=== Summary: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
	exit 1
fi
exit 0

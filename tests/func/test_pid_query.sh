#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# 功能测试：验证 get_sockdelays -p <pid> 命令
# 启动 iperf3 服务端与客户端，查询 iperf3 进程的 socket 时延信息。
# 验证：输出至少一行，且包含 TCP 类型标识。

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

# 检查依赖命令
for cmd in iperf3 pgrep; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "SKIP: required command '$cmd' not found"
		exit 4
	fi
done

IPERF_PORT=5201
PASS=0
FAIL=0

cleanup() {
	pkill -f "iperf3 -s -D -p $IPERF_PORT" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== test_pid_query: get_sockdelays -p ==="

# 启动 iperf3 服务端（守护进程模式）
iperf3 -s -D -p "$IPERF_PORT" 2>/dev/null || true
sleep 1

# 启动 iperf3 客户端，持续 5 秒
iperf3 -c 127.0.0.1 -p "$IPERF_PORT" -t 5 >/dev/null 2>&1 &
CLIENT_PID=$!
sleep 2

# 获取 iperf3 进程 PID（优先取客户端，其次取服务端）
TARGET_PID=""
if kill -0 "$CLIENT_PID" 2>/dev/null; then
	TARGET_PID="$CLIENT_PID"
else
	TARGET_PID=$(pgrep iperf3 | head -1)
fi

if [ -z "$TARGET_PID" ]; then
	echo "[FAIL] no iperf3 process found"
	FAIL=1
else
	echo "Querying PID: $TARGET_PID"

	# 查询 socket 时延信息
	OUTPUT=$("$GET_SOCKDELAYS" -p "$TARGET_PID" 2>&1 || true)

	# 验证 1：输出非空
	LINE_COUNT=$(echo "$OUTPUT" | grep -c . || true)
	if [ "$LINE_COUNT" -ge 1 ]; then
		echo "[PASS] output has $LINE_COUNT line(s)"
		PASS=$((PASS + 1))
	else
		echo "[FAIL] output is empty"
		FAIL=$((FAIL + 1))
	fi

	# 验证 2：输出包含 TCP 类型
	if echo "$OUTPUT" | grep -qi "proto=tcp"; then
		echo "[PASS] output contains TCP type"
		PASS=$((PASS + 1))
	else
		echo "[FAIL] output does not contain TCP type"
		echo "  Output was: $OUTPUT"
		FAIL=$((FAIL + 1))
	fi
fi

echo ""
echo "=== Summary: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
	exit 1
fi
exit 0

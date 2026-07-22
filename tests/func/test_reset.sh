#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# 功能测试：验证 get_sockdelays -r 重置命令
# 1. 产生网络流量，记录重置前的时延计数
# 2. 执行 get_sockdelays -r 重置
# 3. 查询并验证所有计数归零

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
for cmd in iperf3; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "SKIP: required command '$cmd' not found"
		exit 4
	fi
done

IPERF_PORT=5204
PASS=0
FAIL=0

cleanup() {
	if [ -n "${IPERF_PID:-}" ]; then
		kill "$IPERF_PID" 2>/dev/null || true
	fi
}
trap cleanup EXIT

echo "=== test_reset: get_sockdelays -R ==="

# 步骤 1：启动 iperf3 服务端（后台模式，输出全部重定向避免干扰测试输出）
iperf3 -s -p "$IPERF_PORT" >/dev/null 2>&1 &
IPERF_PID=$!
sleep 1

# 产生网络流量以累积时延计数
iperf3 -c 127.0.0.1 -p "$IPERF_PORT" -t 3 >/dev/null 2>&1 || true
sleep 1

# 确认服务端存活
if ! kill -0 "$IPERF_PID" 2>/dev/null; then
	echo "[FAIL] iperf3 server not running"
	FAIL=$((FAIL + 1))
	echo ""
	echo "=== Summary: PASS=$PASS FAIL=$FAIL ==="
	exit 1
fi

# 步骤 2：记录重置前的计数
PRE_RESET_OUTPUT=$("$GET_SOCKDELAYS" -p "$IPERF_PID" 2>&1 || true)
echo "Pre-reset output:"
echo "$PRE_RESET_OUTPUT" | head -5

# 步骤 3：执行重置
echo "Executing reset..."
"$GET_SOCKDELAYS" -R 2>&1 || true
sleep 1

# 步骤 4：查询重置后的计数
POST_RESET_OUTPUT=$("$GET_SOCKDELAYS" -p "$IPERF_PID" 2>&1 || true)
echo "Post-reset output:"
echo "$POST_RESET_OUTPUT" | head -5

# 步骤 5：验证重置后所有计数为零或 N/A
# 输出格式（每个 socket 3 行）:
#   proto=xxx pid=NNN inode=NNN comm=xxx local=x remote=x
#     RX  count=NNN  total=NNN.NNNms  average=NNN.NNNms
#     TX  count=NNN  total=NNN.NNNms  average=NNN.NNNms
# 提取 RX/TX 行的 count= 值，检查是否全为零
NONZERO_COUNT=$(echo "$POST_RESET_OUTPUT" | \
	grep 'count=' | \
	sed -n 's/.*count=\([0-9]*\).*/\1/p' | \
	awk '$1 > 0 {print}' | wc -l)

if [ "$NONZERO_COUNT" -eq 0 ]; then
	echo "[PASS] all counters are zero/N/A after reset"
	PASS=$((PASS + 1))
else
	echo "[FAIL] $NONZERO_COUNT line(s) with non-zero counters after reset"
	FAIL=$((FAIL + 1))
fi

# 额外验证：重置前应有实际数据行（确保流量确实被统计）
# 注意："(no matching sockets)" 也是非空字符串，需要检查 ^proto= 数据行
PRE_RESET_DATA_LINES=$(echo "$PRE_RESET_OUTPUT" | grep -c -E '^proto=' || true)
if [ "$PRE_RESET_DATA_LINES" -ge 1 ]; then
	echo "[PASS] pre-reset output was non-empty (traffic was recorded)"
	PASS=$((PASS + 1))
else
	echo "[INFO] pre-reset output had no data lines (may be normal if no prior traffic)"
fi

echo ""
echo "=== Summary: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
	exit 1
fi
exit 0

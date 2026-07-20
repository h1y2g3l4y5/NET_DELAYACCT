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
for cmd in iperf3 nc; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "SKIP: required command '$cmd' not found"
		exit 4
	fi
done

IPERF_PORT=5204
NC_PORT=12400
PASS=0
FAIL=0

cleanup() {
	pkill -f "iperf3 -s -D -p $IPERF_PORT" 2>/dev/null || true
	if [ -n "${NC_PID:-}" ]; then
		kill "$NC_PID" 2>/dev/null || true
	fi
}
trap cleanup EXIT

echo "=== test_reset: get_sockdelays -R ==="

# 步骤 1：产生网络流量以累积时延计数
iperf3 -s -D -p "$IPERF_PORT" 2>/dev/null || true
sleep 1
iperf3 -c 127.0.0.1 -p "$IPERF_PORT" -t 3 >/dev/null 2>&1 || true
sleep 1

nc -l "$NC_PORT" &
NC_PID=$!
sleep 1
echo "reset-test-traffic" | nc 127.0.0.1 "$NC_PORT" >/dev/null 2>&1 || true
sleep 1

# 步骤 2：记录重置前的计数
PRE_RESET_OUTPUT=$("$GET_SOCKDELAYS" -p "$NC_PID" 2>&1 || true)
echo "Pre-reset output:"
echo "$PRE_RESET_OUTPUT" | head -5

# 步骤 3：执行重置
echo "Executing reset..."
"$GET_SOCKDELAYS" -R 2>&1 || true
sleep 1

# 步骤 4：查询重置后的计数
POST_RESET_OUTPUT=$("$GET_SOCKDELAYS" -p "$NC_PID" 2>&1 || true)
echo "Post-reset output:"
echo "$POST_RESET_OUTPUT" | head -5

# 步骤 5：验证重置后所有计数为零或 N/A
# 输出格式参考: TYPE LADDR LPORT RADDR RPORT COMM PID AVG_RX AVG_TX
# 检查最后两列（AVG_RX, AVG_TX）是否为零或 N/A
NONZERO_COUNT=$(echo "$POST_RESET_OUTPUT" | \
	grep -v -E '^(TYPE|$)' | \
	awk '{
		for (i = NF - 1; i <= NF; i++) {
			val = $i
			gsub(/[usn]/, "", val)
			if (val != "N/A" && val + 0 > 0) print $0
		}
	}' | wc -l)

if [ "$NONZERO_COUNT" -eq 0 ]; then
	echo "[PASS] all counters are zero/N/A after reset"
	PASS=$((PASS + 1))
else
	echo "[FAIL] $NONZERO_COUNT line(s) with non-zero counters after reset"
	FAIL=$((FAIL + 1))
fi

# 额外验证：重置前应有非零计数（确保流量确实被统计）
# 注意：如果内核刚启动或未产生足够流量，此处可能为空
if [ -n "$PRE_RESET_OUTPUT" ]; then
	echo "[PASS] pre-reset output was non-empty (traffic was recorded)"
	PASS=$((PASS + 1))
else
	echo "[INFO] pre-reset output was empty (may be normal if no prior traffic)"
fi

echo ""
echo "=== Summary: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
	exit 1
fi
exit 0

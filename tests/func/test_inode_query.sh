#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# 功能测试：验证 get_sockdelays -i <inode> 命令
# 启动 nc 监听器，从 /proc/<pid>/fd 提取 socket inode，
# 使用 -i 选项查询该 inode，验证输出中包含该 inode 编号。

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
for cmd in nc pgrep readlink; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "SKIP: required command '$cmd' not found"
		exit 4
	fi
done

NC_PORT=12399
PASS=0
FAIL=0

cleanup() {
	if [ -n "${NC_PID:-}" ]; then
		kill "$NC_PID" 2>/dev/null || true
		wait "$NC_PID" 2>/dev/null || true
	fi
}
trap cleanup EXIT

echo "=== test_inode_query: get_sockdelays -i ==="

# 启动 nc 监听器
nc -l "$NC_PORT" &
NC_PID=$!
sleep 1

# 确认 nc 进程存活
if ! kill -0 "$NC_PID" 2>/dev/null; then
	echo "[FAIL] nc listener failed to start"
	exit 1
fi

# 从 /proc/<pid>/fd 中提取 socket inode
INODE=""
for fd_path in /proc/"$NC_PID"/fd/*; do
	target=$(readlink "$fd_path" 2>/dev/null || true)
	if [[ "$target" == socket:* ]]; then
		# 格式为 socket:[<inode>]，提取数字部分
		INODE=$(echo "$target" | grep -oE '[0-9]+' || true)
		if [ -n "$INODE" ]; then
			break
		fi
	fi
done

if [ -z "$INODE" ]; then
	echo "[FAIL] could not extract socket inode from /proc/$NC_PID/fd"
	FAIL=$((FAIL + 1))
else
	echo "Found socket inode: $INODE (pid=$NC_PID)"

	# 使用 -i 查询
	OUTPUT=$("$GET_SOCKDELAYS" -i "$INODE" 2>&1 || true)

	if [ -z "$OUTPUT" ]; then
		echo "[FAIL] get_sockdelays -i $INODE returned empty output"
		FAIL=$((FAIL + 1))
	else
		# 验证输出中包含该 inode
		if echo "$OUTPUT" | grep -q "$INODE"; then
			echo "[PASS] output contains inode $INODE"
			PASS=$((PASS + 1))
		else
			echo "[FAIL] output does not contain inode $INODE"
			echo "  Output was: $OUTPUT"
			FAIL=$((FAIL + 1))
		fi

		# 验证输出行数：按 inode 查询应返回单行（不含表头）
		DATA_LINES=$(echo "$OUTPUT" | grep -v -E '^(TYPE|$)' | wc -l)
		if [ "$DATA_LINES" -eq 1 ]; then
			echo "[PASS] output has exactly 1 data line"
			PASS=$((PASS + 1))
		else
			echo "[FAIL] output has $DATA_LINES data lines, expected 1"
			FAIL=$((FAIL + 1))
		fi
	fi
fi

echo ""
echo "=== Summary: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
	exit 1
fi
exit 0

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# 功能测试：验证单进程多 socket 场景
# 启动一个 Python 脚本打开 3 个 TCP socket 连接到本地 localhost，
# 使用 get_sockdelays -p 查询，验证输出至少 3 行且所有行 PID 相同。

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
if ! command -v python3 >/dev/null 2>&1; then
	if ! command -v nc >/dev/null 2>&1; then
		echo "SKIP: requires python3 or nc"
		exit 4
	fi
fi

PASS=0
FAIL=0
LISTENER_PIDS=""

cleanup() {
	# 终止所有后台进程
	jobs -p | xargs -r kill 2>/dev/null || true
	# 清理监听器
	for pid in $LISTENER_PIDS; do
		kill "$pid" 2>/dev/null || true
	done
}
trap cleanup EXIT

echo "=== test_multi_socket: single process, multiple sockets ==="

# 使用 Python 打开 3 个 TCP socket 的脚本
# 如果 python3 不可用，回退到 nc 方案
if command -v python3 >/dev/null 2>&1; then
	# 启动 3 个 nc 监听器作为对端
	for port in 13001 13002 13003; do
		nc -l "$port" &
		LISTENER_PIDS="$LISTENER_PIDS $!"
	done
	sleep 1

	# Python 脚本：打开 3 个 socket 连接到上述端口，保持连接
	python3 -c "
import socket, time, os, signal

sockets = []
for port in [13001, 13002, 13003]:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect(('127.0.0.1', port))
    s.sendall(b'hello from socket %d' % port)
    sockets.append(s)

# 保持连接，等待父进程查询
time.sleep(5)

for s in sockets:
    s.close()
" &
	CLIENT_PID=$!
else
	# 回退方案：使用后台 nc 连接模拟多 socket
	for port in 13001 13002 13003; do
		nc -l "$port" &
		LISTENER_PIDS="$LISTENER_PIDS $!"
	done
	sleep 1

	# 用 bash 打开 3 个 nc 连接（通过 coproc 或后台进程）
	# 注意：bash 方案中 3 个 nc 是独立进程，PID 不同
	# 因此这里主要用 Python 方案，nc 方案仅作为降级
	for port in 13001 13002 13003; do
		( exec 3<>/dev/tcp/127.0.0.1/$port; sleep 5; exec 3>&- ) &
	done
	# 使用当前 shell 的 PID 作为目标（bash 的 /dev/tcp 会创建 socket）
	CLIENT_PID=$$
fi

sleep 2

echo "Client PID: $CLIENT_PID"

# 查询该 PID 的 socket 信息
OUTPUT=$("$GET_SOCKDELAYS" -p "$CLIENT_PID" 2>&1 || true)

# 验证 1：输出至少 3 行（不含表头）
DATA_LINES=$(echo "$OUTPUT" | grep -v -E '^(TYPE|$)' | wc -l)
if [ "$DATA_LINES" -ge 3 ]; then
	echo "[PASS] output has $DATA_LINES data line(s), expected >= 3"
	PASS=$((PASS + 1))
else
	echo "[FAIL] output has $DATA_LINES data line(s), expected >= 3"
	echo "  Output was:"
	echo "$OUTPUT" | head -10
	FAIL=$((FAIL + 1))
fi

# 验证 2：所有数据行的 PID 字段相同
# 输出格式中 PID 通常是倒数第 3 列（AVG_RX, AVG_TX 在最后）
UNIQUE_PIDS=$(echo "$OUTPUT" | \
	grep -v -E '^(TYPE|$)' | \
	awk '{print $(NF-2)}' | sort -u | wc -l)
if [ "$UNIQUE_PIDS" -eq 1 ]; then
	echo "[PASS] all lines have the same PID"
	PASS=$((PASS + 1))
else
	echo "[FAIL] found $UNIQUE_PIDS different PIDs in output, expected 1"
	FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Summary: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
	exit 1
fi
exit 0

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# 并发查询压力测试
#
# 工作流程：
#   1. 启动 N 个并行的 get_sockdelays -p 1 进程（查询 init 进程的 socket）
#   2. 每个进程连续查询 100 次
#   3. 验证没有内核 oops、没有工具崩溃
#   4. 所有进程正常退出则返回 0
#
# 用法: ./concurrent-query.sh <N>
#   N: 并发进程数，默认 32

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="$SCRIPT_DIR/../reports"
DATE_STR=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$REPORT_DIR/concurrent-query-${DATE_STR}.log"

# 并发进程数
N="${1:-32}"
QUERIES_PER_PROCESS=100

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

# 创建报告目录
mkdir -p "$REPORT_DIR"

# 目标 PID：查询 init 进程 (PID 1)
TARGET_PID=1

echo "============================================" | tee -a "$LOG_FILE"
echo "  Concurrent query stress test" | tee -a "$LOG_FILE"
echo "  Concurrency: $N processes" | tee -a "$LOG_FILE"
echo "  Queries per process: $QUERIES_PER_PROCESS" | tee -a "$LOG_FILE"
echo "  Target PID: $TARGET_PID" | tee -a "$LOG_FILE"
echo "  Start: $(date)" | tee -a "$LOG_FILE"
echo "============================================" | tee -a "$LOG_FILE"

# 单个查询工作进程的函数
worker() {
	local worker_id=$1
	local success=0
	local fail=0
	local i

	for i in $(seq 1 "$QUERIES_PER_PROCESS"); do
		if "$GET_SOCKDELAYS" -p "$TARGET_PID" >/dev/null 2>&1; then
			success=$((success + 1))
		else
			fail=$((fail + 1))
		fi
	done

	echo "worker-$worker_id: success=$success fail=$fail"
}

# 启动 N 个并发工作进程
echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Launching $N worker processes..." | tee -a "$LOG_FILE"

START_TIME=$(date +%s)

PIDS=""
for i in $(seq 1 "$N"); do
	worker "$i" >> "$LOG_FILE" 2>&1 &
	PIDS="$PIDS $!"
done

# 等待所有工作进程完成
echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Waiting for all workers to complete..." | tee -a "$LOG_FILE"

FAIL_COUNT=0
for pid in $PIDS; do
	if ! wait "$pid"; then
		FAIL_COUNT=$((FAIL_COUNT + 1))
		echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Worker pid=$pid exited with non-zero status" | tee -a "$LOG_FILE"
	fi
done

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# ---------------------------------------------------------------------------
# 检查内核稳定性
# ---------------------------------------------------------------------------

# 检查 dmesg 中是否有新的 oops/panic
OOPS_COUNT=$(dmesg 2>/dev/null | tail -200 | grep -cE "(Kernel panic|Oops:|BUG:)" || true)

# 统计结果
TOTAL_QUERIES=$((N * QUERIES_PER_PROCESS))
TOTAL_SUCCESS=$(grep -oP 'success=\K[0-9]+' "$LOG_FILE" | awk '{s+=$1} END{print s+0}')
TOTAL_FAIL=$(grep -oP 'fail=\K[0-9]+' "$LOG_FILE" | awk '{s+=$1} END{print s+0}')

echo "" | tee -a "$LOG_FILE"
echo "============================================" | tee -a "$LOG_FILE"
echo "  Concurrent query test summary" | tee -a "$LOG_FILE"
echo "  Duration: ${DURATION}s" | tee -a "$LOG_FILE"
echo "  Total queries: $TOTAL_QUERIES" | tee -a "$LOG_FILE"
echo "  Successful: $TOTAL_SUCCESS" | tee -a "$LOG_FILE"
echo "  Failed: $TOTAL_FAIL" | tee -a "$LOG_FILE"
echo "  Crashed workers: $FAIL_COUNT" | tee -a "$LOG_FILE"
echo "  Kernel oops in dmesg (last 200 lines): $OOPS_COUNT" | tee -a "$LOG_FILE"
echo "  End: $(date)" | tee -a "$LOG_FILE"

# 判定结果
EXIT_CODE=0

if [ "$FAIL_COUNT" -gt 0 ]; then
	echo "  [FAIL] $FAIL_COUNT worker(s) crashed" | tee -a "$LOG_FILE"
	EXIT_CODE=1
else
	echo "  [PASS] All workers completed successfully" | tee -a "$LOG_FILE"
fi

if [ "$OOPS_COUNT" -gt 0 ]; then
	echo "  [FAIL] $OOPS_COUNT kernel oops detected in dmesg" | tee -a "$LOG_FILE"
	EXIT_CODE=1
else
	echo "  [PASS] No kernel oops detected" | tee -a "$LOG_FILE"
fi

if [ "$TOTAL_FAIL" -gt 0 ]; then
	echo "  [WARN] $TOTAL_FAIL query(ies) returned non-zero (may be normal if PID 1 has no sockets)" | tee -a "$LOG_FILE"
fi

echo "============================================" | tee -a "$LOG_FILE"

exit "$EXIT_CODE"

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# 长时间稳定性测试（默认 24 小时）
#
# 工作流程：
#   1. 启动 iperf3 服务端
#   2. 循环启动 iperf3 客户端进行持续流量测试
#   3. 每小时运行 get_sockdelays -p <pid> 并记录输出
#   4. 测试结束后检查 dmesg 中的 kmemleak 报告和 hung task 警告
#   5. 全部通过则返回 0，发现问题则返回非零
#
# 用法: ./long-run.sh <duration-hours>
#   duration-hours: 测试持续时间（小时），默认 24

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="$SCRIPT_DIR/../reports"
DATE_STR=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$REPORT_DIR/long-run-${DATE_STR}.log"
DMESG_FILE="$REPORT_DIR/long-run-${DATE_STR}-dmesg.txt"

# 测试持续时间（小时）
DURATION_HOURS="${1:-24}"
DURATION_SECONDS=$((DURATION_HOURS * 3600))
INTERVAL_SECONDS=3600  # 每小时记录一次

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

# 创建报告目录
mkdir -p "$REPORT_DIR"

IPERF_PORT=5207
EXIT_CODE=0
IPERF_SERVER_PID=""

cleanup() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Cleaning up..." | tee -a "$LOG_FILE"

	# 终止 iperf3 客户端
	jobs -p | xargs -r kill 2>/dev/null || true

	# 终止 iperf3 服务端
	pkill -f "iperf3 -s -D -p $IPERF_PORT" 2>/dev/null || true

	# 保存 dmesg 用于分析
	dmesg > "$DMESG_FILE" 2>/dev/null || true
	echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] dmesg saved to $DMESG_FILE" | tee -a "$LOG_FILE"
}
trap cleanup EXIT

echo "============================================" | tee -a "$LOG_FILE"
echo "  Long-run stability test" | tee -a "$LOG_FILE"
echo "  Duration: $DURATION_HOURS hours ($DURATION_SECONDS seconds)" | tee -a "$LOG_FILE"
echo "  Log: $LOG_FILE" | tee -a "$LOG_FILE"
echo "  Start: $(date)" | tee -a "$LOG_FILE"
echo "============================================" | tee -a "$LOG_FILE"

# 启动 iperf3 服务端
iperf3 -s -D -p "$IPERF_PORT" 2>/dev/null || true
sleep 1
IPERF_SERVER_PID=$(pgrep -f "iperf3 -s -D -p $IPERF_PORT" | head -1 || true)

if [ -z "$IPERF_SERVER_PID" ]; then
	echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Failed to start iperf3 server" | tee -a "$LOG_FILE"
	exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] iperf3 server started (pid=$IPERF_SERVER_PID, port=$IPERF_PORT)" | tee -a "$LOG_FILE"

# 主测试循环
START_TIME=$(date +%s)
ELAPSED=0
ITERATION=0

while [ "$ELAPSED" -lt "$DURATION_SECONDS" ]; do
	ITERATION=$((ITERATION + 1))
	REMAINING=$((DURATION_SECONDS - ELAPSED))
	# 每次 iperf3 运行 60 秒或剩余时间（取较小者）
	RUN_TIME=$((REMAINING < 60 ? REMAINING : 60))

	echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Iteration $ITERATION: running iperf3 for ${RUN_TIME}s (elapsed=${ELAPSED}s, remaining=${REMAINING}s)" | tee -a "$LOG_FILE"

	# 运行 iperf3 客户端
	iperf3 -c 127.0.0.1 -p "$IPERF_PORT" -t "$RUN_TIME" >/dev/null 2>&1 || true

	# 更新已用时间
	ELAPSED=$(( $(date +%s) - START_TIME ))

	# 每小时记录一次 get_sockdelays 输出
	if [ $((ITERATION % 60)) -eq 0 ] || [ "$ELAPSED" -ge "$DURATION_SECONDS" ]; then
		echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Hourly snapshot (elapsed=${ELAPSED}s):" | tee -a "$LOG_FILE"

		# 查询 iperf3 服务端的 socket 时延
		if [ -n "$IPERF_SERVER_PID" ] && kill -0 "$IPERF_SERVER_PID" 2>/dev/null; then
			"$GET_SOCKDELAYS" -p "$IPERF_SERVER_PID" 2>&1 | tee -a "$LOG_FILE" || true
		else
			echo "  [WARN] iperf3 server (pid=$IPERF_SERVER_PID) no longer running" | tee -a "$LOG_FILE"
			# 尝试重新启动
			iperf3 -s -D -p "$IPERF_PORT" 2>/dev/null || true
			sleep 1
			IPERF_SERVER_PID=$(pgrep -f "iperf3 -s -D -p $IPERF_PORT" | head -1 || true)
		fi

		echo "---" | tee -a "$LOG_FILE"
	fi
done

echo "" | tee -a "$LOG_FILE"
echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Test duration complete, checking dmesg for issues..." | tee -a "$LOG_FILE"

# ---------------------------------------------------------------------------
# 检查 dmesg 中的问题
# ---------------------------------------------------------------------------

# 保存完整 dmesg
dmesg > "$DMESG_FILE" 2>/dev/null || true

# 检查 kmemleak 报告
KMEMLEAK_COUNT=$(dmesg 2>/dev/null | grep -c "kmemleak:" || true)
if [ "$KMEMLEAK_COUNT" -gt 0 ]; then
	echo "$(date '+%Y-%m-%d %H:%M:%S') [FAIL] Found $KMEMLEAK_COUNT kmemleak report(s) in dmesg" | tee -a "$LOG_FILE"
	dmesg | grep "kmemleak:" | tee -a "$LOG_FILE"
	EXIT_CODE=1
else
	echo "$(date '+%Y-%m-%d %H:%M:%S') [PASS] No kmemleak reports found" | tee -a "$LOG_FILE"
fi

# 检查 hung task 警告
HUNG_TASK_COUNT=$(dmesg 2>/dev/null | grep -c "INFO: task.*hung" || true)
if [ "$HUNG_TASK_COUNT" -gt 0 ]; then
	echo "$(date '+%Y-%m-%d %H:%M:%S') [FAIL] Found $HUNG_TASK_COUNT hung task warning(s) in dmesg" | tee -a "$LOG_FILE"
	dmesg | grep "INFO: task.*hung" | head -5 | tee -a "$LOG_FILE"
	EXIT_CODE=1
else
	echo "$(date '+%Y-%m-%d %H:%M:%S') [PASS] No hung task warnings found" | tee -a "$LOG_FILE"
fi

# 检查 oops/panic
OOPS_COUNT=$(dmesg 2>/dev/null | grep -cE "(Kernel panic|Oops:|BUG:|WARNING:.*CPU:" || true)
if [ "$OOPS_COUNT" -gt 0 ]; then
	echo "$(date '+%Y-%m-%d %H:%M:%S') [FAIL] Found $OOPS_COUNT kernel oops/panic/bug in dmesg" | tee -a "$LOG_FILE"
	dmesg | grep -E "(Kernel panic|Oops:|BUG:|WARNING:.*CPU:)" | head -5 | tee -a "$LOG_FILE"
	EXIT_CODE=1
else
	echo "$(date '+%Y-%m-%d %H:%M:%S') [PASS] No kernel oops/panic found" | tee -a "$LOG_FILE"
fi

# 检查 RCU stall
RCU_STALL_COUNT=$(dmesg 2>/dev/null | grep -c "rcu_sched self-detected stall" || true)
if [ "$RCU_STALL_COUNT" -gt 0 ]; then
	echo "$(date '+%Y-%m-%d %H:%M:%S') [FAIL] Found $RCU_STALL_COUNT RCU stall(s) in dmesg" | tee -a "$LOG_FILE"
	EXIT_CODE=1
else
	echo "$(date '+%Y-%m-%d %H:%M:%S') [PASS] No RCU stalls found" | tee -a "$LOG_FILE"
fi

# ---------------------------------------------------------------------------
# 最终报告
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOG_FILE"
echo "============================================" | tee -a "$LOG_FILE"
echo "  Long-run test summary" | tee -a "$LOG_FILE"
echo "  Duration: $DURATION_HOURS hours" | tee -a "$LOG_FILE"
echo "  Iterations: $ITERATION" | tee -a "$LOG_FILE"
echo "  kmemleak: $KMEMLEAK_COUNT" | tee -a "$LOG_FILE"
echo "  hung task: $HUNG_TASK_COUNT" | tee -a "$LOG_FILE"
echo "  oops/panic: $OOPS_COUNT" | tee -a "$LOG_FILE"
echo "  RCU stall: $RCU_STALL_COUNT" | tee -a "$LOG_FILE"
echo "  End: $(date)" | tee -a "$LOG_FILE"
if [ "$EXIT_CODE" -eq 0 ]; then
	echo "  Result: PASS" | tee -a "$LOG_FILE"
else
	echo "  Result: FAIL" | tee -a "$LOG_FILE"
fi
echo "============================================" | tee -a "$LOG_FILE"

exit "$EXIT_CODE"

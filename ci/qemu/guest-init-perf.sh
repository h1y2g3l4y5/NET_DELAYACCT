#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# guest-init-perf.sh — 性能测试专用 guest init（简化版）
#
# 与 guest-init.sh 的区别：
#   - 跳过 get_sockdelays 诊断（OFF 内核无 genl family，诊断会失败产生噪音）
#   - 直接运行 /opt/run-perf-tests.sh
#   - 适用于 K0/K2/K3 三模式对比测试
#
# K0/K2/K3 模式说明：
#   K0: OFF 内核（CONFIG_NET_DELAYACCT=n），无插桩开销（基线）
#   K2: ON 内核，检测开启，无主动查询（纯插桩开销）
#   K3: ON 内核，检测开启 + 主动查询（导出开销，需 get_sockdelays）
#
# 内核 cmdline 参数（host 侧 perf-test.sh 传入）：
#   query_mode=K0|K2|K3          控制 K3 主动查询行为
#   test_duration=N              iperf3 测试时长（秒）
#   warmup_duration=N            iperf3 --omit 预热时长（秒）
#   enable_cycles=0|1            是否采集 cycles/packet
#   fixed_load_rates=R1,R2,R3    固定负载速率列表（Mbps，逗号分隔）
#
# Invoked via kernel cmdline: init=/init

set -e

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "=== QEMU perf guest boot: $(date -u) ==="

# ----------------------------------------------------------------------------
# 从 /proc/cmdline 解析 host 传入的参数，导出为环境变量供 run-perf-tests.sh 使用
# ----------------------------------------------------------------------------
# 默认值与 run-perf-tests.sh 保持一致；仅在 cmdline 显式给出时覆盖
export QUERY_MODE="${QUERY_MODE:-K2}"
export TEST_DURATION="${TEST_DURATION:-10}"
export WARMUP_DURATION="${WARMUP_DURATION:-3}"
export ENABLE_CYCLES="${ENABLE_CYCLES:-0}"
export FIXED_LOAD_RATES="${FIXED_LOAD_RATES:-}"

_cmdline_arg() {
    # 用 awk 从 /proc/cmdline 提取 key=value（仅取第一个匹配）
    # $1 = key 名
    awk -v k="$1=" '
        {
            for (i = 1; i <= NF; i++) {
                if (substr($i, 1, length(k)) == k) {
                    print substr($i, length(k) + 1)
                    exit
                }
            }
        }
    ' /proc/cmdline 2>/dev/null
}

_val=$(_cmdline_arg query_mode)
[ -n "$_val" ] && export QUERY_MODE="$_val"
_val=$(_cmdline_arg test_duration)
[ -n "$_val" ] && export TEST_DURATION="$_val"
_val=$(_cmdline_arg warmup_duration)
[ -n "$_val" ] && export WARMUP_DURATION="$_val"
_val=$(_cmdline_arg enable_cycles)
[ -n "$_val" ] && export ENABLE_CYCLES="$_val"
# fixed_load_rates 在 cmdline 中用逗号分隔（避免空格破坏 cmdline tokenization），
# 转换为空格分隔以匹配 run-perf-tests.sh 的预期格式
_val=$(_cmdline_arg fixed_load_rates)
if [ -n "$_val" ]; then
    # tr 替换逗号为空格；awk squeeze 重复空格并 trim 两端
    export FIXED_LOAD_RATES="$(echo "$_val" | tr ',' ' ' | awk '{$1=$1};1')"
fi
unset _val _cmdline_arg

echo "[guest-init] perf params: QUERY_MODE=$QUERY_MODE TEST_DURATION=$TEST_DURATION WARMUP_DURATION=$WARMUP_DURATION ENABLE_CYCLES=$ENABLE_CYCLES FIXED_LOAD_RATES='$FIXED_LOAD_RATES'"

# Watchdog: force poweroff after 600s
# 提高上限以容纳更长的测试矩阵：K3 主动查询 + cycles/packet + 固定负载延迟测试
# 原 540s 在新增测试项后余量不足，600s 给 perf test timeout (540s) 留 60s 收尾时间
( sleep 600; echo "WATCHDOG: forcing poweroff after 600s timeout"; poweroff -f ) &
WATCHDOG_PID=$!

# --- Mount essential filesystems ---
# 注意：mountpoint 不是 busybox applet，直接 mount（已挂载时返回 EBUSY，用 || true 忽略）
# 注意：前三个 mount 不能用 2>/dev/null 重定向，因为此时 /dev 尚未挂载，/dev/null 不存在
mount -t proc  proc  /proc  -o nosuid,noexec,nodev || true
mount -t sysfs sysfs /sys   -o nosuid,noexec,nodev || true
mount -t devtmpfs dev /dev -o mode=0755,nosuid || true
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts -o mode=0620,gid=5 2>/dev/null || true
mount -t tmpfs  tmpfs  /dev/shm 2>/dev/null || true

# --- Bring up loopback ---
ip link set lo up 2>/dev/null || true

# --- Load net_delayacct if compiled as module (ON kernel only) ---
modprobe net-delayacct 2>/dev/null || true

RESULT_FILE="/root/test-output.txt"

{
    echo "=== QEMU Perf Run: $(date -u) ==="
    echo "Kernel: $(uname -r)"
    echo "Query mode: $QUERY_MODE"
    echo "Test duration: ${TEST_DURATION}s (warmup: ${WARMUP_DURATION}s)"
    echo ""

    if [ -x "/opt/run-perf-tests.sh" ]; then
        echo "--- Running run-perf-tests.sh ---"
        set +e
        # perf test timeout 540s：容纳 RUNS=3 + K3 后台查询 + cycles/packet + 固定负载延迟
        # （原 480s 仅覆盖 RUNS=3 基础测试）
        if command -v bash >/dev/null 2>&1; then
            timeout 540 bash /opt/run-perf-tests.sh 2>&1
        else
            timeout 540 sh /opt/run-perf-tests.sh 2>&1
        fi
        rc=$?
        set -e
        if [ "$rc" -eq 124 ]; then
            echo "  (perf tests timed out after 540s)"
        elif [ "$rc" -ne 0 ]; then
            echo "  (perf tests exited with rc=$rc)"
        fi
    else
        echo "ERROR: /opt/run-perf-tests.sh not found"
    fi

    echo ""
    echo "=== Perf run finished: $(date -u) ==="
} 2>&1 | tee "$RESULT_FILE"

kill "$WATCHDOG_PID" 2>/dev/null || true
sync
echo "Perf guest init completed, powering off..."
poweroff -f || halt -f || shutdown -h now

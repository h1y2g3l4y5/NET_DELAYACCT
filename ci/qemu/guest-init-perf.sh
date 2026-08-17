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
#   query_mode=K0|K2|K3          K3 = 附加 dump 计时（Perf-D）
#   perf_runs=N                  bench-net 轮数（默认 5）
#
# Invoked via kernel cmdline: init=/init

set -e

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "=== QEMU perf guest boot: $(date -u) ==="

# Watchdog: force poweroff after 600s
# 微基准矩阵单次 ~40s（bench 5 轮×2 项×~1s + ftrace 对账 + dump），余量充足
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

# ----------------------------------------------------------------------------
# 从 /proc/cmdline 解析 host 传入的参数，导出为环境变量供 run-perf-tests.sh 使用
# 注意：必须在 mount /proc 之后执行！否则 /proc/cmdline 不存在，awk 读取失败
#       在 set -e 下会导致 init 退出 → 内核 panic（exitcode=0x100）
# ----------------------------------------------------------------------------
# 默认值与 run-perf-tests.sh 保持一致；仅在 cmdline 显式给出时覆盖
export QUERY_MODE="${QUERY_MODE:-K2}"
export PERF_RUNS="${PERF_RUNS:-5}"

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

# || true 防止 awk 读取失败时 set -e 终止 init（双重保险）
_val=$(_cmdline_arg query_mode) || true
[ -n "$_val" ] && export QUERY_MODE="$_val"
_val=$(_cmdline_arg perf_runs) || true
[ -n "$_val" ] && export PERF_RUNS="$_val"
unset _val _cmdline_arg

echo "[guest-init] perf params: QUERY_MODE=$QUERY_MODE PERF_RUNS=$PERF_RUNS"

# --- Bring up loopback ---
ip link set lo up 2>/dev/null || true

# --- Load net_delayacct if compiled as module (ON kernel only) ---
modprobe net-delayacct 2>/dev/null || true

RESULT_FILE="/root/test-output.txt"

{
    echo "=== QEMU Perf Run: $(date -u) ==="
    echo "Kernel: $(uname -r)"
    echo "Query mode: $QUERY_MODE"
    echo "Bench rounds: $PERF_RUNS"
    echo ""

    if [ -x "/opt/run-perf-tests.sh" ]; then
        echo "--- Running run-perf-tests.sh ---"
        set +e
        # perf test timeout 540s：微基准矩阵 ~40s（bench 2 项×RUNS 轮×~1s
        # + ftrace 对账 + dump），大余量容纳 TCG 慢速路径
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

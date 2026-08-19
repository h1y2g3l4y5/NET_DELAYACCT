#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# guest-init-perf.sh — 性能测试专用 guest init（简化版）
#
# 20260819 v3 同 boot A/B：
#   AB  boot（ON 内核）：run-perf-tests.sh 检测到
#       /sys/module/net_delayacct/parameters/enabled 后，在同一 boot 内
#       交错翻转 OFF/ON 跑 24 格矩阵（消除启动间漂移与二进制布局差异）
#   OFF boot（OFF 内核）：仅采集 slab 基线（sock_objsize，编译期确定值）
#   K0/K2/K3 三模式 boot 编排已废弃（v2 跨 boot 对比不可归因）
#
# 内核 cmdline 参数（host 侧 perf-test.sh 传入）：
#   perf_runs=N                  AB 对数（默认 3，每对 = OFF 块 + ON 块）
#
# Invoked via kernel cmdline: init=/init

set -e

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "=== QEMU perf guest boot: $(date -u) ==="

# Watchdog: force poweroff after 660s
# AB 模式单 boot 时长：boot ~10s + 6 块×24 格×~1.3s ≈ 190s + ftrace ~15s
# + dump ~5s ≈ 220s（KVM）；TCG ~3x（boot 120s + 同量级 bench）≈ 350-500s。
# 660s 兜底覆盖 TCG；host 侧 QEMU timeout（KVM 300s / TCG 700s）为外层
# 第二道防线，二者独立。
( sleep 660; echo "WATCHDOG: forcing poweroff after 660s timeout"; poweroff -f ) &
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
export PERF_RUNS="${PERF_RUNS:-3}"

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
_val=$(_cmdline_arg perf_runs) || true
[ -n "$_val" ] && export PERF_RUNS="$_val"
unset _val _cmdline_arg

echo "[guest-init] perf params: PERF_RUNS=$PERF_RUNS (AB pairs)"

# --- Bring up loopback ---
ip link set lo up 2>/dev/null || true

# --- Load net_delayacct if compiled as module (ON kernel only) ---
modprobe net-delayacct 2>/dev/null || true

RESULT_FILE="/root/test-output.txt"

{
    echo "=== QEMU Perf Run: $(date -u) ==="
    echo "Kernel: $(uname -r)"
    echo "AB pairs: $PERF_RUNS"
    echo ""

    if [ -x "/opt/run-perf-tests.sh" ]; then
        echo "--- Running run-perf-tests.sh ---"
        set +e
        # perf test timeout 660s：同 boot A/B（bench 6 块×24 格×~1.3s
        # + ftrace 对账 + dump），KVM ~220s，TCG ~500s，大余量兜底
        if command -v bash >/dev/null 2>&1; then
            timeout 660 bash /opt/run-perf-tests.sh 2>&1
        else
            timeout 660 sh /opt/run-perf-tests.sh 2>&1
        fi
        rc=$?
        set -e
        if [ "$rc" -eq 124 ]; then
            echo "  (perf tests timed out after 660s)"
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

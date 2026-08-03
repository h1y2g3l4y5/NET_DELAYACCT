#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# guest-init-perf.sh — 性能测试专用 guest init（简化版）
#
# 与 guest-init.sh 的区别：
#   - 跳过 get_sockdelays 诊断（OFF 内核无 genl family，诊断会失败产生噪音）
#   - 直接运行 /opt/run-perf-tests.sh
#   - 适用于 ON/OFF 双内核对比测试
#
# Invoked via kernel cmdline: init=/init

set -e

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "=== QEMU perf guest boot: $(date -u) ==="

# Watchdog: force poweroff after 540s
( sleep 540; echo "WATCHDOG: forcing poweroff"; poweroff -f ) &
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
    echo ""

    if [ -x "/opt/run-perf-tests.sh" ]; then
        echo "--- Running run-perf-tests.sh ---"
        set +e
        if command -v bash >/dev/null 2>&1; then
            timeout 480 bash /opt/run-perf-tests.sh 2>&1
        else
            timeout 480 sh /opt/run-perf-tests.sh 2>&1
        fi
        rc=$?
        set -e
        if [ "$rc" -eq 124 ]; then
            echo "  (perf tests timed out after 480s)"
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

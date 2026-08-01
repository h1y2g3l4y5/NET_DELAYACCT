#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Guest init script — runs inside the QEMU VM.
#
# Invoked via kernel cmdline: init=/init
#
# 1. Mount essential filesystems
# 2. Bring up loopback
# 3. Diagnostics + genl family verification
# 4. Run unified test suite (run-tests.sh)
# 5. Write results to /root/test-output.txt
# 6. Power off

set -e

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "=== QEMU guest boot: $(date -u) ==="

# Watchdog: force poweroff after 540s (must exceed run-tests.sh timeout of 480s;
# TCG software emulation is much slower than KVM and needs the extra headroom)
( sleep 540; echo "WATCHDOG: forcing poweroff after 540s timeout"; poweroff -f ) &
WATCHDOG_PID=$!

# --- Mount essential filesystems (idempotent — skip if already mounted) ---
mountpoint -q /proc  || mount -t proc  proc  /proc  -o nosuid,noexec,nodev
mountpoint -q /sys   || mount -t sysfs sysfs /sys   -o nosuid,noexec,nodev
mountpoint -q /dev   || mount -t devtmpfs dev /dev -o mode=0755,nosuid
mkdir -p /dev/pts /dev/shm
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts -o mode=0620,gid=5
mountpoint -q /dev/shm || mount -t tmpfs  tmpfs  /dev/shm

# --- Mount debugfs + tracefs (for Test 23: ftrace instrumentation verification) ---
# tracefs is needed by Test 23 and embedded ftrace checks in Test 19/20/21.
# Without these mounts, /sys/kernel/debug/tracing is unavailable → Test 23 SKIPs.
mkdir -p /sys/kernel/debug
mountpoint -q /sys/kernel/debug 2>/dev/null || mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
# Modern path: tracefs can be mounted independently at /sys/kernel/tracing
mkdir -p /sys/kernel/tracing
mountpoint -q /sys/kernel/tracing 2>/dev/null || mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null || true

# --- Bring up loopback ---
ip link set lo up 2>/dev/null || true

# --- Load net_delayacct if compiled as module ---
modprobe net-delayacct 2>/dev/null || true

# --- Verify genl family is registered by actually calling get_sockdelays ---
echo "Checking net_delayacct genl family..."
if timeout 10 /usr/local/bin/get_sockdelays -p 1 >/dev/null 2>&1; then
	echo "genl family accessible (get_sockdelays works)"
else
	# get_sockdelays failed or timed out — try to diagnose (with timeout)
	echo "genl check failed, diagnosing..."
	timeout 5 /usr/local/bin/get_sockdelays -p 1 2>&1 | head -3 || echo "  (get_sockdelays timed out or failed)"
fi

# Diagnostic: check tool binary, genl family, and query with debug
echo "=== Diagnostics ==="
echo "Tool binary info:"
ls -la /usr/local/bin/get_sockdelays
strings /usr/local/bin/get_sockdelays | grep -E "debug|version" | head -3

echo "Kernel printk levels:"
cat /proc/sys/kernel/printk 2>/dev/null || echo "  (not available)"

echo "Genl family listing (/proc/net/generic):"
cat /proc/net/generic 2>/dev/null || echo "  (not available)"

echo "Diagnostic: nc listener query test..."
nc -l -p 19999 &
NC_DIAG_PID=$!
sleep 1
if kill -0 "$NC_DIAG_PID" 2>/dev/null; then
	echo "  nc pid=$NC_DIAG_PID"
	echo "  get_sockdelays -d output (stderr+stdout):"
	timeout 10 /usr/local/bin/get_sockdelays -d -p "$NC_DIAG_PID" 2>&1 | head -30
	echo "  kernel messages after query (last 15 net_delayacct lines):"
	dmesg | grep -i "net_delayacct" | tail -15
	echo "  last 10 kernel messages (any):"
	dmesg | tail -10
	kill "$NC_DIAG_PID" 2>/dev/null || true
	wait "$NC_DIAG_PID" 2>/dev/null || true
else
	echo "  (nc failed to start)"
fi

# Always show kernel net_delayacct messages for debugging
echo "All kernel net_delayacct messages:"
dmesg | grep -i "net_delayacct" || echo "  (no net_delayacct kernel messages)"

echo "[guest-init] Starting unified test suite..."

RESULT_FILE="/root/test-output.txt"

{
	echo "=== QEMU Test Run: $(date -u) ==="
	echo "Kernel: $(uname -r)"
	echo ""

	if [ -x "/usr/local/bin/get_sockdelays" ]; then
		echo "get_sockdelays binary: OK"

		# Run the unified test suite
		if [ -x "/opt/run-tests.sh" ]; then
			echo "--- Running run-tests.sh (unified test suite) ---"
			set +e
			# Use bash if available (test scripts use bash syntax), fall back to sh
			if command -v bash >/dev/null 2>&1; then
				timeout 480 bash /opt/run-tests.sh 2>&1
			else
				timeout 480 sh /opt/run-tests.sh 2>&1
			fi
			rc=$?
			set -e
			if [ "$rc" -eq 124 ]; then
				echo "  (tests timed out after 480s)"
			elif [ "$rc" -ne 0 ]; then
				echo "  (tests exited with rc=$rc)"
			fi
		else
			echo "ERROR: /opt/run-tests.sh not found"
		fi
	else
		echo "ERROR: get_sockdelays binary not found"
	fi

	echo ""
	echo "=== Test run finished: $(date -u) ==="
	echo ""
	echo "=== Kernel net_delayacct messages (post-test) ==="
	dmesg | grep -i "net_delayacct" || echo "  (none)"
} 2>&1 | tee "$RESULT_FILE"

# --- Sync and power off ---
# Kill the watchdog since we finished normally
kill "$WATCHDOG_PID" 2>/dev/null || true
sync
echo "Guest init completed successfully, powering off..."
poweroff -f || halt -f || shutdown -h now

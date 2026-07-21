#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Guest init script — runs inside the QEMU VM.
#
# Invoked via kernel cmdline: init=/sbin/qemu-init
#
# 1. Mount essential filesystems
# 2. Bring up loopback
# 3. Run the selftest suite
# 4. Write results to /root/test-output.txt
# 5. Power off

set -e

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "=== QEMU guest boot: $(date -u) ==="

# Watchdog: force poweroff after 120s to prevent CI hang if any step blocks
( sleep 120; echo "WATCHDOG: forcing poweroff after 120s timeout"; poweroff -f ) &
WATCHDOG_PID=$!

# --- Mount essential filesystems (idempotent — skip if already mounted) ---
mountpoint -q /proc  || mount -t proc  proc  /proc  -o nosuid,noexec,nodev
mountpoint -q /sys   || mount -t sysfs sysfs /sys   -o nosuid,noexec,nodev
mountpoint -q /dev   || mount -t devtmpfs dev /dev -o mode=0755,nosuid
mkdir -p /dev/pts /dev/shm
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts -o mode=0620,gid=5
mountpoint -q /dev/shm || mount -t tmpfs  tmpfs  /dev/shm

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

# Always show kernel net_delayacct messages for debugging
echo "Kernel net_delayacct messages:"
dmesg | grep -i "net_delayacct" || echo "  (no net_delayacct kernel messages)"

echo "[guest-init] Starting test suite..."

# --- Find and run test scripts ---
TEST_ROOT="/opt/net_delayacct_tests"
RESULT_FILE="/root/test-output.txt"

{
	echo "=== QEMU Test Run: $(date -u) ==="
	echo "Kernel: $(uname -r)"
	echo ""

	if [ -d "$TEST_ROOT" ]; then
		export GET_SOCKDELAYS="/usr/local/bin/get_sockdelays"

		if [ -x "/usr/local/bin/get_sockdelays" ]; then
			echo "get_sockdelays binary: OK"

			# Run the selftest suite
			if [ -f "$TEST_ROOT/test_netdelayacct.sh" ]; then
				echo "--- Running test_netdelayacct.sh ---"
				timeout 30 bash "$TEST_ROOT/test_netdelayacct.sh" 2>&1 || echo "  (test timed out or failed)"
				echo ""
			fi

			# Run functional tests
			if [ -d "$TEST_ROOT/func" ]; then
				for t in "$TEST_ROOT/func/test_"*.sh; do
					if [ -f "$t" ]; then
						echo "--- Running $(basename "$t") ---"
						timeout 30 bash "$t" 2>&1 || echo "  (test timed out or failed)"
						echo ""
					fi
				done
			fi
		else
			echo "ERROR: get_sockdelays binary not found"
		fi
	else
		echo "ERROR: test directory $TEST_ROOT not found"
	fi

	echo ""
	echo "=== Test run finished: $(date -u) ==="
	echo ""
	echo "=== Kernel net_delayacct messages (post-test) ==="
	dmesg | grep -i "net_delayacct" || echo "  (none)"
} > "$RESULT_FILE" 2>&1

# --- Sync and power off ---
# Kill the watchdog since we finished normally
kill "$WATCHDOG_PID" 2>/dev/null || true
sync
echo "Guest init completed successfully, powering off..."
poweroff -f || halt -f || shutdown -h now

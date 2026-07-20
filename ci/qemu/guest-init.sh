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

# --- Verify genl family is registered ---
echo "Checking net_delayacct genl family..."
if grep -q "net_delayacct" /proc/net/genetlink 2>/dev/null; then
	echo "genl family registered OK"
else
	echo "WARNING: net_delayacct genl family not found in /proc/net/genetlink"
	echo "Kernel messages for net_delayacct:"
	dmesg | grep -i "net_delayacct\|net-delayacct\|net_delay" || echo "  (no messages found)"
	echo "Checking if module is loaded:"
	lsmod | grep delayacct 2>/dev/null || echo "  (not found in lsmod)"
fi

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
				bash "$TEST_ROOT/test_netdelayacct.sh" 2>&1 || true
				echo ""
			fi

			# Run functional tests
			if [ -d "$TEST_ROOT/func" ]; then
				for t in "$TEST_ROOT/func/test_"*.sh; do
					if [ -f "$t" ]; then
						echo "--- Running $(basename "$t") ---"
						bash "$t" 2>&1 || true
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
} > "$RESULT_FILE" 2>&1

# --- Sync and power off ---
sync
echo "Powering off..."
poweroff -f || halt -f || shutdown -h now

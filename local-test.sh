#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# local-test.sh — 本地快速测试脚本，无需 CI，不用 debootstrap
#
# 流程：
#   1. 将修改的内核模块源码同步到内核树
#   2. 增量编译内核 (ccache 加速)
#   3. 编译用户态工具 get_sockdelays
#   4. 用 busybox 创建轻量 initramfs
#   5. QEMU 启动，跑测试，保存结果
#
# 使用：
#   ./local-test.sh              # 完整测试
#   ./local-test.sh --kernel-only # 只编译内核和工具
#   ./local-test.sh --qemu-only   # 只跑 QEMU（假设已编译）
#
# 日志位置：tests/reports/local/test-YYYYMMDD_HHMMSS.log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
LINUX_SRC="${LINUX_SRC:-$PROJECT_DIR/../linux-6.6}"
LOG_DIR="$PROJECT_DIR/tests/reports/local"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/test-${TIMESTAMP}.log"

KERNEL_PATCH_DIR="$PROJECT_DIR/kernel-patches"
QEMU_MEMORY="${QEMU_MEMORY:-1024M}"
QEMU_TIMEOUT="${QEMU_TIMEOUT:-180}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

init_log() {
	mkdir -p "$LOG_DIR"
	exec > >(tee -a "$LOG_FILE") 2>&1
	echo "=== Local Test $(date) ==="
	echo "Log: $LOG_FILE"
	echo ""
}

log_section() {
	echo ""
	echo "--- [$1] $(date +%H:%M:%S) ---"
}

# ============================================================================
# Step 1: Sync kernel module source to kernel tree
# ============================================================================
step_sync_source() {
	log_section "Syncing kernel module source"

	install -m 0644 "$KERNEL_PATCH_DIR/include-net-net-delayacct.h" \
		"$LINUX_SRC/include/net/net-delayacct.h"
	install -m 0644 "$KERNEL_PATCH_DIR/include-uapi-linux-net-delayacct.h" \
		"$LINUX_SRC/include/uapi/linux/net-delayacct.h"
	install -m 0644 "$KERNEL_PATCH_DIR/net-core-net-delayacct.c" \
		"$LINUX_SRC/net/core/net-delayacct.c"

	# Ensure Kconfig and Makefile fragments are present
	if ! grep -q "CONFIG_NET_DELAYACCT" "$LINUX_SRC/net/Kconfig" 2>/dev/null; then
		cat "$KERNEL_PATCH_DIR/Kconfig-fragment" >> "$LINUX_SRC/net/Kconfig"
	fi
	if ! grep -q "net-delayacct" "$LINUX_SRC/net/core/Makefile" 2>/dev/null; then
		cat "$KERNEL_PATCH_DIR/Makefile-fragment" >> "$LINUX_SRC/net/core/Makefile"
	fi

	echo "Source files synced OK"
}

# ============================================================================
# Step 2: Apply .patch files if not already applied
# ============================================================================
step_apply_patches() {
	log_section "Apply patches"

	cd "$LINUX_SRC"

	# Check if patches are already applied (look for delayacct_start in skbuff.h)
	if grep -q "delayacct_start" include/linux/skbuff.h 2>/dev/null; then
		echo "Patches already applied (delayacct_start found in skbuff.h)"
	else
		shopt -s nullglob
		for p in "$KERNEL_PATCH_DIR/"*.patch; do
			local pname=$(basename "$p")
			echo "  Applying $pname..."
			if ! git apply "$p" 2>/dev/null; then
				patch -p1 --fuzz=3 < "$p" 2>/dev/null || {
					echo "  ${YELLOW}WARNING: failed to apply $pname${NC}"
				}
			fi
		done

		# sock.c fixup
		sed -i '/sk_tx_queue_clear(sk);/a\\tnet_delayacct_init(\&sk->sk_net_delayacct);' \
			net/core/sock.c 2>/dev/null || true
	fi
}

# ============================================================================
# Step 3: Build kernel (incremental)
# ============================================================================
step_build_kernel() {
	log_section "Building kernel"

	cd "$LINUX_SRC"

	# Touch source files to force rebuild (rm .o not allowed in sandbox)
	touch net/core/net-delayacct.c include/net/net-delayacct.h 2>/dev/null || true

	# Ensure config exists
	if [ ! -f .config ]; then
		echo "Generating .config..."
		make defconfig 2>&1 | tail -1
		"$LINUX_SRC/scripts/kconfig/merge_config.sh" -m .config \
			"$PROJECT_DIR/ci/kernel.config.fragment" \
			"$PROJECT_DIR/ci/qemu/kernel-qemu.config" 2>&1 | tail -3
		make olddefconfig 2>&1 | tail -1
	fi

	# Verify CONFIG_NET_DELAYACCT
	if ! grep -q "CONFIG_NET_DELAYACCT=y" .config; then
		echo "${YELLOW}WARNING: CONFIG_NET_DELAYACCT not set, reconfiguring...${NC}"
		"$LINUX_SRC/scripts/kconfig/merge_config.sh" -m .config \
			"$PROJECT_DIR/ci/kernel.config.fragment" 2>&1 | tail -1
		make olddefconfig 2>&1 | tail -1
	fi

	echo "Building bzImage (with ccache)..."
	make -j"$(nproc)" CC="ccache gcc" bzImage 2>&1 | tail -10

	if [ -f arch/x86/boot/bzImage ]; then
		echo "${GREEN}Kernel build OK: arch/x86/boot/bzImage${NC}"
	else
		echo "${RED}Kernel build FAILED${NC}"
		exit 1
	fi
}

# ============================================================================
# Step 4: Build userspace tool
# ============================================================================
step_build_tool() {
	log_section "Building get_sockdelays"

	cd "$PROJECT_DIR"

	# Install UAPI header
	sudo install -m 0644 \
		"$LINUX_SRC/include/uapi/linux/net-delayacct.h" \
		/usr/include/linux/net-delayacct.h 2>/dev/null || {
		echo "(UAPI header install skipped, trying without sudo)"
		cp "$LINUX_SRC/include/uapi/linux/net-delayacct.h" \
			"$PROJECT_DIR/userspace/get_sockdelays/linux/net-delayacct.h" 2>/dev/null || true
	}

	make tool 2>&1

	if [ -x userspace/get_sockdelays/get_sockdelays ]; then
		echo "${GREEN}Tool build OK${NC}"
	else
		echo "${RED}Tool build FAILED${NC}"
		exit 1
	fi
}

# ============================================================================
# Step 5: Create initramfs with busybox + tests
# ============================================================================
step_create_initramfs() {
	log_section "Creating initramfs"

	local INITRD_DIR="/tmp/local-test-initrd-$$"
	local INITRD_IMG="$PROJECT_DIR/ci/qemu/local-initrd.img"

	rm -rf "$INITRD_DIR"
	mkdir -p "$INITRD_DIR"/{bin,sbin,dev,proc,sys,tmp,etc,usr/local/bin,opt/test,root}

	# Use busybox-static if available, otherwise try regular busybox
	if command -v busybox &>/dev/null; then
		BUSYBOX=$(command -v busybox)
	else
		echo "Installing busybox-static..."
		sudo apt-get install -y busybox-static 2>/dev/null || {
			echo "${RED}Please install busybox-static: sudo apt-get install busybox-static${NC}"
			exit 1
		}
		BUSYBOX=$(command -v busybox)
	fi

	# Copy busybox and create symlinks
	cp "$BUSYBOX" "$INITRD_DIR/bin/busybox"
	chmod +x "$INITRD_DIR/bin/busybox"
	for cmd in sh ls cat echo grep wc head tail awk sed sleep kill pgrep \
		   mount umount mknod chmod chown mkdir rmdir cp mv rm ln \
		   nc iperf3 reboot poweroff dirname basename which true false test [ [[ \
		   sort readlink ip ifconfig; do
		ln -sf /bin/busybox "$INITRD_DIR/bin/$cmd" 2>/dev/null || true
	done
	ln -sf /bin/busybox "$INITRD_DIR/sbin/init"

	# Copy get_sockdelays binary and its shared libraries
	local TOOL_BIN="$PROJECT_DIR/userspace/get_sockdelays/get_sockdelays"
	cp "$TOOL_BIN" "$INITRD_DIR/usr/local/bin/get_sockdelays"
	chmod +x "$INITRD_DIR/usr/local/bin/get_sockdelays"

	# Copy shared libraries needed by get_sockdelays
	mkdir -p "$INITRD_DIR/lib" "$INITRD_DIR/lib64"
	local lib
	for lib in $(ldd "$TOOL_BIN" 2>/dev/null | grep -o '/[^ ]*\.so[^ ]*' | sort -u); do
		[ -f "$lib" ] || continue
		local dest="$INITRD_DIR$lib"
		mkdir -p "$(dirname "$dest")"
		cp -L "$lib" "$dest"
	done
	echo "Copied shared libraries for get_sockdelays"

	# Copy bash for test scripts (test scripts use bash-specific syntax)
	if [ -f /bin/bash ]; then
		cp /bin/bash "$INITRD_DIR/bin/bash"
		chmod +x "$INITRD_DIR/bin/bash"
		# Copy bash's shared libraries too
		for lib in $(ldd /bin/bash 2>/dev/null | grep -o '/[^ ]*\.so[^ ]*' | sort -u); do
			[ -f "$lib" ] || continue
			local dest="$INITRD_DIR$lib"
			mkdir -p "$(dirname "$dest")"
			cp -L "$lib" "$dest" 2>/dev/null || true
		done
	fi

	# Copy test scripts
	if [ -d "$PROJECT_DIR/tests/func" ]; then
		cp "$PROJECT_DIR/tests/func/test_"*.sh "$INITRD_DIR/opt/test/" 2>/dev/null || true
	fi
	chmod +x "$INITRD_DIR/opt/test/"*.sh 2>/dev/null || true

	# init script
	cat > "$INITRD_DIR/init" << 'INITEOF'
#!/bin/sh

log() { echo "$*"; echo "$*" >> /root/test-output.txt; }

export PATH=/usr/local/bin:/usr/bin:/bin:/sbin

# Mount essentials
/bin/mount -t proc none /proc
/bin/mount -t sysfs none /sys
/bin/mount -t devtmpfs none /dev 2>/dev/null || /bin/mknod -m 666 /dev/null c 1 3
/bin/mkdir -p /dev/pts /dev/shm

# Bring up loopback (required for TCP/UDP tests)
/bin/mount -t tmpfs none /tmp 2>/dev/null || true
/bin/ip link set lo up 2>/dev/null || /bin/ifconfig lo 127.0.0.1 up 2>/dev/null || true

log ""
log "=== local-test guest init ==="
log "Date: $(date)"
log "Kernel: $(uname -r)"

# Check net_delayacct module
log ""
log "--- dmesg net_delayacct ---"
dmesg | grep -i net_delayacct || log "(no net_delayacct messages)"

# Test 1: query PID 1 (basic genl test)
log ""
log "--- get_sockdelays -p 1 ---"
timeout 10 /usr/local/bin/get_sockdelays -p 1 2>&1 || log "(timeout or error)"

# Test 2: self PID query
log ""
log "--- get_sockdelays self PID ---"
MYPID=$$
timeout 10 /usr/local/bin/get_sockdelays -p "$MYPID" 2>&1 || log "(timeout or error)"

# Run func tests if available (ignore failures)
log ""
log "--- Running func tests ---"
for t in /opt/test/test_*.sh; do
	[ -f "$t" ] || continue
	tname=$(basename "$t")
	log ""
	log "--- $tname ---"
	timeout 30 /bin/bash "$t" 2>&1 || log "[FAIL] $tname (timeout or failed)"
done

# Post-test dmesg
log ""
log "=== Kernel net_delayacct messages (post-test) ==="
dmesg | grep -i net_delayacct || log "(none)"

log ""
log "=== Test run finished: $(date) ==="
log ""

# Shutdown: try reboot, fall back to poweroff, then exit
/bin/sleep 1
/bin/reboot -f 2>/dev/null || /bin/poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
INITEOF

	chmod +x "$INITRD_DIR/init"

	# Package as cpio
	(cd "$INITRD_DIR" && find . | cpio -o -H newc | gzip) > "$INITRD_IMG"
	rm -rf "$INITRD_DIR"

	echo "Initramfs: $INITRD_IMG ($(du -sh "$INITRD_IMG" | cut -f1))"
}

# ============================================================================
# Step 6: Run QEMU
# ============================================================================
step_run_qemu() {
	log_section "Booting QEMU"

	local KERNEL_IMAGE="$LINUX_SRC/arch/x86/boot/bzImage"
	local INITRD="$PROJECT_DIR/ci/qemu/local-initrd.img"

	[ -f "$KERNEL_IMAGE" ] || { echo "${RED}No bzImage found${NC}"; exit 1; }
	[ -f "$INITRD" ] || { echo "${RED}No initrd found${NC}"; exit 1; }

	echo "Timeout: ${QEMU_TIMEOUT}s"
	echo ""

	timeout "$QEMU_TIMEOUT" qemu-system-x86_64 \
		-m "$QEMU_MEMORY" \
		-smp 2 \
		-kernel "$KERNEL_IMAGE" \
		-initrd "$INITRD" \
		-append "console=ttyS0,115200n8 rdinit=/init" \
		-nographic \
		-no-reboot \
		2>&1 || true

	echo ""
	echo "QEMU exited"
}

# ============================================================================
# Step 7: Show results
# ============================================================================
step_show_results() {
	log_section "Test Results"

	echo ""
	echo "========== TEST RESULTS =========="
	echo "Log: $LOG_FILE"
	echo ""

	# Extract PASS/FAIL from QEMU output (already in log file)
	if grep -q "\[FAIL\]" "$LOG_FILE" 2>/dev/null; then
		local fail_count=$(grep -c "\[FAIL\]" "$LOG_FILE" || true)
		echo "${RED}${fail_count} test(s) FAILED${NC}"
		grep -E "\[(PASS|FAIL)\]" "$LOG_FILE" || true
	else
		local pass_count=$(grep -c "\[PASS\]" "$LOG_FILE" || true)
		if [ "$pass_count" -gt 0 ]; then
			echo "${GREEN}All $pass_count test(s) PASSED${NC}"
		else
			echo "${YELLOW}No test results found — guest may have crashed${NC}"
		fi
	fi

	# Show dmesg
	echo ""
	echo "--- Kernel net_delayacct messages ---"
	grep -i "net_delayacct" "$LOG_FILE" 2>/dev/null || echo "(none found)"

	echo ""
	echo "=================================="
}

# ============================================================================
# Main
# ============================================================================
init_log

case "${1:-}" in
	--kernel-only)
		step_sync_source
		step_apply_patches
		step_build_kernel
		step_build_tool
		echo "${GREEN}Kernel + tool built. Run './local-test.sh --qemu-only' to test.${NC}"
		;;
	--qemu-only)
		step_create_initramfs
		step_run_qemu
		step_show_results
		;;
	--help|-h)
		echo "Usage: ./local-test.sh [--kernel-only|--qemu-only]"
		echo ""
		echo "  (no args)     Full test: sync → build → QEMU → results"
		echo "  --kernel-only Build kernel + tool only, skip QEMU"
		echo "  --qemu-only   Run QEMU test only (assumes already built)"
		;;
	*)
		step_sync_source
		step_apply_patches
		step_build_kernel
		step_build_tool
		step_create_initramfs
		step_run_qemu
		step_show_results
		;;
esac

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# ci-test.sh — Push-triggered QEMU test, invoked by GitHub Actions self-hosted runner.
#
# Called from: ci.yml → qemu-test job (runs-on: self-hosted)
#
# Per-run flow:
#   1. Update linux-6.6.y kernel source
#   2. Apply NET_DELAYACCT patches
#   3. Build kernel (incremental)
#   4. Build get_sockdelays tool
#   5. Prepare rootfs (copy binary + tests into the image)
#   6. Boot kernel in QEMU, guest runs tests, powers off
#   7. Extract test output, display summary
#   8. Commit results back to the repo
#
# Prerequisites on the VM (run setup.sh once):
#   - LINUX_SRC:  cloned linux-6.6.y tree
#   - ROOTFS_IMG: pre-built ext4 rootfs with test deps

set -euo pipefail

# In CI, GITHUB_WORKSPACE points to the checked-out project
PROJECT_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LINUX_SRC="${LINUX_SRC:-$HOME/linux-6.6}"
ROOTFS_IMG="${ROOTFS_IMG:-$HOME/qemu-rootfs.img}"
QEMU_MEMORY="${QEMU_MEMORY:-1024M}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KERNEL_PATCH_DIR="$PROJECT_DIR/kernel-patches"
REPORT_DIR="$PROJECT_DIR/tests/reports/qemu"

log()  { echo "::group::$*"; }
endlog() { echo "::endgroup::"; }

# ============================================================================
# Step 1: Update kernel source
# ============================================================================
log "Updating kernel source"
cd "$LINUX_SRC"
git fetch origin linux-6.6.y 2>&1 | tail -1
git checkout "origin/linux-6.6.y" 2>&1 | tail -1
endlog

# ============================================================================
# Step 2: Apply NET_DELAYACCT patches
# ============================================================================
log "Applying NET_DELAYACCT patches"
cd "$LINUX_SRC"

# Clean any previous changes
git checkout -- . 2>/dev/null || true
git clean -fd 2>/dev/null || true

# Install new source files
install -m 0644 "$KERNEL_PATCH_DIR/include-net-net-delayacct.h"        include/net/net-delayacct.h
install -m 0644 "$KERNEL_PATCH_DIR/include-uapi-linux-net-delayacct.h" include/uapi/linux/net-delayacct.h
install -m 0644 "$KERNEL_PATCH_DIR/net-core-net-delayacct.c"           net/core/net-delayacct.c

# Append fragments if not already present
if ! grep -q "CONFIG_NET_DELAYACCT" net/Kconfig 2>/dev/null; then
	cat "$KERNEL_PATCH_DIR/Kconfig-fragment" >> net/Kconfig
fi
if ! grep -q "net-delayacct" net/core/Makefile 2>/dev/null; then
	cat "$KERNEL_PATCH_DIR/Makefile-fragment" >> net/core/Makefile
fi

# Apply .patch files
shopt -s nullglob
for p in "$KERNEL_PATCH_DIR/"*.patch; do
	log "  Applying $(basename "$p")"
	if ! git apply "$p" 2>/dev/null; then
		patch -p1 --fuzz=3 < "$p" 2>/dev/null || {
			log "  WARNING: failed to apply $(basename "$p")"
		}
	fi
done
log "  Initializing sk_net_delayacct in sk_prot_alloc (Bug1 fix)"
sed -i 's/sk_tx_queue_clear(sk);/sk_tx_queue_clear(sk);\n\tnet_delayacct_init(\&sk->sk_net_delayacct);/' net/core/sock.c
grep -A1 'sk_tx_queue_clear' net/core/sock.c
endlog

# ============================================================================
# Step 3: Build kernel
# ============================================================================
log "Configuring and building kernel"
cd "$LINUX_SRC"

# Force rebuild of net-delayacct module to pick up changes
rm -f net/core/net-delayacct.o

make defconfig 2>&1 | tail -1

"$LINUX_SRC/scripts/kconfig/merge_config.sh" -m .config \
	"$PROJECT_DIR/ci/kernel.config.fragment" \
	"$SCRIPT_DIR/kernel-qemu.config" 2>&1 | tail -3

make olddefconfig 2>&1 | tail -1

grep -E 'CONFIG_(NET_DELAYACCT|VIRTIO_BLK|VIRTIO_NET|EXT4_FS)=' .config

make -j"$(nproc)" bzImage 2>&1 | tail -5

[ -f arch/x86/boot/bzImage ] || { log "Kernel build FAILED"; exit 1; }
log "Kernel build OK: arch/x86/boot/bzImage"
endlog

# ============================================================================
# Step 4: Build get_sockdelays tool
# ============================================================================
log "Building get_sockdelays tool"
cd "$PROJECT_DIR"

# Install UAPI header for compilation
install -m 0644 -D \
	"$KERNEL_PATCH_DIR/include-uapi-linux-net-delayacct.h" \
	/usr/include/linux/net-delayacct.h

make -B tool 2>&1 | tail -5
[ -x userspace/get_sockdelays/get_sockdelays ] || { log "Tool build FAILED"; exit 1; }
log "Tool build OK"
endlog

# ============================================================================
# Step 5: Prepare rootfs
# ============================================================================
log "Preparing rootfs"
MNT="/tmp/qemu-rootfs-mnt-$$"
mkdir -p "$MNT"
mount -o loop "$ROOTFS_IMG" "$MNT" || { log "Failed to mount rootfs"; exit 1; }

# Guest init script
install -m 0755 "$SCRIPT_DIR/guest-init.sh" "$MNT/sbin/qemu-init"

# Binary
install -m 0755 "$PROJECT_DIR/userspace/get_sockdelays/get_sockdelays" \
	"$MNT/usr/local/bin/get_sockdelays"

# Test scripts
rm -rf "$MNT/opt/net_delayacct_tests"
mkdir -p "$MNT/opt/net_delayacct_tests/func"

if [ -f "$PROJECT_DIR/tests/selftests/net-delayacct/test_netdelayacct.sh" ]; then
	cp "$PROJECT_DIR/tests/selftests/net-delayacct/test_netdelayacct.sh" \
	   "$PROJECT_DIR/tests/selftests/net-delayacct/test_helper.sh" \
	   "$MNT/opt/net_delayacct_tests/"
	if ls "$PROJECT_DIR/tests/func/test_"*.sh >/dev/null 2>&1; then
		cp "$PROJECT_DIR/tests/func/test_"*.sh \
		   "$MNT/opt/net_delayacct_tests/func/"
	fi
	chmod +x "$MNT/opt/net_delayacct_tests/"*.sh 2>/dev/null || true
	chmod +x "$MNT/opt/net_delayacct_tests/func/"*.sh 2>/dev/null || true
fi

umount "$MNT"
rmdir "$MNT"
log "Rootfs prepared"
endlog

# ============================================================================
# Step 6: Run QEMU
# ============================================================================
log "Booting QEMU (timeout: 5 min)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
QEMU_LOG="$REPORT_DIR/qemu-boot-${TIMESTAMP}.log"
mkdir -p "$REPORT_DIR"

timeout 300 qemu-system-x86_64 \
	-m "$QEMU_MEMORY" \
	-smp 2 \
	-kernel "$LINUX_SRC/arch/x86/boot/bzImage" \
	-drive file="$ROOTFS_IMG",format=raw,if=virtio \
	-append "console=ttyS0,115200n8 root=/dev/vda rw init=/sbin/qemu-init" \
	-nographic \
	-no-reboot \
	2>&1 | tee "$QEMU_LOG" || true

log "QEMU exited"
endlog

# ============================================================================
# Step 7: Extract results
# ============================================================================
log "Extracting test results"
MNT="/tmp/qemu-rootfs-mnt-$$"
mkdir -p "$MNT"
mount -o loop "$ROOTFS_IMG" "$MNT" || { log "Failed to mount rootfs"; exit 1; }

GUEST_OUT="$MNT/root/test-output.txt"
REPORT_FILE="$REPORT_DIR/test-report-${TIMESTAMP}.txt"

if [ -f "$GUEST_OUT" ]; then
	cp "$GUEST_OUT" "$REPORT_FILE"
	rm -f "$GUEST_OUT"
	log "Report: $REPORT_FILE"

	# Show summary in CI log
	echo ""
	echo "========== TEST RESULTS =========="
	cat "$REPORT_FILE"
	echo "=================================="
	echo ""

	# Count pass/fail for CI status
	if grep -q "\[FAIL\]" "$REPORT_FILE" 2>/dev/null; then
		FAIL_COUNT=$(grep -c "\[FAIL\]" "$REPORT_FILE" || true)
		log "Tests FAILED ($FAIL_COUNT failures)"
		TEST_RESULT="failure"
	else
		log "All tests PASSED"
		TEST_RESULT="success"
	fi
else
	log "WARNING: No test output found — guest may have crashed"
	echo "No test output produced. Check QEMU boot log." > "$REPORT_FILE"
	TEST_RESULT="failure"
fi

umount "$MNT"
rmdir "$MNT"
endlog

# ============================================================================
# Step 8: Commit results back to repo
# ============================================================================
log "Committing results"

cd "$PROJECT_DIR"

# Configure git for the CI user
git config user.email "ci@net-delayacct.local"
git config user.name "NET_DELAYACCT CI"

git add "$REPORT_DIR/"
if git diff --cached --quiet; then
	log "No changes to commit"
else
	git commit -m "test: QEMU test results ${TIMESTAMP}" --allow-empty
	git push origin HEAD 2>&1 | tail -3 || log "Push failed (will retry next run)"
	log "Results committed and pushed"
fi
endlog

# ============================================================================
# Exit with appropriate status
# ============================================================================
if [ "$TEST_RESULT" = "failure" ]; then
	exit 1
fi
log "All tests passed"

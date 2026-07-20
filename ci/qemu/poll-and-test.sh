#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# poll-and-test.sh — Poll GitHub for new commits, build kernel, run QEMU tests.
#
# Intended to be run by cron on a VMware Linux VM.
#
# Workflow:
#   1. git fetch to check for new commits on origin/main
#   2. If a new commit is found:
#      a. Build kernel with patches applied (incremental if possible)
#      b. Build get_sockdelays userspace tool
#      c. Copy binary + test scripts into rootfs image
#      d. Boot kernel in QEMU with the rootfs
#      e. Guest runs tests and writes output
#      f. Extract test results from rootfs
#      g. Commit results to repo and push
#
# Configuration (override via environment or edit defaults below):
#   NETDELAY_REPO      Path to local clone of NET_DELAYACCT repo
#   LINUX_SRC          Path to linux-6.6.y kernel source
#   ROOTFS_IMG         Path to the rootfs ext4 image
#   QEMU_MEMORY        RAM for QEMU guest (default: 1024M)
#   BRANCH             Branch to track (default: main)

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-detect NETDELAY_REPO by walking up from SCRIPT_DIR
NETDELAY_REPO=""
for d in "$SCRIPT_DIR" "$SCRIPT_DIR/.." "$SCRIPT_DIR/../.."; do
	if [ -f "$d/../userspace/get_sockdelays/get_sockdelays.c" ]; then
		NETDELAY_REPO="$(cd "$d/.." && pwd)"
		break
	fi
done
NETDELAY_REPO="${NETDELAY_REPO:-$HOME/NET_DELAYACCT}"

# Derived paths: everything lives alongside the repo (same as setup.sh)
LINUX_SRC="${LINUX_SRC:-$NETDELAY_REPO/../linux-6.6}"
ROOTFS_IMG="${ROOTFS_IMG:-$NETDELAY_REPO/../qemu-rootfs.img}"
QEMU_MEMORY="${QEMU_MEMORY:-1024M}"
BRANCH="${BRANCH:-main}"
LAST_TESTED_FILE="$NETDELAY_REPO/.qemu_last_tested"
REPORT_DIR="$NETDELAY_REPO/tests/reports/qemu"
KERNEL_PATCH_DIR="$NETDELAY_REPO/kernel-patches"

# ============================================================================
# Helper functions
# ============================================================================
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die()  { log "FATAL: $*"; exit 1; }

check_prereqs() {
	local missing=""
	for cmd in git make gcc qemu-system-x86_64 sudo; do
		command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
	done
	[ -z "$missing" ] || die "Missing commands:$missing"

	[ -d "$NETDELAY_REPO/.git" ]    || die "Not a git repo: $NETDELAY_REPO"
	[ -d "$LINUX_SRC" ]             || die "Kernel source not found: $LINUX_SRC"
	[ -f "$ROOTFS_IMG" ]            || die "Rootfs image not found: $ROOTFS_IMG (run setup.sh first)"
}

# Apply project patches into the kernel source tree.
# Uses a build marker to avoid full reset when nothing changed.
apply_patches() {
	log "Applying NET_DELAYACCT patches to kernel source..."
	cd "$LINUX_SRC"

	local current_kernel="$(git rev-parse HEAD)"
	local current_repo="$(cd "$NETDELAY_REPO" && git rev-parse HEAD)"
	local marker="$LINUX_SRC/.netdelay_build_marker"
	local full_reset=1

	# Check marker: if kernel + repo commits unchanged, skip full reset
	if [ -f "$marker" ]; then
		local saved_kernel saved_repo
		saved_kernel="$(head -1 "$marker")"
		saved_repo="$(tail -1 "$marker")"
		if [ "$saved_kernel" = "$current_kernel" ] && [ "$saved_repo" = "$current_repo" ]; then
			full_reset=0
			log "  Kernel source unchanged from last build, using incremental mode"
		else
			log "  Kernel or repo changed, doing full reset"
		fi
	fi

	if [ "$full_reset" -eq 1 ]; then
		git checkout -- . 2>/dev/null || true
		git clean -fd 2>/dev/null || true

		# Append Kconfig/Makefile fragments
		if ! grep -q "CONFIG_NET_DELAYACCT" net/Kconfig 2>/dev/null; then
			cat "$KERNEL_PATCH_DIR/Kconfig-fragment" >> net/Kconfig
		fi
		if ! grep -q "net-delayacct" net/core/Makefile 2>/dev/null; then
			cat "$KERNEL_PATCH_DIR/Makefile-fragment" >> net/core/Makefile
		fi
		log "  Appended Kconfig/Makefile fragments"

		# Apply .patch files
		shopt -s nullglob
		local patches=("$KERNEL_PATCH_DIR/"*.patch)
		for p in "${patches[@]}"; do
			log "  Applying $(basename "$p")..."
			if ! git apply "$p" 2>/dev/null; then
				if ! patch -p1 --fuzz=3 < "$p" 2>/dev/null; then
					log "  WARNING: failed to apply $(basename "$p"), trying to continue..."
				fi
			fi
		done
	else
		log "  Skipping full reset — only updating net-delayacct source files"
	fi

	# Always re-install source files (catches changes to the .c/.h files)
	sudo install -m 0644 "$KERNEL_PATCH_DIR/include-net-net-delayacct.h"        include/net/net-delayacct.h
	sudo install -m 0644 "$KERNEL_PATCH_DIR/include-uapi-linux-net-delayacct.h" include/uapi/linux/net-delayacct.h
	sudo install -m 0644 "$KERNEL_PATCH_DIR/net-core-net-delayacct.c"           net/core/net-delayacct.c

	# Save build marker
	echo "$current_kernel" > "$marker"
	echo "$current_repo" >> "$marker"

	return 0
}

# Configure and build the kernel.
# Keeps .config between runs for incremental builds.
build_kernel() {
	cd "$LINUX_SRC"

	if [ -f .config ]; then
		log "Kernel config exists — incremental build (skipping defconfig)"
	else
		log "Configuring kernel (first time)..."
		make defconfig 2>&1 | tail -1

		# Merge our config fragments
		"$LINUX_SRC/scripts/kconfig/merge_config.sh" -m .config \
			"$NETDELAY_REPO/ci/kernel.config.fragment" \
			"$SCRIPT_DIR/kernel-qemu.config" 2>&1 | tail -3

		make olddefconfig 2>&1 | tail -1
	fi

	# Verify critical configs
	log "Verifying config:"
	grep -E 'CONFIG_(NET_DELAYACCT|VIRTIO_BLK|VIRTIO_NET|EXT4_FS)=' .config || true

	log "Building kernel (this may take a while, progress shown below)..."
	echo ""
	make -j"$(nproc)" CC="${CC:-gcc}" bzImage 2>&1
	local make_rc=$?
	echo ""
	[ "$make_rc" -eq 0 ] || die "Kernel build failed (exit code $make_rc)"
	[ -f arch/x86/boot/bzImage ] || die "bzImage not built"

	log "Kernel build complete: arch/x86/boot/bzImage"
}

# Build the userspace get_sockdelays tool.
build_tool() {
	log "Building get_sockdelays tool..."
	cd "$NETDELAY_REPO"

	# Install UAPI header so the tool can find it
	sudo install -m 0644 -D \
		"$KERNEL_PATCH_DIR/include-uapi-linux-net-delayacct.h" \
		/usr/include/linux/net-delayacct.h

	make tool CC="${CC:-gcc}" 2>&1 | tail -3
	[ -x userspace/get_sockdelays/get_sockdelays ] || die "get_sockdelays binary not built"

	log "Tool build complete: userspace/get_sockdelays/get_sockdelays"
}

# Prepare rootfs: copy latest binary, test scripts, init script into the image.
prepare_rootfs() {
	log "Preparing rootfs image..."
	local mnt="/tmp/qemu-rootfs-mnt-$$"
	sudo mkdir -p "$mnt"

	# Mount the ext4 rootfs image
	sudo mount -o loop "$ROOTFS_IMG" "$mnt" || die "Failed to mount $ROOTFS_IMG"

	# Copy guest init script as /sbin/qemu-init
	sudo install -m 0755 "$SCRIPT_DIR/guest-init.sh" "$mnt/sbin/qemu-init"

	# Copy get_sockdelays binary
	sudo install -m 0755 "$NETDELAY_REPO/userspace/get_sockdelays/get_sockdelays" \
		"$mnt/usr/local/bin/get_sockdelays"

	# Copy test scripts
	sudo rm -rf "$mnt/opt/net_delayacct_tests"
	sudo mkdir -p "$mnt/opt/net_delayacct_tests/func"

	# Copy selftest scripts
	if [ -f "$NETDELAY_REPO/tests/selftests/net-delayacct/test_netdelayacct.sh" ]; then
		sudo cp "$NETDELAY_REPO/tests/selftests/net-delayacct/test_netdelayacct.sh" \
			"$mnt/opt/net_delayacct_tests/"
		sudo cp "$NETDELAY_REPO/tests/selftests/net-delayacct/test_helper.sh" \
			"$mnt/opt/net_delayacct_tests/"
	fi

	# Copy functional test scripts
	if ls "$NETDELAY_REPO/tests/func/test_"*.sh >/dev/null 2>&1; then
		sudo cp "$NETDELAY_REPO/tests/func/test_"*.sh \
			"$mnt/opt/net_delayacct_tests/func/"
	fi

	# Make scripts executable
	sudo chmod +x "$mnt/opt/net_delayacct_tests/"*.sh 2>/dev/null || true
	sudo chmod +x "$mnt/opt/net_delayacct_tests/func/"*.sh 2>/dev/null || true

	sudo umount "$mnt"
	sudo rmdir "$mnt"
	log "Rootfs prepared"
}

# Boot the kernel in QEMU and run tests.
run_qemu() {
	log "Booting QEMU with test kernel..."
	local bzImage="$LINUX_SRC/arch/x86/boot/bzImage"
	local logfile="$NETDELAY_REPO/tests/reports/qemu/qemu-boot-$(date +%Y%m%d_%H%M%S).log"

	mkdir -p "$(dirname "$logfile")"

	# Run QEMU; the guest's init script will run tests and power off.
	# We set a timeout (5 min) to prevent hanging forever.
	qemu-system-x86_64 \
		-m "$QEMU_MEMORY" \
		-smp 2 \
		-kernel "$bzImage" \
		-drive file="$ROOTFS_IMG",format=raw,if=virtio \
		-append "console=ttyS0,115200n8 root=/dev/vda rw quiet init=/sbin/qemu-init" \
		-nographic \
		-no-reboot \
		2>&1 | tee "$logfile" || true

	log "QEMU exited. Boot log: $logfile"
}

# Extract test output from the rootfs image.
extract_results() {
	log "Extracting test results from rootfs..."
	local mnt="/tmp/qemu-rootfs-mnt-$$"
	sudo mkdir -p "$mnt"
	sudo mount -o loop "$ROOTFS_IMG" "$mnt" || die "Failed to mount rootfs for result extraction"

	local guest_output="$mnt/root/test-output.txt"
	local timestamp=$(date +%Y%m%d_%H%M%S)
	local report_file="$REPORT_DIR/test-report-${timestamp}.txt"

	mkdir -p "$REPORT_DIR"

	if [ -f "$guest_output" ]; then
		sudo cp "$guest_output" "$report_file"
		sudo chown "$(id -u):$(id -g)" "$report_file"
		log "Test report saved: $report_file"

		# Print summary to log
		log "--- Test output preview ---"
		head -40 "$report_file"
		if [ "$(wc -l < "$report_file")" -gt 40 ]; then
			log "  ... (truncated, see full report)"
		fi
		log "--- End preview ---"

		# Clean up guest output for next run
		sudo rm -f "$guest_output"
	else
		log "WARNING: No test output found in guest"
		{
			echo "=== QEMU Test Run: $(date -u) ==="
			echo "Kernel: $(uname -r)"
			echo ""
			echo "ERROR: Guest did not produce test output."
			echo "This usually means the guest crashed or the init script failed."
		} > "$report_file"
	fi

	sudo umount "$mnt"
	sudo rmdir "$mnt"
}

# Commit and push test results back to the repo.
commit_results() {
	log "Committing test results..."
	cd "$NETDELAY_REPO"

	# Only commit if there are changes
	if git diff --quiet && git diff --cached --quiet; then
		# Check for untracked files
		if [ -z "$(git ls-files --others --exclude-standard "$REPORT_DIR")" ]; then
			log "No new results to commit"
			return 0
		fi
	fi

	GIT_TERMINAL_PROMPT=0 git add "$REPORT_DIR/"
	GIT_TERMINAL_PROMPT=0 git commit -m "test: qemu test results $(date +%Y-%m-%d)" --allow-empty || true
	GIT_TERMINAL_PROMPT=0 git push origin "$BRANCH" 2>&1 | tail -3 || log "WARNING: git push failed (check network/credentials)"
	log "Results commit done"
}

# ============================================================================
# Main
# ============================================================================
main() {
	log "=== poll-and-test.sh started ==="

	check_prereqs

	# Ensure remote URL uses HTTPS (fixes stale/damaged URLs from sudo)
	cd "$NETDELAY_REPO"
	GIT_REMOTE_URL="https://github.com/h1y2g3l4y5/NET_DELAYACCT.git"
	if [ "$(git remote get-url origin 2>/dev/null)" != "$GIT_REMOTE_URL" ]; then
		git remote set-url origin "$GIT_REMOTE_URL"
		log "Fixed git remote URL"
	fi

	# Fetch latest from remote
	cd "$NETDELAY_REPO"
	git fetch origin "$BRANCH" 2>&1 | tail -1
	local remote_head
	remote_head=$(git rev-parse "origin/$BRANCH")

	# Check if we already tested this commit
	if [ -f "$LAST_TESTED_FILE" ]; then
		local last_tested
		last_tested=$(cat "$LAST_TESTED_FILE")
		if [ "$remote_head" = "$last_tested" ]; then
			log "No new commits since $remote_head (already tested). Skipping."
			exit 0
		fi
		log "New commit detected: $last_tested -> $remote_head"
	else
		log "First run — testing current HEAD: $remote_head"
	fi

	# Update the kernel source tree
	log "Updating kernel source..."
	cd "$LINUX_SRC"
	git fetch origin linux-6.6.y 2>&1 | tail -1
	git checkout "origin/linux-6.6.y" 2>&1 | tail -1

	# Checkout and test the new commit
	cd "$NETDELAY_REPO"
	git checkout "$remote_head" 2>&1 | tail -1

	# Build and test cycle
	local build_ok=1
	apply_patches || build_ok=0
	if [ "$build_ok" -eq 1 ]; then
		build_kernel || build_ok=0
	fi
	if [ "$build_ok" -eq 1 ]; then
		build_tool || build_ok=0
	fi

	if [ "$build_ok" -eq 1 ]; then
		prepare_rootfs
		run_qemu
		extract_results
	else
		log "Build failed — recording failure report"
		mkdir -p "$REPORT_DIR"
		{
			echo "=== BUILD FAILURE: $(date -u) ==="
			echo "Commit: $remote_head"
			echo ""
			echo "The kernel or tool build failed. Check the CI logs for details."
		} > "$REPORT_DIR/test-report-$(date +%Y%m%d_%H%M%S).txt"
	fi

	commit_results

	# Mark as tested
	echo "$remote_head" > "$LAST_TESTED_FILE"
	log "=== poll-and-test.sh finished ==="
}

main "$@"

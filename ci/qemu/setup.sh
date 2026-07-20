#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# setup.sh — One-time setup for the NET_DELAYACCT QEMU test environment.
#
# Run once on your VMware Linux VM to:
#   1. Install system dependencies (build tools, QEMU, debootstrap, etc.)
#   2. Clone the linux-6.6.y kernel source
#   3. Create a minimal Debian rootfs image for QEMU
#   4. Install test dependencies inside the rootfs
#   5. Clone the NET_DELAYACCT repo
#   6. Print cron job instructions
#
# Usage:
#   sudo bash ci/qemu/setup.sh
#
# After setup, run manually to verify:
#   bash ci/qemu/poll-and-test.sh

set -euo pipefail

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die()  { log "FATAL: $*"; exit 1; }

# Must run as root
[ "$(id -u)" -eq 0 ] || die "This script must be run as root (sudo)."

# ============================================================================
# Configuration — override via environment
# ============================================================================
# Auto-detect repo
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for d in "$SCRIPT_DIR" "$SCRIPT_DIR/.." "$SCRIPT_DIR/../.."; do
	if [ -f "$d/../userspace/get_sockdelays/get_sockdelays.c" ]; then
		NETDELAY_REPO="$(cd "$d/.." && pwd)"
		break
	fi
done
NETDELAY_REPO="${NETDELAY_REPO:-$WORKDIR/NET_DELAYACCT}"

WORKDIR="${WORKDIR:-$HOME}"   # Will be adjusted for root below
# (NETDELAY_REPO already set above if detected)
LINUX_SRC="${LINUX_SRC:-$WORKDIR/linux-6.6}"
ROOTFS_IMG="${ROOTFS_IMG:-$WORKDIR/qemu-rootfs.img}"
ROOTFS_SIZE="${ROOTFS_SIZE:-2G}"
DEBIAN_RELEASE="${DEBIAN_RELEASE:-bookworm}"
USER_NAME="${SUDO_USER:-$USER}"

# Adjust workdir for root's perspective
if [ "$USER_NAME" != "root" ] && [ -n "$USER_NAME" ]; then
	WORKDIR="/home/$USER_NAME"
	LINUX_SRC="$WORKDIR/linux-6.6"
	ROOTFS_IMG="$WORKDIR/qemu-rootfs.img"
fi

# ============================================================================
# Step 1: Install system dependencies
# ============================================================================
log "=== Step 1: Installing system dependencies ==="

export DEBIAN_FRONTEND=noninteractive
apt-get update

apt-get install -y \
	build-essential \
	git \
	libelf-dev \
	libssl-dev \
	bison \
	flex \
	libncurses-dev \
	libmnl-dev \
	bc \
	ccache \
	iperf3 \
	ncat \
	qemu-system-x86 \
	debootstrap \
	wget \
	curl

log "Dependencies installed"

# ============================================================================
# Step 2: Clone linux-6.6.y kernel source
# ============================================================================
log "=== Step 2: Cloning linux-6.6.y kernel source ==="

if [ -d "$LINUX_SRC/.git" ]; then
	log "Kernel source already exists at $LINUX_SRC, fetching latest..."
	cd "$LINUX_SRC"
	git fetch origin linux-6.6.y
else
	log "Cloning linux-6.6.y from mirror (this will take a few minutes)..."
	# Use TUNA mirror for faster clone inside mainland China.
	# Fallback to kernel.org if the mirror is unavailable.
	KERNEL_URL="https://mirrors.tuna.tsinghua.edu.cn/git/linux-stable.git"
	if ! git clone --progress --depth 1 --branch linux-6.6.y "$KERNEL_URL" "$LINUX_SRC"; then
		log "Mirror failed, falling back to kernel.org..."
		git clone --progress --depth 1 --branch linux-6.6.y \
			https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git \
			"$LINUX_SRC"
	fi
fi

# Fix ownership
chown -R "$USER_NAME:$USER_NAME" "$LINUX_SRC"

log "Kernel source ready at $LINUX_SRC"

# ============================================================================
# Step 3: Clone NET_DELAYACCT repo
# ============================================================================
log "=== Step 3: Cloning NET_DELAYACCT repo ==="

if [ -d "$NETDELAY_REPO/.git" ]; then
	log "Repo ready at $NETDELAY_REPO"
	cd "$NETDELAY_REPO"
	git fetch origin 2>/dev/null || log "Fetch failed (non-fatal), using existing code"
else
	log "Cloning NET_DELAYACCT..."
	git clone https://github.com/h1y2g3l4y5/NET_DELAYACCT.git "$NETDELAY_REPO"
fi

chown -R "$USER_NAME:$USER_NAME" "$NETDELAY_REPO"

log "NET_DELAYACCT repo ready at $NETDELAY_REPO"

# ============================================================================
# Step 4: Create QEMU rootfs image
# ============================================================================
log "=== Step 4: Creating QEMU rootfs image ==="

if [ -f "$ROOTFS_IMG" ]; then
	log "Rootfs image already exists at $ROOTFS_IMG"
	read -p "Recreate? This will DESTROY existing rootfs. [y/N]: " choice
	case "$choice" in
		[Yy]*) log "Recreating rootfs..."; rm -f "$ROOTFS_IMG" ;;
		*)     log "Skipping rootfs creation"; return 0 ;;
	esac
fi

# Create empty image file
log "Creating ${ROOTFS_SIZE} ext4 image..."
dd if=/dev/zero of="$ROOTFS_IMG" bs=1 count=0 seek="$ROOTFS_SIZE" status=none
mkfs.ext4 -F "$ROOTFS_IMG" 2>&1 | tail -1

# Mount it
local mnt="/tmp/qemu-rootfs-create-$$"
mkdir -p "$mnt"
mount -o loop "$ROOTFS_IMG" "$mnt"

# Bootstrap Debian
log "Bootstrapping Debian $DEBIAN_RELEASE (this will take several minutes)..."
# Use TUNA mirror for faster bootstrap inside mainland China.
DEBIAN_MIRROR="http://mirrors.tuna.tsinghua.edu.cn/debian"
debootstrap --include=systemd,net-tools,iproute2,procps,util-linux,bash \
	"$DEBIAN_RELEASE" "$mnt" "$DEBIAN_MIRROR" 2>&1 | tail -5

[ -d "$mnt/bin" ] || die "debootstrap failed"

# Install additional packages inside the rootfs
log "Installing packages inside rootfs..."
# Mount host filesystems for chroot
mount --bind /dev  "$mnt/dev"
mount --bind /proc "$mnt/proc"
mount --bind /sys  "$mnt/sys"

# Copy resolv.conf for network inside chroot
cp /etc/resolv.conf "$mnt/etc/resolv.conf"

# Replace apt sources with mirror for faster installs inside China
cat > "$mnt/etc/apt/sources.list" << APTEOF
deb $DEBIAN_MIRROR $DEBIAN_RELEASE main
deb $DEBIAN_MIRROR $DEBIAN_RELEASE-updates main
APTEOF

# Install test dependencies
chroot "$mnt" /bin/bash -c "
	export DEBIAN_FRONTEND=noninteractive
	apt-get update 2>&1 | tail -1
	apt-get install -y iperf3 ncat libmnl0 2>&1 | tail -3
	# Clean up to save space
	apt-get clean
	rm -rf /var/lib/apt/lists/*
" 2>&1 | tail -5

# Set root password (empty / no password for QEMU)
chroot "$mnt" passwd -d root 2>/dev/null || true

# Configure serial console getty on ttyS0
# We use a simple init script instead of full systemd boot to keep it fast
# So we don't need getty

# Clean up chroot mounts
umount "$mnt/sys"
umount "$mnt/proc"
umount "$mnt/dev"
rm -f "$mnt/etc/resolv.conf"

# Make the guest-init script
log "Installing guest init script..."
mkdir -p "$mnt/sbin"
cp "$NETDELAY_REPO/ci/qemu/guest-init.sh" "$mnt/sbin/qemu-init"
chmod +x "$mnt/sbin/qemu-init"

# Create directory for test scripts
mkdir -p "$mnt/opt/net_delayacct_tests"
mkdir -p "$mnt/usr/local/bin"

umount "$mnt"
rmdir "$mnt"

chown "$USER_NAME:$USER_NAME" "$ROOTFS_IMG"
log "Rootfs image created at $ROOTFS_IMG"

# ============================================================================
# Step 5: Create report directory
# ============================================================================
log "=== Step 5: Creating report directories ==="
mkdir -p "$NETDELAY_REPO/tests/reports/qemu"
chown -R "$USER_NAME:$USER_NAME" "$NETDELAY_REPO/tests/reports"

# ============================================================================
# Step 6: Make scripts executable
# ============================================================================
log "=== Step 6: Setting up scripts ==="
chmod +x "$NETDELAY_REPO/ci/qemu/poll-and-test.sh"
chmod +x "$NETDELAY_REPO/ci/qemu/ci-test.sh"
chown -R "$USER_NAME:$USER_NAME" "$NETDELAY_REPO/ci/qemu"

# ============================================================================
# Step 7: Register GitHub Actions self-hosted runner
# ============================================================================
log "=== Step 7: Self-hosted runner (MANUAL step) ==="
log ""
log "To enable push-triggered QEMU tests, register a self-hosted runner on this VM:"
log ""
log "  1. Open in browser:"
log "     https://github.com/h1y2g3l4y5/NET_DELAYACCT/settings/actions/runners/new"
log "     (Repo Settings → Actions → Runners → New self-hosted runner)"
log ""
log "  2. Follow the on-screen instructions to download and configure the runner."
log "     Use 'runner' as the runner user and install it in /home/runner/actions-runner/"
log ""
log "  3. Register as a service so it auto-starts:"
log "     cd /home/runner/actions-runner"
log "     sudo ./svc.sh install runner"
log "     sudo ./svc.sh start"
log ""
log "  4. Verify the runner appears in Settings → Actions → Runners as 'Idle'"
log ""
log "  After registration, every push to main/dev will automatically trigger"
log "  the qemu-test job which builds the kernel and runs tests in QEMU on this VM."
log "  Results appear in GitHub Actions and are committed back to tests/reports/qemu/."
log ""

# ============================================================================
# Done
# ============================================================================
log ""
log "============================================="
log "  SETUP COMPLETE"
log "============================================="
log ""
log "Push-triggered test (requires self-hosted runner):"
log "   Register runner → push code → auto-tested in QEMU"
log ""
log "Cron-based test (alternative, no runner needed):"
log "   crontab -u $USER_NAME -e"
log "   */30 * * * * bash $NETDELAY_REPO/ci/qemu/poll-and-test.sh >> $NETDELAY_REPO/tests/reports/qemu/cron.log 2>&1"
log ""
log "Manual test (verify setup):"
log "   sudo -u $USER_NAME bash $NETDELAY_REPO/ci/qemu/poll-and-test.sh"
log ""
log "Configuration:"
log "   NET_DELAYACCT repo:  $NETDELAY_REPO"
log "   Kernel source:       $LINUX_SRC"
log "   Rootfs image:        $ROOTFS_IMG"
log ""
log "Environment variables for tuning:"
log "   QEMU_MEMORY=2048M    (default: 1024M)"
log "   BRANCH=dev           (default: main)"
log ""

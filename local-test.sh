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
QEMU_TIMEOUT_KVM="${QEMU_TIMEOUT_KVM:-90}"
QEMU_TIMEOUT_TCG="${QEMU_TIMEOUT_TCG:-240}"
# Backward compatibility: if user still exports QEMU_TIMEOUT, use it for both.
if [ -n "${QEMU_TIMEOUT:-}" ]; then
	QEMU_TIMEOUT_KVM="$QEMU_TIMEOUT"
	QEMU_TIMEOUT_TCG="$QEMU_TIMEOUT"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

init_log() {
	mkdir -p "$LOG_DIR"
	# NOTE: do NOT use `exec > >(tee ...)` here — the detached tee
	# subprocess cannot be killed by an outer `timeout`, which made
	# the whole script hang and swallowed QEMU output. Instead the
	# main body is wrapped in a single `| tee -a` pipeline below.
}

log_section() {
	echo ""
	echo "--- [$1] $(date +%H:%M:%S) ---"
}

copy_binary_with_libs() {
	local src="$1"
	local dest_root="$2"
	local dest="$dest_root$src"
	local lib

	[ -x "$src" ] || return 1
	mkdir -p "$(dirname "$dest")"
	cp -L "$src" "$dest"
	chmod +x "$dest" 2>/dev/null || true

	for lib in $(ldd "$src" 2>/dev/null | grep -o '/[^ ]*' | sort -u); do
		[ -f "$lib" ] || continue
		mkdir -p "$(dirname "$dest_root$lib")"
		cp -L "$lib" "$dest_root$lib" 2>/dev/null || true
	done
	return 0
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

	# Ensure config exists and has CONFIG_NET_DELAYACCT=y
	if [ ! -f .config ]; then
		echo "Generating .config..."
		make defconfig 2>&1 | tail -1
		"$LINUX_SRC/scripts/kconfig/merge_config.sh" -m .config \
			"$PROJECT_DIR/ci/kernel.config.fragment" \
			"$PROJECT_DIR/ci/qemu/kernel-qemu.config" 2>&1 | tail -3
		make olddefconfig 2>&1 | tail -1
	elif ! grep -q "CONFIG_NET_DELAYACCT=y" .config; then
		echo "Adding CONFIG_NET_DELAYACCT=y to existing .config..."
		"$LINUX_SRC/scripts/kconfig/merge_config.sh" -m .config \
			"$PROJECT_DIR/ci/kernel.config.fragment" 2>&1 | tail -1
		make olddefconfig 2>&1 | tail -1
	else
		echo "Config OK (CONFIG_NET_DELAYACCT=y already set)"
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

	# Copy busybox and create symlinks for base commands only
	cp "$BUSYBOX" "$INITRD_DIR/bin/busybox"
	chmod +x "$INITRD_DIR/bin/busybox"
	for cmd in sh ls cat echo grep wc head tail awk sed sleep kill pgrep \
		   mount umount mknod chmod chown mkdir rmdir cp mv rm ln \
		   timeout dmesg readlink command killall sort uniq dirname \
		   basename date test tr cut which true false \
		   ip ifconfig nslookup wget; do
		ln -sf /bin/busybox "$INITRD_DIR/bin/$cmd" 2>/dev/null || true
	done
	ln -sf /bin/busybox "$INITRD_DIR/sbin/init"

	# Prefer real host binaries for iperf3 / nc when available.
	# This makes the guest environment much closer to CI than busybox applets.
	if command -v iperf3 >/dev/null 2>&1; then
		copy_binary_with_libs "$(command -v iperf3)" "$INITRD_DIR"
		echo "Packed real iperf3 from $(command -v iperf3)"
	else
		ln -sf /bin/busybox "$INITRD_DIR/bin/iperf3" 2>/dev/null || true
		echo "WARNING: host iperf3 not found, falling back to busybox symlink"
	fi

	if command -v nc >/dev/null 2>&1; then
		copy_binary_with_libs "$(command -v nc)" "$INITRD_DIR"
		echo "Packed real nc from $(command -v nc)"
	else
		ln -sf /bin/busybox "$INITRD_DIR/bin/nc" 2>/dev/null || true
		echo "WARNING: host nc not found, falling back to busybox symlink"
	fi

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

	# Copy test scripts (func + selftests)
	if [ -d "$PROJECT_DIR/tests/func" ]; then
		cp "$PROJECT_DIR/tests/func/test_"*.sh "$INITRD_DIR/opt/test/" 2>/dev/null || true
	fi
	# Copy selftest suite (test_netdelayacct.sh + helper)
	if [ -d "$PROJECT_DIR/tests/selftests/net-delayacct" ]; then
		cp "$PROJECT_DIR/tests/selftests/net-delayacct/test_netdelayacct.sh" \
		   "$PROJECT_DIR/tests/selftests/net-delayacct/test_helper.sh" \
		   "$INITRD_DIR/opt/test/" 2>/dev/null || true
	fi
	chmod +x "$INITRD_DIR/opt/test/"*.sh 2>/dev/null || true

	# init script
	cat > "$INITRD_DIR/init" << 'INITEOF'
#!/bin/sh

log() { echo "$*"; echo "$*" >> /root/test-output.txt; }

export PATH=/usr/local/bin:/usr/bin:/bin:/sbin
# Export tool path so the selftest (which runs under 'set -u') can find it
# without crashing on the unbound GET_SOCKDELAYS variable.
export GET_SOCKDELAYS=/usr/local/bin/get_sockdelays

# Mount essentials
/bin/mount -t proc none /proc
/bin/mount -t sysfs none /sys
/bin/mount -t devtmpfs none /dev 2>/dev/null || /bin/mknod -m 666 /dev/null c 1 3
/bin/mkdir -p /dev/pts /dev/shm

# Bring up loopback (required for TCP/UDP tests)
/bin/mount -t tmpfs none /tmp 2>/dev/null || true
/bin/ip link set lo up 2>/dev/null || /bin/ifconfig lo 127.0.0.1 up 2>/dev/null || true

# Configure external network (QEMU user-mode networking)
# This enables real-world traffic demos (e.g., TCP to baidu.com, UDP to bilibili.com)
if /bin/ip link show eth0 >/dev/null 2>&1; then
	/bin/ip link set eth0 up
	/bin/ip addr add 10.0.2.15/24 dev eth0 2>/dev/null || true
	/bin/ip route add default via 10.0.2.2 2>/dev/null || true
	echo "nameserver 10.0.2.3" > /etc/resolv.conf
	log "External network: eth0 configured (10.0.2.15/24, gw 10.0.2.2, dns 10.0.2.3)"
	EXTERNAL_NET=1
else
	log "External network: eth0 not found, real-world demos will be skipped"
	EXTERNAL_NET=0
fi

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

# Test 3: inode query — create a socket, extract its inode, query by inode
log ""
log "--- get_sockdelays -i (inode query) ---"
INODE=""
NC_PORT=19999
if command -v nc >/dev/null 2>&1; then
	nc -l -p "$NC_PORT" &
	NC_PID=$!
	/bin/sleep 1
	if kill -0 "$NC_PID" 2>/dev/null; then
		for fd_path in /proc/"$NC_PID"/fd/*; do
			target=$(readlink "$fd_path" 2>/dev/null || true)
			case "$target" in
				socket:\[*\])
					INODE=$(echo "$target" | sed 's/.*socket:\[\([0-9]*\)\].*/\1/')
					break
					;;
			esac
		done
		if [ -n "$INODE" ]; then
			log "extracted inode=$INODE from nc listener pid=$NC_PID"
			timeout 10 /usr/local/bin/get_sockdelays -i "$INODE" 2>&1 || log "(timeout or error)"
		else
			log "(could not extract inode from nc listener)"
		fi
		kill "$NC_PID" 2>/dev/null || true
	else
		log "(nc listener failed to start)"
	fi
else
	log "(nc not available, skipping inode query test)"
fi

# Run func tests if available (ignore failures)
log ""
log "--- Running func tests ---"
for t in /opt/test/test_*.sh; do
	[ -f "$t" ] || continue
	tname=$(basename "$t")
	log ""
	log "--- $tname ---"
	timeout 30 /bin/bash "$t" 2>&1
	rc=$?
	if [ "$rc" -eq 4 ]; then
		log "[SKIP] $tname (dependencies not met)"
	elif [ "$rc" -ne 0 ]; then
		log "[FAIL] $tname (timeout or failed, rc=$rc)"
	fi
done

# ============================================================================
# Visualization Demo — demonstrate get_sockdelays features for manual review
# ============================================================================
log ""
log "========================================"
log "  get_sockdelays Visualization Demo"
log "========================================"

# Demo 1: Help and version
log ""
log "--- Demo 1: Tool help ---"
log "$ get_sockdelays -h"
/usr/local/bin/get_sockdelays -h 2>&1

log ""
log "--- Demo 2: Tool version ---"
log "$ get_sockdelays -V"
/usr/local/bin/get_sockdelays -V 2>&1

# Demo 3: TCP socket query
log ""
log "--- Demo 3: TCP socket query (local iperf3) ---"
TCP_PORT=21524
iperf3 -s -p "$TCP_PORT" >/dev/null 2>&1 &
TCP_PID=$!
sleep 1
if kill -0 "$TCP_PID" 2>/dev/null; then
	iperf3 -c 127.0.0.1 -p "$TCP_PORT" -t 5 >/dev/null 2>&1 &
	CLIENT_PID=$!
	sleep 2
	log "# iperf3 server pid=$TCP_PID, client pid=$CLIENT_PID"
	log "$ get_sockdelays -p $TCP_PID"
	/usr/local/bin/get_sockdelays -p "$TCP_PID" 2>&1
	log ""
	log "$ get_sockdelays -p $CLIENT_PID"
	/usr/local/bin/get_sockdelays -p "$CLIENT_PID" 2>&1
	kill "$CLIENT_PID" 2>/dev/null || true
	wait "$CLIENT_PID" 2>/dev/null || true
else
	log "(iperf3 server failed to start)"
fi
kill "$TCP_PID" 2>/dev/null || true
wait "$TCP_PID" 2>/dev/null || true

# Demo 4: UDP socket query
log ""
log "--- Demo 4: UDP socket query (local iperf3 -u) ---"
UDP_PORT=21525
iperf3 -s -p "$UDP_PORT" >/dev/null 2>&1 &
UDP_PID=$!
sleep 1
if kill -0 "$UDP_PID" 2>/dev/null; then
	iperf3 -c 127.0.0.1 -p "$UDP_PORT" -u -t 10 -b 100M >/dev/null 2>&1 &
	UDP_CLIENT=$!
	sleep 2
	log "# iperf3 UDP server pid=$UDP_PID, client pid=$UDP_CLIENT"
	log "$ get_sockdelays -p $UDP_PID"
	/usr/local/bin/get_sockdelays -p "$UDP_PID" 2>&1
	log ""
	log "$ get_sockdelays -p $UDP_CLIENT"
	/usr/local/bin/get_sockdelays -p "$UDP_CLIENT" 2>&1
	kill "$UDP_CLIENT" 2>/dev/null || true
	wait "$UDP_CLIENT" 2>/dev/null || true
else
	log "(iperf3 UDP server failed to start)"
fi
kill "$UDP_PID" 2>/dev/null || true
wait "$UDP_PID" 2>/dev/null || true

# Demo 5: Inode query
log ""
log "--- Demo 5: Inode query (-i <inode>) ---"
NC_PORT=21526
nc -l -p "$NC_PORT" &
NC_PID=$!
sleep 1
if kill -0 "$NC_PID" 2>/dev/null; then
	INODE=""
	for fd_path in /proc/"$NC_PID"/fd/*; do
		target=$(readlink "$fd_path" 2>/dev/null || true)
		case "$target" in
			socket:\[*\])
				INODE=$(echo "$target" | sed 's/.*socket:\[\([0-9]*\)\].*/\1/')
				break
				;;
		esac
	done
	if [ -n "$INODE" ]; then
		log "# Extracted inode=$INODE from nc listener pid=$NC_PID"
		log "$ get_sockdelays -i $INODE"
		/usr/local/bin/get_sockdelays -i "$INODE" 2>&1
	else
		log "(could not extract inode)"
	fi
	kill "$NC_PID" 2>/dev/null || true
	wait "$NC_PID" 2>/dev/null || true
else
	log "(nc listener failed to start)"
fi

# Demo 6: JSON output
log ""
log "--- Demo 6: JSON output (-j) ---"
JSON_PORT=21527
iperf3 -s -p "$JSON_PORT" >/dev/null 2>&1 &
JSON_PID=$!
sleep 1
if kill -0 "$JSON_PID" 2>/dev/null; then
	iperf3 -c 127.0.0.1 -p "$JSON_PORT" -t 5 >/dev/null 2>&1 &
	JSON_CLIENT=$!
	sleep 2
	log "# iperf3 server pid=$JSON_PID"
	log "$ get_sockdelays -j -p $JSON_PID"
	/usr/local/bin/get_sockdelays -j -p "$JSON_PID" 2>&1
	kill "$JSON_CLIENT" 2>/dev/null || true
	wait "$JSON_CLIENT" 2>/dev/null || true
else
	log "(iperf3 server failed to start)"
fi
kill "$JSON_PID" 2>/dev/null || true
wait "$JSON_PID" 2>/dev/null || true

# Demo 7: Reset counters
log ""
log "--- Demo 7: Reset counters (-R) ---"
log "$ get_sockdelays -R"
/usr/local/bin/get_sockdelays -R 2>&1

# Demo 8: Debug diagnostics
log ""
log "--- Demo 8: Debug diagnostics (-d) ---"
DBG_PORT=21528
nc -l -p "$DBG_PORT" &
DBG_PID=$!
sleep 1
if kill -0 "$DBG_PID" 2>/dev/null; then
	log "# nc listener pid=$DBG_PID"
	log "$ get_sockdelays -d -p $DBG_PID"
	/usr/local/bin/get_sockdelays -d -p "$DBG_PID" 2>&1
	kill "$DBG_PID" 2>/dev/null || true
	wait "$DBG_PID" 2>/dev/null || true
else
	log "(nc listener failed to start)"
fi

# Demo 9: Real-world TCP — connect to baidu.com
log ""
log "--- Demo 9: Real-world TCP (nc www.baidu.com 80) ---"
if [ "$EXTERNAL_NET" = "1" ]; then
	# Use 'sleep' pipe to keep nc's stdin open so the TCP connection
	# stays alive long enough for get_sockdelays to query it.
	(sleep 8) | nc www.baidu.com 80 >/dev/null 2>&1 &
	BAIDU_PID=$!
	sleep 2
	if kill -0 "$BAIDU_PID" 2>/dev/null; then
		log "# nc connected to www.baidu.com:80, pid=$BAIDU_PID"
		log "$ get_sockdelays -p $BAIDU_PID"
		/usr/local/bin/get_sockdelays -p "$BAIDU_PID" 2>&1
	else
		log "(nc exited before query — trying wget fallback)"
		wget -q -O /dev/null http://www.baidu.com 2>/dev/null &
		WGET_PID=$!
		sleep 1
		if kill -0 "$WGET_PID" 2>/dev/null; then
			log "$ get_sockdelays -p $WGET_PID"
			/usr/local/bin/get_sockdelays -p "$WGET_PID" 2>&1
			kill "$WGET_PID" 2>/dev/null || true
			wait "$WGET_PID" 2>/dev/null || true
		else
			log "(wget also exited too quickly)"
		fi
	fi
	kill "$BAIDU_PID" 2>/dev/null || true
	wait "$BAIDU_PID" 2>/dev/null || true
else
	log "(external network unavailable, skipping)"
fi

# Demo 10: Real-world UDP — connect to bilibili.com (QUIC port)
log ""
log "--- Demo 10: Real-world UDP (bilibili.com video streaming) ---"
if [ "$EXTERNAL_NET" = "1" ]; then
	# Resolve bilibili.com first so we can use the IP directly with nc -u.
	# Filter for IPv4 only — QEMU user-mode networking only forwards IPv4.
	BILI_IP=$(nslookup www.bilibili.com 2>/dev/null | awk '{print $NF}' | grep '^[0-9]' | grep '\.' | grep -v ':' | grep -v '^10\.0\.2\.' | head -1 | sed 's/#.*//')
	if [ -n "$BILI_IP" ]; then
		log "# Resolved www.bilibili.com -> $BILI_IP"
		# Open a UDP socket to bilibili's QUIC port (443/udp).
		# Bilibili serves video over QUIC (HTTP/3), which uses UDP.
		(sleep 8) | nc -u -w 10 "$BILI_IP" 443 >/dev/null 2>&1 &
		BILI_PID=$!
		sleep 3
		if kill -0 "$BILI_PID" 2>/dev/null; then
			log "# nc -u connected to $BILI_IP:443 (bilibili QUIC), pid=$BILI_PID"
			log "$ get_sockdelays -p $BILI_PID"
			/usr/local/bin/get_sockdelays -p "$BILI_PID" 2>&1
		else
			log "# nc -u to bilibili exited (server may refuse raw UDP)"
			log "# Falling back to local iperf3 -u (simulating video streaming)"
			UDP_FB_PORT=21530
			iperf3 -s -p "$UDP_FB_PORT" >/dev/null 2>&1 &
			UDP_FB_PID=$!
			sleep 1
			iperf3 -c 127.0.0.1 -p "$UDP_FB_PORT" -u -t 5 -b 50M >/dev/null 2>&1 &
			UDP_FB_CLI=$!
			sleep 2
			log "# iperf3 -u (simulated video stream), server pid=$UDP_FB_PID"
			log "$ get_sockdelays -p $UDP_FB_PID"
			/usr/local/bin/get_sockdelays -p "$UDP_FB_PID" 2>&1
			kill "$UDP_FB_CLI" 2>/dev/null || true
			wait "$UDP_FB_CLI" 2>/dev/null || true
			kill "$UDP_FB_PID" 2>/dev/null || true
			wait "$UDP_FB_PID" 2>/dev/null || true
		fi
		kill "$BILI_PID" 2>/dev/null || true
		wait "$BILI_PID" 2>/dev/null || true
	else
		log "(DNS resolution for www.bilibili.com returned no IPv4 address)"
	fi
else
	log "(external network unavailable, skipping)"
fi

log ""
log "========================================"
log "  Demo complete"
log "========================================"

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
	local qemu_common_args=()
	local qemu_mode="kvm"
	local qemu_rc=0

	[ -f "$KERNEL_IMAGE" ] || { echo "${RED}No bzImage found${NC}"; exit 1; }
	[ -f "$INITRD" ] || { echo "${RED}No initrd found${NC}"; exit 1; }

	echo "Timeout (kvm): ${QEMU_TIMEOUT_KVM}s"
	echo "Timeout (tcg): ${QEMU_TIMEOUT_TCG}s"
	echo ""

	qemu_common_args=(
		-m "$QEMU_MEMORY"
		-smp 2
		-kernel "$KERNEL_IMAGE"
		-initrd "$INITRD"
		-append "console=ttyS0,115200n8 rdinit=/init"
		-nographic
		-no-reboot
		-netdev user,id=net0
		-device e1000,netdev=net0
	)

	echo "QEMU mode: ${qemu_mode} (timeout=${QEMU_TIMEOUT_KVM}s)"
	set +e
	timeout "$QEMU_TIMEOUT_KVM" qemu-system-x86_64 \
		-machine q35,accel=kvm,smm=off \
		-cpu host,-sgx \
		"${qemu_common_args[@]}"
	qemu_rc=$?
	set -e

	if [ "$qemu_rc" -ne 0 ] && grep -Eq '(/dev/kvm|failed to initialize kvm|Permission denied|/dev/sgx_vepc|hit restricted)' "$LOG_FILE" 2>/dev/null; then
		qemu_mode="tcg"
		echo ""
		echo "KVM/SGX unavailable in current environment, falling back to TCG..."
		echo "QEMU mode: ${qemu_mode} (timeout=${QEMU_TIMEOUT_TCG}s)"
		set +e
		timeout "$QEMU_TIMEOUT_TCG" qemu-system-x86_64 \
			-machine q35,accel=tcg,smm=off \
			-cpu qemu64,-sgx \
			"${qemu_common_args[@]}"
		qemu_rc=$?
		set -e
	fi

	echo ""
	echo "QEMU exited (mode=${qemu_mode}, rc=${qemu_rc})"
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

# Wrap the whole body in a single `tee` pipeline so that:
#   - output goes to BOTH the terminal and the log file
#   - `timeout` / Ctrl-C kills the script and tee exits cleanly with the pipe
#     (the previous `exec > >(tee ...)` in init_log left a detached tee that
#      hung the terminal and swallowed QEMU output)
{
	echo "=== Local Test $(date) ==="
	echo "Log: $LOG_FILE"
	echo ""

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
} 2>&1 | tee -a "$LOG_FILE"

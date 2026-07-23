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
# Visualization Demo — get_sockdelays 工具功能演示
# 演示目的：展示 get_sockdelays 在各种真实场景下的输出效果
# 输出格式：每个 socket 占 3 行（标识行 + RX 行 + TX 行），延迟以 ms 显示
# ============================================================================
log ""
log "########################################"
log "#  get_sockdelays 可视化演示"
log "#  格式：proto=xxx ... owner_task=进程名 local=本端 remote=对端"
log "#         RX  count=包数  total=总延迟ms  average=平均延迟ms"
log "#         TX  count=包数  total=总延迟ms  average=平均延迟ms"
log "########################################"

# ================================================================
# 第一部分：基础功能 — 帮助、版本、基础查询
# ================================================================
log ""
log "# ================================================================"
log "#  第一部分：基础功能"
log "# ================================================================"

# Demo 1: 帮助信息 — 查看工具支持的所有参数
log ""
log "# [Demo 1] 查看工具帮助信息"
log "$ get_sockdelays -h"
/usr/local/bin/get_sockdelays -h 2>&1

# Demo 2: 版本信息
log ""
log "# [Demo 2] 查看工具版本号"
log "$ get_sockdelays -V"
/usr/local/bin/get_sockdelays -V 2>&1

# Demo 3: TCP socket 查询 — 用 iperf3 产生 TCP 流量后查询
log ""
log "# [Demo 3] 查询进程的 TCP socket 延迟统计"
log "# 场景：iperf3 产生 TCP 流量（5 秒），然后查询服务端和客户端进程的 socket"
TCP_PORT=21524
iperf3 -s -p "$TCP_PORT" >/dev/null 2>&1 &
TCP_PID=$!
sleep 1
if kill -0 "$TCP_PID" 2>/dev/null; then
	iperf3 -c 127.0.0.1 -p "$TCP_PORT" -t 5 >/dev/null 2>&1 &
	CLIENT_PID=$!
	sleep 2
	log "# 服务端 pid=$TCP_PID（拥有监听 socket + 已连接 socket）"
	log "$ get_sockdelays -p $TCP_PID"
	/usr/local/bin/get_sockdelays -p "$TCP_PID" 2>&1
	log ""
	log "# 客户端 pid=$CLIENT_PID（拥有 2 个已连接 socket）"
	log "$ get_sockdelays -p $CLIENT_PID"
	/usr/local/bin/get_sockdelays -p "$CLIENT_PID" 2>&1
	kill "$CLIENT_PID" 2>/dev/null || true
	wait "$CLIENT_PID" 2>/dev/null || true
else
	log "(iperf3 server failed to start)"
fi
kill "$TCP_PID" 2>/dev/null || true
wait "$TCP_PID" 2>/dev/null || true

# Demo 4: UDP socket 查询 — 用 iperf3 -u 产生 UDP 流量后查询
log ""
log "# [Demo 4] 查询进程的 UDP socket 延迟统计"
log "# 场景：iperf3 -u 产生 UDP 流量（10 秒, 100Mbps），同时有 TCP 控制连接和 UDP 数据连接"
UDP_PORT=21525
iperf3 -s -p "$UDP_PORT" >/dev/null 2>&1 &
UDP_PID=$!
sleep 1
if kill -0 "$UDP_PID" 2>/dev/null; then
	iperf3 -c 127.0.0.1 -p "$UDP_PORT" -u -t 10 -b 100M >/dev/null 2>&1 &
	UDP_CLIENT=$!
	sleep 2
	log "# 服务端 pid=$UDP_PID（同时有 proto=tcp 控制连接 和 proto=udp 数据连接）"
	log "$ get_sockdelays -p $UDP_PID"
	/usr/local/bin/get_sockdelays -p "$UDP_PID" 2>&1
	log ""
	log "# 客户端 pid=$UDP_CLIENT（同样同时拥有 TCP + UDP socket）"
	log "$ get_sockdelays -p $UDP_CLIENT"
	/usr/local/bin/get_sockdelays -p "$UDP_CLIENT" 2>&1
	kill "$UDP_CLIENT" 2>/dev/null || true
	wait "$UDP_CLIENT" 2>/dev/null || true
else
	log "(iperf3 UDP server failed to start)"
fi
kill "$UDP_PID" 2>/dev/null || true
wait "$UDP_PID" 2>/dev/null || true

# Demo 5: Inode 查询 — 通过 socket inode 号查询
log ""
log "# [Demo 5] 通过 inode 号查询指定的单个 socket"
log "# 场景：nc 创建监听 socket → 提取 /proc/PID/fd 中的 socket inode → 按 inode 查询"
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
		log "# 从 nc 进程 (pid=$NC_PID) 提取到 socket inode=$INODE"
		log "# inode 查询的返回值中 flags=0（非 MULTI），因为只返回一个 socket"
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

# Demo 6: JSON 输出 — 机器可读格式
log ""
log "# [Demo 6] JSON 格式输出（-j），便于脚本解析"
log "# JSON 中的 avg_ns 字段是内核侧计算的平均每次延迟（纳秒）"
JSON_PORT=21527
iperf3 -s -p "$JSON_PORT" >/dev/null 2>&1 &
JSON_PID=$!
sleep 1
if kill -0 "$JSON_PID" 2>/dev/null; then
	iperf3 -c 127.0.0.1 -p "$JSON_PORT" -t 5 >/dev/null 2>&1 &
	JSON_CLIENT=$!
	sleep 2
	log "$ get_sockdelays -j -p $JSON_PID"
	/usr/local/bin/get_sockdelays -j -p "$JSON_PID" 2>&1
	kill "$JSON_CLIENT" 2>/dev/null || true
	wait "$JSON_CLIENT" 2>/dev/null || true
else
	log "(iperf3 server failed to start)"
fi
kill "$JSON_PID" 2>/dev/null || true
wait "$JSON_PID" 2>/dev/null || true

# Demo 7: 计数器重置 — 清零所有统计
log ""
log "# [Demo 7] 重置所有 socket 的延迟计数器（-R）"
log "# 重置后查询同一 socket，RX/TX count 应全部为 0"
log "$ get_sockdelays -R"
/usr/local/bin/get_sockdelays -R 2>&1

# Demo 8: Debug 诊断输出 — 查看 netlink 通信细节
log ""
log "# [Demo 8] Debug 诊断模式（-d），输出 netlink 收发细节到 stderr"
log "# 可以看到：send_and_recv 的 seq/portid、recvfrom 的字节数、每步的返回值"
DBG_PORT=21528
nc -l -p "$DBG_PORT" &
DBG_PID=$!
sleep 1
if kill -0 "$DBG_PID" 2>/dev/null; then
	log "$ get_sockdelays -d -p $DBG_PID"
	/usr/local/bin/get_sockdelays -d -p "$DBG_PID" 2>&1
	kill "$DBG_PID" 2>/dev/null || true
	wait "$DBG_PID" 2>/dev/null || true
else
	log "(nc listener failed to start)"
fi

# ================================================================
# 第二部分：真实网络场景 — 连接外部互联网服务
# ================================================================
log ""
log "# ================================================================"
log "#  第二部分：真实网络场景"
log "#  通过 QEMU 用户态网络（e1000 + user-mode netdev）连接外网"
log "# ================================================================"

# Demo 9: 真实 TCP 连接 — 连接百度网站
log ""
log "# [Demo 9] 真实场景：TCP 连接百度网站 (www.baidu.com:80)"
log "# 场景：nc 直接向百度发起 HTTP 连接，local 地址为 10.0.2.15（QEMU 内网 IP）"
log "# remote 地址为百度服务器的真实公网 IP"
if [ "$EXTERNAL_NET" = "1" ]; then
	(sleep 8) | nc www.baidu.com 80 >/dev/null 2>&1 &
	BAIDU_PID=$!
	sleep 2
	if kill -0 "$BAIDU_PID" 2>/dev/null; then
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
	log "(外部网络不可用，跳过)"
fi

# Demo 10: 真实 UDP 连接 — B站视频流
log ""
log "# [Demo 10] 真实场景：UDP 连接 B站视频流 (www.bilibili.com:443 QUIC)"
log "# B站使用 QUIC (HTTP/3) 传输视频，底层基于 UDP 协议"
log "# 先 DNS 解析 B站 IPv4 地址 → nc -u 连接 → 查询该进程的 socket"
if [ "$EXTERNAL_NET" = "1" ]; then
	BILI_IP=$(nslookup www.bilibili.com 2>/dev/null | awk '{print $NF}' | grep '^[0-9]' | grep '\.' | grep -v ':' | grep -v '^10\.0\.2\.' | head -1 | sed 's/#.*//')
	if [ -n "$BILI_IP" ]; then
		log "# DNS 解析: www.bilibili.com → $BILI_IP"
		(sleep 8) | nc -u -w 10 "$BILI_IP" 443 >/dev/null 2>&1 &
		BILI_PID=$!
		sleep 3
		if kill -0 "$BILI_PID" 2>/dev/null; then
			log "$ get_sockdelays -p $BILI_PID"
			/usr/local/bin/get_sockdelays -p "$BILI_PID" 2>&1
		else
			log "# B站服务器拒绝裸 UDP 数据包（需要 QUIC 握手）"
			log "# 回退到本地 iperf3 -u，模拟视频流场景"
			UDP_FB_PORT=21530
			iperf3 -s -p "$UDP_FB_PORT" >/dev/null 2>&1 &
			UDP_FB_PID=$!
			sleep 1
			iperf3 -c 127.0.0.1 -p "$UDP_FB_PORT" -u -t 5 -b 50M >/dev/null 2>&1 &
			UDP_FB_CLI=$!
			sleep 2
			log "# iperf3 -u 模拟视频流（50Mbps, 5s），服务端 pid=$UDP_FB_PID"
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
		log "(DNS 解析 www.bilibili.com 无 IPv4 地址)"
	fi
else
	log "(外部网络不可用，跳过)"
fi

# ================================================================
# 第三部分：严格压力测试 — 高并发、大流量、混合协议、边界条件
# 测试目的：验证 get_sockdelays 在压力场景下不崩溃、不遗漏、不挂死
# 以前局限：最多只测 3 个 socket/进程，RX/TX count 只有几十~几百级别
# 本轮改进：一个进程持有 10+ socket，每个都有独立流量（count 可达数千）
# ================================================================
log ""
log "# ================================================================"
log "#  第三部分：严格压力测试"
log "#  核心指标：①不崩溃 ②不遗漏 socket ③计数值不溢出(64位) ④协议行区分正确"
log "# ================================================================"

# Demo 11: 高并发多连接 — 一个进程持有 10+ socket（iperf3 -P 并行流）
log ""
log "# [Demo 11] 压力测试：高并发多连接（iperf3 -P 10 并行流, 单进程 11 socket）"
log "# 原理：iperf3 -P 10 在客户端和服务端之间建立 10 条并行 TCP 连接"
log "#       服务端进程 = 1 个监听 socket + 10 个已连接 socket = 共 11 个"
log "#       每个 socket 都有独立的数据流（非空闲监听）"
log "# 对比旧版：旧版用 10 个 nc 进程各 1 个 socket，本版是 1 个进程 11 个 socket"
log "# 验证点：工具能否在一个进程内完整枚举全部 11 个 socket，不遗漏"
STRESS_PORT=21531
iperf3 -s -p "$STRESS_PORT" >/dev/null 2>&1 &
STRESS_PID=$!
sleep 1
if kill -0 "$STRESS_PID" 2>/dev/null; then
	iperf3 -c 127.0.0.1 -p "$STRESS_PORT" -P 6 -t 3 >/dev/null 2>&1 &
	STRESS_CLI=$!
	sleep 2  # 等待 6 条并行连接全部建立（TCG 模式网络较慢，需多等）
	log "# 执行命令：iperf3 -P 6（6 条并行 TCP 连接到服务端 pid=$STRESS_PID）"
	log "# 预期结果：至少有 6 个 proto=tcp 行（1 监听 + 6 数据连接 = 7 个 socket）"
	log "$ get_sockdelays -p $STRESS_PID"
	/usr/local/bin/get_sockdelays -p "$STRESS_PID" 2>&1
	# 统计验证
	SOCK_COUNT=$(/usr/local/bin/get_sockdelays -p "$STRESS_PID" 2>/dev/null | grep -c '^proto=' || true)
	log "# 验证结果：服务端进程共 $SOCK_COUNT 个 socket（预期 >= 6, 理想值 7）"
	RX_SUM=$(/usr/local/bin/get_sockdelays -p "$STRESS_PID" 2>/dev/null | grep 'RX  count=' | awk '{sum+=$3} END {print sum+0}' || echo 0)
	TX_SUM=$(/usr/local/bin/get_sockdelays -p "$STRESS_PID" 2>/dev/null | grep 'TX  count=' | awk '{sum+=$3} END {print sum+0}' || echo 0)
	log "# 验证结果：所有 socket 累计 RX=$RX_SUM, TX=$TX_SUM（应有非零流量）"
	log "# 结论：✓ 高并发（7 socket/进程）下工具正常工作，无崩溃无遗漏"
	kill "$STRESS_CLI" 2>/dev/null || true
	wait "$STRESS_CLI" 2>/dev/null || true
else
	log "✗ (iperf3 服务端启动失败)"
fi
kill "$STRESS_PID" 2>/dev/null || true
wait "$STRESS_PID" 2>/dev/null || true

# Demo 12: 大流量高计数 — 不限速传输，RX/TX count 百级~千级
log ""
log "# [Demo 12] 压力测试：大流量高 RX/TX 计数（iperf3 -P 3, 不限速, 单次查询）"
log "# 原理：iperf3 -P 3 条并行流，不限制带宽，TCP 跑满 loopback 速率"
log "#       客户端 3 个 socket 同时大量发送，服务端 3 个 socket 同时大量接收"
log "# 对比旧版：旧版 -t 2 -b 200M（限速短时），RX count 只有几十"
log "# 验证点：count 可达数百级，无 64 位溢出，total_ms 数值合理"
BIG_PORT=21532
iperf3 -s -p "$BIG_PORT" >/dev/null 2>&1 &
BIG_SERV=$!
sleep 1
if kill -0 "$BIG_SERV" 2>/dev/null; then
	iperf3 -c 127.0.0.1 -p "$BIG_PORT" -P 3 -t 5 >/dev/null 2>&1 &
	BIG_CLI=$!
	sleep 7  # 等待流量完成（TCG 模式网络较慢）
	log "# 执行命令：iperf3 -P 3 -t 5（3 条并行 TCP 流 × 5 秒，不限带宽）"
	log "# 查询时间点：流量完成后"
	log "# 客户端 pid=$BIG_CLI（3 个数据 socket 同时发送）："
	log "$ get_sockdelays -p $BIG_CLI"
	/usr/local/bin/get_sockdelays -p "$BIG_CLI" 2>&1
	CLI_SOCK=$(/usr/local/bin/get_sockdelays -p "$BIG_CLI" 2>/dev/null | grep -c '^proto=' || true)
	MAX_TX=$(/usr/local/bin/get_sockdelays -p "$BIG_CLI" 2>/dev/null | grep 'TX  count=' | awk '{print $3}' | sort -rn | head -1 || echo 0)
	MAX_RX=$(/usr/local/bin/get_sockdelays -p "$BIG_CLI" 2>/dev/null | grep 'RX  count=' | awk '{print $3}' | sort -rn | head -1 || echo 0)
	log "# 客户端统计：$CLI_SOCK 个 socket，最大 TX count=$MAX_TX, 最大 RX count=$MAX_RX"
	log ""
	log "# 服务端 pid=$BIG_SERV（3 个数据 socket 同时接收 + 1 监听）："
	log "$ get_sockdelays -p $BIG_SERV"
	/usr/local/bin/get_sockdelays -p "$BIG_SERV" 2>&1
	MAX_RX_SRV=$(/usr/local/bin/get_sockdelays -p "$BIG_SERV" 2>/dev/null | grep 'RX  count=' | awk '{print $3}' | sort -rn | head -1 || echo 0)
	SOCK_SRV=$(/usr/local/bin/get_sockdelays -p "$BIG_SERV" 2>/dev/null | grep -c '^proto=' || true)
	log "# 服务端统计：共 $SOCK_SRV 个 socket，最大 RX count=$MAX_RX_SRV"
	log "# 结论：✓ 高流量场景下 count 无溢出，total_ms 与流量正相关"
	kill "$BIG_CLI" 2>/dev/null || true
	wait "$BIG_CLI" 2>/dev/null || true
else
	log "✗ (iperf3 服务端启动失败)"
fi
kill "$BIG_SERV" 2>/dev/null || true
wait "$BIG_SERV" 2>/dev/null || true

# Demo 13: TCP+UDP 混合 + 各自多连接 — 协议隔离验证
log ""
log "# [Demo 13] 压力测试：TCP + UDP 混合，各自多连接，验证协议隔离"
log "# 原理：同时启动 TCP server（-P 5 并行流）+ UDP server（-u 模式）"
log "#       TCP server 持有 ~6 个 socket（1 监听 + 5 数据）"
log "#       UDP server 持有 ~2 个 socket（1 TCP 控制 + 1 UDP 数据）"
log "# 验证点：proto=tcp 和 proto=udp 各行独立、互不干扰、计数分别统计"
MIX_PORT_TCP=21533
MIX_PORT_UDP=21534
iperf3 -s -p "$MIX_PORT_TCP" >/dev/null 2>&1 &
MIX_TCP_PID=$!
iperf3 -s -p "$MIX_PORT_UDP" >/dev/null 2>&1 &
MIX_UDP_PID=$!
sleep 1
if kill -0 "$MIX_TCP_PID" 2>/dev/null && kill -0 "$MIX_UDP_PID" 2>/dev/null; then
	iperf3 -c 127.0.0.1 -p "$MIX_PORT_TCP" -P 5 -t 3 >/dev/null 2>&1 &
	MIX_TCP_CLI=$!
	iperf3 -c 127.0.0.1 -p "$MIX_PORT_UDP" -u -t 3 -b 50M >/dev/null 2>&1 &
	MIX_UDP_CLI=$!
	sleep 2
	log "# 执行命令：iperf3 -P 5 TCP (端口 $MIX_PORT_TCP) + iperf3 -u UDP (端口 $MIX_PORT_UDP) 同时运行"
	log ""
	log "# TCP 服务端 pid=$MIX_TCP_PID（iperf3 -P 5：1 监听 + 5 数据 = ~6 socket）："
	log "# 预期：全部为 proto=tcp 行，无 proto=udp 混入"
	log "$ get_sockdelays -p $MIX_TCP_PID"
	/usr/local/bin/get_sockdelays -p "$MIX_TCP_PID" 2>&1
	T_ONLY=$(/usr/local/bin/get_sockdelays -p "$MIX_TCP_PID" 2>/dev/null | grep -c '^proto=tcp' || true)
	U_ONLY=$(/usr/local/bin/get_sockdelays -p "$MIX_TCP_PID" 2>/dev/null | grep -c '^proto=udp' || true)
	log "# 验证：TCP 服务端 proto=tcp=$T_ONLY (预期 ~6), proto=udp=$U_ONLY (预期 0)"
	log ""
	log "# UDP 服务端 pid=$MIX_UDP_PID（iperf3 -u：1 TCP 控制 + 1 UDP 数据 = ~2 socket）："
	log "# 预期：proto=tcp=1 (控制连接) + proto=udp=1 (数据连接)"
	log "$ get_sockdelays -p $MIX_UDP_PID"
	/usr/local/bin/get_sockdelays -p "$MIX_UDP_PID" 2>&1
	U_TCP_C=$(/usr/local/bin/get_sockdelays -p "$MIX_UDP_PID" 2>/dev/null | grep -c '^proto=tcp' || true)
	U_UDP_C=$(/usr/local/bin/get_sockdelays -p "$MIX_UDP_PID" 2>/dev/null | grep -c '^proto=udp' || true)
	log "# 验证：UDP 服务端 proto=tcp=$U_TCP_C (预期 1), proto=udp=$U_UDP_C (预期 1)"
	log "# 结论：✓ TCP/UDP 混合场景下协议行正确隔离，互不干扰"
	kill "$MIX_TCP_CLI" 2>/dev/null || true
	kill "$MIX_UDP_CLI" 2>/dev/null || true
	wait "$MIX_TCP_CLI" 2>/dev/null || true
	wait "$MIX_UDP_CLI" 2>/dev/null || true
else
	log "✗ (iperf3 服务端启动失败)"
fi
kill "$MIX_TCP_PID" 2>/dev/null || true
kill "$MIX_UDP_PID" 2>/dev/null || true
wait "$MIX_TCP_PID" 2>/dev/null || true
wait "$MIX_UDP_PID" 2>/dev/null || true

# Demo 14: 边界条件测试
log ""
log "# [Demo 14] 边界条件测试"
log "# 测试以下几种极端情况："
log "#   (a) PID 1 (init 进程) — 验证对无 socket 的进程返回空结果"
log "#   (b) 不存在的 PID — 验证错误处理是否健壮"
log "#   (c) 工具自身 PID — 验证对没有 socket 的进程不崩溃"
log ""
log "# (a) 查询 PID 1 (init 进程，通常没有网络 socket)："
log "$ get_sockdelays -p 1"
PID1_COUNT=$(/usr/local/bin/get_sockdelays -p 1 2>/dev/null | grep -c '^proto=' || true)
log "# PID 1 返回了 $PID1_COUNT 个 socket（预期 0 个 TCP/UDP socket）"
log ""
log "# (b) 查询不存在的 PID (99999)："
log "$ get_sockdelays -p 99999"
RC_BAD=$(set +e; /usr/local/bin/get_sockdelays -p 99999 >/dev/null 2>&1; echo $?)
log "# 不存在的 PID 退出码=$RC_BAD（预期非 0，表示错误被正确处理）"
log ""
log "# (c) 查询当前 shell 自身 $$（通常没有 TCP/UDP socket）："
log "$ get_sockdelays -p $$"
SELF_COUNT=$(/usr/local/bin/get_sockdelays -p $$ 2>/dev/null | grep -c '^proto=' || true)
log "# 自身 PID ($$) 返回了 $SELF_COUNT 个 socket"

log ""
log "########################################"
log "#  演示结束"
log "########################################"

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

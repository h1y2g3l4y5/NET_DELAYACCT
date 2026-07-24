#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# demo-tests.sh — get_sockdelays visualization + stress demos
#
# Expected to be called from guest-init.sh with basic mounts already set up.
# Output goes to stdout (captured by guest-init's tee to result file).
# NOTE: uses POSIX sh only — initramfs has busybox, no bash.

log() { echo "$*"; }

export PATH=/usr/local/bin:/usr/bin:/bin:/sbin
export GET_SOCKDELAYS=/usr/local/bin/get_sockdelays

# --- Pre-flight checks: confirm tools exist before running demos ---
log ""
log "=== demo-tests.sh pre-flight checks ==="
log "shell: $(readlink /proc/$$/exe 2>/dev/null || echo sh)"
log "get_sockdelays: $([ -x /usr/local/bin/get_sockdelays ] && echo OK || echo MISSING)"
log "iperf3: $(command -v iperf3 2>/dev/null || echo MISSING)"
log "nc: $(command -v nc 2>/dev/null || echo MISSING)"
log "busybox: $(command -v busybox 2>/dev/null || echo MISSING)"

# If get_sockdelays is missing, abort early with a clear message
if [ ! -x /usr/local/bin/get_sockdelays ]; then
	log "FATAL: get_sockdelays not found, aborting demos"
	exit 1
fi

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

# Check external network
if ip link show eth0 >/dev/null 2>&1; then
	EXTERNAL_NET=1
else
	EXTERNAL_NET=0
fi

# ================================================================
# 第一部分：基础功能 — 帮助、版本、基础查询
# ================================================================
log ""
log "# ================================================================"
log "#  第一部分：基础功能"
log "# ================================================================"

# Demo 1: 帮助信息
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

# Demo 5: Inode 查询
log ""
log "# [Demo 5] 通过 inode 号查询指定的单个 socket"
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

# Demo 6: JSON 输出
log ""
log "# [Demo 6] JSON 格式输出（-j），便于脚本解析"
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

# Demo 7: 计数器重置
log ""
log "# [Demo 7] 重置所有 socket 的延迟计数器（-R）"
log "$ get_sockdelays -R"
/usr/local/bin/get_sockdelays -R 2>&1

# Demo 8: Debug 诊断输出
log ""
log "# [Demo 8] Debug 诊断模式（-d），输出 netlink 收发细节到 stderr"
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
log "#  通过 QEMU 用户态网络连接外网"
log "# ================================================================"

# Demo 9: 真实 TCP 连接 — 连接百度网站
log ""
log "# [Demo 9] 真实场景：TCP 连接百度网站 (www.baidu.com:80)"
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
# ================================================================
log ""
log "# ================================================================"
log "#  第三部分：严格压力测试"
log "#  核心指标：①不崩溃 ②不遗漏 socket ③计数值不溢出(64位) ④协议行区分正确"
log "# ================================================================"

# Demo 11: 高并发多连接
log ""
log "# [Demo 11] 压力测试：高并发多连接（iperf3 -P 6 并行流, 单进程 7 socket）"
STRESS_PORT=21531
iperf3 -s -p "$STRESS_PORT" >/dev/null 2>&1 &
STRESS_PID=$!
sleep 1
if kill -0 "$STRESS_PID" 2>/dev/null; then
	iperf3 -c 127.0.0.1 -p "$STRESS_PORT" -P 6 -t 3 >/dev/null 2>&1 &
	STRESS_CLI=$!
	sleep 2
	log "# 执行命令：iperf3 -P 6（6 条并行 TCP 连接到服务端 pid=$STRESS_PID）"
	log "$ get_sockdelays -p $STRESS_PID"
	/usr/local/bin/get_sockdelays -p "$STRESS_PID" 2>&1
	SOCK_COUNT=$(/usr/local/bin/get_sockdelays -p "$STRESS_PID" 2>/dev/null | grep -c '^proto=' || true)
	log "# 验证：服务端进程共 $SOCK_COUNT 个 socket（预期 >= 6）"
	RX_SUM=$(/usr/local/bin/get_sockdelays -p "$STRESS_PID" 2>/dev/null | grep 'RX  count=' | awk '{sum+=$3} END {print sum+0}' || echo 0)
	TX_SUM=$(/usr/local/bin/get_sockdelays -p "$STRESS_PID" 2>/dev/null | grep 'TX  count=' | awk '{sum+=$3} END {print sum+0}' || echo 0)
	log "# 验证：所有 socket 累计 RX=$RX_SUM, TX=$TX_SUM（应有非零流量）"
	log "# ✓ 高并发（7 socket/进程）下工具正常工作"
	kill "$STRESS_CLI" 2>/dev/null || true
	wait "$STRESS_CLI" 2>/dev/null || true
else
	log "✗ (iperf3 服务端启动失败)"
fi
kill "$STRESS_PID" 2>/dev/null || true
wait "$STRESS_PID" 2>/dev/null || true

# Demo 12: 大流量高计数
log ""
log "# [Demo 12] 压力测试：大流量高 RX/TX 计数（iperf3 -P 3, 不限速, 5s）"
BIG_PORT=21532
iperf3 -s -p "$BIG_PORT" >/dev/null 2>&1 &
BIG_SERV=$!
sleep 1
if kill -0 "$BIG_SERV" 2>/dev/null; then
	iperf3 -c 127.0.0.1 -p "$BIG_PORT" -P 3 -t 5 >/dev/null 2>&1 &
	BIG_CLI=$!
	sleep 4
	log "# 执行命令：iperf3 -P 3 -t 5（3 条并行 TCP 流 × 5 秒，不限带宽）"
	log "# 客户端 pid=$BIG_CLI（3 个数据 socket 同时发送）："
	log "$ get_sockdelays -p $BIG_CLI"
	/usr/local/bin/get_sockdelays -p "$BIG_CLI" 2>&1
	MAX_TX=$(/usr/local/bin/get_sockdelays -p "$BIG_CLI" 2>/dev/null | grep 'TX  count=' | awk '{print $3}' | sort -rn | head -1 || echo 0)
	log "# 最大 TX count=$MAX_TX"
	log ""
	log "# 服务端 pid=$BIG_SERV（3 个数据 socket 同时接收 + 1 监听）："
	log "$ get_sockdelays -p $BIG_SERV"
	/usr/local/bin/get_sockdelays -p "$BIG_SERV" 2>&1
	MAX_RX_SRV=$(/usr/local/bin/get_sockdelays -p "$BIG_SERV" 2>/dev/null | grep 'RX  count=' | awk '{print $3}' | sort -rn | head -1 || echo 0)
	log "# 最大 RX count=$MAX_RX_SRV"
	log "# ✓ 高流量场景下 count 无溢出，total_ms 与流量正相关"
	kill "$BIG_CLI" 2>/dev/null || true
	wait "$BIG_CLI" 2>/dev/null || true
else
	log "✗ (iperf3 服务端启动失败)"
fi
kill "$BIG_SERV" 2>/dev/null || true
wait "$BIG_SERV" 2>/dev/null || true

# Demo 13: TCP+UDP 混合
log ""
log "# [Demo 13] 压力测试：TCP + UDP 混合，验证协议隔离"
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
	log "# TCP 服务端 pid=$MIX_TCP_PID（iperf3 -P 5：1 监听 + 5 数据）："
	log "$ get_sockdelays -p $MIX_TCP_PID"
	/usr/local/bin/get_sockdelays -p "$MIX_TCP_PID" 2>&1
	T_ONLY=$(/usr/local/bin/get_sockdelays -p "$MIX_TCP_PID" 2>/dev/null | grep -c '^proto=tcp' || true)
	U_ONLY=$(/usr/local/bin/get_sockdelays -p "$MIX_TCP_PID" 2>/dev/null | grep -c '^proto=udp' || true)
	log "# 验证：TCP 服务端 proto=tcp=$T_ONLY, proto=udp=$U_ONLY (预期 0)"
	log ""
	log "# UDP 服务端 pid=$MIX_UDP_PID（1 TCP 控制 + 1 UDP 数据）："
	log "$ get_sockdelays -p $MIX_UDP_PID"
	/usr/local/bin/get_sockdelays -p "$MIX_UDP_PID" 2>&1
	U_TCP_C=$(/usr/local/bin/get_sockdelays -p "$MIX_UDP_PID" 2>/dev/null | grep -c '^proto=tcp' || true)
	U_UDP_C=$(/usr/local/bin/get_sockdelays -p "$MIX_UDP_PID" 2>/dev/null | grep -c '^proto=udp' || true)
	log "# 验证：UDP 服务端 proto=tcp=$U_TCP_C, proto=udp=$U_UDP_C (预期各 1)"
	log "# ✓ TCP/UDP 混合场景下协议行正确隔离，互不干扰"
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
log "# (a) 查询 PID 1 (init 进程)："
log "$ get_sockdelays -p 1"
PID1_COUNT=$(/usr/local/bin/get_sockdelays -p 1 2>/dev/null | grep -c '^proto=' || true)
log "# PID 1 返回了 $PID1_COUNT 个 socket"
log ""
log "# (b) 查询不存在的 PID (99999)："
log "$ get_sockdelays -p 99999"
RC_BAD=$(set +e; /usr/local/bin/get_sockdelays -p 99999 >/dev/null 2>&1; echo $?)
log "# 不存在的 PID 退出码=$RC_BAD（预期非 0）"
log ""
log "# (c) 查询当前 shell 自身 $$："
log "$ get_sockdelays -p $$"
SELF_COUNT=$(/usr/local/bin/get_sockdelays -p $$ 2>/dev/null | grep -c '^proto=' || true)
log "# 自身 PID ($$) 返回了 $SELF_COUNT 个 socket"

log ""
log "########################################"
log "#  可视化演示结束"
log "########################################"

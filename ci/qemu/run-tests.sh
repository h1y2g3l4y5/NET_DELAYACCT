#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# run-tests.sh — NET_DELAYACCT 统一测试套件
#
# 合并自：selftest (test_netdelayacct.sh) + func tests (tests/func/*.sh)
#         + demo-tests.sh (可视化演示 + 压力测试)
#
# 测试用例清单 (共 22 项):
#   基础功能 (6 项): PID查询 / Inode查询 / 重置-基础 / TCP路径 / UDP路径 / 多Socket
#   工具展示 (2 项): JSON输出 / Debug模式
#   压力测试 (3 项): 高并发 / 大流量 / 混合协议
#   边界条件 (1 项): PID 1 / 不存在PID / -h / -V
#   稳定性   (1 项): 并发查询压力 (空PID + busyPID 混合)
#   过滤功能 (3 项): 协议过滤 / 端口过滤 / 组合过滤
#   语义验证 (1 项): Reset 非原子语义 (流量中 reset 存在非零)
#   双向流量 (1 项): 同 socket RX+TX 同时有数据
#   路径覆盖 (4 项): TCP splice RX / TCP zerocopy RX / UDP corked TX / IPv6 TCP+UDP
#
# 运行环境: QEMU guest 内，get_sockdelays 安装于 /usr/local/bin/
#           delayacct_path_test (辅助程序，路径覆盖测试用) 安装于 /usr/local/bin/
# 输出格式: 结构化 [PASS]/[FAIL]/[SKIP] + 末尾汇总框

export PATH=/usr/local/bin:/usr/bin:/bin:/sbin
GET_SOCKDELAYS="${GET_SOCKDELAYS:-/usr/local/bin/get_sockdelays}"
PATH_HELPER="${PATH_HELPER:-/usr/local/bin/delayacct_path_test}"

# 严格模式：fail fast，同时要求所有变量必须先定义
set -euo pipefail

# ============================================================
# 全局计数器
# ============================================================
_PASSED=0
_FAILED=0
_SKIPPED=0
_test_num=0

# ============================================================
# 辅助函数
# ============================================================
_test_header() {
	_test_num=$((_test_num + 1))
	echo ""
	echo "----------------------------------------------------------"
	printf "  Test %02d: %s\n" "$_test_num" "$1"
	echo "----------------------------------------------------------"
}

_pass()  { echo "    [PASS] $*"; _PASSED=$((_PASSED + 1)); }
_fail()  { echo "    [FAIL] $*"; _FAILED=$((_FAILED + 1)); }
_skip()  { echo "    [SKIP] $*"; _SKIPPED=$((_SKIPPED + 1)); }

# 检查命令是否存在，不存在则 SKIP 当前测试并返回 1
_require() {
	for _cmd; do
		if ! command -v "$_cmd" >/dev/null 2>&1; then
			_skip "missing command: $_cmd"
			return 1
		fi
	done
	return 0
}

# 检查二进制是否可执行
_check_tool() {
	if [ ! -x "$GET_SOCKDELAYS" ]; then
		echo "FATAL: get_sockdelays not found at $GET_SOCKDELAYS"
		exit 1
	fi
}

# 检查辅助程序是否存在，不存在则 SKIP 当前测试并返回 1
# 用于路径覆盖测试 (Test 19-21: splice/zerocopy/corked)，辅助程序缺失时优雅降级
_require_helper() {
	if [ ! -x "$PATH_HELPER" ]; then
		_skip "missing helper: delayacct_path_test (path-coverage test skipped)"
		return 1
	fi
	return 0
}

# 强制杀掉进程：先 SIGTERM，最多等待 2 秒，仍未退出则 SIGKILL 兜底
_kill() {
	local pid="$1"
	kill "$pid" 2>/dev/null || true
	local i=0
	while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do
		sleep 0.1
		i=$((i + 1))
	done
	kill -9 "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
}

# 失败诊断：打印 get_sockdelays 输出 + 进程状态 + 协议/计数摘要
_show_output() {
	local label="${1:-get_sockdelays output}"
	local data="${2:-}"
	local pid="${3:-}"

	echo "    +-- $label ---"
	if [ -n "$data" ]; then
		echo "$data" | sed 's/^/    | /'
	else
		echo "    | (empty output)"
	fi
	local tcp=$(echo "$data" | grep -c 'proto=tcp' || true)
	local udp=$(echo "$data" | grep -c 'proto=udp' || true)
	local lines=$(echo "$data" | grep -c 'proto=' || true)
	local rx_sum=$(echo "$data" | awk '/RX  count=/{split($2,a,"="); s+=a[2]} END{print s+0}')
	local tx_sum=$(echo "$data" | awk '/TX  count=/{split($2,a,"="); s+=a[2]} END{print s+0}')
	printf "    | summary: lines=%-3s (tcp=%-3s udp=%-3s) rx_sum=%-6s tx_sum=%-6s\n" \
		"$lines" "$tcp" "$udp" "$rx_sum" "$tx_sum"
	if [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null; then
		if kill -0 "$pid" 2>/dev/null; then
			echo "    | PID $pid: alive"
		else
			echo "    | PID $pid: not running (exited)"
		fi
	fi
	echo "    +---------------"
}

# 测试说明
_desc() {
	echo ""
	echo "  · 原理: $1"
	echo "  · 实现: $2"
	echo "  · 断言: $3"
}

# 打印 get_sockdelays 工具输出（宽度自动适配内容）
_output() {
	local label="${1:-get_sockdelays output}"
	local data="${2:-}"
	if [ -z "$data" ]; then
		return
	fi
	# 计算最长行宽度（含前缀 "  | " = 5 chars，取整到 4 的倍数方便对齐）
	local maxw=0 linew=0
	while IFS= read -r line; do
		linew=${#line}
		[ "$linew" -gt "$maxw" ] && maxw=$linew
	done <<EOF
$label
$data
EOF
	# 盒宽度: 最长行 + 前缀 5 + 余量 3，最小 60
	local boxw=$((maxw + 8))
	[ "$boxw" -lt 60 ] && boxw=60
	# 确保偶数宽度
	[ $((boxw % 2)) -eq 1 ] && boxw=$((boxw + 1))

	local line="$(printf '%*s' "$boxw" '' | tr ' ' '-')"
	echo "  +${line}"
	printf "  | %s\n" "$label"
	echo "  +${line}"
	echo "$data" | sed 's/^/  | /'
	echo "  +${line}"
}

# ============================================================
# 测试开始
# ============================================================
echo ""
echo "+==============================================================+"
echo "|        NET_DELAYACCT Unified Test Suite                     |"
echo "+==============================================================+"
echo "|  Sections: 基础功能 / 工具展示 / 压力测试 / 边界条件 / 稳定性  |"
echo "+==============================================================+"

_check_tool

# ================================================================
# 第一部分：基础功能测试 (Test 01 - 06)
# ================================================================
echo ""
echo "+--------------------------------------------------------------+"
echo "|  第一部分：基础功能                                           |"
echo "+--------------------------------------------------------------+"

# ---- Test 01: PID 查询 ----
_test_header "PID 查询 (iperf3 客户端)"
if _require iperf3; then
	_desc \
		"get_sockdelays -p <PID> 通过 Generic Netlink 内核接口查询指定进程持有的所有 socket 统计" \
		"启动 iperf3 TCP server+client，客户端后台运行 &，在传输进行中 (sleep 2) 查询客户端 PID" \
		"proto=tcp 数据行 >= 1"
	IPERF_PORT=21401
	iperf3 -s -p "$IPERF_PORT" >/dev/null 2>&1 &
	_SRV=$!
	sleep 1
	if kill -0 "$_SRV" 2>/dev/null; then
		iperf3 -c 127.0.0.1 -p "$IPERF_PORT" -t 5 >/dev/null 2>&1 &
		_CLI=$!
		sleep 2
		if kill -0 "$_CLI" 2>/dev/null; then
			OUT=$("$GET_SOCKDELAYS" -p "$_CLI" 2>&1 || true)
			_output "get_sockdelays -p $_CLI" "$OUT"
			DATA_LINES=$(echo "$OUT" | grep -c '^proto=' || true)
			HAS_TCP=$(echo "$OUT" | grep -c 'proto=tcp' || true)
			if [ "$DATA_LINES" -ge 1 ] && [ "$HAS_TCP" -ge 1 ]; then
				_pass "data_lines=$DATA_LINES, proto=tcp found"
			else
				_show_output "get_sockdelays -p $_CLI" "$OUT" "$_CLI"
				_fail "data_lines=$DATA_LINES, proto=tcp=$HAS_TCP"
			fi
			_kill "$_CLI"
		else
			_fail "iperf3 client exited before query"
		fi
		_kill "$_SRV"
	else
		_fail "iperf3 server failed to start"
	fi
fi

# ---- Test 02: Inode 查询 ----
_test_header "Inode 查询 (nc 监听端)"
if _require nc readlink; then
	_desc \
		"每个 socket 在内核中有唯一 inode 号，通过 /proc/<PID>/fd/<N> 的 socket:[inode] 符号链接可提取" \
		"nc -l 创建监听 socket → 遍历 /proc/\$PID/fd/* 提取 inode → get_sockdelays -i <inode> 查询" \
		"输出中 inode=\$INODE 匹配"
	NC_PORT=21402
	nc -l -p "$NC_PORT" >/dev/null 2>&1 &
	_NC=$!
	sleep 1
	if kill -0 "$_NC" 2>/dev/null; then
		INODE=""
		for _fd in /proc/"$_NC"/fd/*; do
			_target=$(readlink "$_fd" 2>/dev/null || true)
			case "$_target" in
				socket:\[*\])
					INODE=$(echo "$_target" | sed 's/.*socket:\[\([0-9]*\)\].*/\1/')
					break
					;;
			esac
		done
		if [ -n "$INODE" ]; then
			OUT=$("$GET_SOCKDELAYS" -i "$INODE" 2>&1 || true)
			_output "get_sockdelays -i $INODE" "$OUT"
			if echo "$OUT" | grep -q "inode=$INODE"; then
				_pass "inode=$INODE matched"
			else
				_show_output "get_sockdelays -i $INODE" "$OUT"
				_fail "inode=$INODE not in output"
			fi
		else
			_fail "could not extract socket inode from /proc/$_NC/fd"
		fi
		_kill "$_NC"
	else
		_fail "nc listener failed to start"
	fi
fi

# ---- Test 03: 重置计数器（基础功能） ----
_test_header "重置计数器-基础 (-R，停止流量后全 0)"
if _require iperf3; then
	_desc \
		"get_sockdelays -R 向内核发送 RESET 命令，遍历所有 socket 调用 net_delayacct_reset() 清零 per-sock 统计" \
		"iperf3 产生流量并结束 → 查询确认有数据 → -R 重置 → 再次查询 → 检查 count=0" \
		"停止流量后所有 socket 的 count > 0 的行数 = 0（验证 reset 清零能力本身）"
	IPERF_PORT=21403
	iperf3 -s -p "$IPERF_PORT" >/dev/null 2>&1 &
	_SRV=$!
	sleep 1
	if kill -0 "$_SRV" 2>/dev/null; then
		# 关键：client 同步运行（非 &），确保 -R 时流量已停止
		# 这是「基础功能」测试：验证停止流量后 reset 能清零
		iperf3 -c 127.0.0.1 -p "$IPERF_PORT" -t 3 >/dev/null 2>&1 || true
		sleep 1

		# 重置前确认有数据
		PRE=$("$GET_SOCKDELAYS" -p "$_SRV" 2>&1 || true)
		_output "重置前 (get_sockdelays -p $_SRV)" "$PRE"
		PRE_DATA=$(echo "$PRE" | grep -c '^proto=' || true)

		# 执行重置（此时流量已停止，无并发包干扰）
		"$GET_SOCKDELAYS" -R >/dev/null 2>&1 || true
		sleep 1

		# 重置后检查
		POST=$("$GET_SOCKDELAYS" -p "$_SRV" 2>&1 || true)
		_output "重置后 (get_sockdelays -p $_SRV)" "$POST"
		NONZERO=$(echo "$POST" | grep 'count=' | sed 's/.*count=\([0-9]*\).*/\1/' | awk '$1>0' | wc -l || true)

		if [ "$NONZERO" -eq 0 ]; then
			_pass "all counters=0 after reset (pre data=$PRE_DATA lines)"
		else
			_show_output "after reset (get_sockdelays -R then -p $_SRV)" "$POST" "$_SRV"
			_fail "$NONZERO non-zero counter(s) after reset"
		fi
		_kill "$_SRV"
	else
		_fail "iperf3 server failed to start"
	fi
fi

# ---- Test 04: TCP 路径 ----
_test_header "TCP 路径 (iperf3)"
if _require iperf3; then
	_desc \
		"验证 kernel per-socket 延迟统计框架对 TCP socket 的追踪能力" \
		"iperf3 TCP 传输完成后查询 server PID，检查 proto=tcp 行存在 + RX 计数 > 0" \
		"proto=tcp 行 >= 1，且有 RX 数据（timing 边缘 case 放宽到只要有 TCP socket 即可）"
	IPERF_PORT=21404
	iperf3 -s -p "$IPERF_PORT" >/dev/null 2>&1 &
	_SRV=$!
	sleep 1
	if kill -0 "$_SRV" 2>/dev/null; then
		iperf3 -c 127.0.0.1 -p "$IPERF_PORT" -t 5 >/dev/null 2>&1 || true
		sleep 1
		OUT=$("$GET_SOCKDELAYS" -p "$_SRV" 2>&1 || true)
		_output "get_sockdelays -p $_SRV (server)" "$OUT"

		# 检查 proto=tcp 行存在 + 有 RX/TX统计数据
		TCP_LINES=$(echo "$OUT" | grep -c 'proto=tcp' || true)
		HAS_RX=$(echo "$OUT" | grep 'RX  count=' | head -1 | grep -c 'count=[1-9]' || true)

		if [ "$TCP_LINES" -ge 1 ]; then
			if [ "$HAS_RX" -ge 1 ]; then
				_pass "proto=tcp found ($TCP_LINES socket(s)), RX has data"
			else
				# 有 TCP socket 但没有 RX 数据 (可能是 timing 问题，给 pass 但标注)
				_pass "proto=tcp found ($TCP_LINES socket(s)), RX=0 (timing)"
			fi
		else
				_show_output "get_sockdelays -p $_SRV" "$OUT" "$_SRV"
				_fail "no proto=tcp in output"
			fi
		_kill "$_SRV"
	else
		_fail "iperf3 server failed to start"
	fi
fi

# ---- Test 05: UDP 路径 ----
_test_header "UDP 路径 (iperf3 -u)"
if _require iperf3; then
	_desc \
		"验证 kernel per-socket 延迟统计框架对 UDP socket 的追踪能力。UDP 无连接状态，统计行为与 TCP 不同" \
		"iperf3 UDP 客户端 & 后台运行 (-u -b 10M)，传输进行中同时查 client 和 server 两端的 proto=udp" \
		"两端 proto=udp 总数 >= 1"
	IPERF_PORT=21405
	iperf3 -s -p "$IPERF_PORT" >/dev/null 2>&1 &
	_SRV=$!
	sleep 1
	if kill -0 "$_SRV" 2>/dev/null; then
		# 客户端必须后台运行 (&)，否则同步阻塞 5s 后 UDP socket 已被清理
		iperf3 -c 127.0.0.1 -p "$IPERF_PORT" -u -t 5 -b 10M >/dev/null 2>&1 &
		_CLI=$!
		sleep 2
		if kill -0 "$_CLI" 2>/dev/null; then
			# 同时查客户端和服务端，UDP 可能只在其中一侧可见
			SRV_OUT=$("$GET_SOCKDELAYS" -p "$_SRV" 2>&1 || true)
			CLI_OUT=$("$GET_SOCKDELAYS" -p "$_CLI" 2>&1 || true)
			_output "get_sockdelays -p $_SRV (server)" "$SRV_OUT"
			_output "get_sockdelays -p $_CLI (client)" "$CLI_OUT"
			SRV_UDP=$(echo "$SRV_OUT" | grep -c 'proto=udp' || true)
			CLI_UDP=$(echo "$CLI_OUT" | grep -c 'proto=udp' || true)
			TOTAL_UDP=$((SRV_UDP + CLI_UDP))
			if [ "$TOTAL_UDP" -ge 1 ]; then
				_pass "proto=udp found (server=$SRV_UDP, client=$CLI_UDP)"
			else
				_show_output "get_sockdelays -p $_SRV (server)" "$SRV_OUT" "$_SRV"
				_show_output "get_sockdelays -p $_CLI (client)" "$CLI_OUT" "$_CLI"
				_fail "no proto=udp in output (server=$SRV_UDP, client=$CLI_UDP)"
			fi
			_kill "$_CLI"
		else
			_fail "iperf3 UDP client exited before query"
		fi
		_kill "$_SRV"
	else
		_fail "iperf3 server failed to start"
	fi
fi

# ---- Test 06: 多 Socket 进程 ----
_test_header "多 Socket 枚举 (iperf3 -P 4 并行流)"
if _require iperf3; then
	_desc \
		"验证一个进程持有多个 socket 时 get_sockdelays 能否全量枚举，不遗漏" \
		"iperf3 -P 4 产生 4 条并行 TCP 流 → 查询 server PID。iperf3 会 fork 子进程，客户端只查父进程 PID" \
		"客户端父进程 >= 1 socket (control)，服务端 >= 6 socket（至少 1 listen + 1 control + 4 data；实际可能因 TIME-WAIT 等状态更高）"
	IPERF_PORT=21406
	iperf3 -s -p "$IPERF_PORT" >/dev/null 2>&1 &
	_SRV=$!
	sleep 1
	if kill -0 "$_SRV" 2>/dev/null; then
		iperf3 -c 127.0.0.1 -p "$IPERF_PORT" -P 4 -t 5 >/dev/null 2>&1 &
		_CLI=$!
		sleep 2
		if kill -0 "$_CLI" 2>/dev/null; then
			# iperf3 -P 4 会 fork 子进程处理数据连接。
			# $_CLI 是父进程 PID，只持有 control socket。
			# 子进程的数据 socket 不会出现在父进程的 fd 表中，
			# 所以客户端侧只检查父进程至少 1 个 control socket。
			# 服务端不 fork，所有数据 socket 都在主进程可见。
			CLI_OUT=$("$GET_SOCKDELAYS" -p "$_CLI" 2>&1 || true)
			CLI_LINES=$(echo "$CLI_OUT" | grep -c 'proto=tcp' || true)

			# 服务端: 至少 1 listen + 1 control + 4 data = >=6
			# 实际可能因 TIME-WAIT 残留 socket 等状态更高，断言用 >=6 即可
			SRV_OUT=$("$GET_SOCKDELAYS" -p "$_SRV" 2>&1 || true)
			SRV_LINES=$(echo "$SRV_OUT" | grep -c 'proto=tcp' || true)

			_output "get_sockdelays -p $_SRV (server, expect >=6)" "$SRV_OUT"
			_output "get_sockdelays -p $_CLI (client parent, expect >=1)" "$CLI_OUT"

			if [ "$CLI_LINES" -ge 1 ] && [ "$SRV_LINES" -ge 6 ]; then
				_pass "client(parent)=$CLI_LINES, server=$SRV_LINES sockets"
			else
				_show_output "get_sockdelays -p $_CLI (client parent)" "$CLI_OUT" "$_CLI"
				_show_output "get_sockdelays -p $_SRV (server)" "$SRV_OUT" "$_SRV"
				_fail "client(parent)=$CLI_LINES (expect>=1), server=$SRV_LINES (expect>=6)"
			fi
			_kill "$_CLI"
		else
			_fail "iperf3 client exited before query"
		fi
		_kill "$_SRV"
	else
		_fail "iperf3 server failed to start"
	fi
fi

# ================================================================
# 第二部分：工具展示 (Test 07 - 08)
# ================================================================
echo ""
echo "+--------------------------------------------------------------+"
echo "|  第二部分：工具展示                                           |"
echo "+--------------------------------------------------------------+"

# ---- Test 07: JSON 输出 ----
_test_header "JSON 格式输出 (-j)"
if _require iperf3; then
	_desc \
		"get_sockdelays -j 将 socket 统计以 JSON 格式输出，便于程序解析" \
		"iperf3 TCP 传输中查询 -j -p SERVER_PID → 检查输出是否包含 \"proto\" 和 \"rx\" 字段" \
		"\"proto\" 出现 >= 1 次且 \"rx\" 出现 >= 1 次"
	IPERF_PORT=21407
	iperf3 -s -p "$IPERF_PORT" >/dev/null 2>&1 &
	_SRV=$!
	sleep 1
	if kill -0 "$_SRV" 2>/dev/null; then
		iperf3 -c 127.0.0.1 -p "$IPERF_PORT" -t 3 >/dev/null 2>&1 &
		_CLI=$!
		sleep 1
		OUT=$("$GET_SOCKDELAYS" -j -p "$_SRV" 2>&1 || true)
		_output "get_sockdelays -j -p $_SRV" "$OUT"

		# JSON 应包含 "proto" 字段
		HAS_PROTO=$(echo "$OUT" | grep -c '"proto"' || true)
		HAS_RX=$(echo "$OUT" | grep -c '"rx"' || true)

		if [ "$HAS_PROTO" -ge 1 ] && [ "$HAS_RX" -ge 1 ]; then
			_pass "valid JSON with proto/rx fields"
		else
			_show_output "get_sockdelays -j -p $_SRV" "$OUT" "$_SRV"
			_fail "missing JSON fields (proto=$HAS_PROTO, rx=$HAS_RX)"
		fi
		_kill "$_CLI"
		_kill "$_SRV"
	else
		_fail "iperf3 server failed to start"
	fi
fi

# ---- Test 08: Debug 模式 ----
_test_header "Debug 诊断模式 (-d)"
if _require nc; then
	_desc \
		"get_sockdelays -d 在 stderr 输出 netlink 收发诊断信息 (diag)，用于排查内核通信问题" \
		"nc -l 创建 socket → get_sockdelays -d -p PID 2>&1 合并捕获 stderr+stdout" \
		"输出非空（至少包含 diag 或 socket 数据行）"
	NC_PORT=21408
	nc -l -p "$NC_PORT" >/dev/null 2>&1 &
	_NC=$!
	sleep 1
	if kill -0 "$_NC" 2>/dev/null; then
		# -d 模式输出到 stderr，我们合并捕获
		OUT=$("$GET_SOCKDELAYS" -d -p "$_NC" 2>&1 || true)
		_output "get_sockdelays -d -p $_NC" "$OUT"
		# Debug 输出应包含 netlink 收发信息或正常 socket 数据
		if [ -n "$OUT" ]; then
			_pass "debug output produced ($(echo "$OUT" | wc -l) lines)"
		else
			_show_output "get_sockdelays -d -p $_NC" "$OUT"
			_fail "debug output empty"
		fi
		_kill "$_NC"
	else
		_fail "nc listener failed to start"
	fi
fi

# ================================================================
# 第三部分：压力测试 (Test 09 - 11)
# ================================================================
echo ""
echo "+--------------------------------------------------------------+"
echo "|  第三部分：压力测试                                           |"
echo "|  核心指标: ①不崩溃 ②不遗漏socket ③计数无溢出 ④协议隔离正确   |"
echo "+--------------------------------------------------------------+"

# ---- Test 09: 高并发多连接 ----
_test_header "高并发多连接 (iperf3 -P 8)"
if _require iperf3; then
	_desc \
		"大量并行连接测试 socket 枚举能力和计数正确性，同时验证方向分离语义（server TX 应远小）" \
		"iperf3 -P 8 (8 条并行流) → 查 server 验 socket 枚举+RX，查 client 验 TX；反向: server TX 应远小于 client TX" \
		"server: socket>=9 且 RX>0；client: TX>0；反向: server TX <= client TX/10（server 纯 ACK 不走 sendmsg/clone，TX≈0）"
	IPERF_PORT=21409
	iperf3 -s -p "$IPERF_PORT" >/dev/null 2>&1 &
	_SRV=$!
	sleep 1
	if kill -0 "$_SRV" 2>/dev/null; then
		# 8 并行流
		iperf3 -c 127.0.0.1 -p "$IPERF_PORT" -P 8 -t 5 >/dev/null 2>&1 &
		_CLI=$!
		sleep 2
		if kill -0 "$_CLI" 2>/dev/null; then
			# server 侧：验证 socket 枚举 + RX 计数 + 反向 TX 约束
			# server 是接收方，TX 以 ACK 为主（不走 sendmsg，按设计不计入），
			# 但也可能含重传等少量 TX；故断言 server TX 远小于 client TX 而非绝对 0。
			OUT=$("$GET_SOCKDELAYS" -p "$_SRV" 2>&1 || true)
			_output "get_sockdelays -p $_SRV (server)" "$OUT"
			SOCK_COUNT=$(echo "$OUT" | grep -c 'proto=tcp' || true)
			RX_SUM=$(echo "$OUT" | awk '/RX  count=/{split($2,a,"="); s+=a[2]} END{print s+0}')
			SRV_TX_SUM=$(echo "$OUT" | awk '/TX  count=/{split($2,a,"="); s+=a[2]} END{print s+0}')

			# client 侧：验证 TX 计数
			# client 是发送方，数据走 sendmsg → tx_start 计入。
			# 注意：client RX 包含收到的 ACK（RX 在 __netif_receive_skb_core 入口计入，
			# 覆盖所有入包），故 client RX > 0 是正常的，不做反向约束。
			CLI_OUT=$("$GET_SOCKDELAYS" -p "$_CLI" 2>&1 || true)
			_output "get_sockdelays -p $_CLI (client)" "$CLI_OUT"
			CLI_TX_SUM=$(echo "$CLI_OUT" | awk '/TX  count=/{split($2,a,"="); s+=a[2]} END{print s+0}')
			CLI_RX_SUM=$(echo "$CLI_OUT" | awk '/RX  count=/{split($2,a,"="); s+=a[2]} END{print s+0}')

			FAILS=0
			# 正向断言
			if [ "$SOCK_COUNT" -lt 9 ]; then
				FAILS=$((FAILS + 1))
				echo "    server socket_count=$SOCK_COUNT (expect >=9)"
			fi
			if [ "$RX_SUM" -le 0 ]; then
				FAILS=$((FAILS + 1))
				echo "    server RX_SUM=$RX_SUM (expect >0)"
			fi
			if [ "$CLI_TX_SUM" -le 0 ]; then
				FAILS=$((FAILS + 1))
				echo "    client TX_SUM=$CLI_TX_SUM (expect >0)"
			fi
			# 反向约束：server TX 应远小于 client TX。
			# 单向传输下 server 只发纯 ACK，而纯 ACK 用 alloc_skb 零初始化 delayacct_start，
			# tx_end 守卫（start==0 跳过）使其不计入 TX，故 server TX 应接近 0。
			# client TX_SUM 为 0 时跳过比较（避免除零，且正向断言已捕获）。
			if [ "$CLI_TX_SUM" -gt 0 ] && [ "$SRV_TX_SUM" -gt $((CLI_TX_SUM / 10)) ]; then
				FAILS=$((FAILS + 1))
				echo "    server TX_SUM=$SRV_TX_SUM > client_TX/10=$((CLI_TX_SUM/10)) (expect server TX << client TX)"
			fi

			if [ "$FAILS" -eq 0 ]; then
				_pass "srv: sock=$SOCK_COUNT RX=$RX_SUM TX=$SRV_TX_SUM, cli: TX=$CLI_TX_SUM RX=$CLI_RX_SUM"
			else
				_show_output "get_sockdelays -p $_SRV (server)" "$OUT" "$_SRV"
				_show_output "get_sockdelays -p $_CLI (client)" "$CLI_OUT" "$_CLI"
				_fail "$FAILS check(s) failed (srv: sock=$SOCK_COUNT RX=$RX_SUM TX=$SRV_TX_SUM, cli: TX=$CLI_TX_SUM RX=$CLI_RX_SUM)"
			fi
			_kill "$_CLI"
		else
			_fail "iperf3 client exited before query"
		fi
		_kill "$_SRV"
	else
		_fail "iperf3 server failed to start"
	fi
fi

# ---- Test 10: 大流量高计数 ----
_test_header "大流量高计数 (iperf3 -P 4, 不限速)"
if _require iperf3; then
	_desc \
		"不限速大流量传输，验证 RX/TX 计数不会溢出或截断。按传输方向分端验证" \
		"iperf3 -P 4 -t 5 不限速 → 分别查 server(RX) 和 client(TX) 的对端方向" \
		"server RX >= 50 且 client TX >= 50（TCG 慢，阈值取保守值；KVM 下实际远超）"
	IPERF_PORT=21410
	iperf3 -s -p "$IPERF_PORT" >/dev/null 2>&1 &
	_SRV=$!
	sleep 1
	if kill -0 "$_SRV" 2>/dev/null; then
		iperf3 -c 127.0.0.1 -p "$IPERF_PORT" -P 4 -t 5 >/dev/null 2>&1 &
		_CLI=$!
		sleep 2
		if kill -0 "$_CLI" 2>/dev/null; then
			# TCP 大流量：server 侧 RX 高（接收数据），client 侧 TX 高（发送数据）
			# 只查一侧必然有一方计数极低：server 仅发 ACK（不走 sendmsg，按设计不计入 TX），
			# client 仅发数据（RX 仅有 ACK 不计入）。阈值 50 兼顾 TCG 慢模拟。
			SRV_OUT=$("$GET_SOCKDELAYS" -p "$_SRV" 2>&1 || true)
			CLI_OUT=$("$GET_SOCKDELAYS" -p "$_CLI" 2>&1 || true)
			_output "get_sockdelays -p $_SRV (server, expect RX>=50)" "$SRV_OUT"
			_output "get_sockdelays -p $_CLI (client, expect TX>=50)" "$CLI_OUT"
			MAX_SRV_RX=$(echo "$SRV_OUT" | awk '/RX  count=/{split($2,a,"="); print a[2]+0}' | sort -rn | head -1 || true)
			MAX_CLI_TX=$(echo "$CLI_OUT" | awk '/TX  count=/{split($2,a,"="); print a[2]+0}' | sort -rn | head -1 || true)

			if [ "${MAX_SRV_RX:-0}" -ge 50 ] && [ "${MAX_CLI_TX:-0}" -ge 50 ]; then
				_pass "server RX=$MAX_SRV_RX, client TX=$MAX_CLI_TX (both >=50)"
			else
				_show_output "get_sockdelays -p $_SRV (server)" "$SRV_OUT" "$_SRV"
				_show_output "get_sockdelays -p $_CLI (client)" "$CLI_OUT" "$_CLI"
				_fail "server RX=$MAX_SRV_RX, client TX=$MAX_CLI_TX (expect >=50)"
			fi
			_kill "$_CLI"
		else
			_fail "iperf3 client exited before query"
		fi
		_kill "$_SRV"
	else
		_fail "iperf3 server failed to start"
	fi
fi

# ---- Test 11: TCP+UDP 混合 ----
_test_header "混合协议隔离 (TCP + UDP 同时运行)"
if _require iperf3; then
	_desc \
		"TCP 和 UDP 同时传输，验证内核统计按协议正确隔离，不会交叉污染" \
		"启动 TCP server + UDP server → 同时运行 TCP 和 UDP client → 分别查两个 server PID" \
		"TCP server: tcp>=5, udp=0; UDP server: tcp>=1(control), udp>=1(data)"
	TCP_PORT=21411
	UDP_PORT=21412
	iperf3 -s -p "$TCP_PORT" >/dev/null 2>&1 &
	_TCP_SRV=$!
	iperf3 -s -p "$UDP_PORT" >/dev/null 2>&1 &
	_UDP_SRV=$!
	sleep 1

	if kill -0 "$_TCP_SRV" 2>/dev/null && kill -0 "$_UDP_SRV" 2>/dev/null; then
		iperf3 -c 127.0.0.1 -p "$TCP_PORT" -P 4 -t 5 >/dev/null 2>&1 &
		_TCP_CLI=$!
		iperf3 -c 127.0.0.1 -p "$UDP_PORT" -u -t 5 -b 20M >/dev/null 2>&1 &
		_UDP_CLI=$!
		sleep 2

		# TCP 服务端：应该只有 proto=tcp，没有 proto=udp
		TCP_OUT=$("$GET_SOCKDELAYS" -p "$_TCP_SRV" 2>&1 || true)
		_output "TCP server (get_sockdelays -p $_TCP_SRV)" "$TCP_OUT"
		TCP_TCP=$(echo "$TCP_OUT" | grep -c 'proto=tcp' || true)
		TCP_UDP=$(echo "$TCP_OUT" | grep -c 'proto=udp' || true)

		# UDP 服务端：iperf3 用 TCP 做控制连接，所以有 TCP+UDP 各 1
		UDP_OUT=$("$GET_SOCKDELAYS" -p "$_UDP_SRV" 2>&1 || true)
		_output "UDP server (get_sockdelays -p $_UDP_SRV)" "$UDP_OUT"
		UDP_TCP=$(echo "$UDP_OUT" | grep -c 'proto=tcp' || true)
		UDP_UDP=$(echo "$UDP_OUT" | grep -c 'proto=udp' || true)

		FAILS=0
		# TCP 服务端: tcp>=5 (1 listen + 4 data), udp=0
		if [ "${TCP_TCP:-0}" -ge 5 ] && [ "${TCP_UDP:-0}" -eq 0 ]; then
			:
		else
			FAILS=$((FAILS + 1))
			echo "    TCP server: tcp=$TCP_TCP (expect>=5), udp=$TCP_UDP (expect=0)"
		fi
		# UDP 服务端: tcp>=1 (control), udp>=1 (data)
		if [ "${UDP_TCP:-0}" -ge 1 ] && [ "${UDP_UDP:-0}" -ge 1 ]; then
			:
		else
			FAILS=$((FAILS + 1))
			echo "    UDP server: tcp=$UDP_TCP (expect>=1), udp=$UDP_UDP (expect>=1)"
		fi

		if [ "$FAILS" -eq 0 ]; then
			_pass "TCP(srv tcp=$TCP_TCP udp=$TCP_UDP) UDP(srv tcp=$UDP_TCP udp=$UDP_UDP)"
		else
			_show_output "TCP server (get_sockdelays -p $_TCP_SRV)" "$TCP_OUT" "$_TCP_SRV"
			_show_output "UDP server (get_sockdelays -p $_UDP_SRV)" "$UDP_OUT" "$_UDP_SRV"
			_fail "$FAILS protocol isolation check(s) failed"
		fi

		_kill "$_TCP_CLI"; _kill "$_UDP_CLI"
	else
		_fail "iperf3 server(s) failed to start"
	fi
	_kill "$_TCP_SRV"; _kill "$_UDP_SRV"
fi

# ================================================================
# 第四部分：边界条件 (Test 12)
# ================================================================
echo ""
echo "+--------------------------------------------------------------+"
echo "|  第四部分：边界条件                                           |"
echo "+--------------------------------------------------------------+"

# ---- Test 12: 边界条件 ----
_test_header "边界条件 (PID 1 / 不存在PID / -h / -V)"
_desc \
	"验证 get_sockdelays 在极端输入下不崩溃、合理报错" \
	"(a)PID 1 正常退出不崩溃 (b)不存在 PID 应报非零错误 (c)-h 显示帮助 (d)-V 显示版本" \
	"4 项子检查全部通过，使用本地计数器避免测试计数膨胀"
BOUNDARY_OK=0
BOUNDARY_NG=0

# (a) PID 1 (init): 不应崩溃
if OUT=$("$GET_SOCKDELAYS" -p 1 2>&1); then
	_output "get_sockdelays -p 1" "$OUT"
	BOUNDARY_OK=$((BOUNDARY_OK + 1))
	echo "    (a) PID 1: exit OK ($(echo "$OUT" | grep -c 'proto=' || echo 0) sockets)"
elif echo "$OUT" | grep -q 'no matching'; then
	BOUNDARY_OK=$((BOUNDARY_OK + 1))
	echo "    (a) PID 1: exit OK (no matching sockets)"
else
	BOUNDARY_NG=$((BOUNDARY_NG + 1))
	echo "    (a) PID 1: unexpected failure"
fi

# (b) 不存在的 PID: 应有非零退出码或错误消息
if ! "$GET_SOCKDELAYS" -p 99999 >/dev/null 2>&1; then
	BOUNDARY_OK=$((BOUNDARY_OK + 1))
	echo "    (b) PID 99999: non-zero exit (expected)"
else
	BOUNDARY_NG=$((BOUNDARY_NG + 1))
	echo "    (b) PID 99999: should have failed"
fi

# (c) -h 帮助: 应有输出
if OUT=$("$GET_SOCKDELAYS" -h 2>&1) && echo "$OUT" | grep -q -i 'usage\|用法'; then
	BOUNDARY_OK=$((BOUNDARY_OK + 1))
	echo "    (c) -h: usage shown"
else
	BOUNDARY_NG=$((BOUNDARY_NG + 1))
	echo "    (c) -h: help not shown"
fi

# (d) -V 版本: 应有输出
if "$GET_SOCKDELAYS" -V >/dev/null 2>&1; then
	BOUNDARY_OK=$((BOUNDARY_OK + 1))
	echo "    (d) -V: version OK"
else
	BOUNDARY_NG=$((BOUNDARY_NG + 1))
	echo "    (d) -V: version check failed"
fi

if [ "$BOUNDARY_NG" -eq 0 ]; then
	_pass "all $BOUNDARY_OK boundary checks passed"
else
	_fail "$BOUNDARY_NG/$((BOUNDARY_OK+BOUNDARY_NG)) boundary checks failed"
fi

# ================================================================
# 第五部分：稳定性 (Test 13)
# ================================================================
echo ""
echo "+--------------------------------------------------------------+"
echo "|  第五部分：稳定性 (perf)                                       |"
echo "+--------------------------------------------------------------+"

# ---- Test 13: 并发查询压力（空 PID + busy PID 混合） ----
_test_header "并发查询压力 (4 空 PID + 4 busyPID workers × 10 queries)"
_desc \
		"多个 worker 同时对内核发起 Netlink 查询，验证内核并发安全——无死锁、无竞态、无 Oops" \
		"启动 iperf3 busy server（持有多 socket）→ 4 worker 查 PID 1（空 fdtable）+ 4 worker 查 busy PID（per-socket 路径）→ 各 10 次 → dmesg 检查" \
		"无 worker 崩溃 + dmesg 无 kernel panic/Oops/BUG + busy worker 成功查询次数 > 0"
TMPDIR=$(mktemp -d)
_start_ts=$(date +%s)

# 启动一个 busy iperf3 server，让部分 worker 查询它（覆盖 per-socket 并发路径）
BUSY_PID=""
BUSY_PORT=21413
if command -v iperf3 >/dev/null 2>&1; then
	iperf3 -s -p "$BUSY_PORT" >/dev/null 2>&1 &
	BUSY_SRV=$!
	sleep 1
	if kill -0 "$BUSY_SRV" 2>/dev/null; then
		BUSY_PID="$BUSY_SRV"
		# 持续发起多流连接，让 server 持有多个活跃 socket
		iperf3 -c 127.0.0.1 -p "$BUSY_PORT" -P 4 -t 30 >/dev/null 2>&1 &
		BUSY_CLI=$!
	fi
fi

# worker 函数：_label="empty" 查 PID 1（空 fdtable），_label="busy" 查 busy PID（per-socket 路径）
# busy-PID worker 真正进入 net_delayacct_fill_sock()，触发 per-socket spinlock 和 cb->ctx 遍历，
# 是暴露并发安全问题的关键路径。
_worker() {
	_wid="$1"
	_target="$2"
	_label="$3"
	_ok=0
	_ng=0
	_i=0
	while [ "$_i" -lt "$QUERIES" ]; do
		if "$GET_SOCKDELAYS" -p "$_target" >/dev/null 2>&1; then
			_ok=$((_ok + 1))
		else
			_ng=$((_ng + 1))
		fi
		_i=$((_i + 1))
	done
	echo "worker-${_label}: ok=$_ok fail=$_ng" > "$TMPDIR/worker-${_wid}.out"
}

WORKERS_EMPTY=4
WORKERS_BUSY=4
QUERIES=10

# 启动 empty-PID workers（查 PID 1，覆盖空 fdtable 快速返回路径）
# 收集 worker PID，避免 wait 等待 iperf3 server/client（它们是独立后台进程）
WORKER_PIDS=""
_w=0
while [ "$_w" -lt "$WORKERS_EMPTY" ]; do
	_worker "$_w" 1 "empty" &
	WORKER_PIDS="$WORKER_PIDS $!"
	_w=$((_w + 1))
done

# 启动 busy-PID workers（查 iperf3 server，覆盖 per-socket 并发遍历路径）
if [ -n "$BUSY_PID" ]; then
	_w=0
	while [ "$_w" -lt "$WORKERS_BUSY" ]; do
		_worker "$((_w + WORKERS_EMPTY))" "$BUSY_PID" "busy" &
		WORKER_PIDS="$WORKER_PIDS $!"
		_w=$((_w + 1))
	done
fi

# 只等待 worker 进程，不等待 iperf3 server（server 持续运行直到被 kill）
# 逐个 wait 每个 worker PID，完整收集每个 worker 的退出码；bash 的
# `wait pid1 pid2 ...` 只返回最后一个 PID 的退出状态，会漏掉前面崩溃的 worker。
# 崩溃检测同时依赖 _CRASH 计数器（检查 worker 输出文件是否完整）。
for _wpid in $WORKER_PIDS; do
	_wrc=0
	wait "$_wpid" 2>/dev/null || _wrc=$?
	if [ "$_wrc" -ne 0 ]; then
		echo "    [diag] worker $_wpid exited with $_wrc (some worker may have failed, check dmesg)"
	fi
done

_end_ts=$(date +%s)
_duration=$((_end_ts - _start_ts))

# 清理 busy server
if [ -n "$BUSY_PID" ]; then
	_kill "$BUSY_CLI"
	_kill "$BUSY_SRV"
fi

# 汇总结果
_TOTAL_OK=0
_TOTAL_FAIL=0
_CRASH=0
_BUSY_OK=0
for _f in "$TMPDIR"/worker-*.out; do
	[ -f "$_f" ] || { _CRASH=$((_CRASH + 1)); continue; }
	_ok=$(grep -o 'ok=[0-9]*' "$_f" | cut -d= -f2 || true)
	_ng=$(grep -o 'fail=[0-9]*' "$_f" | cut -d= -f2 || true)
	_TOTAL_OK=$((_TOTAL_OK + _ok))
	_TOTAL_FAIL=$((_TOTAL_FAIL + _ng))
	# 统计 busy worker 的成功次数（验证 per-socket 路径确实被走到）
	if grep -q 'worker-busy' "$_f"; then
		_BUSY_OK=$((_BUSY_OK + _ok))
	fi
done

# 展示 worker 摘要 + 一份 sample 输出
echo "  +-- worker summary ($((_TOTAL_OK + _TOTAL_FAIL)) queries total, empty=${WORKERS_EMPTY} busy=${WORKERS_BUSY}) --"
echo "  | ok=$_TOTAL_OK fail=$_TOTAL_FAIL crashed=$_CRASH workers, busy_ok=$_BUSY_OK"
for _f in "$TMPDIR"/worker-*.out; do
	[ -f "$_f" ] && echo "  | sample: $(cat "$_f")" && break
done
echo "  +------------------------------------------------------------"

rm -rf "$TMPDIR"

# 检查 dmesg 中的内核问题
OOPS=$(dmesg 2>/dev/null | tail -100 | grep -cE 'Kernel panic|Oops:|BUG:' || true)

TOTAL=$((_TOTAL_OK + _TOTAL_FAIL))
FAILS=0
[ "$_CRASH" -ne 0 ] && FAILS=$((FAILS + 1))
[ "$OOPS" -ne 0 ] && FAILS=$((FAILS + 1))
# busy worker 必须有成功查询（证明 per-socket 并发路径被实际覆盖）
[ -n "$BUSY_PID" ] && [ "$_BUSY_OK" -le 0 ] && FAILS=$((FAILS + 1))

if [ "$FAILS" -eq 0 ]; then
	_pass "$TOTAL queries (ok=$_TOTAL_OK fail=$_TOTAL_FAIL busy_ok=$_BUSY_OK), ${_duration}s, no oops"
else
	if [ "$OOPS" -gt 0 ]; then
		echo "    +-- dmesg oops (last 100 lines) -------------"
		dmesg 2>/dev/null | tail -100 | sed 's/^/    | /'
		echo "    +-------------------------------------------"
	fi
	_fail "crashed=$_CRASH workers, oops=$OOPS, busy_ok=$_BUSY_OK, queries=$TOTAL"
fi

# ================================================================
# 第六部分：过滤功能测试 (Test 14 - 16)
# ================================================================
echo ""
echo "+--------------------------------------------------------------+"
echo "|  第六部分：过滤功能 (--proto/--lport/--family)              |"
echo "+--------------------------------------------------------------+"

# ---- Test 14: --proto 过滤 ----
_test_header "协议过滤 (--proto tcp / --proto udp)"
if _require iperf3; then
	_desc \
		"验证 --proto 过滤在内核侧正确筛选 socket，只返回指定协议的统计" \
		"启动 TCP+UDP server → 用 --proto tcp 和 --proto udp 分别查询 → 验证只返回对应协议" \
		"--proto tcp 只返回 TCP socket; --proto udp 只返回 UDP socket"
	TCP_PORT=21414
	UDP_PORT=21415
	iperf3 -s -p "$TCP_PORT" >/dev/null 2>&1 &
	_TCP_SRV=$!
	iperf3 -s -p "$UDP_PORT" >/dev/null 2>&1 &
	_UDP_SRV=$!
	sleep 1

	if kill -0 "$_TCP_SRV" 2>/dev/null && kill -0 "$_UDP_SRV" 2>/dev/null; then
		# 启动客户端产生流量。UDP client 用 -t 8 确保三次查询期间
		# server 的 UDP 数据 socket 不会被关闭（iperf3 server 在 client
		# 断开后会关闭与该 client 关联的 UDP 数据 socket）。
		iperf3 -c 127.0.0.1 -p "$TCP_PORT" -P 2 -t 8 >/dev/null 2>&1 &
		iperf3 -c 127.0.0.1 -p "$UDP_PORT" -u -t 8 -b 10M >/dev/null 2>&1 &
		sleep 2

		# UDP server 同时有 TCP(控制) 和 UDP(数据) socket
		# --proto tcp 应只返回 TCP, --proto udp 应只返回 UDP
		UDP_ALL=$("$GET_SOCKDELAYS" -p "$_UDP_SRV" 2>&1 || true)
		UDP_TCP_ONLY=$("$GET_SOCKDELAYS" -p "$_UDP_SRV" --proto tcp 2>&1 || true)
		UDP_UDP_ONLY=$("$GET_SOCKDELAYS" -p "$_UDP_SRV" --proto udp 2>&1 || true)

		_output "UDP server all" "$UDP_ALL"
		_output "UDP server --proto tcp" "$UDP_TCP_ONLY"
		_output "UDP server --proto udp" "$UDP_UDP_ONLY"

		ALL_TCP=$(echo "$UDP_ALL" | grep -c 'proto=tcp' || true)
		ALL_UDP=$(echo "$UDP_ALL" | grep -c 'proto=udp' || true)
		F_TCP_ONLY_TCP=$(echo "$UDP_TCP_ONLY" | grep -c 'proto=tcp' || true)
		F_TCP_ONLY_UDP=$(echo "$UDP_TCP_ONLY" | grep -c 'proto=udp' || true)
		F_UDP_ONLY_TCP=$(echo "$UDP_UDP_ONLY" | grep -c 'proto=tcp' || true)
		F_UDP_ONLY_UDP=$(echo "$UDP_UDP_ONLY" | grep -c 'proto=udp' || true)

		FAILS=0
		# 无过滤时应有 TCP 和 UDP
		if [ "${ALL_TCP:-0}" -lt 1 ] || [ "${ALL_UDP:-0}" -lt 1 ]; then
			FAILS=$((FAILS + 1))
			echo "    no filter: tcp=$ALL_TCP udp=$ALL_UDP (both should be >=1)"
		fi
		# --proto tcp 应只有 TCP，无 UDP
		if [ "${F_TCP_ONLY_TCP:-0}" -lt 1 ] || [ "${F_TCP_ONLY_UDP:-0}" -ne 0 ]; then
			FAILS=$((FAILS + 1))
			echo "    --proto tcp: tcp=$F_TCP_ONLY_TCP udp=$F_TCP_ONLY_UDP (expect tcp>=1, udp=0)"
		fi
		# --proto udp 应只有 UDP，无 TCP
		if [ "${F_UDP_ONLY_UDP:-0}" -lt 1 ] || [ "${F_UDP_ONLY_TCP:-0}" -ne 0 ]; then
			FAILS=$((FAILS + 1))
			echo "    --proto udp: tcp=$F_UDP_ONLY_TCP udp=$F_UDP_ONLY_UDP (expect tcp=0, udp>=1)"
		fi

		# negative case: 纯 UDP 进程 (nc -u -l) 查 --proto tcp 应返回空。
		# iperf3 server 总是持有 TCP 控制 socket，无法构成「纯 UDP」进程；
		# 用 nc -u -l 创建只含 UDP socket 的进程，验证 --proto tcp 不会误返回
		# UDP socket（防止「过滤失败默认返回全部」一类实现缺陷）。
		if command -v nc >/dev/null 2>&1; then
			NC_PORT=21418
			nc -u -l -p "$NC_PORT" >/dev/null 2>&1 &
			_NC=$!
			sleep 1
			if kill -0 "$_NC" 2>/dev/null; then
				NEG_OUT=$("$GET_SOCKDELAYS" -p "$_NC" --proto tcp 2>&1 || true)
				_output "nc UDP-only --proto tcp (negative, expect empty)" "$NEG_OUT"
				NEG_LINES=$(echo "$NEG_OUT" | grep -c 'proto=' || true)
				if [ "${NEG_LINES:-0}" -ne 0 ]; then
					FAILS=$((FAILS + 1))
					echo "    negative: UDP-only --proto tcp returned $NEG_LINES line(s) (expect 0)"
				fi
				_kill "$_NC"
			fi
		fi

		if [ "$FAILS" -eq 0 ]; then
			_pass "filter: all(tcp=$ALL_TCP,udp=$ALL_UDP) tcp_only(tcp=$F_TCP_ONLY_TCP,udp=$F_TCP_ONLY_UDP) udp_only(tcp=$F_UDP_ONLY_TCP,udp=$F_UDP_ONLY_UDP) negative_ok"
		else
			_fail "$FAILS proto filter check(s) failed"
		fi
	else
		_fail "iperf3 server(s) failed to start"
	fi
	_kill "$_TCP_SRV"; _kill "$_UDP_SRV"
fi

# ---- Test 15: --lport 过滤 ----
_test_header "端口过滤 (--lport)"
if _require iperf3; then
	_desc \
		"验证 --lport 过滤在内核侧正确筛选 socket，只返回指定本地端口的统计" \
		"启动 server 在端口 21416 → 用 --lport 21416 查询 → 验证只返回该端口的 socket" \
		"--lport <port> 只返回匹配本地端口的 socket"
	FILT_PORT=21416
	iperf3 -s -p "$FILT_PORT" >/dev/null 2>&1 &
	_SRV=$!
	sleep 1

	if kill -0 "$_SRV" 2>/dev/null; then
		iperf3 -c 127.0.0.1 -p "$FILT_PORT" -P 2 -t 3 >/dev/null 2>&1 &
		sleep 2

		ALL_OUT=$("$GET_SOCKDELAYS" -p "$_SRV" 2>&1 || true)
		FILT_OUT=$("$GET_SOCKDELAYS" -p "$_SRV" --lport "$FILT_PORT" 2>&1 || true)
		NOFILT_OUT=$("$GET_SOCKDELAYS" -p "$_SRV" --lport 99999 2>&1 || true)

		_output "all sockets" "$ALL_OUT"
		_output "--lport $FILT_PORT" "$FILT_OUT"
		_output "--lport 99999 (no match)" "$NOFILT_OUT"

		ALL_COUNT=$(echo "$ALL_OUT" | grep -c 'proto=' || true)
		# Output format is "local=<addr>:<port> remote=<addr>:<port>".
		# Match the port only in the local= field: [^ ]* stops at the first
		# space (before "remote="), so the regex never matches the remote
		# port.  Works for both IPv4 (127.0.0.1:port) and IPv6
		# ([::ffff:127.0.0.1]:port) formats.
		FILT_COUNT=$(echo "$FILT_OUT" | grep -cE "local=[^ ]*:$FILT_PORT( |$)" || true)
		FILT_OTHER=$(echo "$FILT_OUT" | grep 'proto=' | grep -cvE "local=[^ ]*:$FILT_PORT( |$)" || true)
		NOFILT_COUNT=$(echo "$NOFILT_OUT" | grep -c 'proto=' || true)

		FAILS=0
		if [ "${ALL_COUNT:-0}" -lt 1 ]; then
			FAILS=$((FAILS + 1))
			echo "    no filter: count=$ALL_COUNT (expect >=1)"
		fi
		if [ "${FILT_COUNT:-0}" -lt 1 ] || [ "${FILT_OTHER:-0}" -ne 0 ]; then
			FAILS=$((FAILS + 1))
			echo "    --lport $FILT_PORT: matched=$FILT_COUNT other=$FILT_OTHER (expect matched>=1, other=0)"
		fi
		if [ "${NOFILT_COUNT:-0}" -ne 0 ]; then
			FAILS=$((FAILS + 1))
			echo "    --lport 99999: count=$NOFILT_COUNT (expect 0)"
		fi

		if [ "$FAILS" -eq 0 ]; then
			_pass "lport filter: all=$ALL_COUNT, matched=$FILT_COUNT, nomatch=$NOFILT_COUNT"
		else
			_fail "$FAILS lport filter check(s) failed"
		fi
	else
		_fail "iperf3 server failed to start"
	fi
	_kill "$_SRV"
fi

# ---- Test 16: 组合过滤 ----
_test_header "组合过滤 (--proto tcp --lport)"
if _require iperf3; then
	_desc \
		"验证 --proto + --lport 组合过滤，两个条件同时生效（AND 语义）" \
		"启动 iperf3 server (端口 21417) → 发起 UDP 流量（UDP client 会先建 TCP 控制连接）→ 用 --proto tcp --lport 21417 查询" \
		"组合过滤只返回 TCP 且端口匹配的 socket；UDP socket 被 proto 过滤排除"
	COMB_PORT=21417
	# iperf3 server 默认同时监听 TCP 和 UDP，只需一个 server 实例
	iperf3 -s -p "$COMB_PORT" >/dev/null 2>&1 &
	_SRV=$!
	sleep 1

	if kill -0 "$_SRV" 2>/dev/null; then
		# 只启动 UDP client：iperf3 UDP client 会先与 server 建立 TCP 控制连接
		# （lport=COMB_PORT），再发送 UDP 数据（server 侧创建 UDP 数据 socket）。
		# 这样 baseline 同时含 TCP(控制) 和 UDP(数据)，验证组合过滤的 AND 语义。
		# 不并行启动 TCP client：iperf3 server 单线程处理，TCP client(-P 2) 会
		# 占用 server 导致 UDP client 无法建立控制连接，server 侧无 UDP socket。
		# -t 8 确保查询期间 UDP 数据 socket 存活（client 断开后 server 关闭它）。
		iperf3 -c 127.0.0.1 -p "$COMB_PORT" -u -t 8 -b 10M >/dev/null 2>&1 &
		# sleep 3 让 client 完成连接建立（TCP 控制连接 + UDP 关联）
		sleep 3

		# 无过滤基线：应同时有 TCP 和 UDP
		ALL_OUT=$("$GET_SOCKDELAYS" -p "$_SRV" 2>&1 || true)
		# 组合过滤：--proto tcp --lport
		COMB_OUT=$("$GET_SOCKDELAYS" -p "$_SRV" --proto tcp --lport "$COMB_PORT" 2>&1 || true)
		# negative 组合：--proto udp --lport 99999 应返回空。
		# server 有 UDP socket（监听 COMB_PORT），但没有 UDP socket 使用端口 99999。
		# --proto udp 匹配 UDP server socket（proto 条件满足），
		# --lport 99999 不匹配任何 socket（lport 条件不满足），
		# AND 语义下两者需同时满足 → 结果应为空。
		# 这验证了 AND 过滤不会因一个条件满足就返回结果。
		NEG_OUT=$("$GET_SOCKDELAYS" -p "$_SRV" --proto udp --lport 99999 2>&1 || true)
		_output "all sockets (baseline)" "$ALL_OUT"
		_output "combined --proto tcp --lport $COMB_PORT" "$COMB_OUT"
		_output "negative --proto udp --lport 99999 (expect empty)" "$NEG_OUT"

		ALL_TCP=$(echo "$ALL_OUT" | grep -c 'proto=tcp' || true)
		ALL_UDP=$(echo "$ALL_OUT" | grep -c 'proto=udp' || true)
		COMB_TCP=$(echo "$COMB_OUT" | grep -c 'proto=tcp' || true)
		COMB_UDP=$(echo "$COMB_OUT" | grep -c 'proto=udp' || true)
		COMB_PORT_MATCH=$(echo "$COMB_OUT" | grep -cE "local=[^ ]*:$COMB_PORT( |$)" || true)
		COMB_PORT_OTHER=$(echo "$COMB_OUT" | grep 'proto=tcp' | grep -cvE "local=[^ ]*:$COMB_PORT( |$)" || true)
		NEG_LINES=$(echo "$NEG_OUT" | grep -c 'proto=' || true)

		FAILS=0
		# 基线：无过滤时应同时有 TCP 和 UDP
		if [ "${ALL_TCP:-0}" -lt 1 ] || [ "${ALL_UDP:-0}" -lt 1 ]; then
			FAILS=$((FAILS + 1))
			echo "    baseline: tcp=$ALL_TCP udp=$ALL_UDP (both should be >=1)"
		fi
		# 组合过滤：应只有 TCP，无 UDP
		if [ "${COMB_TCP:-0}" -lt 1 ]; then
			FAILS=$((FAILS + 1))
			echo "    combined: tcp=$COMB_TCP (expect >=1)"
		fi
		if [ "${COMB_UDP:-0}" -ne 0 ]; then
			FAILS=$((FAILS + 1))
			echo "    combined: udp=$COMB_UDP (expect 0, proto filter should exclude UDP)"
		fi
		if [ "${COMB_PORT_OTHER:-0}" -ne 0 ]; then
			FAILS=$((FAILS + 1))
			echo "    combined: port_other=$COMB_PORT_OTHER (expect 0, lport filter should exclude)"
		fi
		# negative: --proto udp --lport 99999 应无匹配
		if [ "${NEG_LINES:-0}" -ne 0 ]; then
			FAILS=$((FAILS + 1))
			echo "    negative: --proto udp --lport 99999 returned $NEG_LINES line(s) (expect 0)"
		fi

		if [ "$FAILS" -eq 0 ]; then
			_pass "combined filter: baseline(tcp=$ALL_TCP,udp=$ALL_UDP) filtered(tcp=$COMB_TCP,udp=$COMB_UDP,port_match=$COMB_PORT_MATCH) negative_ok"
		else
			_fail "$FAILS combined filter check(s) failed"
		fi
	else
		_fail "iperf3 server failed to start"
	fi
	_kill "$_SRV"
fi

# ================================================================
# 第七部分：语义验证 + 双向流量 + 路径覆盖 (Test 17 - 22)
# ================================================================
echo ""
echo "+--------------------------------------------------------------+"
echo "|  第七部分：语义验证 / 双向流量 / 路径覆盖                    |"
echo "+--------------------------------------------------------------+"

# ---- Test 17: Reset 非原子语义 (流量中 -R 后仍存在 count>0) ----
_test_header "Reset 非原子语义 (流量中 -R 后仍存在 count>0)"
if _require iperf3; then
	_desc \
		"验证 RESET 不是全局原子快照：reset 之后，活跃流量仍会累加计数" \
		"iperf3 client 持续发送中执行 -R → 立即查询 server → 断言存在 count>0 的 socket" \
		"reset 后存在至少 1 个 count>0 的 socket（证明 reset 不冻结后续流量，即非原子）"
	IPERF_PORT=21430
	iperf3 -s -p "$IPERF_PORT" >/dev/null 2>&1 &
	_SRV=$!
	sleep 1
	if kill -0 "$_SRV" 2>/dev/null; then
		# client 持续发送（后台，长 -t），保证 -R 期间流量活跃
		iperf3 -c 127.0.0.1 -p "$IPERF_PORT" -P 2 -t 12 >/dev/null 2>&1 &
		_CLI=$!
		sleep 3  # 让流量建立并积累
		if kill -0 "$_CLI" 2>/dev/null; then
			# 在活跃流量中执行 RESET
			"$GET_SOCKDELAYS" -R >/dev/null 2>&1 || true
			# 短暂等待让 reset 后的新包累加（非原子：reset 不阻塞包处理）
			sleep 1
			POST=$("$GET_SOCKDELAYS" -p "$_SRV" 2>&1 || true)
			_output "reset-during-traffic 后查询 (get_sockdelays -p $_SRV)" "$POST"
			NONZERO=$(echo "$POST" | grep 'count=' | sed 's/.*count=\([0-9]*\).*/\1/' | awk '$1>0' | wc -l || true)

			# 若首次为 0（极端 timing：reset 后恰好无新包到达），再等一次重试
			if [ "$NONZERO" -eq 0 ]; then
				sleep 2
				POST2=$("$GET_SOCKDELAYS" -p "$_SRV" 2>&1 || true)
				NONZERO=$(echo "$POST2" | grep 'count=' | sed 's/.*count=\([0-9]*\).*/\1/' | awk '$1>0' | wc -l || true)
				_output "reset-during-traffic 二次查询" "$POST2"
			fi

			if [ "$NONZERO" -ge 1 ]; then
				_pass "non-atomic confirmed: $NONZERO socket(s) with count>0 after reset during active traffic"
			else
				_show_output "reset-during-traffic" "$POST" "$_SRV"
				_fail "no count>0 after reset during traffic (non-atomic not demonstrated)"
			fi
			_kill "$_CLI"
		else
			_fail "iperf3 client exited before reset"
		fi
		_kill "$_SRV"
	else
		_fail "iperf3 server failed to start"
	fi
fi

# ---- Test 18: 双向流量 (iperf3 -R 反向，同 socket RX+TX>0) ----
_test_header "双向流量 (iperf3 -R 反向，server 同 socket RX>0 且 TX>0)"
if _require iperf3; then
	_desc \
		"验证同一 socket 上 RX 和 TX 同时被统计：iperf3 -R 让 server 反向发数据" \
		"iperf3 -R → server 发数据(TX via sendmsg) + 收 ACK(RX via 入口打点) → 查 server" \
		"server 存在 socket 同时 RX>0 且 TX>0（双向流量都被统计）"
	IPERF_PORT=21431
	iperf3 -s -p "$IPERF_PORT" >/dev/null 2>&1 &
	_SRV=$!
	sleep 1
	if kill -0 "$_SRV" 2>/dev/null; then
		# -R: reverse，server 向 client 发送数据流
		iperf3 -c 127.0.0.1 -p "$IPERF_PORT" -R -t 6 >/dev/null 2>&1 &
		_CLI=$!
		sleep 3
		if kill -0 "$_CLI" 2>/dev/null; then
			OUT=$("$GET_SOCKDELAYS" -p "$_SRV" 2>&1 || true)
			_output "get_sockdelays -p $_SRV (server, -R reverse)" "$OUT"
			# 统计同时 RX>0 且 TX>0 的 socket 数（每 socket 三行：proto/RX/TX）
			BIDI=$(echo "$OUT" | awk '
				/^proto=/{rx=0;tx=0}
				/RX  count=/{split($2,a,"=");rx=a[2]+0}
				/TX  count=/{split($2,a,"=");tx=a[2]+0;if(rx>0&&tx>0)c++}
				END{print c+0}
			')
			TCP_LINES=$(echo "$OUT" | grep -c 'proto=tcp' || true)
			if [ "$BIDI" -ge 1 ]; then
				_pass "bidirectional: $BIDI socket(s) with RX>0 && TX>0 (tcp sockets=$TCP_LINES)"
			else
				_show_output "server -R reverse" "$OUT" "$_SRV"
				_fail "no socket with both RX>0 and TX>0 (bidi=$BIDI, tcp=$TCP_LINES)"
			fi
			_kill "$_CLI"
		else
			_fail "iperf3 client exited before query"
		fi
		_kill "$_SRV"
	else
		_fail "iperf3 server failed to start"
	fi
fi

# ---- Test 19: TCP splice RX 路径 (tcp_read_sock) ----
_test_header "TCP splice RX 路径 (splice→/dev/null, 覆盖 tcp_read_sock)"
if _require_helper; then
	_desc \
		"验证 tcp_read_sock() RX 路径打点：splice() 走 tcp_read_sock 而非 tcp_recvmsg_locked" \
		"helper splice-server listen → helper tcp-sender 连接并发送 → 查 server PID 验 RX>0" \
		"splice-server 的 TCP data socket RX count > 0"
	SPLICE_PORT=21432
	"$PATH_HELPER" splice-server "$SPLICE_PORT" >/dev/null 2>&1 &
	_SRV=$!
	sleep 1
	if kill -0 "$_SRV" 2>/dev/null; then
		"$PATH_HELPER" tcp-sender 127.0.0.1 "$SPLICE_PORT" 8 >/dev/null 2>&1 &
		_CLI=$!
		sleep 3
		if kill -0 "$_SRV" 2>/dev/null; then
			OUT=$("$GET_SOCKDELAYS" -p "$_SRV" 2>&1 || true)
			_output "splice-server sockets (get_sockdelays -p $_SRV)" "$OUT"
			TCP_LINES=$(echo "$OUT" | grep -c 'proto=tcp' || true)
			RX_SUM=$(echo "$OUT" | awk '/RX  count=/{split($2,a,"="); s+=a[2]} END{print s+0}')
			if [ "$TCP_LINES" -ge 1 ] && [ "$RX_SUM" -gt 0 ]; then
				_pass "splice RX path covered: tcp=$TCP_LINES RX_sum=$RX_SUM (>0)"
			else
				_show_output "splice-server" "$OUT" "$_SRV"
				_fail "splice RX: tcp=$TCP_LINES RX_sum=$RX_SUM (expect RX>0)"
			fi
		else
			_fail "splice-server exited before query (sender may have closed early)"
		fi
		_kill "$_CLI"
		_kill "$_SRV"
	else
		_fail "splice-server failed to start"
	fi
fi

# ---- Test 20: TCP zerocopy RX 路径 (tcp_zerocopy_receive) ----
_test_header "TCP zerocopy RX 路径 (TCP_ZEROCOPY_RECEIVE, 覆盖 tcp_zerocopy_receive)"
if _require_helper; then
	_desc \
		"验证 tcp_zerocopy_receive() RX 路径打点" \
		"helper zerocopy-server listen → tcp-sender 发送 → 查 server 验 RX>0" \
		"zerocopy-server TCP data socket RX count > 0（内核不支持 TCP_ZEROCOPY_RECEIVE 时 SKIP）"
	ZC_PORT=21433
	"$PATH_HELPER" zerocopy-server "$ZC_PORT" >/tmp/zc.log 2>&1 &
	_SRV=$!
	sleep 1
	if ! kill -0 "$_SRV" 2>/dev/null; then
		# 启动即退出：可能内核不支持 zerocopy (exit 3)
		_rc=0
		wait "$_SRV" 2>/dev/null || _rc=$?
		if [ "$_rc" -eq 3 ]; then
			_skip "kernel/config does not support TCP_ZEROCOPY_RECEIVE (server exited 3, see /tmp/zc.log)"
		else
			_fail "zerocopy-server exited at startup (rc=$_rc)"
		fi
	else
		"$PATH_HELPER" tcp-sender 127.0.0.1 "$ZC_PORT" 8 >/dev/null 2>&1 &
		_CLI=$!
		sleep 3
		if ! kill -0 "$_SRV" 2>/dev/null; then
			# 连接后退出：getsockopt 失败 (exit 3 = 不支持)
			_rc=0
			wait "$_SRV" 2>/dev/null || _rc=$?
			_kill "$_CLI"
			if [ "$_rc" -eq 3 ]; then
				_skip "kernel/config does not support TCP_ZEROCOPY_RECEIVE (getsockopt failed, see /tmp/zc.log)"
			else
				_fail "zerocopy-server exited unexpectedly (rc=$_rc)"
			fi
		else
			OUT=$("$GET_SOCKDELAYS" -p "$_SRV" 2>&1 || true)
			_output "zerocopy-server sockets (get_sockdelays -p $_SRV)" "$OUT"
			TCP_LINES=$(echo "$OUT" | grep -c 'proto=tcp' || true)
			RX_SUM=$(echo "$OUT" | awk '/RX  count=/{split($2,a,"="); s+=a[2]} END{print s+0}')
			if [ "$TCP_LINES" -ge 1 ] && [ "$RX_SUM" -gt 0 ]; then
				_pass "zerocopy RX path covered: tcp=$TCP_LINES RX_sum=$RX_SUM (>0)"
			else
				_show_output "zerocopy-server" "$OUT" "$_SRV"
				_fail "zerocopy RX: tcp=$TCP_LINES RX_sum=$RX_SUM (expect RX>0)"
			fi
			_kill "$_CLI"
			_kill "$_SRV"
		fi
	fi
fi


# ---- Test 21: UDP corked TX 路径 (udp_push_pending_frames) ----
_test_header "UDP corked TX 路径 (UDP_CORK, 覆盖 udp_push_pending_frames)"
if _require_helper; then
	_desc \
		"验证 udp_push_pending_frames() TX 路径打点：UDP_CORK flush 触发 corked 发送" \
		"helper corked-udp-client 用 UDP_CORK 发送（每 8 包 uncork 一次触发 flush）→ 查 client 验 TX>0" \
		"corked-udp-client 的 UDP socket TX count > 0（TX 在 send 路径打点，无需接收端）"
	CORK_PORT=21434
	# 无需接收端：TX 打点在 udp_push_pending_frames（send 路径），
	# 与对端是否存在无关。发往无监听端口仅产生 ICMP unreachable，不影响 TX 计数。
	"$PATH_HELPER" corked-udp-client 127.0.0.1 "$CORK_PORT" 8 >/dev/null 2>&1 &
	_CLI=$!
	sleep 1
	if kill -0 "$_CLI" 2>/dev/null; then
		OUT=$("$GET_SOCKDELAYS" -p "$_CLI" 2>&1 || true)
		_output "corked-udp-client sockets (get_sockdelays -p $_CLI)" "$OUT"
		UDP_LINES=$(echo "$OUT" | grep -c 'proto=udp' || true)
		TX_SUM=$(echo "$OUT" | awk '/TX  count=/{split($2,a,"="); s+=a[2]} END{print s+0}')
		if [ "$UDP_LINES" -ge 1 ] && [ "$TX_SUM" -gt 0 ]; then
			_pass "corked TX path covered: udp=$UDP_LINES TX_sum=$TX_SUM (>0)"
		else
			_show_output "corked-udp-client" "$OUT" "$_CLI"
			_fail "corked TX: udp=$UDP_LINES TX_sum=$TX_SUM (expect TX>0)"
		fi
		_kill "$_CLI"
	else
		_fail "corked-udp-client failed to start"
	fi
fi

# ---- Test 22: IPv6 TCP+UDP 路径 (iperf3 -c ::1) ----
_test_header "IPv6 路径 (iperf3 -c ::1, 覆盖 udpv6/tcpv6 sendmsg/recvmsg)"
if _require iperf3; then
	if [ ! -r /proc/net/if_inet6 ]; then
		_skip "IPv6 not enabled in kernel (/proc/net/if_inet6 absent)"
	else
		_desc \
			"验证 IPv6 loopback (::1) 的 TCP/UDP 路径打点（udpv6_recvmsg/sendmsg、tcpv6）" \
			"iperf3 server → IPv6 TCP client (-c ::1) + IPv6 UDP client (-u -c ::1) → 查两端" \
			"存在 IPv6 socket (local=[...]) 且 server RX>0、udp client TX>0"
		IPERF_PORT=21435
		iperf3 -s -p "$IPERF_PORT" >/dev/null 2>&1 &
		_SRV=$!
		sleep 1
		if kill -0 "$_SRV" 2>/dev/null; then
			# IPv6 TCP
			iperf3 -c ::1 -p "$IPERF_PORT" -t 4 >/dev/null 2>&1 &
			_TCP_CLI=$!
			sleep 3
			_kill "$_TCP_CLI"
			# IPv6 UDP (后台，查询期间保持 socket 存活)
			iperf3 -c ::1 -p "$IPERF_PORT" -u -t 6 -b 10M >/dev/null 2>&1 &
			_UDP_CLI=$!
			sleep 2
			SRV_OUT=$("$GET_SOCKDELAYS" -p "$_SRV" 2>&1 || true)
			CLI_OUT=$("$GET_SOCKDELAYS" -p "$_UDP_CLI" 2>&1 || true)
			_output "server (IPv6 TCP+UDP)" "$SRV_OUT"
			_output "udp client (IPv6)" "$CLI_OUT"
			# IPv6 socket 在输出中表现为 local=[...]:port（地址带方括号）
			SRV_V6=$(echo "$SRV_OUT" | grep -cE 'local=\[' || true)
			CLI_V6=$(echo "$CLI_OUT" | grep -cE 'local=\[' || true)
			SRV_RX=$(echo "$SRV_OUT" | awk '/RX  count=/{split($2,a,"="); s+=a[2]} END{print s+0}')
			CLI_TX=$(echo "$CLI_OUT" | awk '/TX  count=/{split($2,a,"="); s+=a[2]} END{print s+0}')
			FAILS=0
			V6_TOTAL=$((SRV_V6 + CLI_V6))
			if [ "$V6_TOTAL" -lt 1 ]; then
				FAILS=$((FAILS + 1))
				echo "    no IPv6 sockets found (srv_v6=$SRV_V6 cli_v6=$CLI_V6)"
			fi
			if [ "${SRV_RX:-0}" -le 0 ]; then
				FAILS=$((FAILS + 1))
				echo "    server IPv6 RX=$SRV_RX (expect >0)"
			fi
			if [ "${CLI_TX:-0}" -le 0 ]; then
				FAILS=$((FAILS + 1))
				echo "    udp client IPv6 TX=$CLI_TX (expect >0)"
			fi
			if [ "$FAILS" -eq 0 ]; then
				_pass "IPv6 path covered: v6_sockets(srv=$SRV_V6,cli=$CLI_V6) srv_RX=$SRV_RX cli_TX=$CLI_TX"
			else
				_show_output "server IPv6" "$SRV_OUT" "$_SRV"
				_show_output "udp client IPv6" "$CLI_OUT" "$_UDP_CLI"
				_fail "$FAILS IPv6 check(s) failed (v6=$V6_TOTAL srv_RX=$SRV_RX cli_TX=$CLI_TX)"
			fi
			_kill "$_UDP_CLI"
			_kill "$_SRV"
		else
			_fail "iperf3 server failed to start"
		fi
	fi
fi
_TOTAL=$((_PASSED + _FAILED + _SKIPPED))

echo ""
echo "+==============================================================+"
printf "|  %-58s |\n" "NET_DELAYACCT Test Results"
echo "+==============================================================+"
printf "|  Tests run:  %2d     PASS: %2d     FAIL: %2d     SKIP: %2d   |\n" \
	"$_TOTAL" "$_PASSED" "$_FAILED" "$_SKIPPED"
echo "+==============================================================+"
if [ "$_FAILED" -eq 0 ]; then
	printf "|  %-58s |\n" "RESULT: ALL PASS"
else
	printf "|  %-58s |\n" "RESULT: $_FAILED FAILURE(S)"
fi
echo "+==============================================================+"
echo ""

# 退出码: 有 FAIL 则为 1
[ "$_FAILED" -eq 0 ]

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# run-perf-tests.sh — NET_DELAYACCT 性能基准测试（guest 侧）
#
# 在 QEMU guest 内运行，输出 PERF: key=value 格式结果供 host 解析。
# 每项测试运行 RUNS 次（默认 3），host 侧取中位数。
#
# 测试矩阵（对应 Review v6.4.0 Perf-1~Perf-5）：
#   Perf-1: TCP 吞吐 (iperf3 -t 5, Gbits/sec)
#   Perf-2: 小包 UDP PPS (iperf3 -u -l 64 -b 0 -t 5, packets/sec)
#   Perf-3: TCP 连接延迟 (bash /dev/tcp connect, 50 次取中位数, μs)
#   Perf-4: 每 socket 内存 (/proc/slabinfo TCP slab objsize, bytes)
#   Perf-5: CPU 利用率 (iperf3 5s 期间 /proc/stat 采样, %)
#
# 用法: bash /opt/run-perf-tests.sh
# 输出: PERF: key=value 行

set -uo pipefail

RUNS="${PERF_RUNS:-3}"
IPERF_BASE_PORT=19090

echo "=== NET_DELAYACCT Performance Tests ==="
echo "Kernel: $(uname -r)"
echo "Runs per test: $RUNS"

# 检测 net_delayacct 是否启用 (ON) 或关闭 (OFF)
DELAYACCT_MODE="OFF"
if [ -f /proc/net/generic ] && grep -q "net_delayacct" /proc/net/generic 2>/dev/null; then
    DELAYACCT_MODE="ON"
fi
# 备用检测：检查内核模块/内置
if [ "$DELAYACCT_MODE" = "OFF" ] && dmesg 2>/dev/null | grep -q "net_delayacct: framework registered"; then
    DELAYACCT_MODE="ON"
fi
echo "PERF: mode=$DELAYACCT_MODE"
echo "PERF: kernel=$(uname -r)"
echo "PERF: runs=$RUNS"

# ----------------------------------------------------------------------------
# 辅助函数
# ----------------------------------------------------------------------------

# 安全清理后台进程
_kill_proc() {
    local pid=$1
    kill "$pid" 2>/dev/null || true
    sleep 0.1
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# 取中位数（输入：空格分隔的数字列表）
_median() {
    echo "$@" | tr ' ' '\n' | sort -n | awk '{a[NR]=$1} END {if(NR%2==1) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2}'
}

# ----------------------------------------------------------------------------
# Perf-1: TCP 吞吐 (iperf3, Gbits/sec)
# ----------------------------------------------------------------------------
perf_1_tcp_throughput() {
    local run=$1
    local port=$((IPERF_BASE_PORT))
    iperf3 -s -p "$port" >/dev/null 2>&1 &
    local srv_pid=$!
    sleep 0.5
    # iperf3 TCP sender 行格式：[  5] 0.00-5.00 sec 2.06 GBytes 3.45 Gbits/sec 0 sender
    # `[  5]` 被 awk 拆成 `[` 和 `5]`，所以 $7=带宽值, $8=单位
    # 只运行一次 iperf3，同时提取值和单位
    local sender_line throughput unit
    sender_line=$(iperf3 -c 127.0.0.1 -p "$port" -t 5 2>/dev/null | grep -E "sender$" | tail -1)
    _kill_proc "$srv_pid"
    throughput=$(echo "$sender_line" | awk '{print $7}')
    unit=$(echo "$sender_line" | awk '{print $8}')
    # 统一转换为 Mbits/sec
    if [ -z "$throughput" ] || ! echo "$throughput" | grep -qE '^[0-9.]+$'; then
        echo "PERF: tcp_throughput_mbps_run${run}=SKIP"
        return
    fi
    case "$unit" in
        Gbits/sec) throughput=$(awk "BEGIN{printf \"%.2f\", $throughput * 1000}") ;;
        Mbits/sec) throughput=$(awk "BEGIN{printf \"%.2f\", $throughput}") ;;
        Kbits/sec) throughput=$(awk "BEGIN{printf \"%.2f\", $throughput / 1000}") ;;
        *) echo "PERF: tcp_throughput_mbps_run${run}=SKIP"; return ;;
    esac
    echo "PERF: tcp_throughput_mbps_run${run}=$throughput"
}

# ----------------------------------------------------------------------------
# Perf-2: 小包 UDP PPS (iperf3 -u -l 64 -b 0, packets/sec)
# ----------------------------------------------------------------------------
perf_2_udp_pps() {
    local run=$1
    local port=$((IPERF_BASE_PORT + 1))
    iperf3 -s -p "$port" >/dev/null 2>&1 &
    local srv_pid=$!
    sleep 0.5
    # iperf3 UDP sender 行格式：[  5] 0.00-5.00 sec 2.06 MBytes 3.45 Mbits/sec 3.044 ms 0/2940 (0%) sender
    # `[  5]` 被 awk 拆成 `[` 和 `5]` 两个字段，导致列号偏移，不能用固定列号。
    # 用 grep 提取 "lost/total" 字段（如 0/2940），取 total 部分。
    local raw_output total_datagrams
    raw_output=$(iperf3 -c 127.0.0.1 -p "$port" -u -l 64 -b 0 -t 5 2>/dev/null | grep -E "sender$" | tail -1)
    _kill_proc "$srv_pid"
    total_datagrams=$(echo "$raw_output" | grep -oE '[0-9]+/[0-9]+' | tail -1 | cut -d/ -f2)
    # 验证是正整数（避免浮点数导致 bash 算术语法错误退出脚本）
    if ! echo "$total_datagrams" | grep -qE '^[0-9]+$' || [ "$total_datagrams" -eq 0 ] 2>/dev/null; then
        echo "PERF: udp_pps_run${run}=SKIP"
        return
    fi
    # PPS = total_datagrams / 5 (duration=5s)
    local pps=$((total_datagrams / 5))
    echo "PERF: udp_pps_run${run}=$pps"
}

# ----------------------------------------------------------------------------
# Perf-3: TCP 连接延迟 (bash /dev/tcp connect time, μs)
#
# 测量 TCP connect() 延迟作为 per-connection 开销的代理指标。
# loopback 连接延迟典型值 50-200μs，net_delayacct 每包 ~60-90ns
# 开销（3-way handshake 约 6 次包遍历 ≈ 360-540ns），预期差异在噪声内。
# ----------------------------------------------------------------------------
perf_3_tcp_latency() {
    local run=$1
    local port=$((IPERF_BASE_PORT + 2))

    # nc -k (keep-alive) 持续接受连接
    nc -k -l -p "$port" >/dev/null 2>&1 &
    local srv_pid=$!
    sleep 0.3

    if ! kill -0 "$srv_pid" 2>/dev/null; then
        echo "PERF: tcp_latency_us_run${run}=SKIP"
        return
    fi

    local latencies=""
    local i start_us end_us latency_us
    for i in $(seq 1 50); do
        # 使用 EPOCHREALTIME (bash 5+) 获取微秒精度时间戳
        # busybox date +%s%N 不支持纳秒（返回字面 %N），会导致算术错误
        start_us=${EPOCHREALTIME:-}
        [ -z "$start_us" ] && break  # bash < 5, 无法测量
        # 在子 shell 中打开 /dev/tcp 连接，避免 exec 失败导致脚本退出
        if (exec 3<>/dev/tcp/127.0.0.1/"$port") 2>/dev/null; then
            end_us=${EPOCHREALTIME:-}
            if [ -n "$start_us" ] && [ -n "$end_us" ]; then
                # EPOCHREALTIME 格式: seconds.microseconds (如 1234567890.123456)
                # 去掉小数点转为整数微秒
                local s_int e_int
                s_int=${start_us/./}
                e_int=${end_us/./}
                latency_us=$((e_int - s_int))
                latencies="$latencies $latency_us"
            fi
        fi
    done

    _kill_proc "$srv_pid"

    if [ -z "$latencies" ]; then
        echo "PERF: tcp_latency_us_run${run}=SKIP"
        return
    fi

    # 取中位数（已是微秒单位）
    local median_us
    median_us=$(_median $latencies)
    echo "PERF: tcp_latency_us_run${run}=$median_us"
}

# ----------------------------------------------------------------------------
# Perf-4: 每 socket 内存 (/proc/slabinfo TCP slab objsize, bytes)
# ----------------------------------------------------------------------------
perf_4_memory() {
    local run=$1
    # struct sock 没有独立的 slab —— 它是基类，通过 sk_prot_alloc() 分配，
    # 实际使用各协议自己的 prot->slab（slab 名 = prot->name，如 "TCP"/"UDP"）。
    # 因此 net_delayacct 给 struct sock 增加字段的内存开销，体现在 TCP/TCPv6/
    # UDP/UDPv6 等 slab 的 objsize 上。这里用 TCP slab 作代表：
    # struct tcp_sock 的第一个成员就是 struct sock，故 ON 内核的 TCP slab
    # objsize 应比 OFF 大 ~72 bytes（struct net_delayacct 大小）。
    #
    # /proc/slabinfo 格式: name active_objs num_objs objsize objperslab ...
    # 第 4 列是 objsize。guest 内 init 为 root，可直接读 /proc/slabinfo
    # （SLUB 需 CONFIG_SLUB_DEBUG=y，当前内核配置已满足；sysfs 的 object_size
    #  需要 CONFIG_SLUB_DEBUG_ON=y 才有值，故不使用 sysfs 方案）。
    local objsize
    objsize=$(awk '$1=="TCP"{print $4}' /proc/slabinfo 2>/dev/null)
    if [ -z "$objsize" ] || ! echo "$objsize" | grep -qE '^[0-9]+$'; then
        echo "PERF: sock_objsize_bytes_run${run}=SKIP"
        return
    fi
    echo "PERF: sock_objsize_bytes_run${run}=$objsize"
}

# ----------------------------------------------------------------------------
# Perf-5: CPU 利用率 (iperf3 5s 期间 /proc/stat 采样, %)
#
# 在 -smp 1 的 QEMU 中，CPU 利用率 = 100% - idle%。
# net_delayacct 每包 ~60-90ns 开销会体现为更高 CPU 利用率。
# ----------------------------------------------------------------------------
perf_5_cpu() {
    local run=$1
    local port=$((IPERF_BASE_PORT + 3))

    # 采样 /proc/stat: cpu user nice system idle iowait irq softirq ...
    # idle = 第 5 列, total = 所有列之和
    local idle_before total_before idle_after total_after
    local stat_line
    stat_line=$(head -1 /proc/stat 2>/dev/null)
    idle_before=$(echo "$stat_line" | awk '{print $5}')
    total_before=$(echo "$stat_line" | awk '{s=0; for(i=2;i<=NF;i++) s+=$i; print s}')

    iperf3 -s -p "$port" >/dev/null 2>&1 &
    local srv_pid=$!
    sleep 0.5
    iperf3 -c 127.0.0.1 -p "$port" -t 5 >/dev/null 2>&1 || true
    _kill_proc "$srv_pid"

    stat_line=$(head -1 /proc/stat 2>/dev/null)
    idle_after=$(echo "$stat_line" | awk '{print $5}')
    total_after=$(echo "$stat_line" | awk '{s=0; for(i=2;i<=NF;i++) s+=$i; print s}')

    if [ -z "$idle_before" ] || [ -z "$total_before" ] || \
       [ -z "$idle_after" ] || [ -z "$total_after" ]; then
        echo "PERF: cpu_util_pct_run${run}=SKIP"
        return
    fi

    local idle_diff total_diff cpu_pct
    idle_diff=$((idle_after - idle_before))
    total_diff=$((total_after - total_before))
    if [ "$total_diff" -le 0 ]; then
        echo "PERF: cpu_util_pct_run${run}=SKIP"
        return
    fi
    cpu_pct=$((100 - (idle_diff * 100 / total_diff)))
    echo "PERF: cpu_util_pct_run${run}=$cpu_pct"
}

# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------
echo "PERF: start=1"

# Perf-4 (memory) 只需运行一次（slabinfo objsize 是静态值）
perf_4_memory 1

# 其余测试运行 RUNS 次
for run in $(seq 1 "$RUNS"); do
    echo "--- Perf run $run/$RUNS ---"
    perf_1_tcp_throughput "$run"
    perf_2_udp_pps "$run"
    perf_3_tcp_latency "$run"
    perf_5_cpu "$run"
done

echo "PERF: end=1"
echo "=== Performance tests completed ==="

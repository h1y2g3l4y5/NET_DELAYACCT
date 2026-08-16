#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# run-perf-tests.sh — NET_DELAYACCT 性能基准测试（guest 侧）
#
# 支持 K0/K2/K3 三种模式：
#   K0: OFF 内核（CONFIG_NET_DELAYACCT=n）
#   K2: ON 内核，检测开启，无查询（纯插桩开销）
#   K3: ON 内核，检测开启 + 主动查询（导出开销）
#
# 测试矩阵：
#   Perf-1: TCP 吞吐 (iperf3, Mbps)
#   Perf-2: 小包 UDP PPS (iperf3 -u -l 64, packets/sec)
#   Perf-3: TCP 连接延迟 (bash /dev/tcp, P50/P95/P99/P99.9/max, μs)
#   Perf-4: 每 socket 内存 (/proc/slabinfo, bytes)
#   Perf-5: CPU 利用率 (iperf3 期间 /proc/stat, %)
#   Perf-6: Idle CPU (无流量时 CPU, %)
#   Perf-7: cycles/packet (perf stat, cycles) — 条件性
#   Perf-8: 固定负载延迟 (给定速率下 P99, μs) — 条件性
#
# 环境变量:
#   PERF_RUNS (默认 3): 每项测试运行次数
#   TEST_DURATION (默认 10): iperf3 测试时长（秒）
#   WARMUP_DURATION (默认 3): iperf3 --omit 预热时长（秒）
#   QUERY_MODE (默认 K2): K2=不查询, K3=测试时主动查询
#   ENABLE_CYCLES (默认 0): 是否采集 cycles/packet
#   FIXED_LOAD_RATES (可选): 固定负载速率列表（Mbps），空格分隔
#
# 用法: bash /opt/run-perf-tests.sh
# 输出: PERF: key=value 行

set -uo pipefail

RUNS="${PERF_RUNS:-3}"
TEST_DURATION="${TEST_DURATION:-10}"
WARMUP_DURATION="${WARMUP_DURATION:-3}"
QUERY_MODE="${QUERY_MODE:-K2}"
ENABLE_CYCLES="${ENABLE_CYCLES:-0}"
FIXED_LOAD_RATES="${FIXED_LOAD_RATES:-}"
IPERF_BASE_PORT=19090

echo "=== NET_DELAYACCT Performance Tests ==="
echo "Kernel: $(uname -r)"
echo "Runs per test: $RUNS"
echo "Test duration: ${TEST_DURATION}s (warmup: ${WARMUP_DURATION}s)"
echo "Query mode: $QUERY_MODE"

# 检测 net_delayacct 是否启用 (ON) 或关闭 (OFF)
DELAYACCT_MODE="OFF"
if [ -f /proc/net/generic ] && grep -q "net_delayacct" /proc/net/generic 2>/dev/null; then
    DELAYACCT_MODE="ON"
fi
if [ "$DELAYACCT_MODE" = "OFF" ] && dmesg 2>/dev/null | grep -q "net_delayacct: framework registered"; then
    DELAYACCT_MODE="ON"
fi
echo "PERF: mode=$DELAYACCT_MODE"
echo "PERF: query_mode=$QUERY_MODE"
echo "PERF: kernel=$(uname -r)"
echo "PERF: runs=$RUNS"
echo "PERF: test_duration=$TEST_DURATION"

# ----------------------------------------------------------------------------
# 辅助函数
# ----------------------------------------------------------------------------

_kill_proc() {
    local pid=$1
    kill "$pid" 2>/dev/null || true
    sleep 0.1
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# 取中位数
_median() {
    echo "$@" | tr ' ' '\n' | sort -n | awk '{a[NR]=$1} END {if(NR==0){print ""; exit} if(NR%2==1) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2}'
}

# 取百分位：输出 "P50 P95 P99 P99.9 max"
_percentiles() {
    echo "$1" | tr ' ' '\n' | sort -n | awk '
    {a[NR]=$1}
    END {
        n=NR
        if(n==0){print "SKIP SKIP SKIP SKIP SKIP"; exit}
        # 使用最近排名法 (nearest rank)
        p50=a[int((n*50+99)/100)]
        if(p50=="")p50=a[n]
        p95=a[int((n*95+99)/100)]
        if(p95=="")p95=a[n]
        p99=a[int((n*99+99)/100)]
        if(p99=="")p99=a[n]
        p999=a[int((n*999+999)/1000)]
        if(p999=="")p999=a[n]
        max=a[n]
        printf "%d %d %d %d %d", p50, p95, p99, p999, max
    }'
}

# iperf3 带可选 --omit 预热
_iperf3_client() {
    local port=$1
    shift
    if [ "$WARMUP_DURATION" -gt 0 ] 2>/dev/null; then
        iperf3 -c 127.0.0.1 -p "$port" -t "$TEST_DURATION" --omit "$WARMUP_DURATION" "$@" 2>/dev/null
    else
        iperf3 -c 127.0.0.1 -p "$port" -t "$TEST_DURATION" "$@" 2>/dev/null
    fi
}

# ----------------------------------------------------------------------------
# K3 模式：启动后台查询（模拟导出开销）
# ----------------------------------------------------------------------------
K3_BG_PID=""
if [ "$QUERY_MODE" = "K3" ] && [ "$DELAYACCT_MODE" = "ON" ]; then
    if command -v get_sockdelays >/dev/null 2>&1; then
        echo "K3 mode: starting background queries (get_sockdelays)..."
        (
            while true; do
                get_sockdelays -p 1 >/dev/null 2>&1 || true
                sleep 0.05
            done
        ) &
        K3_BG_PID=$!
        echo "  background query PID: $K3_BG_PID"
    else
        echo "WARNING: K3 mode requested but get_sockdelays not found, falling back to K2 behavior"
    fi
fi

# ----------------------------------------------------------------------------
# Perf-1: TCP 吞吐 (iperf3, Mbps)
# ----------------------------------------------------------------------------
perf_1_tcp_throughput() {
    local run=$1
    local port=$((IPERF_BASE_PORT))
    iperf3 -s -p "$port" >/dev/null 2>&1 &
    local srv_pid=$!
    sleep 0.5
    local sender_line throughput unit
    sender_line=$(_iperf3_client "$port" | grep -E "sender$" | tail -1)
    _kill_proc "$srv_pid"
    throughput=$(echo "$sender_line" | awk '{print $7}')
    unit=$(echo "$sender_line" | awk '{print $8}')
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
#
# 20260816 设计审查 B8：PPS 用 sender 口径 = CPU 饱和发送能力（受 hook
# 开销影响的被测量）；receiver 行的 Lost/Total 提取丢包率独立输出
# （-b 0 饱和灌包下 loopback 实测丢 24-29%，比例波动大会污染 PPS，
# 故 receiver 口径不用于 PPS）。丢包率仅 info 展示，不参与 verdict。
# ----------------------------------------------------------------------------
perf_2_udp_pps() {
    local run=$1
    local port=$((IPERF_BASE_PORT + 1))
    iperf3 -s -p "$port" >/dev/null 2>&1 &
    local srv_pid=$!
    sleep 0.5
    local raw_output sender_line recv_line total_datagrams recv_pair lost_cnt lost_pct pps
    raw_output=$(_iperf3_client "$port" -u -l 64 -b 0)
    _kill_proc "$srv_pid"
    sender_line=$(printf '%s\n' "$raw_output" | grep -E "sender$" | tail -1)
    recv_line=$(printf '%s\n' "$raw_output" | grep -E "receiver$" | tail -1)

    total_datagrams=$(printf '%s\n' "$sender_line" | grep -oE '[0-9]+/[0-9]+' | tail -1 | cut -d/ -f2)
    if ! echo "$total_datagrams" | grep -qE '^[0-9]+$' || [ "$total_datagrams" -eq 0 ] 2>/dev/null; then
        echo "PERF: udp_pps_run${run}=SKIP"
        echo "PERF: udp_loss_pct_run${run}=SKIP"
        return
    fi

    recv_pair=$(printf '%s\n' "$recv_line" | grep -oE '[0-9]+/[0-9]+' | tail -1)
    # PPS 用 sender 口径（CPU 饱和发送能力，受 hook 开销影响，是有效被测量）；
    # receiver 口径会混入丢包比例的波动（-b 0 饱和灌包下 loopback 实测丢 24-29%，
    # 比例本身噪声大，会污染 PPS），丢包率独立输出 info 展示
    pps=$((total_datagrams / TEST_DURATION))
    echo "PERF: udp_pps_run${run}=$pps"
    if echo "$recv_pair" | grep -qE '^[0-9]+/[0-9]+$'; then
        lost_cnt=${recv_pair%%/*}
        local recv_total=${recv_pair##*/}
        if [ "$recv_total" -gt 0 ] 2>/dev/null; then
            echo "PERF: udp_loss_pct_run${run}=$(awk -v l="$lost_cnt" -v t="$recv_total" 'BEGIN {printf "%.3f", l * 100 / t}')"
            return
        fi
    fi
    echo "PERF: udp_loss_pct_run${run}=SKIP"
}

# ----------------------------------------------------------------------------
# Perf-3: TCP 连接延迟 (bash /dev/tcp, P50/P95/P99/P99.9/max, μs)
#
# 测量 TCP connect() 延迟。使用 200 次采样（间隔 5ms，无 fork），
# 输出百分位分布用于检测尾延迟变化。设计变更见函数内注释（20260816 审查）。
# ----------------------------------------------------------------------------
perf_3_tcp_latency() {
    local run=$1
    local port=$((IPERF_BASE_PORT + 2))

    # SYN 溢出调优：100 连接零间隔连发 + nc -k 串行 accept 会导致半连接队列
    # 溢出丢 SYN，客户端按初始 RTO=1s 重传 → p999/max 出现 ~1s 离群点
    # （20260816_015227 实测 K3 2/3 轮中招，中位数被污染）。
    # syncookies: SYN 队列溢出时不丢包，直接回 SYNACK
    # somaxconn:  加大 accept 队列深度，吸收串行 accept 的瞬时积压
    echo 1 > /proc/sys/net/ipv4/tcp_syncookies 2>/dev/null
    echo 1024 > /proc/sys/net/core/somaxconn 2>/dev/null
    # 读回验证（诊断 initramfs 下 /proc/sys 是否可写；20260816_135316 一轮
    # 调优后 p999 仍全 1s，需确认写入是否生效）
    echo "PERF: sysctl_check syncookies=$(cat /proc/sys/net/ipv4/tcp_syncookies 2>/dev/null || echo NA) somaxconn=$(cat /proc/sys/net/core/somaxconn 2>/dev/null || echo NA)"

    nc -k -l -p "$port" >/dev/null 2>&1 &
    local srv_pid=$!
    sleep 0.3

    if ! kill -0 "$srv_pid" 2>/dev/null; then
        echo "PERF: tcp_latency_p50_run${run}=SKIP"
        echo "PERF: tcp_latency_p95_run${run}=SKIP"
        echo "PERF: tcp_latency_p99_run${run}=SKIP"
        echo "PERF: tcp_latency_p999_run${run}=SKIP"
        echo "PERF: tcp_latency_max_run${run}=SKIP"
        return
    fi

    local latencies=""
    local raw_samples
    local i start_us end_us latency_us
    # 样本设计（20260816 设计审查 B1/B2/B7 重做）：
    # - n=200：n=100 时 p99 与 p999/max 过近（剔除后 n=97 甚至退化 p99==max），
    #   n=200 保证 p99=index 198 独立于尾部单样本
    # - 连接间隔 5ms：给 busybox nc -k（串行 accept, listen backlog=1）时间清空
    #   accept 队列。零间隔连发时 connect() 大部分耗时在等 accept 排队（毫秒级），
    #   被测的 delayacct hook（~7us/connect，ftrace 实测）完全被淹没——此前
    #   p95/p99/p999 实测的是 QEMU 调度而非内核 connect 路径
    # - 无 fork 采样：此前 `(exec 3<>/dev/tcp/...)` 每样本 fork 子 shell
    #   （QEMU 内 ~0.5-1.5ms），占 p50 一半以上。改为主 shell `exec 3<>` 直接
    #   打开/关闭 FD，计时窗口内零 fork
    # - 整个循环放命令替换 subshell 中隔离：exec FD 重定向失败会退出非交互
    #   shell，隔离后最坏只丢本轮（走 SKIP 防护），主脚本安全
    # - SYN 重传伪影剔除（保留）：>100ms（KVM 正常 p999 10-20ms，超此值只能是
    #   RTO=1s 重传）计 retrans 不进样本；busybox nc listen(3,1) backlog=1，
    #   accept 队列积压 2 个即溢出丢 SYN（strace 实锤），syncookies/somaxconn
    #   无法干预（listen backlog=min(1,1024)=1）
    # - 输出协议：有效样本每行一个延迟 μs；被剔除样本输出 "R"
    local NUM_SAMPLES=200
    raw_samples=$(
        for w in 1 2 3; do
            # 预热（丢弃）：nc 首次 accept / socket slab 分配 / 冷启动重传
            if exec 3<>/dev/tcp/127.0.0.1/"$port" 2>/dev/null; then
                exec 3<&- 2>/dev/null || true
            fi
            sleep 0.005
        done
        for i in $(seq 1 "$NUM_SAMPLES"); do
            start_us=${EPOCHREALTIME:-}
            [ -z "$start_us" ] && exit 0
            if exec 3<>/dev/tcp/127.0.0.1/"$port" 2>/dev/null; then
                end_us=${EPOCHREALTIME:-}
                exec 3<&- 2>/dev/null || true
                if [ -n "$end_us" ]; then
                    latency_us=$(( ${end_us/./} - ${start_us/./} ))
                    if [ "$latency_us" -gt 100000 ]; then
                        echo R
                    else
                        echo "$latency_us"
                    fi
                fi
            else
                # connect 失败（nc 死亡/队列异常）按剔除处理，触发下方防护
                echo R
            fi
            sleep 0.005
        done
    )
    local retrans_cnt
    retrans_cnt=$(printf '%s\n' "$raw_samples" | grep -cx 'R' || true)
    latencies=$(printf '%s\n' "$raw_samples" | grep -vx 'R' | tr '\n' ' ')

    _kill_proc "$srv_pid"

    # 最小有效样本数防护（review v6.5.2 问题 2.1.1）：>100ms 剔除阈值锚定 KVM
    # 模式（正常 p999 仅 10-20ms），TCG 回退路径下正常延迟可能整体 >100ms 被
    # 全量误剔除 → 空/少样本 percentile 失真甚至假 PASS。剔除过半时该轮按
    # no-data 处理（host 端走 SKIP 三态路径，与 CI INVALID>50% 阻塞线对齐）。
    local valid_cnt=$((NUM_SAMPLES - retrans_cnt))
    if [ -z "$latencies" ] || [ "$valid_cnt" -lt $((NUM_SAMPLES / 2)) ]; then
        echo "PERF: tcp_latency_p50_run${run}=SKIP"
        echo "PERF: tcp_latency_p95_run${run}=SKIP"
        echo "PERF: tcp_latency_p99_run${run}=SKIP"
        echo "PERF: tcp_latency_p999_run${run}=SKIP"
        echo "PERF: tcp_latency_max_run${run}=SKIP"
        echo "PERF: tcp_latency_INVALID_run${run}=1 (valid ${valid_cnt}/${NUM_SAMPLES}, retrans ${retrans_cnt} — 疑非 KVM 环境或极端调度噪声)"
        return
    fi

    # 计算百分位
    local pct_result
    pct_result=$(_percentiles "$latencies")
    local p50 p95 p99 p999 max_val
    p50=$(echo "$pct_result" | awk '{print $1}')
    p95=$(echo "$pct_result" | awk '{print $2}')
    p99=$(echo "$pct_result" | awk '{print $3}')
    p999=$(echo "$pct_result" | awk '{print $4}')
    max_val=$(echo "$pct_result" | awk '{print $5}')

    echo "PERF: tcp_latency_p50_run${run}=$p50"
    echo "PERF: tcp_latency_p95_run${run}=$p95"
    echo "PERF: tcp_latency_p99_run${run}=$p99"
    echo "PERF: tcp_latency_p999_run${run}=$p999"
    echo "PERF: tcp_latency_max_run${run}=$max_val"
    # SYN 重传剔除计数（健康指标：剔除过多说明该轮数据受调度噪声影响大）
    echo "PERF: tcp_latency_retrans_run${run}=$retrans_cnt"
    # top3 最大样本（诊断剔除后剩余长尾形态）
    echo "PERF: tcp_latency_top3_run${run}=$(echo $latencies | tr ' ' '\n' | sort -n | tail -3 | tr '\n' ' ')"
}

# ----------------------------------------------------------------------------
# Perf-4: 每 socket 内存 (/proc/slabinfo TCP slab objsize, bytes)
# ----------------------------------------------------------------------------
perf_4_memory() {
    local run=$1
    local objsize
    objsize=$(awk '$1=="TCP"{print $4}' /proc/slabinfo 2>/dev/null)
    if [ -z "$objsize" ] || ! echo "$objsize" | grep -qE '^[0-9]+$'; then
        echo "PERF: sock_objsize_bytes_run${run}=SKIP"
        return
    fi
    echo "PERF: sock_objsize_bytes_run${run}=$objsize"
}

# ----------------------------------------------------------------------------
# Perf-5: CPU 利用率 (iperf3 -J JSON: host_percent + 归一化 CPU/Gbps)
#
# 20260816 设计审查 B3/B4 重做：此前用 /proc/stat 手工差分测"iperf 期间整机
# busy%"，存在两个混杂——(1) 采样窗口含 0.5s server 启动等待（idle 稀释 ~5%）；
# (2) busy% 正比于吞吐，跨模式吞吐不同时 CPU 不可比（K3 吞吐 -11% 时 busy% 假性
# -10.7%，与 idle -6pp 方向矛盾）。改用 iperf3 JSON：
#   - end.cpu_utilization.host_percent：iperf3 以自身流量起止为窗口的 busy%，
#     窗口精确对齐，消除 (1)
#   - cpu_per_gbps = host_percent / (bps/1e9)：单位吞吐的 CPU 代价，消除 (2)；
#     host 端 verdict 改判此指标，cpu_util_pct 降为 info
# ----------------------------------------------------------------------------
perf_5_cpu() {
    local run=$1
    local port=$((IPERF_BASE_PORT + 3))

    iperf3 -s -p "$port" >/dev/null 2>&1 &
    local srv_pid=$!
    sleep 0.5
    local json_out cpu_pct bps
    json_out=$(_iperf3_client "$port" -J 2>/dev/null) || json_out=""
    _kill_proc "$srv_pid"

    # JSON 字段提取（busybox 无 jq，用 awk；iperf3 -J 为 tab 缩进的 JSON，
    # 字段值清理须含 [[:space:]]（tab），否则值带前导 tab 触发 SKIP 校验失败）
    # CPU 字段双版本兼容：3.9+ 为 cpu_utilization_percent.host_total，
    # 旧版（3.1-3.7）为 cpu_utilization.host_percent（本地 iperf3 3.9 实测确认）
    cpu_pct=$(printf '%s\n' "$json_out" | awk -F': *' '
        /"cpu_utilization_percent"/ {blk="new"; next}
        /"cpu_utilization"[[:space:]]*:/ {blk="old"; next}
        blk=="new" && /"host_total"/ {gsub(/[[:space:]",]/,"",$2); print $2; exit}
        blk=="old" && /"host_percent"/ {gsub(/[[:space:]",]/,"",$2); print $2; exit}')
    bps=$(printf '%s\n' "$json_out" | awk -F': *' '
        /"sum_sent"/ {insum=1}
        insum && /"bits_per_second"/ {gsub(/[[:space:]",]/,"",$2); print $2; exit}')

    if [ -z "$cpu_pct" ] || [ -z "$bps" ] || ! echo "$cpu_pct$bps" | grep -qE '^[0-9.]+$'; then
        echo "PERF: cpu_util_pct_run${run}=SKIP"
        echo "PERF: cpu_per_gbps_run${run}=SKIP"
        return
    fi

    echo "PERF: cpu_util_pct_run${run}=$cpu_pct"
    # 归一化 CPU 代价：%/Gbps（1 位小数；bps→Gbps 除 1e9）
    echo "PERF: cpu_per_gbps_run${run}=$(awk -v c="$cpu_pct" -v b="$bps" 'BEGIN {if (b > 0) printf "%.2f", c / (b / 1e9); else print "SKIP"}')"
}

# ----------------------------------------------------------------------------
# Perf-6: Idle CPU (无流量时 CPU 利用率, %)
#
# 测量系统空闲时的 CPU 利用率。若 net_delayacct 使用 static key 门控，
# K2 idle 应与 K0 idle 一致（零开销）。此测试验证"不用时零开销"承诺。
# ----------------------------------------------------------------------------
perf_6_idle_cpu() {
    local run=$1

    local idle_before total_before idle_after total_after
    local stat_line
    stat_line=$(head -1 /proc/stat 2>/dev/null)
    idle_before=$(echo "$stat_line" | awk '{print $5}')
    total_before=$(echo "$stat_line" | awk '{s=0; for(i=2;i<=NF;i++) s+=$i; print s}')

    # 空闲等待 5 秒（无流量）
    sleep 5

    stat_line=$(head -1 /proc/stat 2>/dev/null)
    idle_after=$(echo "$stat_line" | awk '{print $5}')
    total_after=$(echo "$stat_line" | awk '{s=0; for(i=2;i<=NF;i++) s+=$i; print s}')

    if [ -z "$idle_before" ] || [ -z "$total_before" ] || \
       [ -z "$idle_after" ] || [ -z "$total_after" ]; then
        echo "PERF: idle_cpu_pct_run${run}=SKIP"
        return
    fi

    local idle_diff total_diff cpu_pct
    idle_diff=$((idle_after - idle_before))
    total_diff=$((total_after - total_before))
    if [ "$total_diff" -le 0 ]; then
        echo "PERF: idle_cpu_pct_run${run}=SKIP"
        return
    fi
    # Idle CPU = idle 占比（无流量时应该接近 100%）
    cpu_pct=$((idle_diff * 100 / total_diff))
    echo "PERF: idle_cpu_pct_run${run}=$cpu_pct"
}

# ----------------------------------------------------------------------------
# Perf-7: cycles/packet (perf stat, cycles) — 条件性
#
# 使用 perf stat 采集 iperf3 期间的 CPU cycles，除以总包数得到每包开销。
# 需要 perf 可用且 /proc/sys/kernel/perf_event_paranoid <= 2。
# ----------------------------------------------------------------------------
perf_7_cycles_per_packet() {
    local run=$1
    local port=$((IPERF_BASE_PORT + 4))

    # 检查 perf 是否可用
    if ! command -v perf >/dev/null 2>&1; then
        echo "PERF: cycles_per_packet_run${run}=SKIP"
        return
    fi

    # 检查 perf_event_paranoid
    local paranoid
    paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "4")
    if [ "$paranoid" -gt 2 ] 2>/dev/null; then
        echo "PERF: cycles_per_packet_run${run}=SKIP"
        return
    fi

    iperf3 -s -p "$port" >/dev/null 2>&1 &
    local srv_pid=$!
    sleep 0.5

    local perf_out
    perf_out=$(mktemp 2>/dev/null || echo "/tmp/perf_${run}.out")

    # 用 perf stat 包裹 iperf3，采集 cycles
    set +e
    perf stat -e cycles -o "$perf_out" \
        iperf3 -c 127.0.0.1 -p "$port" -t "$TEST_DURATION" \
        ${WARMUP_DURATION:+--omit "$WARMUP_DURATION"} >/dev/null 2>&1
    set -e

    _kill_proc "$srv_pid"

    # 提取 cycles（perf stat 输出格式：<count> cycles）
    local cycles
    cycles=$(awk '/^[[:space:]]*[0-9]+.*cycles/ {gsub(/,/,""); print $1; exit}' "$perf_out" 2>/dev/null)
    rm -f "$perf_out" 2>/dev/null

    # 提取 iperf3 总传输字节数来估算包数
    # TCP: 假设 MTU=1500, MSS=1460, packets = bytes / MSS
    # 这里用 iperf3 的 throughput × duration / MSS 来估算
    # 更精确的方法：从 iperf3 -J JSON 输出提取 retransmits 和总包数
    # 但在最小化 guest 中，用简化估算
    if [ -z "$cycles" ] || ! echo "$cycles" | grep -qE '^[0-9]+$'; then
        echo "PERF: cycles_per_packet_run${run}=SKIP"
        return
    fi

    # 重新运行 iperf3 获取传输字节数（perf 运行已结束）
    iperf3 -s -p "$port" >/dev/null 2>&1 &
    srv_pid=$!
    sleep 0.5
    local iperf_out bytes_str
    iperf_out=$(_iperf3_client "$port" 2>/dev/null | grep -E "sender$" | tail -1)
    _kill_proc "$srv_pid"

    # 提取传输字节数（格式如 "2.06 GBytes" 或 "500 MBytes"）
    local bytes_val bytes_unit bytes_total
    bytes_val=$(echo "$iperf_out" | awk '{print $5}')
    bytes_unit=$(echo "$iperf_out" | awk '{print $6}')
    if [ -z "$bytes_val" ] || ! echo "$bytes_val" | grep -qE '^[0-9.]+$'; then
        echo "PERF: cycles_per_packet_run${run}=SKIP"
        return
    fi

    case "$bytes_unit" in
        GBytes) bytes_total=$(awk "BEGIN{printf \"%d\", $bytes_val * 1000000000}") ;;
        MBytes) bytes_total=$(awk "BEGIN{printf \"%d\", $bytes_val * 1000000}") ;;
        KBytes) bytes_total=$(awk "BEGIN{printf \"%d\", $bytes_val * 1000}") ;;
        *) echo "PERF: cycles_per_packet_run${run}=SKIP"; return ;;
    esac

    # 估算包数 = bytes / 1460 (TCP MSS)
    local packets
    packets=$((bytes_total / 1460))
    if [ "$packets" -le 0 ]; then
        echo "PERF: cycles_per_packet_run${run}=SKIP"
        return
    fi

    local cpp=$((cycles / packets))
    echo "PERF: cycles_per_packet_run${run}=$cpp"
}

# ----------------------------------------------------------------------------
# Perf-8: 固定负载延迟 (给定速率下 P99, μs) — 条件性
#
# 在 iperf3 以固定速率运行时，同时测量 TCP connect() 延迟。
# 用于检测不同负载水平下的尾延迟变化。
# 需要 FIXED_LOAD_RATES 环境变量（空格分隔的 Mbps 速率列表）。
# ----------------------------------------------------------------------------
perf_8_fixed_load_latency() {
    local run=$1

    if [ -z "$FIXED_LOAD_RATES" ]; then
        return
    fi

    local rate
    for rate in $FIXED_LOAD_RATES; do
        # 将速率转换为安全标签（如 300 → 300mbps）
        local rate_label
        rate_label=$(echo "$rate" | awk '{printf "%d", $1}')

        local bg_port=$((IPERF_BASE_PORT + 10))
        local lat_port=$((IPERF_BASE_PORT + 11))

        # 启动 iperf3 server 和 client（后台流量）
        iperf3 -s -p "$bg_port" >/dev/null 2>&1 &
        local bg_srv_pid=$!
        sleep 0.3

        # 启动后台 iperf3 client 以固定速率运行
        _iperf3_client "$bg_port" -b "$rate" >/dev/null 2>&1 &
        local bg_cli_pid=$!

        # 等待流量稳定
        sleep 1

        # 启动 nc server 测量 connect 延迟
        nc -k -l -p "$lat_port" >/dev/null 2>&1 &
        local lat_srv_pid=$!
        sleep 0.3

        # 测量 50 次 connect 延迟
        local latencies=""
        local i start_us end_us latency_us
        for i in $(seq 1 50); do
            start_us=${EPOCHREALTIME:-}
            [ -z "$start_us" ] && break
            if (exec 3<>/dev/tcp/127.0.0.1/"$lat_port") 2>/dev/null; then
                end_us=${EPOCHREALTIME:-}
                if [ -n "$start_us" ] && [ -n "$end_us" ]; then
                    local s_int e_int
                    s_int=${start_us/./}
                    e_int=${end_us/./}
                    latency_us=$((e_int - s_int))
                    latencies="$latencies $latency_us"
                fi
            fi
        done

        # 清理
        _kill_proc "$lat_srv_pid"
        _kill_proc "$bg_cli_pid"
        _kill_proc "$bg_srv_pid"

        if [ -z "$latencies" ]; then
            echo "PERF: fixed_load_${rate_label}mbps_p99_run${run}=SKIP"
            echo "PERF: fixed_load_${rate_label}mbps_p50_run${run}=SKIP"
            continue
        fi

        # 计算 P50 和 P99
        local pct_result p50 p99
        pct_result=$(_percentiles "$latencies")
        p50=$(echo "$pct_result" | awk '{print $1}')
        p99=$(echo "$pct_result" | awk '{print $3}')

        echo "PERF: fixed_load_${rate_label}mbps_p50_run${run}=$p50"
        echo "PERF: fixed_load_${rate_label}mbps_p99_run${run}=$p99"
    done
}

# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------
echo "PERF: start=1"

# Perf-4 (memory) 只需运行一次
perf_4_memory 1

# 其余测试运行 RUNS 次
for run in $(seq 1 "$RUNS"); do
    echo "--- Perf run $run/$RUNS ---"
    perf_1_tcp_throughput "$run"
    perf_2_udp_pps "$run"
    perf_3_tcp_latency "$run"
    perf_5_cpu "$run"
    perf_6_idle_cpu "$run"

    # Perf-7: cycles/packet（条件性）
    if [ "$ENABLE_CYCLES" = "1" ]; then
        perf_7_cycles_per_packet "$run"
    fi

    # Perf-8: 固定负载延迟（条件性）
    perf_8_fixed_load_latency "$run"
done

# 清理 K3 后台查询
if [ -n "$K3_BG_PID" ]; then
    _kill_proc "$K3_BG_PID"
    echo "K3 background queries stopped"
fi

echo "PERF: end=1"
echo "=== Performance tests completed ==="

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# run-perf-tests.sh — NET_DELAYACCT 性能基准测试（guest 侧）
#
# 20260816 方案重建（iperf3 速率驱动 → 固定工作量微基准）：
#
# 旧方案信噪比倒挂（物理分析，详见 ci/qemu/bench-net.c 头注释）：
#   信号 = net_delayacct hook 开销（每包 4 次调用 ~50-150ns），在
#          21.5Gbps 大包吞吐里被 memcpy 稀释到 ~1%，在尾延迟里被
#          vCPU 调度淹没（ftrace 实测 hook 仅占 p99 的 0.06%）
#   噪声 = QEMU 2vCPU 调度 + 共享 runner 漂移：K0 基线轮间 ±3-6%，
#          p99 ±30-90%（K0-vs-K0B 噪声地板两轮实测 53.6%/90.2%）
#   iperf3 固定 10s 时长：工作量不固定，调度扰动直接进结果
#
# 新方案四支柱：
#   Perf-A bench-net：固定循环微基准（UDP64 自发自收 + TCP 1KB rw），
#           绑核 + SCHED_FIFO + QEMU -smp 1，K0/K2 总耗时差 = 插桩
#           开销，分辨率 ~0.1%，hook 信号在 64B 小包路径放大到 5-20%
#   Perf-B ftrace 对账（仅 ON 内核）：hook 调用计数（function tracer，
#           hooks_per_op = trace_count / bench_n）+ 单次 hook 耗时分布
#           （function_graph 叶子 p50/p99），与 Perf-A 交叉验证：
#           Δns/op ≈ hooks_per_op × hook_ns_p50
#   Perf-C slab：TCP slab objsize（确定性，零噪声，保留）
#   Perf-D dump 计时（K3）：get_sockdelays 全量导出 per-call 耗时
#           （含 fork+exec；空 socket 表口径，sock 遍历开销另见
#           功能测试的大数据集用例）
#
# K3 语义变更（相对旧方案）：不再跑"后台查询干扰 iperf3"——-smp 1 下
# SCHED_FIFO 的 bench 会饿死 normal 查询进程，且干扰量 ∝ 环境争抢
# 程度不可迁移到物理机；导出开销改由 Perf-D 直接量化。
#
# 环境变量:
#   PERF_RUNS (默认 5): bench-net 轮数（每轮自动校准 ~1s）
#   QUERY_MODE (默认 K2): K2=纯插桩, K3=附加 dump 计时
#
# 输出: PERF: key=value 行（host 侧 perf-test.sh 消费）

set -uo pipefail

RUNS="${PERF_RUNS:-5}"
QUERY_MODE="${QUERY_MODE:-K2}"

echo "=== NET_DELAYACCT Performance Tests (microbenchmark) ==="
echo "Kernel: $(uname -r)"
echo "Runs: $RUNS  Query mode: $QUERY_MODE"

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

# ----------------------------------------------------------------------------
# Perf-A: bench-net 固定工作量微基准（ns/op，越小越好）
# ----------------------------------------------------------------------------
perf_a_bench() {
    if ! command -v bench-net >/dev/null 2>&1; then
        echo "PERF: bench_udp64_ns_per_op_run1=SKIP"
        echo "PERF: bench_tcprw_ns_per_op_run1=SKIP"
        echo "WARNING: bench-net not found"
        return
    fi

    local out run val
    out=$(bench-net -r="$RUNS" 2>&1) || true
    printf '%s\n' "$out" | grep '^BENCH:' | sed 's/^BENCH: /  bench /'

    # 环境控制状态透传（rt=绑核+实时调度；判定口径一致性依赖 K0/K2 同 env）
    val=$(printf '%s\n' "$out" | grep '^BENCH: env=' | head -1 | sed 's/^BENCH: env=//')
    [ -n "$val" ] && echo "PERF: bench_env=$val"

    # 各轮 ns_per_op 转 PERF 协议（bench-net 第 i 行 → run{i}）
    run=0
    printf '%s\n' "$out" | grep '^BENCH: udp64 ' | grep -oE 'ns_per_op=[0-9.]+' | cut -d= -f2 | \
    while read -r val; do
        run=$((run+1))
        echo "PERF: bench_udp64_ns_per_op_run${run}=$val"
    done
    run=0
    printf '%s\n' "$out" | grep '^BENCH: tcprw ' | grep -oE 'ns_per_op=[0-9.]+' | cut -d= -f2 | \
    while read -r val; do
        run=$((run+1))
        echo "PERF: bench_tcprw_ns_per_op_run${run}=$val"
    done

    # bench-net 失败（error= 行）时补 SKIP 占位，host 侧解析才不会丢指标
    if printf '%s\n' "$out" | grep -q '^BENCH: error='; then
        echo "PERF: bench_error=1"
    fi
}

# ----------------------------------------------------------------------------
# Perf-B: ftrace 对账（仅 ON 内核；信息性，不参与判定）
#
# B1 hook 计数：function tracer 只跟踪 net_delayacct_*，跑固定 N 循环，
#    hooks_per_op = trace 行数 / N。注意 net_delayacct_rx_start 是 inline
#    （头文件一行赋值，-O2 后无独立符号），计数只覆盖 out-of-line 符号
#    （tx_start/tx_end/rx_end），hooks_per_op 是下界。
# B2 单次耗时：function_graph 叶子耗时分布（tracer 自身有开销，此段
#    bench 的 ns/op 不用于判定，只取 hook 自身 duration）。
# ----------------------------------------------------------------------------
perf_b_ftrace() {
    local TDIR=/sys/kernel/tracing
    [ -d "$TDIR" ] || TDIR=/sys/kernel/debug/tracing

    if [ "$DELAYACCT_MODE" != "ON" ]; then
        echo "PERF: ftrace_hooks_per_op_run1=SKIP"
        echo "PERF: ftrace_hook_ns_p50_run1=SKIP"
        return
    fi
    if [ ! -e "$TDIR/current_tracer" ]; then
        mount -t tracefs none /sys/kernel/tracing 2>/dev/null || true
    fi
    if [ ! -w "$TDIR/current_tracer" ]; then
        echo "PERF: ftrace_hooks_per_op_run1=SKIP"
        echo "PERF: ftrace_hook_ns_p50_run1=SKIP"
        return
    fi

    # trace buffer 扩容：2 万循环 × 3-4 符号 × ~90B/行 ≈ 7MB
    echo 8192 > "$TDIR/buffer_size_kb" 2>/dev/null || true
    echo 0 > "$TDIR/tracing_on"

    # ---- B1: hook 调用计数（function tracer）----
    echo > "$TDIR/set_ftrace_filter" 2>/dev/null
    echo 'net_delayacct_*' > "$TDIR/set_ftrace_filter" 2>/dev/null
    local nfun
    nfun=$(grep -c . "$TDIR/set_ftrace_filter" 2>/dev/null || echo 0)
    local BENCH_N=5000
    if [ "${nfun:-0}" -ge 1 ] 2>/dev/null; then
        echo function > "$TDIR/current_tracer" 2>/dev/null
        echo > "$TDIR/trace"
        echo 1 > "$TDIR/tracing_on"
        bench-net -m=udp64 -n="$BENCH_N" -r=1 >/dev/null 2>&1 || true
        echo 0 > "$TDIR/tracing_on"
        local cnt
        cnt=$(grep -c 'net_delayacct' "$TDIR/trace" 2>/dev/null || echo 0)
        echo "PERF: ftrace_hook_funcs=$nfun"
        if [ "$cnt" -gt 0 ] 2>/dev/null; then
            awk -v c="$cnt" -v n="$BENCH_N" \
                'BEGIN {printf "PERF: ftrace_hooks_per_op_run1=%.2f\n", c/n}'
        else
            echo "PERF: ftrace_hooks_per_op_run1=SKIP"
        fi
    else
        echo "PERF: ftrace_hooks_per_op_run1=SKIP"
    fi

    # ---- B2: 单次 hook 耗时（function_graph 叶子 duration）----
    if [ "${nfun:-0}" -ge 1 ] 2>/dev/null; then
        echo > "$TDIR/set_graph_function" 2>/dev/null
        echo 'net_delayacct_*' > "$TDIR/set_graph_function" 2>/dev/null
        echo function_graph > "$TDIR/current_tracer" 2>/dev/null
        echo > "$TDIR/trace"
        echo 1 > "$TDIR/tracing_on"
        bench-net -m=udp64 -n=20000 -r=1 >/dev/null 2>&1 || true
        echo 0 > "$TDIR/tracing_on"
        # 叶子行格式： "   0)   0.440 us    |  net_delayacct_tx_start();"
        printf '%s\n' "$(grep 'net_delayacct' "$TDIR/trace" 2>/dev/null)" | \
        awk '$3 == "us" {print $2 * 1000}' | sort -n | awk '
            {a[NR]=$1}
            END {
                if (NR==0) {print "PERF: ftrace_hook_ns_p50_run1=SKIP"; exit}
                p50=(NR%2==1)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2
                p99=a[int((NR*99+99)/100)]
                printf "PERF: ftrace_hook_ns_p50_run1=%.0f\n", p50
                printf "PERF: ftrace_hook_ns_p99_run1=%.0f\n", p99
                printf "PERF: ftrace_hook_ns_n_run1=%d\n", NR
            }'
    else
        echo "PERF: ftrace_hook_ns_p50_run1=SKIP"
    fi

    # 清理：关 tracer、清 filter，避免残留影响后续测试
    echo nop > "$TDIR/current_tracer" 2>/dev/null
    echo > "$TDIR/set_ftrace_filter" 2>/dev/null
    echo > "$TDIR/set_graph_function" 2>/dev/null
}

# ----------------------------------------------------------------------------
# Perf-C: 每 socket 内存 (/proc/slabinfo TCP slab objsize, bytes)
# /proc/slabinfo 第 4 列 = s->size（含 SLAB_HWCACHE_ALIGN 64B 对齐填充），
# 非 s->object_size；host 侧阈值 192B 以此口径校准
# ----------------------------------------------------------------------------
perf_c_slab() {
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
# Perf-D: dump 导出耗时（K3）：get_sockdelays 全量导出 per-call wall time
# 口径：含 fork+exec+genetlink dump+netlink 解析，空 socket 表。
# 物理意义 = 用户态轮询导出的最小周期成本（不含遍历大量 sock 的代价，
# 后者由功能测试的大数据集用例覆盖）。
# ----------------------------------------------------------------------------
perf_d_dump() {
    if [ "$QUERY_MODE" != "K3" ] || [ "$DELAYACCT_MODE" != "ON" ]; then
        return
    fi
    if ! command -v get_sockdelays >/dev/null 2>&1; then
        echo "PERF: dump_per_call_us_run1=SKIP"
        return
    fi
    # busybox date %N 支持性检测（编译选项依赖，不支持则输出字面 N）
    local t
    t=$(date +%N 2>/dev/null)
    if [ -z "$t" ] || [ "$t" = "N" ]; then
        echo "PERF: dump_per_call_us_run1=SKIP (date %N unsupported)"
        return
    fi
    local t0 t1
    t0=$(date +%s%N)
    local i
    for i in $(seq 1 50); do
        get_sockdelays -p 1 >/dev/null 2>&1 || true
    done
    t1=$(date +%s%N)
    echo "PERF: dump_per_call_us_run1=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", (b-a)/50/1000}')"
}

# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------
echo "PERF: start=1"

perf_c_slab 1
perf_a_bench
perf_b_ftrace
perf_d_dump

echo "PERF: end=1"
echo "=== Performance tests completed ==="

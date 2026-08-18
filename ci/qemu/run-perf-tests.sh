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
# 新方案四支柱（20260817 v2 矩阵化：指标收敛为「每包 CPU 成本」）：
#   Perf-A bench-net：3 维矩阵微基准（路径 udp4/tcp4/udp6/tcp6 × 尺寸
#           64/1400/65000B × 压力 1/16 流 = 24 格），K0/K3 每格总耗时差
#           = 该场景每包 CPU 成本；矩阵扫描成本规律（绝对值随尺寸平稳、
#           相对值 1/尺寸 摊薄）而非单点结论
#   Perf-B ftrace 对账（仅 ON 内核）：
#           B1 hooks/op：function tracer 按 path×size 12 格计数
#              （hooks/op 与流数无关，f1 口径即可），
#              Δns/op ≈ hooks_per_op × hook_ns_p50 逐格对账
#           B2 单次耗时：function_graph 叶子 p50/p99，按 4 路径各测一轮
#   Perf-C slab：TCP slab objsize（确定性，零噪声，单点不进矩阵）
#   Perf-D dump 计时（K3）：get_sockdelays 全量导出 per-call 耗时
#           （含 fork+exec；空 socket 表口径，sock 遍历开销另见
#           功能测试的大数据集用例）
#
# K3 语义：dump 在 bench 之后执行，与纯插桩口径 bench 等价
# （K2 已随 20260817 矩阵简化移除）。
#
# 环境变量:
#   PERF_RUNS (默认 3): 每格 bench 轮数（24 格 × ~1s/轮 × RUNS 控制总时长；
#                       host 侧 K0+K0R 跨 boot 合并中位数，6 样本起）
#   QUERY_MODE (默认 K3): K3=插桩+dump 计时
#
# 输出: PERF: key=value 行（host 侧 perf-test.sh 消费）

set -uo pipefail

RUNS="${PERF_RUNS:-3}"
QUERY_MODE="${QUERY_MODE:-K3}"

# 矩阵定义（与 bench-net.c -m=all 顺序一致）
PATHS="udp4 tcp4 udp6 tcp6"
SIZES="64 1400 65000"
FLOWS_LIST="1 16"

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
# Perf-A: bench-net 矩阵微基准（24 格，每格 RUNS 轮，ns/op 越小越好）
# 每格独立调用 bench-net（独立校准 N），cell 名 = <path>_<size>f<flows>
# ----------------------------------------------------------------------------
perf_a_bench() {
    if ! command -v bench-net >/dev/null 2>&1; then
        local p s
        for p in $PATHS; do
            for s in $SIZES; do
                echo "PERF: bench_${p}_${s}f1_ns_per_op_run1=SKIP"
            done
        done
        echo "WARNING: bench-net not found"
        return
    fi

    local p s f cell out run val bench_err=0

    # 环境控制状态透传（rt=绑核+实时调度；判定口径一致性依赖 K0/K3 同 env）
    out=$(bench-net -m=udp4 -s=64 -f=1 -r=1 -n=2000 2>&1) || true
    val=$(printf '%s\n' "$out" | grep '^BENCH: env=' | head -1 | sed 's/^BENCH: env=//' | cut -d' ' -f1)
    [ -n "$val" ] && echo "PERF: bench_env=$val"

    for f in $FLOWS_LIST; do
        for s in $SIZES; do
            for p in $PATHS; do
                cell="${p}_${s}f${f}"
                out=$(bench-net -m="$p" -s="$s" -f="$f" -r="$RUNS" 2>&1) || true
                printf '%s\n' "$out" | grep '^BENCH:' | sed 's/^BENCH: /  bench /'
                if printf '%s\n' "$out" | grep -q '^BENCH: error='; then
                    bench_err=1
                    echo "PERF: bench_${cell}_ns_per_op_run1=SKIP"
                    continue
                fi
                run=0
                printf '%s\n' "$out" | grep "^BENCH: ${cell} " | \
                    grep -oE 'ns_per_op=[0-9.]+' | cut -d= -f2 | \
                while read -r val; do
                    run=$((run+1))
                    echo "PERF: bench_${cell}_ns_per_op_run${run}=$val"
                done
            done
        done
    done
    [ "$bench_err" = 1 ] && echo "PERF: bench_error=1"
    return 0
}

# ----------------------------------------------------------------------------
# Perf-B: ftrace 对账（仅 ON 内核；信息性，不参与判定）
#
# B1 hooks/op（path×size 12 格，f1 口径）：function tracer 只跟踪
#    net_delayacct_*，跑固定 N 循环，hooks_per_op = trace 行数 / N。
#    注意 net_delayacct_rx_start 是 inline（头文件一行赋值，-O2 后无
#    独立符号），计数只覆盖 out-of-line 符号，hooks_per_op 是下界。
# B2 单次耗时（4 路径）：function_graph 叶子耗时分布（tracer 自身有
#    开销，此段 bench 的 ns/op 不用于判定，只取 hook 自身 duration）。
# ----------------------------------------------------------------------------
perf_b_ftrace() {
    local TDIR=/sys/kernel/tracing
    [ -d "$TDIR" ] || TDIR=/sys/kernel/debug/tracing

    if [ "$DELAYACCT_MODE" != "ON" ]; then
        local p s
        for p in $PATHS; do
            for s in $SIZES; do
                echo "PERF: ftrace_hooks_per_op_${p}_${s}f1_run1=SKIP"
            done
            echo "PERF: ftrace_hook_ns_p50_${p}_run1=SKIP"
        done
        return
    fi
    if [ ! -e "$TDIR/current_tracer" ]; then
        mount -t tracefs none /sys/kernel/tracing 2>/dev/null || true
    fi
    if [ ! -w "$TDIR/current_tracer" ]; then
        local p s
        for p in $PATHS; do
            for s in $SIZES; do
                echo "PERF: ftrace_hooks_per_op_${p}_${s}f1_run1=SKIP"
            done
            echo "PERF: ftrace_hook_ns_p50_${p}_run1=SKIP"
        done
        return
    fi

    # trace buffer 扩容：5000 循环 × ~16 hook × ~90B/行 ≈ 7MB
    echo 8192 > "$TDIR/buffer_size_kb" 2>/dev/null || true
    echo 0 > "$TDIR/tracing_on"

    # ---- B1: hooks/op 计数（function tracer，path×size 12 格）----
    local nfun
    echo > "$TDIR/set_ftrace_filter" 2>/dev/null
    echo 'net_delayacct_*' > "$TDIR/set_ftrace_filter" 2>/dev/null
    nfun=$(grep -c . "$TDIR/set_ftrace_filter" 2>/dev/null || echo 0)
    echo "PERF: ftrace_hook_funcs=$nfun"

    local p s cell BENCH_N=5000 cnt
    for p in $PATHS; do
        for s in $SIZES; do
            cell="${p}_${s}f1"
            if [ "${nfun:-0}" -ge 1 ] 2>/dev/null; then
                echo function > "$TDIR/current_tracer" 2>/dev/null
                echo > "$TDIR/trace"
                echo 1 > "$TDIR/tracing_on"
                bench-net -m="$p" -s="$s" -f=1 -n="$BENCH_N" -r=1 >/dev/null 2>&1 || true
                echo 0 > "$TDIR/tracing_on"
                cnt=$(grep -c 'net_delayacct' "$TDIR/trace" 2>/dev/null || echo 0)
                if [ "$cnt" -gt 0 ] 2>/dev/null; then
                    awk -v c="$cnt" -v n="$BENCH_N" -v cell="$cell" \
                        'BEGIN {printf "PERF: ftrace_hooks_per_op_%s_run1=%.2f\n", cell, c/n}'
                else
                    echo "PERF: ftrace_hooks_per_op_${cell}_run1=SKIP"
                fi
            else
                echo "PERF: ftrace_hooks_per_op_${cell}_run1=SKIP"
            fi
        done
    done

    # ---- B2: 单次 hook 耗时（function_graph 叶子 duration，4 路径）----
    local GR_N=20000
    for p in $PATHS; do
        if [ "${nfun:-0}" -ge 1 ] 2>/dev/null; then
            echo > "$TDIR/set_graph_function" 2>/dev/null
            echo 'net_delayacct_*' > "$TDIR/set_graph_function" 2>/dev/null
            echo function_graph > "$TDIR/current_tracer" 2>/dev/null
            echo > "$TDIR/trace"
            echo 1 > "$TDIR/tracing_on"
            bench-net -m="$p" -s=64 -f=1 -n="$GR_N" -r=1 >/dev/null 2>&1 || true
            echo 0 > "$TDIR/tracing_on"
            # 叶子行格式： "   0)   0.440 us    |  net_delayacct_tx_start();"
            printf '%s\n' "$(grep 'net_delayacct' "$TDIR/trace" 2>/dev/null)" | \
            awk '$3 == "us" {print $2 * 1000}' | sort -n | awk -v p="$p" '
                {a[NR]=$1}
                END {
                    if (NR==0) {printf "PERF: ftrace_hook_ns_p50_%s_run1=SKIP\n", p; exit}
                    p50=(NR%2==1)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2
                    p99=a[int((NR*99+99)/100)]
                    printf "PERF: ftrace_hook_ns_p50_%s_run1=%.0f\n", p, p50
                    printf "PERF: ftrace_hook_ns_p99_%s_run1=%.0f\n", p, p99
                    printf "PERF: ftrace_hook_ns_n_%s_run1=%d\n", p, NR
                }'
        else
            echo "PERF: ftrace_hook_ns_p50_${p}_run1=SKIP"
        fi
    done

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

# 顺序即防御（run#179 实证）：启动初期内核探测日志（PS/2、RT throttling
# 等）仍在向 console 打印，会与早期 PERF: 行串行交错拼接
# （"2240[ 3.872921] input: ..."），数值被污染 → slab/dump 放到
# bench/ftrace 之后（此时 console 已静默 ~15s+）
perf_a_bench
perf_b_ftrace
perf_c_slab 1
perf_d_dump

echo "PERF: end=1"
echo "=== Performance tests completed ==="

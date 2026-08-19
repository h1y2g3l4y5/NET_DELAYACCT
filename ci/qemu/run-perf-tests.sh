#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# run-perf-tests.sh — NET_DELAYACCT 性能基准测试（guest 侧）
#
# 20260819 v3 同 boot A/B（static key 运行时开关）：
#   v2 跨 boot 对比（K0=OFF 内核 vs K3=ON 内核）的不可归因性：
#     - ON/OFF 为不同二进制：struct sock +128B → 对象布局/cache 局部性
#       差异，其性能影响可正可负，与 hook 开销（~百 ns/包）混叠，
#       "ON 比 OFF 快" 的假象即源于此
#     - QEMU 启动间漂移 10%+（vCPU 线程宿主放置随机），高于多数格信号
#   对策：内核补丁新增 net_delayacct.enabled 运行时开关（static key，
#     /sys/module/net_delayacct/parameters/enabled），同一 boot 内交错
#     翻转 OFF/ON 测 24 格矩阵：
#     - 二进制逐字节相同 → 布局差异归零，Δ = 纯 hook 开销
#     - 同 boot 交错差分 → 启动间漂移被消除，残余噪声仅轮间抖动 ~1%
#
#   判定口径（host 侧）：逐格 Δns/op = median(on) − median(off)，
#     Δ% ∈ [-5%, +25%] → PASS（小幅负值为统计涨落；大幅负值物理不可能
#     → INVALID，提示开关未生效/测量异常）
#
# 四支柱（Perf-B/C/D 承袭 v2）：
#   Perf-A bench-net：同 boot AB 交错，PERF_RUNS 对（默认 3），每对
#           OFF/ON 各跑一遍 24 格全矩阵（-m=all -r=1），起始状态逐对
#           交替（时漂对称）；输出 bench_<cell>_ns_per_op_{off,on}_run<k>
#   Perf-B ftrace 对账（ON 态）：B1 hooks/op 12 格（function tracer 计数）
#           + B2 单次耗时（function_graph 叶子 p50/p99，4 路径），
#           Δns/op ≈ hooks/op × hook_ns_p50 逐格对账
#   Perf-C slab：TCP slab objsize（本 boot 单点；OFF 内核 boot 提供基线，
#           编译期确定值，跨 boot 对比零噪声）
#   Perf-D dump 计时（ON 态）：get_sockdelays 全量导出 per-call 耗时
#
# boot 模式（由内核二进制决定，自动检测）：
#   AB : ON 内核 + 运行时开关存在 → 同 boot A/B 全套（bench AB + ftrace
#        + slab + dump）。开关文件缺失（旧 bzImage-on 未含 static key
#        补丁）→ bench 全 SKIP + ab_mode=SKIP，host 侧按 NO-DATA 阻断
#        （防呆：避免旧内核静默跑出无意义数据）
#   OFF: OFF 内核（CONFIG_NET_DELAYACCT=n）→ 仅 slab 基线，其余 SKIP
#
# 环境变量:
#   PERF_RUNS (默认 3): AB 对数（每对 = OFF 块 + ON 块各 24 格）
#
# 输出: PERF: key=value 行（host 侧 perf-test.sh 消费）

set -uo pipefail

RUNS="${PERF_RUNS:-3}"

# 运行时开关（static key 模块参数；ON 内核 built-in，路径固定）
SWITCH="/sys/module/net_delayacct/parameters/enabled"

# 矩阵定义（与 bench-net.c -m=all 顺序一致）
PATHS="udp4 tcp4 udp6 tcp6"
SIZES="64 1400 65000"
FLOWS_LIST="1 16"

echo "=== NET_DELAYACCT Performance Tests (same-boot A/B) ==="
echo "Kernel: $(uname -r)"
echo "AB pairs: $RUNS"

# ----------------------------------------------------------------------------
# boot 模式检测
#   AB  : ON 内核且运行时开关存在（static key 补丁已打）
#   ON* : ON 内核但开关缺失（旧 bzImage）→ 防呆降级
#   OFF : OFF 内核（仅 slab 基线）
# ----------------------------------------------------------------------------
DELAYACCT_MODE="OFF"
if [ -e "$SWITCH" ]; then
    DELAYACCT_MODE="AB"
elif [ -f /proc/net/generic ] && grep -q "net_delayacct" /proc/net/generic 2>/dev/null; then
    DELAYACCT_MODE="ON_NOSWITCH"
fi
if [ "$DELAYACCT_MODE" = "OFF" ] && dmesg 2>/dev/null | grep -q "net_delayacct: framework registered"; then
    DELAYACCT_MODE="ON_NOSWITCH"
fi
echo "PERF: mode=$DELAYACCT_MODE"
echo "PERF: kernel=$(uname -r)"
echo "PERF: runs=$RUNS"

# ----------------------------------------------------------------------------
# 开关翻转 + 读回验证
#   module_param bool 读回为 Y/N（param_get_bool），写入接受 0/1
#   static_branch_enable/disable 由 jump_label 机制保证代码段同步打补丁，
#   读回一致即确认翻转成功
# ----------------------------------------------------------------------------
set_delayacct() {
    local want="$1" got
    echo "$want" > "$SWITCH" 2>/dev/null || return 1
    got=$(cat "$SWITCH" 2>/dev/null | tr -d ' \r\n')
    if [ "$want" = "1" ] && [ "$got" = "Y" ]; then return 0; fi
    if [ "$want" = "0" ] && [ "$got" = "N" ]; then return 0; fi
    return 1
}

# 全矩阵格名列表（SKIP 兜底输出用）
all_cells() {
    local p s f
    for f in $FLOWS_LIST; do
        for s in $SIZES; do
            for p in $PATHS; do
                echo "${p}_${s}f${f}"
            done
        done
    done
}

# ----------------------------------------------------------------------------
# Perf-A: bench-net 同 boot AB 交错矩阵（24 格 × RUNS 对）
#
# 每对 = 两个状态块（各一次 bench-net -m=all -r=1 进程调用，内部 24 格），
# 起始状态逐对交替（对1 OFF→ON，对2 ON→OFF，...）使时漂对两态等权。
# 每格输出：PERF: bench_<cell>_ns_per_op_{off,on}_run<对号>=<ns/op>
# ----------------------------------------------------------------------------
perf_a_bench_ab() {
    if ! command -v bench-net >/dev/null 2>&1; then
        echo "WARNING: bench-net not found"
        local c
        while read -r c; do
            echo "PERF: bench_${c}_ns_per_op_off_run1=SKIP"
            echo "PERF: bench_${c}_ns_per_op_on_run1=SKIP"
        done < <(all_cells)
        return
    fi

    # 环境控制状态透传（rt=绑核+实时调度；OFF/ON 块同 env 保证口径一致）
    local out val
    out=$(bench-net -m=udp4 -s=64 -f=1 -r=1 -n=2000 2>&1) || true
    val=$(printf '%s\n' "$out" | grep '^BENCH: env=' | head -1 | sed 's/^BENCH: env=//' | cut -d' ' -f1)
    [ -n "$val" ] && echo "PERF: bench_env=$val"

    # 开关往返自检（0→1→0→1）：翻转失败则全 SKIP（A/B 无意义）
    if ! set_delayacct 0 || ! set_delayacct 1; then
        echo "PERF: switch_check=fail"
        local c
        while read -r c; do
            echo "PERF: bench_${c}_ns_per_op_off_run1=SKIP"
            echo "PERF: bench_${c}_ns_per_op_on_run1=SKIP"
        done < <(all_cells)
        return
    fi
    echo "PERF: switch_check=ok"
    echo "PERF: ab_pairs=$RUNS"

    local pair st order cell nsval bench_err=0
    for ((pair=1; pair<=RUNS; pair++)); do
        if [ $((pair % 2)) -eq 1 ]; then
            order="off on"
        else
            order="on off"
        fi
        for st in $order; do
            if ! set_delayacct $([ "$st" = "on" ] && echo 1 || echo 0); then
                echo "PERF: switch_error=pair${pair}"
                bench_err=1
                continue
            fi
            echo "--- AB pair ${pair}/${RUNS}: ${st} block ---"
            out=$(bench-net -m=all -r=1 2>&1) || true
            printf '%s\n' "$out" | grep '^BENCH:' | sed 's/^BENCH: /  bench /'
            if printf '%s\n' "$out" | grep -q '^BENCH: error='; then
                bench_err=1
                continue
            fi
            # 解析 24 格：BENCH: <cell> n=<N> ns_per_op=<val> → "<cell> <val>"
            while read -r cell nsval; do
                [ -n "$cell" ] || continue
                echo "PERF: bench_${cell}_ns_per_op_${st}_run${pair}=${nsval}"
            done < <(printf '%s\n' "$out" | \
                grep -oE '^BENCH: [a-z0-9]+_[0-9]+f[0-9]+ n=[0-9]+ ns_per_op=[0-9.]+' | \
                sed -E 's/^BENCH: ([a-z0-9]+) n=[0-9]+ ns_per_op=([0-9.]+)$/\1 \2/')
        done
    done

    # 恢复 ON：后续 ftrace 对账 / dump 计时需要 hook 生效
    set_delayacct 1 || true
    [ "$bench_err" = 1 ] && echo "PERF: bench_error=1"
    return 0
}

# ----------------------------------------------------------------------------
# Perf-B: ftrace 对账（仅 ON 态；信息性，不参与判定）
#
# B1 hooks/op（path×size 12 格，f1 口径）：function tracer 只跟踪
#    net_delayacct_*，跑固定 N 循环，hooks_per_op = trace 行数 / N。
#    注意 net_delayacct_rx_start 是 inline（-O2 后无独立符号），
#    计数只覆盖 out-of-line 符号，hooks_per_op 是下界。
# B2 单次耗时（4 路径）：function_graph 叶子耗时分布（tracer 自身有
#    开销，此段 bench 的 ns/op 不用于判定，只取 hook 自身 duration）。
# ----------------------------------------------------------------------------
perf_b_ftrace() {
    local TDIR=/sys/kernel/tracing
    [ -d "$TDIR" ] || TDIR=/sys/kernel/debug/tracing

    if [ "$DELAYACCT_MODE" != "AB" ]; then
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
# Perf-D: dump 导出耗时（ON 态）：get_sockdelays 全量导出 per-call wall time
# 口径：含 fork+exec+genetlink dump+netlink 解析，空 socket 表。
# 物理意义 = 用户态轮询导出的最小周期成本（不含遍历大量 sock 的代价，
# 后者由功能测试的大数据集用例覆盖）。
# ----------------------------------------------------------------------------
perf_d_dump() {
    if [ "$DELAYACCT_MODE" != "AB" ]; then
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
if [ "$DELAYACCT_MODE" = "AB" ]; then
    perf_a_bench_ab
    perf_b_ftrace
else
    # ON_NOSWITCH：旧 bzImage-on（无 static key 补丁）→ 防呆标记
    if [ "$DELAYACCT_MODE" = "ON_NOSWITCH" ]; then
        echo "PERF: ab_mode=SKIP"
        while read -r _skipcell; do
            echo "PERF: bench_${_skipcell}_ns_per_op_off_run1=SKIP"
            echo "PERF: bench_${_skipcell}_ns_per_op_on_run1=SKIP"
        done < <(all_cells)
    fi
    perf_b_ftrace
fi
perf_c_slab 1
perf_d_dump

echo "PERF: end=1"
echo "=== Performance tests completed ==="

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# perf-test.sh — NET_DELAYACCT 性能基准测试编排脚本（host 侧）
#
# 对比 CONFIG_NET_DELAYACCT=y (ON) vs =n (OFF) 的性能开销：
#   1. 构建 ON 内核 (CONFIG_NET_DELAYACCT=y) → 保存 bzImage-on
#   2. 构建 OFF 内核 (CONFIG_NET_DELAYACCT=n) → 保存 bzImage-off
#   3. 创建 perf initramfs (含 run-perf-tests.sh)
#   4. QEMU 启动 ON 内核 → 收集性能数据
#   5. QEMU 启动 OFF 内核 → 收集性能数据
#   6. 对比并生成报告
#
# 用法: ./perf-test.sh [--skip-build]  # --skip-build 复用已有 bzImage-on/off
#
# 注意: 需写入内核源码树 (../linux-6.6)，须在非沙箱环境运行
# 注意: v6.4.0 性能测试仅本地运行，CI 暂不接入（方案C）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
LINUX_SRC="${LINUX_SRC:-$PROJECT_DIR/../linux-6.6}"
LOG_DIR="$PROJECT_DIR/tests/reports/perf"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 结构化摘要报告文件（Markdown + CSV）
SUMMARY_MD="$LOG_DIR/perf-summary-${TIMESTAMP}.md"
SUMMARY_CSV="$LOG_DIR/perf-summary-${TIMESTAMP}.csv"

QEMU_MEMORY="${QEMU_MEMORY:-1024M}"
QEMU_TIMEOUT_KVM="${QEMU_TIMEOUT_KVM:-300}"
QEMU_TIMEOUT_TCG="${QEMU_TIMEOUT_TCG:-600}"

# --strict 模式控制 FAIL/INVALID 的判定行为（参数解析可覆盖）：
#   warn（默认）：FAIL/INVALID 均为告警（exit 0），不阻断。共享 runner 噪声大，
#     单次 FAIL 可能是噪声非回归；仅 NO-DATA(全SKIP) 或 INVALID>50%(≥3/5) 时 exit 2（数据不可信）
#   fail：FAIL/INVALID 均阻断（exit 1），用于本地严格回归测试
STRICT_MODE="warn"

# 用 $'...' ANSI-C quoting 让变量值为实际转义字符（而非字面 \033），
# 这样 echo（无 -e）与 printf 均能正确输出颜色，日志不再出现 \033[0;31m 字面量
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

mkdir -p "$LOG_DIR"

# perf initramfs 路径
PERF_INITRD="$PROJECT_DIR/ci/qemu/perf-initrd.img"

# 保存的内核镜像（可被 --bzimage-on/off 参数覆盖，CI 用）
BZIMAGE_ON="$LINUX_SRC/arch/x86/boot/bzImage-on"
BZIMAGE_OFF="$LINUX_SRC/arch/x86/boot/bzImage-off"

# verdict exit code 通过临时文件传递（{ ... } | tee 的子 shell 变量不传递到父 shell）
PERF_EXIT_FILE=$(mktemp)
trap 'rm -f "$PERF_EXIT_FILE"' EXIT

# ============================================================================
# 辅助函数
# ============================================================================

log_section() {
    echo ""
    echo "--- [$1] $(date '+%H:%M:%S') ---"
}

# 计算中位数（空格分隔的数值列表）；空列表返回空串
_median() {
    echo "$1" | tr ' ' '\n' | sort -n | \
        awk '{a[NR]=$1} END {if(NR==0){print ""; exit} if(NR%2==1) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2}'
}

# 三态判定，回显状态字 PASS / FAIL / INVALID，由调用方计数与打印
# degradation: 正值=ON 更差（预期方向，工具加开销）；负值=ON 更优（噪声主导→INVALID）；
#              超过 threshold=FAIL，否则 PASS。用 INVALID 而非 FAIL：噪声不是回归，
#              FAIL 会误报回归方向；INVALID 表达"本次测量不可信，建议重跑"。
_verdict3() {
    local degradation="$1" threshold="$2"
    if awk "BEGIN {exit !(${degradation} < 0)}"; then
        echo INVALID
    elif awk "BEGIN {exit !(${degradation} > ${threshold})}"; then
        echo FAIL
    else
        echo PASS
    fi
}

# 复制二进制及其依赖的共享库到 initramfs 目录
copy_binary_with_libs() {
    local bin="$1"
    local dest_dir="$2"
    local bn
    bn=$(basename "$bin")
    cp -L "$bin" "$dest_dir/usr/local/bin/$bn" 2>/dev/null || cp -L "$bin" "$dest_dir/bin/$bn"
    chmod +x "$dest_dir"/usr/local/bin/"$bn" 2>/dev/null || chmod +x "$dest_dir/bin/$bn"
    for lib in $(ldd "$bin" 2>/dev/null | grep -o '/[^ ]*\.so[^ ]*' | sort -u); do
        [ -f "$lib" ] || continue
        local ldest="$dest_dir$lib"
        mkdir -p "$(dirname "$ldest")"
        cp -L "$lib" "$ldest" 2>/dev/null || true
    done
}

# ============================================================================
# Step 1: 构建 ON 内核 (CONFIG_NET_DELAYACCT=y)
# ============================================================================
build_on_kernel() {
    log_section "Building ON kernel (CONFIG_NET_DELAYACCT=y)"

    cd "$LINUX_SRC"

    # 确保 .config 有 CONFIG_NET_DELAYACCT=y
    if ! grep -q "CONFIG_NET_DELAYACCT=y" .config 2>/dev/null; then
        echo "Adding CONFIG_NET_DELAYACCT=y..."
        "$LINUX_SRC/scripts/kconfig/merge_config.sh" -m .config \
            "$PROJECT_DIR/ci/kernel.config.fragment" 2>&1 | tail -3
        make olddefconfig 2>&1 | tail -1
    fi

    # 强制重编译 net-delayacct.c（确保最新代码）
    touch net/core/net-delayacct.c 2>/dev/null || true

    echo "Building bzImage (ON)..."
    make -j"$(nproc)" CC="ccache gcc" bzImage 2>&1 | tail -5

    if [ -f arch/x86/boot/bzImage ]; then
        cp arch/x86/boot/bzImage "$BZIMAGE_ON"
        echo "${GREEN}ON kernel saved: $BZIMAGE_ON${NC}"
    else
        echo "${RED}ON kernel build FAILED${NC}"
        exit 1
    fi
}

# ============================================================================
# Step 2: 构建 OFF 内核 (CONFIG_NET_DELAYACCT=n)
# ============================================================================
build_off_kernel() {
    log_section "Building OFF kernel (CONFIG_NET_DELAYACCT=n)"

    cd "$LINUX_SRC"

    # 备份当前 .config (ON)
    cp .config "$LINUX_SRC/.config.on-backup"

    # 切换 CONFIG_NET_DELAYACCT=n
    echo "Disabling CONFIG_NET_DELAYACCT..."
    if grep -q "CONFIG_NET_DELAYACCT=y" .config; then
        sed -i 's/CONFIG_NET_DELAYACCT=y/# CONFIG_NET_DELAYACCT is not set/' .config
    elif ! grep -q "CONFIG_NET_DELAYACCT" .config; then
        echo "# CONFIG_NET_DELAYACCT is not set" >> .config
    fi
    make olddefconfig 2>&1 | tail -1

    # 确认已关闭
    if grep -q "CONFIG_NET_DELAYACCT=y" .config; then
        echo "${RED}Failed to disable CONFIG_NET_DELAYACCT${NC}"
        cp "$LINUX_SRC/.config.on-backup" .config
        exit 1
    fi
    echo "CONFIG_NET_DELAYACCT is now disabled"

    # 全量重编译（struct sock 大小变化触发大量重编译）
    echo "Building bzImage (OFF) — this may take several minutes..."
    make -j"$(nproc)" CC="ccache gcc" bzImage 2>&1 | tail -5

    if [ -f arch/x86/boot/bzImage ]; then
        cp arch/x86/boot/bzImage "$BZIMAGE_OFF"
        echo "${GREEN}OFF kernel saved: $BZIMAGE_OFF${NC}"
    else
        echo "${RED}OFF kernel build FAILED${NC}"
        cp "$LINUX_SRC/.config.on-backup" .config
        exit 1
    fi

    # 恢复 ON 配置
    echo "Restoring ON config..."
    cp "$LINUX_SRC/.config.on-backup" .config
    make olddefconfig 2>&1 | tail -1
    rm -f "$LINUX_SRC/.config.on-backup"
}

# ============================================================================
# Step 3: 创建 perf initramfs
# ============================================================================
create_perf_initramfs() {
    log_section "Creating perf initramfs"

    local INITRD_DIR
    INITRD_DIR=$(mktemp -d /tmp/perf-initrd.XXXXXX)

    # 基础目录结构
    mkdir -p "$INITRD_DIR"/{bin,sbin,usr/bin,usr/sbin,usr/local/bin,lib,lib64,proc,sys,dev,dev/pts,dev/shm,root,opt,tmp,etc}

    # busybox（基础系统）
    # 注意：busybox --list 包含 "busybox" 自身，必须在符号链接循环中排除，
    # 否则 ln -sf /bin/busybox .../bin/busybox 会把真实二进制覆盖成自引用符号链接
    # （bin/busybox -> /bin/busybox），导致 ELOOP (-40) 内核 panic。
    if [ -f /bin/busybox ]; then
        for applet in $(busybox --list 2>/dev/null | grep -v '^busybox$'); do
            ln -sf /bin/busybox "$INITRD_DIR/bin/$applet" 2>/dev/null || true
        done
        # 先建符号链接再拷贝真实二进制，确保 busybox 本体不被覆盖
        cp /bin/busybox "$INITRD_DIR/bin/busybox"
        chmod +x "$INITRD_DIR/bin/busybox"
    else
        echo "${RED}busybox not found${NC}"
        exit 1
    fi

    # bash（perf 脚本需要）
    if [ -f /bin/bash ]; then
        cp /bin/bash "$INITRD_DIR/bin/bash"
        chmod +x "$INITRD_DIR/bin/bash"
        for lib in $(ldd /bin/bash 2>/dev/null | grep -o '/[^ ]*\.so[^ ]*' | sort -u); do
            [ -f "$lib" ] || continue
            local ldest="$INITRD_DIR$lib"
            mkdir -p "$(dirname "$ldest")"
            cp -L "$lib" "$ldest" 2>/dev/null || true
        done
    fi

    # iperf3（性能测试核心工具）
    if command -v iperf3 >/dev/null 2>&1; then
        copy_binary_with_libs "$(command -v iperf3)" "$INITRD_DIR"
        echo "Packed iperf3"
    else
        echo "${RED}iperf3 not found — perf tests cannot run${NC}"
        exit 1
    fi

    # nc（Perf-3 TCP 延迟测试需要）
    if command -v nc >/dev/null 2>&1; then
        copy_binary_with_libs "$(command -v nc)" "$INITRD_DIR"
        echo "Packed nc"
    else
        echo "${YELLOW}WARNING: nc not found, Perf-3 will SKIP${NC}"
    fi

    # ip 命令（网络配置）
    if command -v ip >/dev/null 2>&1; then
        copy_binary_with_libs "$(command -v ip)" "$INITRD_DIR"
    fi

    # perf 测试脚本
    cp "$PROJECT_DIR/ci/qemu/run-perf-tests.sh" "$INITRD_DIR/opt/run-perf-tests.sh"
    chmod +x "$INITRD_DIR/opt/run-perf-tests.sh"

    # guest init（perf 专用简化版）
    cp "$PROJECT_DIR/ci/qemu/guest-init-perf.sh" "$INITRD_DIR/init"
    chmod +x "$INITRD_DIR/init"

    # 打包 cpio
    (cd "$INITRD_DIR" && find . | cpio -o -H newc 2>/dev/null | gzip) > "$PERF_INITRD"
    rm -rf "$INITRD_DIR"

    echo "Perf initramfs: $PERF_INITRD ($(du -sh "$PERF_INITRD" | cut -f1))"
}

# ============================================================================
# Step 4: QEMU 启动并收集性能数据
# ============================================================================
run_perf_in_qemu() {
    local kernel_img="$1"
    local mode_label="$2"  # ON or OFF
    local qemu_out="/tmp/perf-qemu-${mode_label}-$$.log"

    log_section "Booting QEMU ($mode_label)"

    local qemu_common_args=(
        -m "$QEMU_MEMORY"
        -smp 1
        -kernel "$kernel_img"
        -initrd "$PERF_INITRD"
        -append "console=ttyS0,115200n8 rdinit=/init"
        -nographic
        -no-reboot
        -netdev user,id=net0
        -device e1000,netdev=net0
    )

    local qemu_rc=0

    # 先尝试 KVM
    echo "Trying KVM (timeout=${QEMU_TIMEOUT_KVM}s)..."
    set +e
    timeout "$QEMU_TIMEOUT_KVM" qemu-system-x86_64 \
        -machine q35,accel=kvm,smm=off \
        -cpu host,-sgx \
        "${qemu_common_args[@]}" > "$qemu_out" 2>&1
    qemu_rc=$?
    set -e

    # KVM 失败则回退 TCG
    if [ "$qemu_rc" -ne 0 ] && grep -Eq '(/dev/kvm|failed to initialize kvm|Permission denied)' "$qemu_out" 2>/dev/null; then
        echo "KVM unavailable, falling back to TCG (timeout=${QEMU_TIMEOUT_TCG}s)..."
        set +e
        timeout "$QEMU_TIMEOUT_TCG" qemu-system-x86_64 \
            -machine q35,accel=tcg,smm=off \
            -cpu qemu64,-sgx \
            "${qemu_common_args[@]}" > "$qemu_out" 2>&1
        qemu_rc=$?
        set -e
    fi

    echo "QEMU exited (rc=$qemu_rc)"

    # 提取 PERF: 行
    # tr -d '\r': QEMU 串口输出为 \r\n，去掉 \r 规范化为 Unix 换行，
    # 避免下游 grep/cut 提取的值带 \r 导致数值校验失败
    local result_file="$LOG_DIR/perf-${mode_label}-${TIMESTAMP}.log"
    tr -d '\r' < "$qemu_out" > "$result_file"
    echo "Results saved: $result_file"

    # 输出 PERF: 行
    grep "^PERF:" "$result_file" || echo "${YELLOW}No PERF: lines found in output${NC}"
}

# ============================================================================
# Step 5: 解析并对比结果
# ============================================================================

# 生成 Markdown + CSV 结构化摘要报告
# 参数: $1 = 摘要数据行（每行 tab 分隔: metric unit on_raw off_raw on_med off_med delta_abs delta_pct threshold verdict）
#       $2 = ON mode, $3 = OFF mode
write_summary_files() {
    local summary_data="$1"
    local on_mode="$2"
    local off_mode="$3"

    # CSV
    {
        echo "metric,unit,on_raw,off_raw,on_median,off_median,delta_absolute,delta_percent,threshold,verdict"
        while IFS=$'\t' read -r metric unit on_raw off_raw on_med off_med delta_abs delta_pct threshold verdict; do
            [ -z "$metric" ] && continue
            printf '"%s","%s","%s","%s",%s,%s,%s,%s,%s,%s\n' \
                "$metric" "$unit" "$on_raw" "$off_raw" "$on_med" "$off_med" "$delta_abs" "$delta_pct" "$threshold" "$verdict"
        done <<< "$summary_data"
    } > "$SUMMARY_CSV"

    # Markdown
    {
        echo "# Performance Test Summary"
        echo ""
        echo "- **Timestamp**: ${TIMESTAMP}"
        echo "- **ON kernel mode**: ${on_mode:-unknown}"
        echo "- **OFF kernel mode**: ${off_mode:-unknown}"
        echo ""
        echo "## Metrics"
        echo ""
        echo "| metric | unit | ON raw | OFF raw | ON median | OFF median | delta abs | delta % | threshold | verdict |"
        echo "|--------|------|--------|---------|-----------|------------|-----------|---------|-----------|---------|"
        while IFS=$'\t' read -r metric unit on_raw off_raw on_med off_med delta_abs delta_pct threshold verdict; do
            [ -z "$metric" ] && continue
            echo "| $metric | $unit | $on_raw | $off_raw | $on_med | $off_med | $delta_abs | $delta_pct | $threshold | $verdict |"
        done <<< "$summary_data"
        echo ""
        echo "## Delta Calculation Direction"
        echo ""
        echo "- TCP throughput: (OFF - ON) / OFF * 100 (positive = throughput drop)"
        echo "- UDP PPS: (OFF - ON) / OFF * 100 (positive = PPS drop)"
        echo "- TCP latency: (ON - OFF) / OFF * 100 (positive = latency increase)"
        echo "- CPU utilization: (ON - OFF) / OFF * 100 (positive = CPU increase)"
        echo "- Socket objsize: ON - OFF (bytes)"
    } > "$SUMMARY_MD"

    echo "Summary reports:"
    echo "  Markdown: $SUMMARY_MD"
    echo "  CSV: $SUMMARY_CSV"
}

parse_results() {
    local file="$1"
    local prefix="$2"  # on or off

    # 提取各项测试的多次运行值，取中位数
    # 格式: PERF: tcp_throughput_mbps_run1=123.45
    local key val
    while IFS='=' read -r key val; do
        # 去掉 "PERF: " 前缀
        key="${key#PERF: }"
        # 去掉 "_runN" 后缀
        key="${key%_run*}"
        echo "${prefix}|${key}=${val}"
    done < <(grep "^PERF:" "$file" | grep "_run")
}

compare_and_report() {
    log_section "Performance Comparison Report"

    local on_file="$LOG_DIR/perf-ON-${TIMESTAMP}.log"
    local off_file="$LOG_DIR/perf-OFF-${TIMESTAMP}.log"

    if [ ! -f "$on_file" ] || [ ! -f "$off_file" ]; then
        echo "${RED}Missing result files${NC}"
        PERF_EXIT=1
        return 1
    fi

    # 解析 ON 和 OFF 的所有指标
    declare -A on_values off_values

    local key val run_vals median
    while IFS='|=' read -r prefix metric val; do
        # 跳过 SKIP 值，不参与中位数计算
        [ "$val" = "SKIP" ] && continue
        if [ "$prefix" = "on" ]; then
            on_values["${metric}_vals"]="${on_values[${metric}_vals]:+${on_values[${metric}_vals]} }$val"
        elif [ "$prefix" = "off" ]; then
            off_values["${metric}_vals"]="${off_values[${metric}_vals]:+${off_values[${metric}_vals]} }$val"
        fi
    done < <(parse_results "$on_file" on; parse_results "$off_file" off)

    # 模式检测
    local on_mode off_mode
    on_mode=$(grep "^PERF: mode=" "$on_file" | head -1 | cut -d= -f2)
    off_mode=$(grep "^PERF: mode=" "$off_file" | head -1 | cut -d= -f2)

    echo "ON  kernel mode: $on_mode"
    echo "OFF kernel mode: $off_mode"

    # ON/OFF mode sanity check：确认 QEMU 输出中的 PERF: mode= 与预期一致
    if [ "$on_mode" != "ON" ]; then
        echo "${YELLOW}WARNING: ON kernel log reports mode='${on_mode}', expected 'ON'${NC}"
    fi
    if [ "$off_mode" != "OFF" ]; then
        echo "${YELLOW}WARNING: OFF kernel log reports mode='${off_mode}', expected 'OFF'${NC}"
    fi
    echo ""
    echo "+----------------------------------------------------------------+"
    echo "|  NET_DELAYACCT Performance Comparison (QEMU relative values)  |"
    echo "+----------------------------------------------------------------+"
    printf "| %-28s | %12s | %12s | %8s |\n" "Metric" "ON" "OFF" "Delta"
    echo "+----------------------------------------------------------------+"

    # 对比每个指标
    local metrics="tcp_throughput_mbps udp_pps tcp_latency_us cpu_util_pct"
    # sock_objsize_bytes 只运行一次（静态值），单独处理
    local on_sock off_sock
    # tr -d '\r': QEMU 串口输出为 \r\n，提取的值末尾带 \r 会导致
    # grep -qE '^[0-9]+$' 失败，内存 delta 误显示为 "-"
    on_sock=$(grep "^PERF: sock_objsize_bytes_run1=" "$on_file" | head -1 | cut -d= -f2 | tr -d '\r')
    off_sock=$(grep "^PERF: sock_objsize_bytes_run1=" "$off_file" | head -1 | cut -d= -f2 | tr -d '\r')

    for metric in $metrics; do
        local on_vals="${on_values[${metric}_vals]:-}"
        local off_vals="${off_values[${metric}_vals]:-}"

        if [ -z "$on_vals" ] || [ -z "$off_vals" ]; then
            printf "| %-28s | %12s | %12s | %8s |\n" "$metric" "SKIP" "SKIP" "-"
            continue
        fi

        # 取中位数
        local on_med off_med
        on_med=$(_median "$on_vals")
        off_med=$(_median "$off_vals")

        # 计算变化百分比
        local delta
        if [ "$metric" = "tcp_throughput_mbps" ] || [ "$metric" = "udp_pps" ]; then
            # 吞吐/PPS：下降百分比 = (OFF - ON) / OFF * 100
            delta=$(awk "BEGIN {if(${off_med}>0) printf \"%.1f%%\", (${off_med}-${on_med})/${off_med}*100; else print \"N/A\"}")
        elif [ "$metric" = "tcp_latency_us" ] || [ "$metric" = "cpu_util_pct" ]; then
            # 延迟/CPU：增加百分比 = (ON - OFF) / OFF * 100
            # 用 %+.1f%% 让符号随正负自动（+5.0% / -17.8%），避免 "+%.1f%%" 对负值产生 "+-17.8%" 双符号
            delta=$(awk "BEGIN {if(${off_med}>0) printf \"%+.1f%%\", (${on_med}-${off_med})/${off_med}*100; else print \"N/A\"}")
        fi

        printf "| %-28s | %12s | %12s | %8s |\n" "$metric" "$on_med" "$off_med" "$delta"
    done

    # 内存对比
    if [ -n "$on_sock" ] && [ -n "$off_sock" ] && \
       echo "$on_sock" | grep -qE '^[0-9]+$' && echo "$off_sock" | grep -qE '^[0-9]+$'; then
        local mem_delta=$((on_sock - off_sock))
        printf "| %-28s | %12s | %12s | %+8s |\n" "sock_objsize_bytes" "$on_sock" "$off_sock" "+$mem_delta"
    else
        printf "| %-28s | %12s | %12s | %8s |\n" "sock_objsize_bytes" "${on_sock:-SKIP}" "${off_sock:-SKIP}" "-"
    fi

    echo "+----------------------------------------------------------------+"
    echo ""
    echo "Pass criteria (initial, subject to calibration):"
    echo "  Perf-1 TCP throughput drop:  < 5%"
    echo "  Perf-2 UDP PPS drop:         < 15%"
    echo "  Perf-3 TCP latency increase: < 10% (relative)"
    echo "  Perf-4 Per-socket memory:    <= 192 bytes (slab-aligned, raw struct ~72B)"
    echo "  Perf-5 CPU util increase:    < 10% (relative)"
    echo ""

    # ---- 自动判定（三态：PASS / FAIL / INVALID）----
    # net_delayacct 是加开销工具，ON 合法优于 OFF 不可能；若 ON 反超 OFF
    # （degradation<0）说明测量被噪声主导 → INVALID（非 FAIL，避免误报回归方向）。
    # degradation 统一约定：正值=ON 更差（预期方向），负值=ON 更优（噪声）。
    echo "Verdict:"
    # verdict_pass 用于区分"全部 PASS"与"全部 SKIP(无数据)"：
    # 若 evaluated=pass+fail+invalid=0 说明无任何指标被评估（QEMU 启动但 perf 测试
    # 未产出数据，如内核 panic / guest init 失败），不应报 ALL PASSED（假绿），应 exit 2。
    local verdict_pass=0 verdict_fail=0 verdict_invalid=0 status
    local v_on v_off v_onm v_offm v_drop v_lat v_cpu v_mem v_entry v_m v_t
    # 摘要报告数据行（tab 分隔: metric unit on_raw off_raw on_med off_med delta_abs delta_pct threshold verdict）
    local SUMMARY_ROWS=""

    # Perf-1/2 吞吐与 PPS：degradation = (OFF-ON)/OFF*100，阈值 5% / 15%
    for v_entry in "tcp_throughput_mbps:5" "udp_pps:15"; do
        v_m="${v_entry%:*}"; v_t="${v_entry##*:}"
        v_on="${on_values[${v_m}_vals]:-}"; v_off="${off_values[${v_m}_vals]:-}"
        local v_unit v_delta_abs
        if [ "$v_m" = "tcp_throughput_mbps" ]; then
            v_unit="Mbps"
        else
            v_unit="packets/sec"
        fi
        if [ -n "$v_on" ] && [ -n "$v_off" ]; then
            v_onm=$(_median "$v_on"); v_offm=$(_median "$v_off")
            v_drop=$(awk "BEGIN {printf \"%.1f\", (${v_offm}-${v_onm})/${v_offm}*100}")
            v_delta_abs=$(awk "BEGIN {printf \"%.2f\", ${v_offm}-${v_onm}}")
            status=$(_verdict3 "$v_drop" "$v_t")
            case "$status" in
                PASS)    echo "  ${GREEN}PASS${NC} $v_m: drop ${v_drop}% <= ${v_t}% threshold"; verdict_pass=$((verdict_pass+1));;
                FAIL)    echo "  ${RED}FAIL${NC} $v_m: drop ${v_drop}% > ${v_t}% threshold"; verdict_fail=$((verdict_fail+1));;
                INVALID) echo "  ${YELLOW}INVALID${NC} $v_m: ON>OFF by $(awk -v d="${v_drop}" 'BEGIN{printf "%.1f", (d<0?-d:d)}')% (noise-dominated)"; verdict_invalid=$((verdict_invalid+1));;
            esac
            SUMMARY_ROWS+="${v_m}	${v_unit}	${v_on}	${v_off}	${v_onm}	${v_offm}	${v_delta_abs}	${v_drop}%	${v_t}%	${status}"$'\n'
        else
            echo "  ${YELLOW}SKIP${NC} $v_m: no data"
            SUMMARY_ROWS+="${v_m}	${v_unit}	-	-	-	-	-	-	${v_t}%	SKIP"$'\n'
        fi
    done

    # Perf-3 TCP 延迟：degradation = (ON-OFF)/OFF*100 (相对 %)，阈值 10%
    # 改为相对 %：connect() 延迟在 -smp 1 QEMU 中 ~3800μs（上下文切换主导），
    # 10μs 绝对阈值 = 0.26% of total，远低于噪声。相对阈值与 throughput/cpu 一致。
    v_on="${on_values[tcp_latency_us_vals]:-}"; v_off="${off_values[tcp_latency_us_vals]:-}"
    if [ -n "$v_on" ] && [ -n "$v_off" ]; then
        v_onm=$(_median "$v_on"); v_offm=$(_median "$v_off")
        v_lat=$(awk "BEGIN {printf \"%.1f\", (${v_onm}-${v_offm})/${v_offm}*100}")
        local v_lat_abs
        v_lat_abs=$(awk "BEGIN {printf \"%.2f\", ${v_onm}-${v_offm}}")
        status=$(_verdict3 "$v_lat" 10)
        case "$status" in
            PASS)    echo "  ${GREEN}PASS${NC} tcp_latency_us: +${v_lat}% <= 10% threshold"; verdict_pass=$((verdict_pass+1));;
            FAIL)    echo "  ${RED}FAIL${NC} tcp_latency_us: +${v_lat}% > 10% threshold"; verdict_fail=$((verdict_fail+1));;
            INVALID) echo "  ${YELLOW}INVALID${NC} tcp_latency_us: ON<OFF (noise-dominated)"; verdict_invalid=$((verdict_invalid+1));;
        esac
        SUMMARY_ROWS+="tcp_latency_us	us	${v_on}	${v_off}	${v_onm}	${v_offm}	${v_lat_abs}	${v_lat}%	10%	${status}"$'\n'
    else
        echo "  ${YELLOW}SKIP${NC} tcp_latency_us: no data"
        SUMMARY_ROWS+="tcp_latency_us	us	-	-	-	-	-	-	10%	SKIP"$'\n'
    fi

    # Perf-5 CPU 利用率：degradation = (ON-OFF)/OFF*100 (相对 %)，阈值 10%
    v_on="${on_values[cpu_util_pct_vals]:-}"; v_off="${off_values[cpu_util_pct_vals]:-}"
    if [ -n "$v_on" ] && [ -n "$v_off" ]; then
        v_onm=$(_median "$v_on"); v_offm=$(_median "$v_off")
        v_cpu=$(awk "BEGIN {printf \"%.1f\", (${v_onm}-${v_offm})/${v_offm}*100}")
        local v_cpu_abs
        v_cpu_abs=$(awk "BEGIN {printf \"%.2f\", ${v_onm}-${v_offm}}")
        status=$(_verdict3 "$v_cpu" 10)
        case "$status" in
            PASS)    echo "  ${GREEN}PASS${NC} cpu_util_pct: +${v_cpu}% <= 10% threshold"; verdict_pass=$((verdict_pass+1));;
            FAIL)    echo "  ${RED}FAIL${NC} cpu_util_pct: +${v_cpu}% > 10% threshold"; verdict_fail=$((verdict_fail+1));;
            INVALID) echo "  ${YELLOW}INVALID${NC} cpu_util_pct: ON<OFF (noise-dominated)"; verdict_invalid=$((verdict_invalid+1));;
        esac
        SUMMARY_ROWS+="cpu_util_pct	%	${v_on}	${v_off}	${v_onm}	${v_offm}	${v_cpu_abs}	${v_cpu}%	10%	${status}"$'\n'
    else
        echo "  ${YELLOW}SKIP${NC} cpu_util_pct: no data"
        SUMMARY_ROWS+="cpu_util_pct	%	-	-	-	-	-	-	10%	SKIP"$'\n'
    fi

    # Perf-4 每 socket 内存：degradation = ON-OFF (bytes)，阈值 192
    # 阈值 192 = 72(struct net_delayacct) + 56(SLAB_HWCACHE_ALIGN 64B 对齐填充) + 64(余量)
    # /proc/slabinfo 第 4 列是 s->size（含 64 字节缓存行对齐），非 s->object_size（原始 struct）
    # TCP slab 用 SLAB_HWCACHE_ALIGN（tcp.c kmem_cache_create），ON struct 增加 72B 后
    # 跨 64B 边界 → 对齐填充 56B → slab delta 128B。原始 struct 开销仅 72B（<= 80 理论阈值）。
    if [ -n "$on_sock" ] && [ -n "$off_sock" ] && \
       echo "$on_sock" | grep -qE '^[0-9]+$' && echo "$off_sock" | grep -qE '^[0-9]+$'; then
        v_mem=$((on_sock - off_sock))
        status=$(_verdict3 "$v_mem" 192)
        case "$status" in
            PASS)    echo "  ${GREEN}PASS${NC} sock_objsize: +${v_mem} bytes <= 192 threshold (raw struct ~72B + slab align)"; verdict_pass=$((verdict_pass+1));;
            FAIL)    echo "  ${RED}FAIL${NC} sock_objsize: +${v_mem} bytes > 192 threshold"; verdict_fail=$((verdict_fail+1));;
            INVALID) echo "  ${YELLOW}INVALID${NC} sock_objsize: ON<OFF (noise-dominated)"; verdict_invalid=$((verdict_invalid+1));;
        esac
        SUMMARY_ROWS+="sock_objsize_bytes	bytes	${on_sock}	${off_sock}	${on_sock}	${off_sock}	+${v_mem}	N/A	192	${status}"$'\n'
    else
        echo "  ${YELLOW}SKIP${NC} sock_objsize: no data"
        SUMMARY_ROWS+="sock_objsize_bytes	bytes	${on_sock:-SKIP}	${off_sock:-SKIP}	-	-	-	N/A	192	SKIP"$'\n'
    fi

    # 总结论（优先级：FAIL > INVALID(视strict) > NO-DATA > PASS）
    # exit code: 0=PASS/warn通过, 1=FAIL(strict=fail)/INVALID(strict=fail), 2=数据不可信(全SKIP或INVALID>50%)
    #
    # strict=warn（CI 默认）：FAIL → exit 0（告警，不阻断）。共享 runner 噪声大，
    #   单次 FAIL 可能是噪声非真实回归；FAIL 详情已在上方 Verdict 区 + Step Summary
    #   输出供趋势分析。NO-DATA / INVALID>50% 仍 exit 2（这些是真实问题非噪声）。
    # strict=fail（本地回归）：FAIL → exit 1（阻断），用于严格回归测试。
    echo ""
    if [ "$verdict_fail" -gt 0 ]; then
        case "$STRICT_MODE" in
            fail)
                echo "${RED}=== ${verdict_fail} TEST(S) FAILED (strict=fail, blocking) ===${NC}"
                PERF_EXIT=1
                ;;
            warn|"")
                echo "${YELLOW}=== ${verdict_fail} TEST(S) EXCEEDED THRESHOLD (strict=warn, non-blocking — see summary for trend analysis) ===${NC}"
                PERF_EXIT=0
                ;;
            *)
                echo "${RED}ERROR: unknown STRICT_MODE='$STRICT_MODE'${NC}" >&2
                PERF_EXIT=2
                ;;
        esac
    elif [ "$verdict_invalid" -gt 0 ]; then
        case "$STRICT_MODE" in
            fail)
                echo "${RED}=== ${verdict_invalid} measurement(s) INVALID (strict=fail) ===${NC}"
                PERF_EXIT=1
                ;;
            warn|"")
                echo "${YELLOW}=== INCONCLUSIVE: ${verdict_invalid} measurement(s) noise-dominated (rerun recommended) ===${NC}"
                # INVALID > 50%（≥3/5）视为数据不可信，exit 2 区别于测试失败 exit 1
                if [ "$verdict_invalid" -ge 3 ]; then
                    echo "${RED}=== INVALID ratio > 50%, data unreliable (exit 2) ===${NC}"
                    PERF_EXIT=2
                else
                    PERF_EXIT=0
                fi
                ;;
            *)
                echo "${RED}ERROR: unknown STRICT_MODE='$STRICT_MODE'${NC}" >&2
                PERF_EXIT=2
                ;;
        esac
    elif [ "$verdict_pass" -eq 0 ]; then
        # 所有指标均 SKIP（无数据）：QEMU 启动了但 perf 测试未产出数据
        # （内核 panic / guest init 失败 / run-perf-tests.sh 异常）。
        # 不可报 ALL PASSED（假绿），exit 2 提示数据缺失。
        echo "${RED}=== NO DATA: all metrics SKIP (QEMU booted but no PERF: lines) — check guest logs ===${NC}"
        PERF_EXIT=2
    else
        echo "${GREEN}=== ALL PERFORMANCE TESTS PASSED ===${NC}"
        PERF_EXIT=0
    fi

    echo ""
    echo "Note: QEMU relative values only. For absolute data, run on physical hardware."
    echo "Note: Thresholds are initial values, subject to calibration with multiple runs."
    echo "Full logs: $LOG_DIR/perf-{ON,OFF}-${TIMESTAMP}.log"

    # 生成结构化摘要报告（Markdown + CSV）
    write_summary_files "$SUMMARY_ROWS" "$on_mode" "$off_mode"
}

# ============================================================================
# Main
# ============================================================================

SKIP_BUILD=false
# 参数解析：--skip-build / --strict[=warn|fail] / --bzimage-on=PATH / --bzimage-off=PATH
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build)
            SKIP_BUILD=true
            ;;
        --strict)
            # 无参数 = fail（严格回归，FAIL/INVALID 阻断）
            STRICT_MODE="fail"
            ;;
        --strict=*)
            STRICT_MODE="${1#--strict=}"
            case "$STRICT_MODE" in
                warn|fail) ;;
                *) echo "${RED}ERROR: --strict=$STRICT_MODE invalid (use warn|fail)${NC}" >&2; exit 2 ;;
            esac
            ;;
        --bzimage-on=*)
            BZIMAGE_ON="${1#--bzimage-on=}"
            ;;
        --bzimage-off=*)
            BZIMAGE_OFF="${1#--bzimage-off=}"
            ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--skip-build] [--strict[=warn|fail]] [--bzimage-on=PATH] [--bzimage-off=PATH]
  --skip-build          复用已有 bzImage-on/off（不重新构建内核）
  --strict              INVALID 视作 FAIL 阻断（等同 --strict=fail）
  --strict=warn         INVALID 告警不阻断，但 >50% 时 exit 2（默认）
  --strict=fail         INVALID 阻断 exit 1（CI 严格回归）
  --bzimage-on=PATH     指定 ON 内核路径（CI 中 artifact 下载后用）
  --bzimage-off=PATH    指定 OFF 内核路径
EOF
            exit 0
            ;;
        *)
            echo "${RED}Unknown option: $1${NC}" >&2
            exit 2
            ;;
    esac
    shift
done

{
    echo "=== NET_DELAYACCT Performance Test $(date) ==="
    echo "Linux source: $LINUX_SRC"
    echo "Log dir: $LOG_DIR"
    echo ""

    # Step 1-2: 构建双内核
    if [ "$SKIP_BUILD" = false ]; then
        # 确保源码已同步到内核树
        if [ -f "$PROJECT_DIR/kernel-patches/net-core-net-delayacct.c" ]; then
            cat "$PROJECT_DIR/kernel-patches/net-core-net-delayacct.c" > \
                "$LINUX_SRC/net/core/net-delayacct.c" 2>/dev/null || true
        fi

        build_on_kernel
        build_off_kernel
    else
        echo "Skipping build (--skip-build)"
        if [ ! -f "$BZIMAGE_ON" ] || [ ! -f "$BZIMAGE_OFF" ]; then
            echo "${RED}bzImage-on/off not found, cannot --skip-build${NC}"
            exit 1
        fi
        echo "Using existing: $BZIMAGE_ON, $BZIMAGE_OFF"
    fi

    # Step 3: 创建 perf initramfs
    create_perf_initramfs

    # Step 4: 双跑
    run_perf_in_qemu "$BZIMAGE_ON" "ON"
    echo ""
    run_perf_in_qemu "$BZIMAGE_OFF" "OFF"

    # Step 5: 对比报告
    # || true: compare_and_report 在 missing-files 时 return 1，不让 set -e 绕过
    # PERF_EXIT_FILE 写入（PERF_EXIT 已在 return 前显式设置为 1）
    compare_and_report || true

    # 将 verdict exit code 写入临时文件（pipe 子 shell 变量不传递到父 shell）
    echo "${PERF_EXIT:-0}" > "$PERF_EXIT_FILE"

} 2>&1 | tee "$LOG_DIR/perf-test-${TIMESTAMP}.log"

# 从临时文件读取 verdict exit code（pipe 子 shell 传递）
PERF_EXIT=$(cat "$PERF_EXIT_FILE" 2>/dev/null || echo 0)

echo ""
echo "Full report: $LOG_DIR/perf-test-${TIMESTAMP}.log"
exit "${PERF_EXIT:-0}"

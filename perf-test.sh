#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# perf-test.sh — NET_DELAYACCT 性能基准测试编排脚本（host 侧）
#
# 对比 K0/K2/K3 三种模式的性能开销：
#   K0: OFF 内核（CONFIG_NET_DELAYACCT=n）— 基线，无插桩开销
#   K2: ON 内核，检测开启，无主动查询（纯插桩开销）
#   K3: ON 内核，检测开启 + 主动查询（导出开销，需 get_sockdelays）
#
# 默认运行 K0 vs K2；--with-k3 额外运行 K3。
#
# 流程：
#   1. 构建 ON 内核 (CONFIG_NET_DELAYACCT=y) → bzImage-on（K2/K3 共用）
#   2. 构建 OFF 内核 (CONFIG_NET_DELAYACCT=n) → bzImage-off（K0）
#   3. 创建 perf initramfs（含 run-perf-tests.sh + get_sockdelays + 可选 perf）
#   4. QEMU 启动 K0 (OFF) → 收集性能数据
#   5. QEMU 启动 K2 (ON, QUERY_MODE=K2) → 收集性能数据
#   6. [--with-k3] QEMU 启动 K3 (ON, QUERY_MODE=K3) → 收集性能数据
#   7. 对比并生成报告（K0 为基线，K0→K2 为主判定）
#
# 用法: ./perf-test.sh [--skip-build] [--with-k3] [--test-duration=10] ...
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
#     单次 FAIL 可能是噪声非回归；仅 NO-DATA(全SKIP) 或 INVALID>50% 时 exit 2（数据不可信）
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
# 测试参数（可被命令行参数覆盖）
# ============================================================================

# 是否额外运行 K3 模式
WITH_K3=false

# iperf3 测试时长（秒）
TEST_DURATION="${TEST_DURATION:-10}"

# iperf3 预热时长（秒，--omit）
WARMUP_DURATION="${WARMUP_DURATION:-3}"

# 是否采集 cycles/packet（需 perf 二进制）
ENABLE_CYCLES="${ENABLE_CYCLES:-0}"

# 固定负载速率列表（Mbps，空格分隔；空则不测）
FIXED_LOAD_RATES="${FIXED_LOAD_RATES:-}"

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
# degradation: 正值=K2 更差（预期方向，工具加开销）；负值=K2 更优（噪声主导→INVALID）；
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

    # get_sockdelays 二进制 + 依赖（含 libmnl）— K3 模式必需
    # K3 模式通过后台主动调用 get_sockdelays 模拟导出开销；缺此二进制时
    # run-perf-tests.sh 会自动降级为 K2 行为（仅检测不查询）
    local TOOL_BIN="$PROJECT_DIR/userspace/get_sockdelays/get_sockdelays"
    if [ ! -x "$TOOL_BIN" ]; then
        echo "get_sockdelays not found, attempting build..."
        # 需先安装 UAPI 头到内核源码树（make tool 会查找）
        if [ -f "$LINUX_SRC/include/uapi/linux/net-delayacct.h" ]; then
            (cd "$PROJECT_DIR" && make tool 2>&1 | tail -3) || true
        else
            echo "${YELLOW}WARNING: UAPI header not found in linux src, skip get_sockdelays build${NC}"
        fi
    fi
    if [ -x "$TOOL_BIN" ]; then
        copy_binary_with_libs "$TOOL_BIN" "$INITRD_DIR"
        echo "Packed get_sockdelays (for K3 mode)"
    else
        echo "${YELLOW}WARNING: get_sockdelays not built, K3 mode will fall back to K2 behavior${NC}"
    fi

    # perf 二进制 — cycles/packet 测试（Perf-7）需要
    # 仅当 --enable-cycles 且主机上 perf 可用时打包；缺失则 run-perf-tests.sh 中 Perf-7 SKIP
    if [ "$ENABLE_CYCLES" = "1" ]; then
        if command -v perf >/dev/null 2>&1; then
            copy_binary_with_libs "$(command -v perf)" "$INITRD_DIR"
            echo "Packed perf (for cycles/packet test)"
        else
            echo "${YELLOW}WARNING: perf not found on host, cycles/packet test will SKIP${NC}"
        fi
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

# $1 = kernel_img, $2 = mode_label (K0/K2/K3), $3 = query_mode (传给 guest 的 cmdline 参数)
run_perf_in_qemu() {
    local kernel_img="$1"
    local mode_label="$2"
    local query_mode="$3"
    local qemu_out="/tmp/perf-qemu-${mode_label}-$$.log"

    log_section "Booting QEMU ($mode_label)"

    # 构造内核 cmdline：基础参数 + perf 测试参数
    # fixed_load_rates 用逗号分隔（避免空格破坏 cmdline tokenization），
    # guest 侧 guest-init-perf.sh 会转换为空格分隔
    local append_str="console=ttyS0,115200n8 rdinit=/init"
    append_str+=" query_mode=${query_mode}"
    append_str+=" test_duration=${TEST_DURATION}"
    append_str+=" warmup_duration=${WARMUP_DURATION}"
    append_str+=" enable_cycles=${ENABLE_CYCLES}"
    if [ -n "$FIXED_LOAD_RATES" ]; then
        append_str+=" fixed_load_rates=$(echo "$FIXED_LOAD_RATES" | tr ' ' ',')"
    fi

    local qemu_common_args=(
        -m "$QEMU_MEMORY"
        -smp 1
        -kernel "$kernel_img"
        -initrd "$PERF_INITRD"
        -append "$append_str"
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

# 解析 PERF: *_runN= 行，输出 mode|metric=value
# $1 = 文件, $2 = 模式前缀 (K0/K2/K3)
# 向后兼容：同时支持新指标名（tcp_latency_p50 等）和旧格式（tcp_latency_us）
parse_results() {
    local file="$1"
    local prefix="$2"
    local key val
    while IFS='=' read -r key val; do
        # 去掉 "PERF: " 前缀
        key="${key#PERF: }"
        # 去掉 "_runN" 后缀，保留 metric 名（tcp_latency_p50_run1 → tcp_latency_p50）
        key="${key%_run*}"
        echo "${prefix}|${key}=${val}"
    done < <(grep "^PERF:" "$file" | grep "_run")
}

# 计算 delta 百分比（带符号），用于 K0→Kx 对比
# $1 = metric, $2 = baseline (K0) 值, $3 = compared (Kx) 值
# 输出: ±N.N% 或 "N/A"
# delta 方向（正值语义）：
#   throughput/PPS: (K0 - Kx) / K0 * 100（正值=吞吐下降，Kx 更差）
#   latency/CPU/cycles: (Kx - K0) / K0 * 100（正值=延迟/CPU 增加，Kx 更差）
#   idle_cpu: (Kx - K0) / K0 * 100（正值=idle 增加=好事，见下方说明）
#   sock_objsize: 用 calc_delta_abs（字节差），不调本函数
#
# 注意：idle_cpu 的 delta 方向说明（正值=好事）按需求文档定义。
# guest 输出 idle_cpu_pct 实为"空闲期间 CPU 利用率"（值越小越好），但需求文档
# 指定 delta 方向为 (Kx - K0) / K0 * 100 且"正值=idle增加=好事"，故本函数按
# 文档语义实现。verdict 使用绝对值判定，方向不影响 pass/fail。
calc_delta_pct() {
    local metric="$1" base="$2" comp="$3"
    case "$metric" in
        tcp_throughput_mbps|udp_pps)
            # 吞吐/PPS：下降百分比 = (K0 - Kx) / K0 * 100（正值=Kx 下降=更差）
            awk "BEGIN {if(${base}+0>0) printf \"%+.1f%%\", (${base}-${comp})/${base}*100; else print \"N/A\"}"
            ;;
        idle_cpu_pct)
            # idle_cpu：(Kx - K0) / K0 * 100（正值=idle增加=好事，按需求文档）
            awk "BEGIN {if(${base}+0>0) printf \"%+.1f%%\", (${comp}-${base})/${base}*100; else print \"N/A\"}"
            ;;
        *)
            # 默认（latency/CPU/cycles/fixed_load）：(Kx - K0) / K0 * 100（正值=增加=更差）
            awk "BEGIN {if(${base}+0>0) printf \"%+.1f%%\", (${comp}-${base})/${base}*100; else print \"N/A\"}"
            ;;
    esac
}

# 计算 delta 绝对值（字节），用于 sock_objsize_bytes
# $1 = baseline (K0), $2 = compared (Kx)
calc_delta_abs() {
    local base="$1" comp="$2"
    awk "BEGIN {printf \"%+d\", ${comp}-${base}}"
}

# 生成 Markdown + CSV 结构化摘要报告
# 参数: $1 = 摘要数据行（每行 tab 分隔 13 列）:
#       metric unit k0_raw k2_raw k3_raw k0_med k2_med k3_med delta_k0k2 delta_k0k3 delta_k2k3 threshold verdict
#       $2 = K0 mode, $3 = K2 mode, $4 = K3 mode（"-"表示未运行）
write_summary_files() {
    local summary_data="$1"
    local k0_mode="$2"
    local k2_mode="$3"
    local k3_mode="${4:--}"

    # CSV
    {
        echo "metric,unit,k0_raw,k2_raw,k3_raw,k0_median,k2_median,k3_median,delta_k0k2,delta_k0k3,delta_k2k3,threshold,verdict"
        while IFS=$'\t' read -r metric unit k0_raw k2_raw k3_raw k0_med k2_med k3_med d_k0k2 d_k0k3 d_k2k3 threshold verdict; do
            [ -z "$metric" ] && continue
            printf '"%s","%s","%s","%s","%s",%s,%s,%s,%s,%s,%s,%s,%s\n' \
                "$metric" "$unit" "$k0_raw" "$k2_raw" "$k3_raw" \
                "$k0_med" "$k2_med" "$k3_med" \
                "$d_k0k2" "$d_k0k3" "$d_k2k3" \
                "$threshold" "$verdict"
        done <<< "$summary_data"
    } > "$SUMMARY_CSV"

    # Markdown
    {
        echo "# 性能测试摘要报告"
        echo ""
        echo "- **时间戳**: ${TIMESTAMP}"
        echo "- **K0 内核模式**: ${k0_mode:-unknown}（OFF 内核，基线）"
        echo "- **K2 内核模式**: ${k2_mode:-unknown}（ON 内核，检测开启，无查询）"
        echo "- **K3 内核模式**: ${k3_mode:--}（ON 内核，检测+查询）"
        echo "- **测试时长**: ${TEST_DURATION}s（预热 ${WARMUP_DURATION}s）"
        [ "$ENABLE_CYCLES" = "1" ] && echo "- **cycles/packet**: 启用"
        [ -n "$FIXED_LOAD_RATES" ] && echo "- **固定负载速率**: ${FIXED_LOAD_RATES} Mbps"
        echo ""
        echo "## 指标详情"
        echo ""
        echo "| 指标 | 单位 | K0 | K2 | K3 | K0→K2 差值 | K0→K3 差值 | K2→K3 差值 | 阈值 | 判定 |"
        echo "|------|------|----|----|----|-----------|-----------|-----------|------|------|"
        while IFS=$'\t' read -r metric unit k0_raw k2_raw k3_raw k0_med k2_med k3_med d_k0k2 d_k0k3 d_k2k3 threshold verdict; do
            [ -z "$metric" ] && continue
            echo "| $metric | $unit | $k0_med | $k2_med | $k3_med | $d_k0k2 | $d_k0k3 | $d_k2k3 | $threshold | $verdict |"
        done <<< "$summary_data"
        echo ""
        echo "## Delta 计算方向"
        echo ""
        echo "- TCP 吞吐量: (K0 - Kx) / K0 * 100（正值 = 吞吐下降，Kx 更差）"
        echo "- UDP PPS: (K0 - Kx) / K0 * 100（正值 = PPS 下降，Kx 更差）"
        echo "- TCP 延迟: (Kx - K0) / K0 * 100（正值 = 延迟增加，Kx 更差）"
        echo "- CPU 利用率: (Kx - K0) / K0 * 100（正值 = CPU 增加，Kx 更差）"
        echo "- Idle CPU: (Kx - K0) / K0 * 100（正值 = idle 增加 = 好事，K2/K3 不增加空闲开销）"
        echo "- cycles/packet: (Kx - K0) / K0 * 100（正值 = cycles 增加，Kx 更差）"
        echo "- Socket 对象大小: Kx - K0（字节，正值 = 内存增加）"
        echo ""
        echo "## 判定说明"
        echo ""
        echo "- 主判定基于 K0→K2（与现有 ON/OFF 对比行为一致）"
        echo "- K0→K3 / K2→K3 差值仅供参考，不影响 verdict"
        echo "- K3 未运行时显示 \"-\""
    } > "$SUMMARY_MD"

    echo "摘要报告:"
    echo "  Markdown: $SUMMARY_MD"
    echo "  CSV: $SUMMARY_CSV"
}

compare_and_report() {
    log_section "Performance Comparison Report"

    local k0_file="$LOG_DIR/perf-K0-${TIMESTAMP}.log"
    local k2_file="$LOG_DIR/perf-K2-${TIMESTAMP}.log"
    local k3_file=""
    [ -f "$LOG_DIR/perf-K3-${TIMESTAMP}.log" ] && k3_file="$LOG_DIR/perf-K3-${TIMESTAMP}.log"

    if [ ! -f "$k0_file" ] || [ ! -f "$k2_file" ]; then
        echo "${RED}Missing result files (K0/K2)${NC}"
        PERF_EXIT=1
        return 1
    fi

    # 解析所有模式到 values 数组
    # 键格式: "${mode}|${metric}_vals"，值为空格分隔的多次运行结果
    declare -A values

    local mode metric val
    while IFS='|=' read -r mode metric val; do
        # 跳过 SKIP 值，不参与中位数计算
        [ "$val" = "SKIP" ] && continue
        [ -z "$val" ] && continue
        values["${mode}|${metric}_vals"]="${values[${mode}|${metric}_vals]:+${values[${mode}|${metric}_vals]} }$val"
    done < <(
        parse_results "$k0_file" K0
        parse_results "$k2_file" K2
        [ -n "$k3_file" ] && parse_results "$k3_file" K3
    )

    # 模式检测（PERF: mode= 和 PERF: query_mode=）
    local k0_mode k2_mode k3_mode k0_qmode k2_qmode k3_qmode
    k0_mode=$(grep "^PERF: mode=" "$k0_file" | head -1 | cut -d= -f2 | tr -d '\r')
    k2_mode=$(grep "^PERF: mode=" "$k2_file" | head -1 | cut -d= -f2 | tr -d '\r')
    k0_qmode=$(grep "^PERF: query_mode=" "$k0_file" | head -1 | cut -d= -f2 | tr -d '\r')
    k2_qmode=$(grep "^PERF: query_mode=" "$k2_file" | head -1 | cut -d= -f2 | tr -d '\r')
    if [ -n "$k3_file" ]; then
        k3_mode=$(grep "^PERF: mode=" "$k3_file" | head -1 | cut -d= -f2 | tr -d '\r')
        k3_qmode=$(grep "^PERF: query_mode=" "$k3_file" | head -1 | cut -d= -f2 | tr -d '\r')
    fi

    echo "K0: mode=$k0_mode query=$k0_qmode"
    echo "K2: mode=$k2_mode query=$k2_qmode"
    [ -n "$k3_file" ] && echo "K3: mode=$k3_mode query=$k3_qmode"

    # mode sanity check：确认 QEMU 输出与预期一致
    if [ "$k0_mode" != "OFF" ]; then
        echo "${YELLOW}WARNING: K0 kernel log reports mode='${k0_mode}', expected 'OFF'${NC}"
    fi
    if [ "$k2_mode" != "ON" ]; then
        echo "${YELLOW}WARNING: K2 kernel log reports mode='${k2_mode}', expected 'ON'${NC}"
    fi
    if [ -n "$k3_file" ] && [ "$k3_mode" != "ON" ]; then
        echo "${YELLOW}WARNING: K3 kernel log reports mode='${k3_mode}', expected 'ON'${NC}"
    fi
    echo ""
    echo "+----------------------------------------------------------------------------------------+"
    echo "|          NET_DELAYACCT Performance Comparison (K0 vs K2 vs K3)                          |"
    echo "+----------------------------------------------------------------------------------------+"
    printf "| %-26s | %8s | %8s | %8s | %8s | %8s | %8s | %8s | %-6s |\n" \
        "Metric" "K0" "K2" "K3" "K0→K2" "K0→K3" "K2→K3" "Thresh" "Verdict"
    echo "+----------------------------------------------------------------------------------------+"

    # 判定延迟指标格式：新格式（p50/p95/p99/p999/max）还是旧格式（tcp_latency_us）
    # 新格式优先；仅当新格式缺失且旧格式存在时回退到旧格式（向后兼容）
    local use_new_latency=false
    if [ -n "${values[K0|tcp_latency_p50_vals]:-}" ] || [ -n "${values[K2|tcp_latency_p50_vals]:-}" ]; then
        use_new_latency=true
    fi

    # ---- 对比表辅助 ----
    # 取某 mode 某 metric 的中位数；空则回显空串
    _med_of() {
        local m="$1" mt="$2"
        local v="${values[${m}|${mt}_vals]:-}"
        [ -z "$v" ] && { echo ""; return; }
        _median "$v"
    }
    # 取某 mode 某 metric 的原始值串；空则回显 "SKIP"
    _raw_of() {
        local m="$1" mt="$2"
        local v="${values[${m}|${mt}_vals]:-}"
        echo "${v:-SKIP}"
    }

    # 构建要显示的指标列表
    # 格式: "metric:unit:direction"
    #   direction: drop/increase/idle/abs
    # 条件性指标（cycles_per_packet, fixed_load_*）按数据存在性动态添加
    local table_metrics=()
    table_metrics+=("tcp_throughput_mbps:Mbps:drop")
    table_metrics+=("udp_pps:pps:drop")
    if [ "$use_new_latency" = true ]; then
        table_metrics+=("tcp_latency_p50:us:increase")
        table_metrics+=("tcp_latency_p95:us:increase")
        table_metrics+=("tcp_latency_p99:us:increase")
        table_metrics+=("tcp_latency_p999:us:increase")
        table_metrics+=("tcp_latency_max:us:increase")
    else
        table_metrics+=("tcp_latency_us:us:increase")
    fi
    table_metrics+=("cpu_util_pct:%:increase")
    table_metrics+=("idle_cpu_pct:%:idle")
    # cycles_per_packet：仅当至少一个 mode 有数据时显示
    if [ -n "${values[K0|cycles_per_packet_vals]:-}" ] || \
       [ -n "${values[K2|cycles_per_packet_vals]:-}" ] || \
       [ -n "${values[K3|cycles_per_packet_vals]:-}" ]; then
        table_metrics+=("cycles_per_packet:cycles:increase")
    fi
    # fixed_load_*：按 FIXED_LOAD_RATES 列表动态添加
    # metric 名格式: fixed_load_<rate>mbps_p50 / fixed_load_<rate>mbps_p99
    if [ -n "$FIXED_LOAD_RATES" ]; then
        local _rate
        for _rate in $FIXED_LOAD_RATES; do
            local _rate_label
            _rate_label=$(awk -v r="$_rate" 'BEGIN{printf "%d", r}')
            # 仅当至少一个 mode 有数据时显示
            if [ -n "${values[K0|fixed_load_${_rate_label}mbps_p50_vals]:-}" ] || \
               [ -n "${values[K2|fixed_load_${_rate_label}mbps_p50_vals]:-}" ] || \
               [ -n "${values[K3|fixed_load_${_rate_label}mbps_p50_vals]:-}" ]; then
                table_metrics+=("fixed_load_${_rate_label}mbps_p50:us:increase")
            fi
            if [ -n "${values[K0|fixed_load_${_rate_label}mbps_p99_vals]:-}" ] || \
               [ -n "${values[K2|fixed_load_${_rate_label}mbps_p99_vals]:-}" ] || \
               [ -n "${values[K3|fixed_load_${_rate_label}mbps_p99_vals]:-}" ]; then
                table_metrics+=("fixed_load_${_rate_label}mbps_p99:us:increase")
            fi
        done
    fi
    table_metrics+=("sock_objsize_bytes:bytes:abs")

    # ---- 打印对比表 + 收集摘要行 ----
    # 摘要行格式（tab 分隔 13 列）:
    # metric unit k0_raw k2_raw k3_raw k0_med k2_med k3_med delta_k0k2 delta_k0k3 delta_k2k3 threshold verdict
    local SUMMARY_ROWS=""
    local entry m_metric m_unit m_dir
    local k0_med k2_med k3_med k0_raw k2_raw k3_raw
    local d_k0k2 d_k0k3 d_k2k3
    local k3_disp

    for entry in "${table_metrics[@]}"; do
        m_metric="${entry%%:*}"
        local _rest="${entry#*:}"
        m_unit="${_rest%%:*}"
        m_dir="${_rest##*:}"

        k0_raw=$(_raw_of K0 "$m_metric")
        k2_raw=$(_raw_of K2 "$m_metric")
        k0_med=$(_med_of K0 "$m_metric")
        k2_med=$(_med_of K2 "$m_metric")

        if [ -n "$k3_file" ]; then
            k3_raw=$(_raw_of K3 "$m_metric")
            k3_med=$(_med_of K3 "$m_metric")
            k3_disp="${k3_med:--}"
        else
            k3_raw="-"
            k3_med=""
            k3_disp="-"
        fi

        # 计算 deltas
        if [ -n "$k0_med" ] && [ -n "$k2_med" ]; then
            if [ "$m_dir" = "abs" ]; then
                d_k0k2=$(calc_delta_abs "$k0_med" "$k2_med")
            else
                d_k0k2=$(calc_delta_pct "$m_metric" "$k0_med" "$k2_med")
            fi
        else
            d_k0k2="-"
        fi

        if [ -n "$k3_file" ] && [ -n "$k0_med" ] && [ -n "$k3_med" ]; then
            if [ "$m_dir" = "abs" ]; then
                d_k0k3=$(calc_delta_abs "$k0_med" "$k3_med")
            else
                d_k0k3=$(calc_delta_pct "$m_metric" "$k0_med" "$k3_med")
            fi
        else
            d_k0k3="-"
        fi

        if [ -n "$k3_file" ] && [ -n "$k2_med" ] && [ -n "$k3_med" ]; then
            if [ "$m_dir" = "abs" ]; then
                d_k2k3=$(calc_delta_abs "$k2_med" "$k3_med")
            else
                d_k2k3=$(calc_delta_pct "$m_metric" "$k2_med" "$k3_med")
            fi
        else
            d_k2k3="-"
        fi

        # 显示值（中位数为空则 SKIP）
        local k0_disp k2_disp
        k0_disp="${k0_med:-SKIP}"
        k2_disp="${k2_med:-SKIP}"

        # verdict 占位（实际 verdict 在下方按 K0→K2 计算；非 verdict 指标显示 info）
        printf "| %-26s | %8s | %8s | %8s | %8s | %8s | %8s | %8s | %-6s |\n" \
            "$m_metric" "$k0_disp" "$k2_disp" "$k3_disp" \
            "${d_k0k2:- -}" "${d_k0k3:- -}" "${d_k2k3:- -}" "-" "info"

        # 摘要行：threshold 和 verdict 在 verdict 段填充，这里先留空
        SUMMARY_ROWS+="${m_metric}	${m_unit}	${k0_raw}	${k2_raw}	${k3_raw}	${k0_disp}	${k2_disp}	${k3_disp}	${d_k0k2}	${d_k0k3}	${d_k2k3}	-	-"$'\n'
    done

    echo "+----------------------------------------------------------------------------------------+"
    echo ""
    echo "Pass criteria (initial, subject to calibration):"
    echo "  Perf-1 TCP throughput drop (K0→K2):  < 5%"
    echo "  Perf-2 UDP PPS drop (K0→K2):         < 15%"
    echo "  Perf-3 TCP latency P50 increase:     < 10% (relative)"
    echo "  Perf-3 TCP latency P99 increase:     < 10% (relative, new)"
    echo "  Perf-4 Per-socket memory:            <= 192 bytes (slab-aligned, raw struct ~72B)"
    echo "  Perf-5 CPU util increase (K0→K2):    < 10% (relative)"
    echo "  Perf-6 Idle CPU K2 vs K0 diff:       < 2% (almost zero overhead)"
    echo ""

    # ---- 自动判定（三态：PASS / FAIL / INVALID）----
    # verdict 基于 K0→K2 为主判定（与现有 ON/OFF 对比行为一致）
    # net_delayacct 是加开销工具，K2 合法优于 K0 不可能；若 K2 反超 K0
    # （degradation<0）说明测量被噪声主导 → INVALID（非 FAIL，避免误报回归方向）。
    # degradation 统一约定：正值=K2 更差（预期方向），负值=K2 更优（噪声）。
    echo "Verdict (K0 → K2 primary):"
    local verdict_pass=0 verdict_fail=0 verdict_invalid=0 verdict_skip=0 status
    local v_m v_t v_dir v_unit v_k0 v_k2 v_k0m v_k2m v_drop v_delta_abs

    # Perf-1/2 吞吐与 PPS：degradation = (K0-K2)/K0*100，阈值 5% / 15%
    for v_entry in "tcp_throughput_mbps:5:drop:Mbps" "udp_pps:15:drop:pps"; do
        IFS=':' read -r v_m v_t v_dir v_unit <<< "$v_entry"
        v_k0="${values[K0|${v_m}_vals]:-}"; v_k2="${values[K2|${v_m}_vals]:-}"
        if [ -n "$v_k0" ] && [ -n "$v_k2" ]; then
            v_k0m=$(_median "$v_k0"); v_k2m=$(_median "$v_k2")
            v_drop=$(awk "BEGIN {printf \"%.1f\", (${v_k0m}-${v_k2m})/${v_k0m}*100}")
            v_delta_abs=$(awk "BEGIN {printf \"%.2f\", ${v_k0m}-${v_k2m}}")
            status=$(_verdict3 "$v_drop" "$v_t")
            case "$status" in
                PASS)    echo "  ${GREEN}PASS${NC} $v_m: drop ${v_drop}% <= ${v_t}% threshold"; verdict_pass=$((verdict_pass+1));;
                FAIL)    echo "  ${RED}FAIL${NC} $v_m: drop ${v_drop}% > ${v_t}% threshold"; verdict_fail=$((verdict_fail+1));;
                INVALID) echo "  ${YELLOW}INVALID${NC} $v_m: K2>K0 by $(awk -v d="${v_drop}" 'BEGIN{printf "%.1f", (d<0?-d:d)}')% (noise-dominated)"; verdict_invalid=$((verdict_invalid+1));;
            esac
        else
            echo "  ${YELLOW}SKIP${NC} $v_m: no data"
            verdict_skip=$((verdict_skip+1))
        fi
    done

    # Perf-3 TCP 延迟：阈值 10%
    # 新格式：p50 和 p99 分别判定；旧格式：tcp_latency_us 单一判定
    if [ "$use_new_latency" = true ]; then
        # P50 和 P99: degradation = (K2-K0)/K0*100，阈值 10%
        for v_entry in "tcp_latency_p50:10" "tcp_latency_p99:10"; do
            IFS=':' read -r v_m v_t <<< "$v_entry"
            v_k0="${values[K0|${v_m}_vals]:-}"; v_k2="${values[K2|${v_m}_vals]:-}"
            if [ -n "$v_k0" ] && [ -n "$v_k2" ]; then
                v_k0m=$(_median "$v_k0"); v_k2m=$(_median "$v_k2")
                v_drop=$(awk "BEGIN {printf \"%.1f\", (${v_k2m}-${v_k0m})/${v_k0m}*100}")
                v_delta_abs=$(awk "BEGIN {printf \"%.2f\", ${v_k2m}-${v_k0m}}")
                status=$(_verdict3 "$v_drop" "$v_t")
                case "$status" in
                    PASS)    echo "  ${GREEN}PASS${NC} $v_m: +${v_drop}% <= ${v_t}% threshold"; verdict_pass=$((verdict_pass+1));;
                    FAIL)    echo "  ${RED}FAIL${NC} $v_m: +${v_drop}% > ${v_t}% threshold"; verdict_fail=$((verdict_fail+1));;
                    INVALID) echo "  ${YELLOW}INVALID${NC} $v_m: K2<K0 (noise-dominated)"; verdict_invalid=$((verdict_invalid+1));;
                esac
            else
                echo "  ${YELLOW}SKIP${NC} $v_m: no data"
                verdict_skip=$((verdict_skip+1))
            fi
        done
    else
        # 旧格式：tcp_latency_us（向后兼容）
        v_m="tcp_latency_us"; v_t=10
        v_k0="${values[K0|${v_m}_vals]:-}"; v_k2="${values[K2|${v_m}_vals]:-}"
        if [ -n "$v_k0" ] && [ -n "$v_k2" ]; then
            v_k0m=$(_median "$v_k0"); v_k2m=$(_median "$v_k2")
            v_drop=$(awk "BEGIN {printf \"%.1f\", (${v_k2m}-${v_k0m})/${v_k0m}*100}")
            v_delta_abs=$(awk "BEGIN {printf \"%.2f\", ${v_k2m}-${v_k0m}}")
            status=$(_verdict3 "$v_drop" "$v_t")
            case "$status" in
                PASS)    echo "  ${GREEN}PASS${NC} $v_m: +${v_drop}% <= 10% threshold"; verdict_pass=$((verdict_pass+1));;
                FAIL)    echo "  ${RED}FAIL${NC} $v_m: +${v_drop}% > 10% threshold"; verdict_fail=$((verdict_fail+1));;
                INVALID) echo "  ${YELLOW}INVALID${NC} $v_m: K2<K0 (noise-dominated)"; verdict_invalid=$((verdict_invalid+1));;
            esac
        else
            echo "  ${YELLOW}SKIP${NC} $v_m: no data"
            verdict_skip=$((verdict_skip+1))
        fi
    fi

    # Perf-5 CPU 利用率：degradation = (K2-K0)/K0*100 (相对 %)，阈值 10%
    v_m="cpu_util_pct"; v_t=10
    v_k0="${values[K0|${v_m}_vals]:-}"; v_k2="${values[K2|${v_m}_vals]:-}"
    if [ -n "$v_k0" ] && [ -n "$v_k2" ]; then
        v_k0m=$(_median "$v_k0"); v_k2m=$(_median "$v_k2")
        v_drop=$(awk "BEGIN {printf \"%.1f\", (${v_k2m}-${v_k0m})/${v_k0m}*100}")
        v_delta_abs=$(awk "BEGIN {printf \"%.2f\", ${v_k2m}-${v_k0m}}")
        status=$(_verdict3 "$v_drop" "$v_t")
        case "$status" in
            PASS)    echo "  ${GREEN}PASS${NC} $v_m: +${v_drop}% <= 10% threshold"; verdict_pass=$((verdict_pass+1));;
            FAIL)    echo "  ${RED}FAIL${NC} $v_m: +${v_drop}% > 10% threshold"; verdict_fail=$((verdict_fail+1));;
            INVALID) echo "  ${YELLOW}INVALID${NC} $v_m: K2<K0 (noise-dominated)"; verdict_invalid=$((verdict_invalid+1));;
        esac
    else
        echo "  ${YELLOW}SKIP${NC} $v_m: no data"
        verdict_skip=$((verdict_skip+1))
    fi

    # Perf-6 Idle CPU：K2 vs K0 差异 < 2%（几乎零开销）
    # 使用绝对值判定（|delta| < 2% = PASS），不设 INVALID
    # 理由：idle_cpu 语义在 guest 实现中可能存在歧义（变量名 vs 公式），
    # 绝对值判定方向无关，更稳健。degradation 仍按 (K2-K0)/K0*100 计算。
    v_m="idle_cpu_pct"; v_t=2
    v_k0="${values[K0|${v_m}_vals]:-}"; v_k2="${values[K2|${v_m}_vals]:-}"
    if [ -n "$v_k0" ] && [ -n "$v_k2" ]; then
        v_k0m=$(_median "$v_k0"); v_k2m=$(_median "$v_k2")
        # delta = (K2 - K0) / K0 * 100（按需求文档方向：正值=idle增加=好事）
        v_drop=$(awk "BEGIN {printf \"%.1f\", (${v_k2m}-${v_k0m})/${v_k0m}*100}")
        # 绝对值用于 verdict
        local v_abs_drop
        v_abs_drop=$(awk -v d="$v_drop" 'BEGIN {printf "%.1f", (d<0?-d:d)}')
        if awk "BEGIN {exit !(${v_abs_drop} > ${v_t})}"; then
            status="FAIL"
            echo "  ${RED}FAIL${NC} $v_m: |${v_drop}%| > ${v_t}% threshold (idle overhead too high)"
            verdict_fail=$((verdict_fail+1))
        else
            status="PASS"
            echo "  ${GREEN}PASS${NC} $v_m: |${v_drop}%| <= ${v_t}% threshold (almost zero idle overhead)"
            verdict_pass=$((verdict_pass+1))
        fi
    else
        echo "  ${YELLOW}SKIP${NC} $v_m: no data"
        verdict_skip=$((verdict_skip+1))
    fi

    # Perf-4 每 socket 内存：degradation = K2-K0 (bytes)，阈值 192
    # 阈值 192 = 72(struct net_delayacct) + 56(SLAB_HWCACHE_ALIGN 64B 对齐填充) + 64(余量)
    # /proc/slabinfo 第 4 列是 s->size（含 64 字节缓存行对齐），非 s->object_size（原始 struct）
    # TCP slab 用 SLAB_HWCACHE_ALIGN（tcp.c kmem_cache_create），ON struct 增加 72B 后
    # 跨 64B 边界 → 对齐填充 56B → slab delta 128B。原始 struct 开销仅 72B（<= 80 理论阈值）。
    v_m="sock_objsize_bytes"; v_t=192
    local k0_sock k2_sock k3_sock
    # tr -d '\r': QEMU 串口输出为 \r\n，提取的值末尾带 \r 会导致
    # grep -qE '^[0-9]+$' 失败，内存 delta 误显示为 "-"
    k0_sock=$(grep "^PERF: sock_objsize_bytes_run1=" "$k0_file" | head -1 | cut -d= -f2 | tr -d '\r')
    k2_sock=$(grep "^PERF: sock_objsize_bytes_run1=" "$k2_file" | head -1 | cut -d= -f2 | tr -d '\r')
    if [ -n "$k3_file" ]; then
        k3_sock=$(grep "^PERF: sock_objsize_bytes_run1=" "$k3_file" | head -1 | cut -d= -f2 | tr -d '\r')
    fi
    if [ -n "$k0_sock" ] && [ -n "$k2_sock" ] && \
       echo "$k0_sock" | grep -qE '^[0-9]+$' && echo "$k2_sock" | grep -qE '^[0-9]+$'; then
        v_drop=$((k2_sock - k0_sock))
        status=$(_verdict3 "$v_drop" "$v_t")
        case "$status" in
            PASS)    echo "  ${GREEN}PASS${NC} sock_objsize: +${v_drop} bytes <= ${v_t} threshold (raw struct ~72B + slab align)"; verdict_pass=$((verdict_pass+1));;
            FAIL)    echo "  ${RED}FAIL${NC} sock_objsize: +${v_drop} bytes > ${v_t} threshold"; verdict_fail=$((verdict_fail+1));;
            INVALID) echo "  ${YELLOW}INVALID${NC} sock_objsize: K2<K0 (noise-dominated)"; verdict_invalid=$((verdict_invalid+1));;
        esac
    else
        echo "  ${YELLOW}SKIP${NC} sock_objsize: no data"
        verdict_skip=$((verdict_skip+1))
    fi

    # ---- 信息性指标（K0→K3 / K2→K3，不影响 verdict）----
    if [ -n "$k3_file" ]; then
        echo ""
        echo "Info (K3 deltas, non-blocking):"
        # 简要输出 K0→K3 的关键 delta
        for v_m in tcp_throughput_mbps udp_pps tcp_latency_p50 tcp_latency_p99 cpu_util_pct; do
            v_k0="${values[K0|${v_m}_vals]:-}"
            v_k3="${values[K3|${v_m}_vals]:-}"
            if [ -n "$v_k0" ] && [ -n "$v_k3" ]; then
                v_k0m=$(_median "$v_k0"); v_k3m=$(_median "$v_k3")
                local _d_k0k3
                _d_k0k3=$(calc_delta_pct "$v_m" "$v_k0m" "$v_k3m")
                echo "  $v_m: K0→K3 = $_d_k0k3"
            fi
        done
    fi

    # ---- 总结论（优先级：FAIL > INVALID(视strict) > NO-DATA > PASS）----
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
                # INVALID > 50%（基于已评估指标数 pass+fail+invalid）视为数据不可信，exit 2
                local evaluated=$((verdict_pass + verdict_fail + verdict_invalid))
                if [ "$evaluated" -gt 0 ] && [ "$verdict_invalid" * 2 -gt "$evaluated" ]; then
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
    echo "Full logs: $LOG_DIR/perf-{K0,K2,K3}-${TIMESTAMP}.log"

    # 生成结构化摘要报告（Markdown + CSV）
    write_summary_files "$SUMMARY_ROWS" "$k0_mode" "$k2_mode" "${k3_mode:--}"
}

# ============================================================================
# Main
# ============================================================================

SKIP_BUILD=false

# 参数解析
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build)
            SKIP_BUILD=true
            ;;
        --with-k3)
            WITH_K3=true
            ;;
        --test-duration=*)
            TEST_DURATION="${1#--test-duration=}"
            ;;
        --warmup=*)
            WARMUP_DURATION="${1#--warmup=}"
            ;;
        --enable-cycles)
            ENABLE_CYCLES=1
            ;;
        --fixed-load-rates=*)
            FIXED_LOAD_RATES="${1#--fixed-load-rates=}"
            ;;
        --strict)
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
Usage: $0 [OPTIONS]

模式说明:
  K0: OFF 内核（CONFIG_NET_DELAYACCT=n）— 基线
  K2: ON 内核，检测开启，无主动查询（纯插桩开销）
  K3: ON 内核，检测开启 + 主动查询（导出开销，需 get_sockdelays）

默认运行 K0 vs K2；--with-k3 额外运行 K3。

Options:
  --skip-build              复用已有 bzImage-on/off（不重新构建内核）
  --with-k3                 额外运行 K3 模式（ON 内核 + 主动查询）
  --test-duration=N         iperf3 测试时长（秒，默认 10）
  --warmup=N                iperf3 预热时长（秒，默认 3）
  --enable-cycles           启用 cycles/packet 采集（需 perf 二进制）
  --fixed-load-rates="R1 R2 R3"
                            固定负载速率列表（Mbps，空格分隔）
  --strict                  INVALID 视作 FAIL 阻断（等同 --strict=fail）
  --strict=warn             INVALID 告警不阻断，但 >50% 时 exit 2（默认）
  --strict=fail             INVALID 阻断 exit 1（CI 严格回归）
  --bzimage-on=PATH         指定 ON 内核路径（CI 中 artifact 下载后用）
  --bzimage-off=PATH        指定 OFF 内核路径
  -h, --help                显示此帮助

Exit codes:
  0 = PASS 或 warn 通过
  1 = FAIL（strict=fail 模式）
  2 = 数据不可信（全 SKIP 或 INVALID > 50%）

Examples:
  # 默认：K0 vs K2
  $0 --skip-build --strict=warn

  # 三版本对比：K0 vs K2 vs K3
  $0 --skip-build --with-k3

  # 启用 cycles/packet 和固定负载测试
  $0 --skip-build --enable-cycles --fixed-load-rates="300 500"
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
    echo "Modes: K0 (OFF) + K2 (ON, no query)$([ "$WITH_K3" = true ] && echo " + K3 (ON, with query)")"
    echo "Test duration: ${TEST_DURATION}s (warmup: ${WARMUP_DURATION}s)"
    echo "Enable cycles: $ENABLE_CYCLES"
    echo "Fixed load rates: ${FIXED_LOAD_RATES:-none}"
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

    # Step 4: QEMU 运行各模式
    # K0: OFF 内核（基线）
    run_perf_in_qemu "$BZIMAGE_OFF" "K0" "K0"
    echo ""
    # K2: ON 内核，检测开启，无查询
    run_perf_in_qemu "$BZIMAGE_ON" "K2" "K2"
    echo ""
    # K3: ON 内核，检测开启 + 主动查询（可选）
    if [ "$WITH_K3" = true ]; then
        run_perf_in_qemu "$BZIMAGE_ON" "K3" "K3"
        echo ""
    fi

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

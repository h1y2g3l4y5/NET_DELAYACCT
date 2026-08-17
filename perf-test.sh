#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# perf-test.sh — NET_DELAYACCT 性能基准测试编排脚本（host 侧）
#
# 对比 K0/K2/K3 三种模式的性能开销：
#   K0: OFF 内核（CONFIG_NET_DELAYACCT=n）— 基线，无插桩开销
#   K2: ON 内核，检测开启，无主动查询（纯插桩开销）
#   K3: ON 内核，检测开启 + dump 导出计时（导出开销，需 get_sockdelays）
#
# 20260816 方案重建（iperf3 速率驱动 → 固定工作量微基准）：
# 旧方案信噪比倒挂（信号 ~1% < 噪声 5-50%，见 run-perf-tests.sh 头注释），
# 测得 delta 无法归因。新方案：
#   Perf-A bench-net：固定循环微基准（UDP64 + TCP 1KB rw，绑核+FIFO，
#           -smp 1），ns/op 差值 = 插桩开销，分辨率 ~0.1%
#   Perf-B ftrace 对账（ON 内核，info）：hooks/op × 单次耗时 与 A 交叉验证
#   Perf-C slab objsize（确定性）
#   Perf-D dump per-call 计时（K3）
# 旧 iperf3 指标（吞吐/PPS/延迟百分位/CPU）全部移除。
#
# 流程：
#   1. 构建 ON 内核 (CONFIG_NET_DELAYACCT=y) → bzImage-on（K2/K3 共用）
#   2. 构建 OFF 内核 (CONFIG_NET_DELAYACCT=n) → bzImage-off（K0/K0B）
#   3. 创建 perf initramfs（bench-net 静态编译 + run-perf-tests.sh + get_sockdelays）
#   4. QEMU(-smp 1) 启动 K0 → K2 → [K3] → K0B 收集性能数据
#   5. 对比并生成报告（K0 为基线，K0→K2 为主判定；K0 vs K0B = 噪声地板）
#
# 用法: ./perf-test.sh [--skip-build] [--with-k3] [--runs=5] ...
#
# 注意: 需写入内核源码树 (../linux-6.6)，须在非沙箱环境运行

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
LINUX_SRC="${LINUX_SRC:-$PROJECT_DIR/../linux-6.6}"
LOG_DIR="$PROJECT_DIR/tests/reports/perf"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 结构化摘要报告文件（Markdown + CSV）
SUMMARY_MD="$LOG_DIR/perf-summary-${TIMESTAMP}.md"
SUMMARY_CSV="$LOG_DIR/perf-summary-${TIMESTAMP}.csv"

QEMU_MEMORY="${QEMU_MEMORY:-512M}"
# 微基准矩阵单次 QEMU 时长（-smp 1）：boot ~10s + bench 10×~1s + ftrace
# 对账 ~15s + dump ~5s ≈ 50s（KVM）。
# KVM 240s / TCG 600s：TCG boot ~120s + bench 自动校准（每轮仍 ~1s）
#   + ftrace buffer 操作慢，600s 含余量
QEMU_TIMEOUT_KVM="${QEMU_TIMEOUT_KVM:-240}"
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

# 是否额外运行 K3 模式（附加 dump 导出计时）
WITH_K3=false

# bench-net 每项测试轮数（每轮自动校准 ~1s，中位数抗噪）
PERF_RUNS="${PERF_RUNS:-5}"

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

    # bench-net（固定工作量微基准，20260816 方案重建的核心测量器）
    # 静态编译进 initramfs，无运行时库依赖；缺失则 perf 测试无法运行
    if command -v gcc >/dev/null 2>&1; then
        if gcc -O2 -static -o "$INITRD_DIR/bin/bench-net" \
                "$PROJECT_DIR/ci/qemu/bench-net.c" 2>/dev/null; then
            echo "Packed bench-net (microbenchmark)"
        else
            # 静态链接失败（缺 glibc-static）时退化为动态链接 + 拷贝依赖
            if gcc -O2 -o "$INITRD_DIR/bin/bench-net" \
                    "$PROJECT_DIR/ci/qemu/bench-net.c"; then
                copy_binary_with_libs "$INITRD_DIR/bin/bench-net" "$INITRD_DIR"
                echo "Packed bench-net (dynamic)"
            else
                echo "${RED}bench-net build failed — perf tests cannot run${NC}"
                exit 1
            fi
        fi
    else
        echo "${RED}gcc not found — bench-net cannot be built${NC}"
        exit 1
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
    # nokaslr：本地旧 .config 增量构建的内核会卡在 KASLR 阶段（v6.5.2 坑1），
    # CI fresh clone 构建的内核无此问题；KASLR 只影响启动，禁用不改变运行时基准
    local append_str="console=ttyS0,115200n8 rdinit=/init nokaslr"
    append_str+=" query_mode=${query_mode}"
    append_str+=" perf_runs=${PERF_RUNS}"

    # QEMU 串口输出直接落文件（-serial file:），进程 stderr 单独捕获：
    # 用户终端环境下 -nographic(stdio 多路复用) 与 e1000 会致 QEMU 进程级
    # 卡死（0 串口输出），CI systemd 环境正常；-display none + -serial file:
    # 两种环境均稳定（v6.5.2 坑2，logs/work/2026-08-16/TASK-01）。
    # 启动报错（KVM 不可用等）走 stderr → qemu_err，串口数据走 qemu_out。
    local qemu_err="/tmp/perf-qemu-${mode_label}-$$.err"

    local qemu_common_args=(
        -m "$QEMU_MEMORY"
        # -smp 1（20260816 方案重建）：单 vCPU 消除 vCPU 间迁移/调度相位噪声，
        # bench-net 单进程绑 CPU0 + SCHED_FIFO，配合固定循环次数，
        # K0/K2 的 ns/op 差值即插桩开销（分辨率 ~0.1%）。
        # TCG 回退无需 -smp 2 加速：bench 自动校准每轮 ~1s，矩阵总时长可控
        -smp 1
        -kernel "$kernel_img"
        -initrd "$PERF_INITRD"
        -append "$append_str"
        -display none
        -serial "file:$qemu_out"
        -no-reboot
        # 微基准仅用 loopback，无 NIC 需求；-nic none 阻止 QEMU 默认建 e1000
        # （省去 e1000 探测，且规避用户终端环境的 e1000 卡死坑）
        -nic none
    )

    local qemu_rc=0

    # 先尝试 KVM
    echo "Trying KVM (timeout=${QEMU_TIMEOUT_KVM}s)..."
    set +e
    timeout "$QEMU_TIMEOUT_KVM" qemu-system-x86_64 \
        -machine q35,accel=kvm,smm=off \
        -cpu host,-sgx \
        "${qemu_common_args[@]}" 2> "$qemu_err"
    qemu_rc=$?
    set -e

    # KVM 失败则回退 TCG
    # 报错在 stderr（qemu_err）；串口文件（qemu_out）兜底再查一次：
    #   "Could not access KVM" (模块不可访问) / "failed to initialize kvm" (初始化失败)
    #   / "/dev/kvm" / "Permission denied"
    if [ "$qemu_rc" -ne 0 ] && { grep -Eq '(Could not access KVM|failed to initialize kvm|/dev/kvm|Permission denied)' "$qemu_err" 2>/dev/null || grep -Eq '(Could not access KVM|failed to initialize kvm|/dev/kvm|Permission denied)' "$qemu_out" 2>/dev/null; }; then
        echo "KVM unavailable, falling back to TCG (timeout=${QEMU_TIMEOUT_TCG}s)..."
        set +e
        timeout "$QEMU_TIMEOUT_TCG" qemu-system-x86_64 \
            -machine q35,accel=tcg,smm=off \
            -cpu qemu64,-sgx \
            "${qemu_common_args[@]}" 2> "$qemu_err"
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

    # 诊断输出：PERF 行计数 +（无数据或超时时）QEMU 末尾日志
    # 目的：CI 失败时无需下载 artifact 即可在 job 日志里定位根因
    # （rc=124=timeout / guest panic / init 失败 / run-perf-tests 异常）
    local perf_n
    # grep -c 无匹配时打印 "0" 并退出 1：用 || true 屏蔽退出码，避免 || echo 0 产生 "0\n0"
    perf_n=$(grep -c "^PERF:" "$result_file" 2>/dev/null || true)
    [ -z "$perf_n" ] && perf_n=0
    echo "PERF lines found: $perf_n"
    if [ "$perf_n" -eq 0 ] || [ "$qemu_rc" -ne 0 ]; then
        echo "${YELLOW}--- QEMU output tail (last 30 lines) for diagnosis ---${NC}"
        tail -30 "$result_file" 2>/dev/null | sed 's/^/    /'
        # QEMU 进程级错误（KVM 初始化失败/参数错误等走 stderr，串口文件里没有）
        if [ -s "$qemu_err" ]; then
            echo "${YELLOW}--- QEMU stderr (first 10 lines) ---${NC}"
            head -10 "$qemu_err" | sed 's/^/    /'
        fi
        echo "${YELLOW}--- end tail ---${NC}"
    fi
    rm -f "$qemu_err"

    # 输出 PERF: 行
    grep "^PERF:" "$result_file" || echo "${YELLOW}No PERF: lines found in output${NC}"
}

# ============================================================================
# Step 5: 解析并对比结果
# ============================================================================

# 解析 PERF: *_runN= 行，输出 mode|metric=value
# $1 = 文件, $2 = 模式前缀 (K0/K2/K3/K0B)
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
# delta 方向（正值语义）：bench ns/op 等 latency 类指标
#   (Kx - K0) / K0 * 100（正值 = 耗时增加，Kx 更差）
# sock_objsize 用 calc_delta_abs（字节差），不调本函数
calc_delta_pct() {
    local metric="$1" base="$2" comp="$3"
    # metric 参数保留以兼容调用方签名；方向统一为 (Kx - K0)/K0（正值=更差）
    awk "BEGIN {if(${base}+0>0) printf \"%+.1f%%\", (${comp}-${base})/${base}*100; else print \"N/A\"}"
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
        echo "- **bench 轮数**: ${PERF_RUNS}（每轮自动校准 ~1s）"
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
        echo "- bench ns/op: (Kx - K0) / K0 * 100（正值 = 每循环耗时增加，Kx 更差）"
        echo "- Socket 对象大小: Kx - K0（字节，正值 = 内存增加）"
        echo ""
        echo "## 判定说明"
        echo ""
        echo "- 主判定基于 K0→K2 的 Perf-A 微基准（bench_udp64 / bench_tcprw ns/op）"
        echo "- K2 < K0（负 delta）→ INVALID：加开销工具不可能反向提升，"
        echo "  负值说明测量被噪声主导，建议重跑"
        echo "- ftrace 对账为 info：Δns/op(实测) 应与 hooks/op × 单次 hook 耗时"
        echo "  数量级吻合，用于把微基准差值归因到 hook 开销"
        echo "- K3 dump_per_call_us 为 info：含 fork+exec 的全量导出 wall time"
        echo "  （空 socket 表口径）"
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
    # K0B（B5/B6 噪声地板）：同 OFF 内核在批次末尾再跑一遍，
    # K0(首) vs K0B(尾) 差值 = 时段漂移 + 测量噪声的合成下界
    local k0b_file=""
    [ -f "$LOG_DIR/perf-K0B-${TIMESTAMP}.log" ] && k0b_file="$LOG_DIR/perf-K0B-${TIMESTAMP}.log"

    if [ ! -f "$k0_file" ] || [ ! -f "$k2_file" ]; then
        echo "${RED}Missing result files (K0/K2)${NC}"
        PERF_EXIT=1
        return 1
    fi

    # 解析所有模式到 values 数组
    # 键格式: "${mode}|${metric}_vals"，值为空格分隔的多次运行结果
    declare -A values
    # 摘要表存储：按 metric 存各列，verdict 段回填 threshold/verdict 后统一生成摘要行
    declare -A SUM_UNIT SUM_RAW0 SUM_RAW2 SUM_RAW3 SUM_MED0 SUM_MED2 SUM_MED3
    declare -A SUM_D02 SUM_D03 SUM_D23 VERDICTS THRESHOLDS

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
        [ -n "$k0b_file" ] && parse_results "$k0b_file" K0B
    )

    # 模式检测（PERF: mode= 和 PERF: query_mode=）
    local k0_mode k2_mode k3_mode k0_qmode k2_qmode k3_qmode k0b_mode
    k0_mode=$(grep "^PERF: mode=" "$k0_file" | head -1 | cut -d= -f2 | tr -d '\r')
    k2_mode=$(grep "^PERF: mode=" "$k2_file" | head -1 | cut -d= -f2 | tr -d '\r')
    k0_qmode=$(grep "^PERF: query_mode=" "$k0_file" | head -1 | cut -d= -f2 | tr -d '\r')
    k2_qmode=$(grep "^PERF: query_mode=" "$k2_file" | head -1 | cut -d= -f2 | tr -d '\r')
    if [ -n "$k3_file" ]; then
        k3_mode=$(grep "^PERF: mode=" "$k3_file" | head -1 | cut -d= -f2 | tr -d '\r')
        k3_qmode=$(grep "^PERF: query_mode=" "$k3_file" | head -1 | cut -d= -f2 | tr -d '\r')
    fi
    if [ -n "$k0b_file" ]; then
        k0b_mode=$(grep "^PERF: mode=" "$k0b_file" | head -1 | cut -d= -f2 | tr -d '\r')
        if [ "$k0b_mode" != "OFF" ]; then
            echo "${YELLOW}WARNING: K0B kernel log reports mode='${k0b_mode}', expected 'OFF' (noise floor invalid)${NC}"
        fi
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

    # 对比表数据行在 verdict 段计算完成后再统一打印（表头/数据/表尾延后），
    # 以便回填真实的 Thresh/Verdict 列（此前硬编码 "-" / "info" 与 md/csv 不一致）。

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

    # 构建要显示的指标列表（20260816 方案重建后的指标集）
    # 格式: "metric:unit:direction"，direction: increase/abs
    #   bench_*：Perf-A 微基准，verdict 主判定（increase，K2>K0 = 更差）
    #   ftrace_*：Perf-B 对账，info（Δns/op ≈ hooks_per_op × hook_ns 的锚点）
    #   dump_*：Perf-D K3 导出计时，info
    #   sock_objsize：Perf-C slab，确定性判定
    local table_metrics=()
    table_metrics+=("bench_udp64_ns_per_op:ns/op:increase")
    table_metrics+=("bench_tcprw_ns_per_op:ns/op:increase")
    table_metrics+=("sock_objsize_bytes:bytes:abs")
    # ftrace 对账指标仅 ON 内核产出（K0/OFF 无符号），列存在即显示
    if [ -n "${values[K2|ftrace_hooks_per_op_vals]:-}" ] || \
       [ -n "${values[K3|ftrace_hooks_per_op_vals]:-}" ]; then
        table_metrics+=("ftrace_hooks_per_op:hooks:info")
    fi
    if [ -n "${values[K2|ftrace_hook_ns_p50_vals]:-}" ] || \
       [ -n "${values[K3|ftrace_hook_ns_p50_vals]:-}" ]; then
        table_metrics+=("ftrace_hook_ns_p50:ns:info")
    fi
    # K3 dump 计时（含 fork+exec 口径）
    if [ -n "${values[K3|dump_per_call_us_vals]:-}" ]; then
        table_metrics+=("dump_per_call_us:us:info")
    fi

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
        # 控制台行延后到 verdict 段后统一打印，此处只存摘要数组

        # 存入摘要数组：threshold/verdict 在 verdict 段回填，最后统一生成摘要行
        SUM_UNIT[$m_metric]="$m_unit"
        SUM_RAW0[$m_metric]="$k0_raw"
        SUM_RAW2[$m_metric]="$k2_raw"
        SUM_RAW3[$m_metric]="$k3_raw"
        SUM_MED0[$m_metric]="$k0_disp"
        SUM_MED2[$m_metric]="$k2_disp"
        SUM_MED3[$m_metric]="$k3_disp"
        SUM_D02[$m_metric]="$d_k0k2"
        SUM_D03[$m_metric]="$d_k0k3"
        SUM_D23[$m_metric]="$d_k2k3"
    done

    echo ""
    echo "Pass criteria (initial, subject to noise-floor calibration):"
    echo "  Perf-A bench UDP64 ns/op increase (K0→K2):  < 25%"
    echo "  Perf-A bench TCP rw ns/op increase (K0→K2):  < 25%"
    echo "  Perf-C Per-socket memory:                    <= 192 bytes (slab-aligned, raw struct ~72B)"
    echo "  (ftrace 对账: Δns/op ≈ hooks_per_op × hook_ns_p50，info 级不判定)"
    echo ""

    # ---- 自动判定（三态：PASS / FAIL / INVALID）----
    # verdict 基于 K0→K2 为主判定（与现有 ON/OFF 对比行为一致）
    # net_delayacct 是加开销工具，K2 合法优于 K0 不可能；若 K2 反超 K0
    # （degradation<0）说明测量被噪声主导 → INVALID（非 FAIL，避免误报回归方向）。
    # degradation 统一约定：正值=K2 更差（预期方向），负值=K2 更优（噪声）。
    echo "Verdict (K0 → K2 primary):"
    local verdict_pass=0 verdict_fail=0 verdict_invalid=0 verdict_skip=0 status
    local v_m v_t v_dir v_unit v_k0 v_k2 v_k0m v_k2m v_drop v_delta_abs

    # Perf-A 微基准：degradation = (K2-K0)/K0*100，阈值 25%（初始值）。
    # 理论 hook 开销在 64B 路径 ~5-20%（单次 hook ~50-150ns × 4 次 /
    # 单循环 2-5us）；阈值待 K0-vs-K0B 噪声地板数据积累后收紧
    for v_entry in "bench_udp64_ns_per_op:25" "bench_tcprw_ns_per_op:25"; do
        IFS=':' read -r v_m v_t <<< "$v_entry"
        THRESHOLDS[$v_m]="${v_t}%"
        v_k0="${values[K0|${v_m}_vals]:-}"; v_k2="${values[K2|${v_m}_vals]:-}"
        if [ -n "$v_k0" ] && [ -n "$v_k2" ]; then
            v_k0m=$(_median "$v_k0"); v_k2m=$(_median "$v_k2")
            v_drop=$(awk "BEGIN {printf \"%.1f\", (${v_k2m}-${v_k0m})/${v_k0m}*100}")
            v_delta_abs=$(awk "BEGIN {printf \"%.2f\", ${v_k2m}-${v_k0m}}")
            status=$(_verdict3 "$v_drop" "$v_t")
            case "$status" in
                PASS)    echo "  ${GREEN}PASS${NC} $v_m: +${v_drop}% (Δ${v_delta_abs} ns/op) <= ${v_t}% threshold"; verdict_pass=$((verdict_pass+1));;
                FAIL)    echo "  ${RED}FAIL${NC} $v_m: +${v_drop}% (Δ${v_delta_abs} ns/op) > ${v_t}% threshold"; verdict_fail=$((verdict_fail+1));;
                INVALID) echo "  ${YELLOW}INVALID${NC} $v_m: K2<K0 by $(awk -v d="${v_drop}" 'BEGIN{printf "%.1f", (d<0?-d:d)}')% (noise-dominated)"; verdict_invalid=$((verdict_invalid+1));;
            esac
        else
            status="SKIP"
            echo "  ${YELLOW}SKIP${NC} $v_m: no data"
            verdict_skip=$((verdict_skip+1))
        fi
        VERDICTS[$v_m]="$status"
    done

    # 旧 iperf3 指标（tcp_latency_* / cpu_per_gbps / idle_cpu_pct）随方案
    # 重建移除：其噪声地板（5-90%）远超信号（0.5-2%），判定无物理意义

    # Perf-B ftrace 对账（info，不参与 verdict）：
    #   Δns/op(实测) ≈ hooks_per_op × hook_ns_p50(单次)
    # 数量级吻合则微基准差值可归因到 hook，不吻合提示测量异常
    local ft_hooks ft_ns ft_delta b_delta
    ft_hooks="${values[K2|ftrace_hooks_per_op_run1_vals]:-}${values[K3|ftrace_hooks_per_op_run1_vals]:-}"
    ft_hooks=$(printf '%s' "$ft_hooks" | awk '{print $1}')
    ft_ns="${values[K2|ftrace_hook_ns_p50_run1_vals]:-}${values[K3|ftrace_hook_ns_p50_run1_vals]:-}"
    ft_ns=$(printf '%s' "$ft_ns" | awk '{print $1}')
    v_k0m=$(_med_of K0 bench_udp64_ns_per_op)
    v_k2m=$(_med_of K2 bench_udp64_ns_per_op)
    if [ -n "$ft_hooks" ] && [ -n "$ft_ns" ] && [ -n "$v_k0m" ] && [ -n "$v_k2m" ]; then
        ft_delta=$(awk -v h="$ft_hooks" -v n="$ft_ns" 'BEGIN {printf "%.0f", h * n}')
        b_delta=$(awk -v a="$v_k0m" -v b="$v_k2m" 'BEGIN {printf "%.0f", b - a}')
        echo ""
        echo "  ftrace cross-check (UDP64): measured Δ=${b_delta} ns/op, predicted ≈ hooks/op(${ft_hooks}) × ${ft_ns}ns = ${ft_delta} ns/op"
    fi

    # Perf-4 每 socket 内存：degradation = K2-K0 (bytes)，阈值 192
    # 阈值 192 = 72(struct net_delayacct) + 56(SLAB_HWCACHE_ALIGN 64B 对齐填充) + 64(余量)
    # /proc/slabinfo 第 4 列是 s->size（含 64 字节缓存行对齐），非 s->object_size（原始 struct）
    # TCP slab 用 SLAB_HWCACHE_ALIGN（tcp.c kmem_cache_create），ON struct 增加 72B 后
    # 跨 64B 边界 → 对齐填充 56B → slab delta 128B。原始 struct 开销仅 72B（<= 80 理论阈值）。
    v_m="sock_objsize_bytes"; v_t=192
    THRESHOLDS[$v_m]="${v_t}B"
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
        status="SKIP"
        echo "  ${YELLOW}SKIP${NC} sock_objsize: no data"
        verdict_skip=$((verdict_skip+1))
    fi
    VERDICTS[$v_m]="$status"

    # ---- 信息性指标（K0→K3 / K2→K3，不影响 verdict）----
    # 新方案 K3 的导出开销直接由 Perf-D dump_per_call_us 量化，
    # 对比表中已含 K0→K3 / K2→K3 列，此处不再重复输出

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

    # ---- 打印对比表（verdict 计算完成后，回填真实 Thresh/Verdict）----
    echo ""
    echo "+----------------------------------------------------------------------------------------+"
    echo "|          NET_DELAYACCT Performance Comparison (K0 vs K2 vs K3)                          |"
    echo "+----------------------------------------------------------------------------------------+"
    printf "| %-26s | %8s | %8s | %8s | %8s | %8s | %8s | %8s | %-6s |\n" \
        "Metric" "K0" "K2" "K3" "K0→K2" "K0→K3" "K2→K3" "Thresh" "Verdict"
    echo "+----------------------------------------------------------------------------------------+"
    local entry _t_metric
    for entry in "${table_metrics[@]}"; do
        _t_metric="${entry%%:*}"
        printf "| %-26s | %8s | %8s | %8s | %8s | %8s | %8s | %8s | %-6s |\n" \
            "$_t_metric" "${SUM_MED0[$_t_metric]:-SKIP}" "${SUM_MED2[$_t_metric]:-SKIP}" \
            "${SUM_MED3[$_t_metric]:--}" \
            "${SUM_D02[$_t_metric]:- -}" "${SUM_D03[$_t_metric]:- -}" "${SUM_D23[$_t_metric]:- -}" \
            "${THRESHOLDS[$_t_metric]:--}" "${VERDICTS[$_t_metric]:-info}"
    done
    echo "+----------------------------------------------------------------------------------------+"
    echo ""

    # 生成结构化摘要报告（Markdown + CSV）
    # 回填 threshold/verdict：按 table_metrics 顺序从存储数组重组摘要行
    SUMMARY_ROWS=""
    for entry in "${table_metrics[@]}"; do
        m_metric="${entry%%:*}"
        SUMMARY_ROWS+="${m_metric}	${SUM_UNIT[$m_metric]}	${SUM_RAW0[$m_metric]}	${SUM_RAW2[$m_metric]}	${SUM_RAW3[$m_metric]}	${SUM_MED0[$m_metric]}	${SUM_MED2[$m_metric]}	${SUM_MED3[$m_metric]}	${SUM_D02[$m_metric]}	${SUM_D03[$m_metric]}	${SUM_D23[$m_metric]}	${THRESHOLDS[$m_metric]:--}	${VERDICTS[$m_metric]:-info}"$'\n'
    done
    write_summary_files "$SUMMARY_ROWS" "$k0_mode" "$k2_mode" "${k3_mode:--}"

    # ---- 噪声地板节（B5/B6）：K0(首) vs K0B(尾)，同 OFF 内核 ----
    # |Δ%| = 宿主机时段漂移 + 测量固有噪声的合成下界。floor >= 静态阈值的
    # 指标标 NOISY（该环境下判定不可信，需放宽阈值/加轮数/避开忙时段）。
    # 数据积累多轮后再据此校准静态阈值（本节只报告，不改变判定逻辑）。
    if [ -n "$k0b_file" ]; then
        echo "+----------------------------------------------------------------------------------------+"
        echo "| Noise Floor (K0 first vs K0B last, same OFF kernel)                                     |"
        echo "+----------------------------------------------------------------------------------------+"
        printf "| %-26s | %10s | %10s | %10s | %8s | %-6s |\n" \
            "Metric" "K0(median)" "K0B(median)" "|delta|%" "Thresh" "Usable"
        echo "+----------------------------------------------------------------------------------------+"
        local nf_metric nf_k0m nf_k0bm nf_floor nf_thr nf_ok
        local floor_md="" floor_csv=""
        # 静态阈值须与 verdict 段一致（sock_objsize 确定性无噪声，不在此列）
        for nf_metric in bench_udp64_ns_per_op bench_tcprw_ns_per_op; do
            nf_thr=25
            nf_k0m="${SUM_MED0[$nf_metric]:-}"
            nf_k0bm=$(_median "${values[K0B|${nf_metric}_vals]:-}")
            if [ -n "$nf_k0m" ] && [ -n "$nf_k0bm" ] && \
               awk "BEGIN {exit !(${nf_k0m} > 0)}"; then
                nf_floor=$(awk -v a="$nf_k0m" -v b="$nf_k0bm" \
                    'BEGIN {d=(b-a); if (d<0) d=-d; printf "%.1f", d/a*100}')
                nf_ok=$(awk -v f="$nf_floor" -v t="$nf_thr" \
                    'BEGIN {print (f < t) ? "YES" : "NOISY"}')
            else
                nf_floor="-"; nf_ok="-"
            fi
            printf "| %-26s | %10s | %10s | %10s | %8s | %-6s |\n" \
                "$nf_metric" "${nf_k0m:--}" "${nf_k0bm:--}" "${nf_floor}" "${nf_thr}%" "${nf_ok}"
            floor_md+="| ${nf_metric} | ${nf_k0m:--} | ${nf_k0bm:--} | ${nf_floor}% | ${nf_thr}% | ${nf_ok} |"$'\n'
            floor_csv+="${nf_metric}__noise_floor	${SUM_UNIT[$nf_metric]:--}	${SUM_RAW0[$nf_metric]:--}	-	-	${nf_k0m:--}	${nf_k0bm:--}	-	${nf_floor}%	-	-	${nf_thr}%	FLOOR"$'\n'
        done
        echo "+----------------------------------------------------------------------------------------+"
        echo "Note: NOISY = |K0-K0B| >= threshold -> verdict for this metric is noise-dominated."
        echo ""

        # 追加到 Markdown / CSV 摘要
        local summary_md_path="$LOG_DIR/perf-summary-${TIMESTAMP}.md"
        local summary_csv_path="$LOG_DIR/perf-summary-${TIMESTAMP}.csv"
        {
            echo ""
            echo "## Noise Floor (K0 first vs K0B last, same OFF kernel)"
            echo ""
            echo "| Metric | K0(median) | K0B(median) | floor(\\|delta\\|%) | Thresh | Usable |"
            echo "|---|---|---|---|---|---|"
            printf '%s' "$floor_md"
            echo ""
            echo "NOISY = verdict noise-dominated in this environment (threshold below floor)."
        } >> "$summary_md_path"
        printf '%s' "$floor_csv" >> "$summary_csv_path"
    fi
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
        --runs=*)
            PERF_RUNS="${1#--runs=}"
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
  --runs=N                  bench-net 每项测试轮数（默认 5，每轮自动校准 ~1s）
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
    echo "Bench runs per metric: $PERF_RUNS (auto-calibrated ~1s each)"
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
    # K0B: 同 OFF 内核再跑一遍（批次末尾）。B5/B6：K0(首) vs K0B(尾) 提供
    # 噪声地板（时段漂移 + 测量噪声下界），见 compare_and_report 的 Noise Floor 节
    run_perf_in_qemu "$BZIMAGE_OFF" "K0B" "K0"
    echo ""

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

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# perf-test.sh — NET_DELAYACCT 性能基准测试编排脚本（host 侧）
#
# 对比 K0/K3 两种模式的性能开销：
#   K0: OFF 内核（CONFIG_NET_DELAYACCT=n）— 基线，无插桩开销
#   K3: ON 内核，检测开启 + dump 导出计时（最坏情形口径，需 get_sockdelays）
#
# 20260817 K2 模式移除：K2 与 K3 本就是同一个 bzImage-on，且 guest 侧
# 执行顺序为 bench→ftrace→slab→dump（dump 在 bench 之后），K3 的 bench
# 阶段与 K2 逐字节一致 → K2 是纯冗余启动，主判定直接取 K0→K3。
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
#   1. 构建 ON 内核 (CONFIG_NET_DELAYACCT=y) → bzImage-on（K3/K3R 共用）
#   2. 构建 OFF 内核 (CONFIG_NET_DELAYACCT=n) → bzImage-off（K0/K0R/K0B）
#   3. 创建 perf initramfs（bench-net 静态编译 + run-perf-tests.sh + get_sockdelays）
#   4. QEMU(-smp 1, 宿主侧绑核) WARM 预热 + 交错启动 K0→K3→K0R→K3R→K0B：
#      同二进制"启动间"漂移实测 ~10%（run#178: K2↔K3 同 bzImage 差
#      10.7-12.8%），且批次前 1-2 次启动有 +30% 预热瞬态（run#179）→
#      WARM 丢弃启动吸收瞬态；交错重复使时漂对 K0/K3 等权，
#      K0R/K3R 结果并入 K0/K3 中位数
#   5. 对比并生成报告（K0 为基线，K0→K3 为主判定；全部同二进制启动对
#      |Δ| 的最大值 = 启动间噪声地板，|Δ| 低于地板 → INVALID）
#
# 用法: ./perf-test.sh [--skip-build] [--runs=5] ...
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

# bench-net 每项测试轮数（每轮自动校准 ~1s，中位数抗噪）
PERF_RUNS="${PERF_RUNS:-3}"

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
# degradation: 正值=K3 更差（预期方向，工具加开销）；负值=K3 更优（噪声主导→INVALID）；
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

    # get_sockdelays 二进制 + 依赖（含 libmnl）— K3 模式 Perf-D 必需
    # K3 模式通过主动调用 get_sockdelays 计量导出开销；缺此二进制时
    # run-perf-tests.sh 会自动跳过 dump 计时（bench/ftrace 不受影响）
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
        echo "${YELLOW}WARNING: get_sockdelays not built, K3 dump timing will be SKIPped${NC}"
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

# $1 = kernel_img, $2 = mode_label (WARM/K0/K3/K0R/K3R/K0B),
# $3 = query_mode (传给 guest 的 cmdline 参数), $4 = bench 轮数(默认 PERF_RUNS)
run_perf_in_qemu() {
    local kernel_img="$1"
    local mode_label="$2"
    local query_mode="$3"
    local runs="${4:-${PERF_RUNS:-5}}"
    local qemu_out="/tmp/perf-qemu-${mode_label}-$$.log"

    log_section "Booting QEMU ($mode_label)"

    # 宿主侧绑核（20260817）：QEMU vCPU 线程每次启动被 VM 调度器随机放置
    # （不同 VM CPU/物理核/SMT/turbo 状态），是同二进制启动间漂移的根源。
    # -smp 1 只固定 guest 内 vCPU 数，不约束 QEMU 线程在宿主上的放置。
    # 绑核失败（cpuset 受限/taskset 缺失）降级不绑并告警。
    local pin_cmd=""
    if [ -n "${PERF_PIN_CPU:-}" ]; then
        if taskset -c "$PERF_PIN_CPU" true 2>/dev/null; then
            pin_cmd="taskset -c ${PERF_PIN_CPU}"
            echo "QEMU vCPU thread pinned to host CPU ${PERF_PIN_CPU}"
        else
            echo "${YELLOW}WARNING: pin to CPU ${PERF_PIN_CPU} failed (cpuset restricted?), running unpinned${NC}"
        fi
    fi

    # 构造内核 cmdline：基础参数 + perf 测试参数
    # nokaslr：本地旧 .config 增量构建的内核会卡在 KASLR 阶段（v6.5.2 坑1），
    # CI fresh clone 构建的内核无此问题；KASLR 只影响启动，禁用不改变运行时基准
    local append_str="console=ttyS0,115200n8 rdinit=/init nokaslr"
    # RT 节流禁用（run#179 实证 "sched: RT throttling activated"）：
    # bench 的 SCHED_FIFO 在 loopback 上不睡眠（send 路径 softirq 已将
    # 数据入队，recv 立即返回），950ms/s 配额耗尽后被强制停 50ms/s，
    # 每轮 ~1s 的测量被随机截入 5% 停顿 → 轮内离散 10-25% 的自伤噪声。
    # sched_rt_runtime_us=-1（RUNTIME_INF）关闭节流；单用途测量 guest，
    # 卡死由 QEMU timeout 兜底。内核 6.6 支持 sysctl.* cmdline 参数。
    append_str+=" sysctl.kernel.sched_rt_runtime_us=-1"
    append_str+=" query_mode=${query_mode}"
    append_str+=" perf_runs=${runs}"

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
        # K0/K3 的 ns/op 差值即插桩开销（分辨率 ~0.1%）。
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

    # 先尝试 KVM（$pin_cmd 不加引号：空串展开为零个参数，见上注释）
    echo "Trying KVM (timeout=${QEMU_TIMEOUT_KVM}s)..."
    set +e
    timeout "$QEMU_TIMEOUT_KVM" $pin_cmd qemu-system-x86_64 \
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
        timeout "$QEMU_TIMEOUT_TCG" $pin_cmd qemu-system-x86_64 \
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
# $1 = 文件, $2 = 模式前缀 (K0/K3/K0B)
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
# 参数: $1 = 摘要数据行（每行 tab 分隔 9 列）:
#       metric unit k0_raw k3_raw k0_med k3_med delta_k0k3 threshold verdict
#       $2 = K0 mode, $3 = K3 mode（"-"表示未运行）
write_summary_files() {
    local summary_data="$1"
    local k0_mode="$2"
    local k3_mode="${3:--}"

    # CSV
    {
        echo "metric,unit,k0_raw,k3_raw,k0_median,k3_median,delta_k0k3,threshold,verdict"
        while IFS=$'\t' read -r metric unit k0_raw k3_raw k0_med k3_med d_k0k3 threshold verdict; do
            [ -z "$metric" ] && continue
            printf '"%s","%s","%s","%s",%s,%s,%s,%s,%s\n' \
                "$metric" "$unit" "$k0_raw" "$k3_raw" \
                "$k0_med" "$k3_med" \
                "$d_k0k3" \
                "$threshold" "$verdict"
        done <<< "$summary_data"
    } > "$SUMMARY_CSV"

    # Markdown
    {
        echo "# 性能测试摘要报告"
        echo ""
        echo "- **时间戳**: ${TIMESTAMP}"
        echo "- **K0 内核模式**: ${k0_mode:-unknown}（OFF 内核，基线）"
        echo "- **K3 内核模式**: ${k3_mode:--}（ON 内核，检测+查询，最坏情形）"
        echo "- **bench 轮数**: ${PERF_RUNS}（每轮自动校准 ~1s）"
        echo ""
        echo "## 指标详情"
        echo ""
        echo "| 指标 | 单位 | K0 | K3 | K0→K3 差值 | 阈值 | 判定 |"
        echo "|------|------|----|----|-----------|------|------|"
        while IFS=$'\t' read -r metric unit k0_raw k3_raw k0_med k3_med d_k0k3 threshold verdict; do
            [ -z "$metric" ] && continue
            echo "| $metric | $unit | $k0_med | $k3_med | $d_k0k3 | $threshold | $verdict |"
        done <<< "$summary_data"
        echo ""
        echo "## Delta 计算方向"
        echo ""
        echo "- bench ns/op: (K3 - K0) / K0 * 100（正值 = 每循环耗时增加，K3 更差）"
        echo "- Socket 对象大小: K3 - K0（字节，正值 = 内存增加）"
        echo ""
        echo "## 判定说明"
        echo ""
        echo "- 主判定基于 K0→K3 的 Perf-A 矩阵微基准（bench_<path>_<size>f<flows>"
        echo "  ns/op，4 路径 × 3 尺寸 × 2 压力 = 24 格；每格 Δns/op = 该场景"
        echo "  每包 CPU 成本，Δ% 随尺寸 1/size 摊薄属预期物理规律）"
        echo "- K0/K3 各交错启动 2 次（K0R/K3R 并入中位数），QEMU vCPU 线程"
        echo "  宿主侧绑核，抑制同二进制启动间漂移（实测可达 10%+）"
        echo "- K2 模式已移除（20260817）：与 K3 同 bzImage 且 bench 阶段一致，"
        echo "  dump 在 bench 之后执行不干扰，K3 即最坏情形口径"
        echo "- K3 < K0（负 delta）→ INVALID：加开销工具不可能反向提升，"
        echo "  负值说明测量被噪声主导，建议重跑"
        echo "- |Δ| 低于启动间噪声地板（同二进制启动对 |Δ| 的最大值）→ INVALID："
        echo "  差异不可分辨于启动漂移"
        echo "- ftrace 对账为 info：Δns/op(实测) 应与 hooks/op × 单次 hook 耗时"
        echo "  数量级吻合，用于把微基准差值归因到 hook 开销"
        echo "- K3 dump_per_call_us 为 info：含 fork+exec 的全量导出 wall time"
        echo "  （空 socket 表口径）"
    } > "$SUMMARY_MD"

    echo "摘要报告:"
    echo "  Markdown: $SUMMARY_MD"
    echo "  CSV: $SUMMARY_CSV"
}

compare_and_report() {
    log_section "Performance Comparison Report"

    local k0_file="$LOG_DIR/perf-K0-${TIMESTAMP}.log"
    local k3_file="$LOG_DIR/perf-K3-${TIMESTAMP}.log"
    # K0R/K3R：交错重复启动（20260817），结果并入 K0/K3 中位数，
    # 且 (K0,K0R)/(K3,K3R) 构成同二进制启动对，参与噪声地板估计
    local k0r_file="" k3r_file=""
    [ -f "$LOG_DIR/perf-K0R-${TIMESTAMP}.log" ] && k0r_file="$LOG_DIR/perf-K0R-${TIMESTAMP}.log"
    [ -f "$LOG_DIR/perf-K3R-${TIMESTAMP}.log" ] && k3r_file="$LOG_DIR/perf-K3R-${TIMESTAMP}.log"
    # K0B：同 OFF 内核在批次末尾再跑一遍，
    # K0(首) vs K0B(尾) 差值 = 时段漂移 + 测量噪声的合成下界
    local k0b_file=""
    [ -f "$LOG_DIR/perf-K0B-${TIMESTAMP}.log" ] && k0b_file="$LOG_DIR/perf-K0B-${TIMESTAMP}.log"

    if [ ! -f "$k0_file" ] || [ ! -f "$k3_file" ]; then
        echo "${RED}Missing result files (K0/K3)${NC}"
        PERF_EXIT=1
        return 1
    fi

    # 解析所有模式到 values 数组
    # 键格式: "${mode}|${metric}_vals"，值为空格分隔的多次运行结果
    declare -A values
    # 摘要表存储：按 metric 存各列，verdict 段回填 threshold/verdict 后统一生成摘要行
    declare -A SUM_UNIT SUM_RAW0 SUM_RAW3 SUM_MED0 SUM_MED3 SUM_ABS
    declare -A SUM_D03 VERDICTS THRESHOLDS

    local mode metric val dropped=0
    while IFS='|=' read -r mode metric val; do
        # 跳过 SKIP 值，不参与中位数计算
        [ "$val" = "SKIP" ] && continue
        [ -z "$val" ] && continue
        # 串口污染防护（run#179 实证）：启动初期内核 console 消息会拼进
        # PERF 行（"2240[ 3.87] input: ..."），非纯数值样本丢弃并计数告警
        if ! printf '%s' "$val" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
            dropped=$((dropped+1))
            continue
        fi
        values["${mode}|${metric}_vals"]="${values[${mode}|${metric}_vals]:+${values[${mode}|${metric}_vals]} }$val"
    done < <(
        parse_results "$k0_file" K0
        [ -n "$k0r_file" ] && parse_results "$k0r_file" K0
        parse_results "$k3_file" K3
        [ -n "$k3r_file" ] && parse_results "$k3r_file" K3
        [ -n "$k0b_file" ] && parse_results "$k0b_file" K0B
    )
    if [ "$dropped" -gt 0 ]; then
        echo "${YELLOW}WARNING: dropped ${dropped} corrupted (non-numeric) PERF samples — serial console interleaving${NC}"
    fi

    # 模式检测（PERF: mode= 和 PERF: query_mode=）
    local k0_mode k3_mode k0_qmode k3_qmode k0b_mode
    k0_mode=$(grep "^PERF: mode=" "$k0_file" | head -1 | cut -d= -f2 | tr -d '\r')
    k3_mode=$(grep "^PERF: mode=" "$k3_file" | head -1 | cut -d= -f2 | tr -d '\r')
    k0_qmode=$(grep "^PERF: query_mode=" "$k0_file" | head -1 | cut -d= -f2 | tr -d '\r')
    k3_qmode=$(grep "^PERF: query_mode=" "$k3_file" | head -1 | cut -d= -f2 | tr -d '\r')
    if [ -n "$k0b_file" ]; then
        k0b_mode=$(grep "^PERF: mode=" "$k0b_file" | head -1 | cut -d= -f2 | tr -d '\r')
        if [ "$k0b_mode" != "OFF" ]; then
            echo "${YELLOW}WARNING: K0B kernel log reports mode='${k0b_mode}', expected 'OFF' (noise floor invalid)${NC}"
        fi
    fi
    local k0r_mode k3r_mode
    if [ -n "$k0r_file" ]; then
        k0r_mode=$(grep "^PERF: mode=" "$k0r_file" | head -1 | cut -d= -f2 | tr -d '\r')
        if [ "$k0r_mode" != "OFF" ]; then
            echo "${YELLOW}WARNING: K0R kernel log reports mode='${k0r_mode}', expected 'OFF'${NC}"
        fi
    fi
    if [ -n "$k3r_file" ]; then
        k3r_mode=$(grep "^PERF: mode=" "$k3r_file" | head -1 | cut -d= -f2 | tr -d '\r')
        if [ "$k3r_mode" != "ON" ]; then
            echo "${YELLOW}WARNING: K3R kernel log reports mode='${k3r_mode}', expected 'ON'${NC}"
        fi
    fi

    echo "K0: mode=$k0_mode query=$k0_qmode"
    echo "K3: mode=$k3_mode query=$k3_qmode"

    # mode sanity check：确认 QEMU 输出与预期一致
    if [ "$k0_mode" != "OFF" ]; then
        echo "${YELLOW}WARNING: K0 kernel log reports mode='${k0_mode}', expected 'OFF'${NC}"
    fi
    if [ "$k3_mode" != "ON" ]; then
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
    # 从单次启动的日志文件取 metric 中位数（用于同二进制启动对地板计算）
    _file_med() {
        local f="$1" mt="$2"
        [ -f "$f" ] || { echo ""; return; }
        local v
        v=$(parse_results "$f" X | awk -F'=' -v k="X|${mt}=" \
            'index($0, k)==1 {print substr($0, length(k)+1)}' | tr '\n' ' ')
        [ -z "${v// /}" ] && { echo ""; return; }
        _median "$v"
    }
    # 同二进制两启动中位数的 |Δ|%；任一为空输出空串（该对不可用）
    _pair_floor() {
        if [ -n "$1" ] && [ -n "$2" ]; then
            awk "BEGIN {if (${1}+0 > 0) {d=(${2}-${1}); if (d<0) d=-d; printf \"%.1f\", d/${1}*100}}"
        fi
        return 0
    }

    # ---- 矩阵格动态发现（bench_<cell>_ns_per_op，cell=<path>_<size>f<flows>）----
    # 以 K0 侧出现的键为准（K3 侧 ftrace 指标 K0 无）；顺序按字母排序
    # （同路径格相邻：tcp4_* / tcp6_* / udp4_* / udp6_*）
    local bench_cells=()
    while IFS= read -r _cell; do
        [ -n "$_cell" ] && bench_cells+=("$_cell")
    done < <(printf '%s\n' "${!values[@]}" | sed -n 's/^K0|bench_\(.*\)_ns_per_op_vals$/\1/p' | sort -u)
    if [ "${#bench_cells[@]}" -eq 0 ]; then
        echo "${RED}No bench matrix cells found in K0 log (expected bench_<path>_<size>f<flows>)${NC}"
        PERF_EXIT=2
        return 1
    fi
    echo "Matrix cells: ${#bench_cells[@]} (paths x sizes x flows)"

    # 构建要显示的指标列表（20260817 v2 矩阵化）
    # 格式: "metric:unit:direction"，direction: increase/abs
    #   bench_*：Perf-A 矩阵微基准（动态发现），verdict 主判定
    #   ftrace_hooks_per_op_*：Perf-B 逐格 hook 计数，info
    #   ftrace_hook_ns_*：Perf-B 逐路径单次耗时，info
    #   dump_*：Perf-D K3 导出计时，info
    #   sock_objsize：Perf-C slab，确定性判定（不进矩阵，单点）
    local table_metrics=()
    local _bc
    for _bc in "${bench_cells[@]}"; do
        table_metrics+=("bench_${_bc}_ns_per_op:ns/op:increase")
    done
    table_metrics+=("sock_objsize_bytes:bytes:abs")
    # ftrace 对账指标仅 ON 内核产出（K0/OFF 无符号），键存在即显示
    local _fk
    while IFS= read -r _fk; do
        [ -n "$_fk" ] && table_metrics+=("${_fk}:hooks:info")
    done < <(printf '%s\n' "${!values[@]}" | sed -n 's/^K3|\(ftrace_hooks_per_op_.*\)_vals$/\1/p' | sort -u)
    while IFS= read -r _fk; do
        [ -n "$_fk" ] && table_metrics+=("${_fk}:ns:info")
    done < <(printf '%s\n' "${!values[@]}" | sed -n 's/^K3|\(ftrace_hook_ns_p50_.*\)_vals$/\1/p' | sort -u)
    # K3 dump 计时（含 fork+exec 口径）
    if [ -n "${values[K3|dump_per_call_us_vals]:-}" ]; then
        table_metrics+=("dump_per_call_us:us:info")
    fi

    # ---- 打印对比表 + 收集摘要行 ----
    # 摘要行格式（tab 分隔 9 列）:
    # metric unit k0_raw k3_raw k0_med k3_med delta_k0k3 threshold verdict
    local SUMMARY_ROWS=""
    local entry m_metric m_unit m_dir
    local k0_med k3_med k0_raw k3_raw
    local d_k0k3

    for entry in "${table_metrics[@]}"; do
        m_metric="${entry%%:*}"
        local _rest="${entry#*:}"
        m_unit="${_rest%%:*}"
        m_dir="${_rest##*:}"

        k0_raw=$(_raw_of K0 "$m_metric")
        k3_raw=$(_raw_of K3 "$m_metric")
        k0_med=$(_med_of K0 "$m_metric")
        k3_med=$(_med_of K3 "$m_metric")

        # 计算 deltas
        if [ -n "$k0_med" ] && [ -n "$k3_med" ]; then
            if [ "$m_dir" = "abs" ]; then
                d_k0k3=$(calc_delta_abs "$k0_med" "$k3_med")
            else
                d_k0k3=$(calc_delta_pct "$m_metric" "$k0_med" "$k3_med")
            fi
        else
            d_k0k3="-"
        fi

        # 存入摘要数组：threshold/verdict 在 verdict 段回填，最后统一生成摘要行
        SUM_UNIT[$m_metric]="$m_unit"
        SUM_RAW0[$m_metric]="$k0_raw"
        SUM_RAW3[$m_metric]="$k3_raw"
        SUM_MED0[$m_metric]="${k0_med:-SKIP}"
        SUM_MED3[$m_metric]="${k3_med:-SKIP}"
        SUM_D03[$m_metric]="$d_k0k3"
        # Δns/op：bench 格的每包 CPU 成本（主指标，绝对量）
        if [[ "$m_metric" == bench_* ]] && [ -n "$k0_med" ] && [ -n "$k3_med" ]; then
            SUM_ABS[$m_metric]=$(awk -v a="$k0_med" -v b="$k3_med" \
                'BEGIN {printf "%+.0f", b-a}')
        else
            SUM_ABS[$m_metric]="-"
        fi
    done

    # ---- 启动间噪声地板（多对同二进制估计，20260817）----
    # 同二进制启动对的 |Δ| = QEMU 线程放置 + 时段漂移 + 测量噪声。
    # 单对估不准：run#178 K0↔K0B=1% 而 K2↔K3=13%（同为同二进制对），
    # 取所有可用对的最大值作为地板（保守上界）。verdict 中 |K0→K3 Δ|
    # 低于地板 → INVALID（差异不可分辨于启动漂移）。
    declare -A FLOOR FLOOR_DETAIL
    local pf_m pf_cell pf_a pf_b pf_d pf_max pf_detail pf_fa pf_fb pf_lbl
    for pf_cell in "${bench_cells[@]}"; do
        pf_m="bench_${pf_cell}_ns_per_op"
        pf_max=""; pf_detail=""
        # 三个同二进制启动对（K0↔K0B 覆盖首尾长程漂移）
        while IFS='|' read -r pf_fa pf_fb pf_lbl; do
            [ -z "$pf_lbl" ] && continue
            pf_a=$(_file_med "$pf_fa" "$pf_m")
            pf_b=$(_file_med "$pf_fb" "$pf_m")
            pf_d=$(_pair_floor "$pf_a" "$pf_b")
            [ -n "$pf_d" ] || continue
            pf_detail+="${pf_lbl} ${pf_d}%  "
            if [ -z "$pf_max" ]; then
                pf_max="$pf_d"
            elif awk "BEGIN {exit !(${pf_d} > ${pf_max})}"; then
                pf_max="$pf_d"
            fi
        done <<EOF
${k0_file}|${k0r_file}|K0-K0R
${k3_file}|${k3r_file}|K3-K3R
${k0_file}|${k0b_file}|K0-K0B
EOF
        FLOOR[$pf_m]="${pf_max:-}"
        FLOOR_DETAIL[$pf_m]="${pf_detail%% }"
    done

    echo ""
    echo "Pass criteria (initial, subject to noise-floor calibration):"
    echo "  Perf-A matrix bench ns/op increase (K0→K3):   < 25% per cell (24 cells)"
    echo "  Perf-C Per-socket memory:                    <= 192 bytes (slab-aligned, raw struct ~72B)"
    echo "  (ftrace 对账: Δns/op ≈ hooks_per_op × hook_ns_p50，逐格交叉验证，info 级不判定)"
    echo ""

    # ---- 自动判定（三态：PASS / FAIL / INVALID）----
    # verdict 基于 K0→K3 为主判定（K3 = ON 内核最坏情形：插桩 + dump）
    # net_delayacct 是加开销工具，K3 合法优于 K0 不可能；若 K3 反超 K0
    # （degradation<0）说明测量被噪声主导 → INVALID（非 FAIL，避免误报回归方向）。
    # degradation 统一约定：正值=K3 更差（预期方向），负值=K3 更优（噪声）。
    # 20260817：|Δ| 低于启动间噪声地板也 → INVALID（差异不可分辨于启动漂移）
    echo "Verdict (K0 → K3 primary):"
    local verdict_pass=0 verdict_fail=0 verdict_invalid=0 verdict_skip=0 status
    local v_m v_t v_dir v_unit v_k0 v_k3 v_k0m v_k3m v_drop v_delta_abs v_cell
    local v_floor v_below_floor

    # Perf-A 矩阵微基准（逐格）：degradation = (K3-K0)/K0*100，阈值 25%（初始值）。
    # 理论 hook 开销：64B 格 ~5-20%（信号最强），1400B 格 ~1-3%，
    # 65000B 格 <0.5%（GSO 摊薄，预期多为 below-floor INVALID，属物理规律）
    for v_cell in "${bench_cells[@]}"; do
        v_m="bench_${v_cell}_ns_per_op"; v_t=25
        THRESHOLDS[$v_m]="${v_t}%"
        v_k0="${values[K0|${v_m}_vals]:-}"; v_k3="${values[K3|${v_m}_vals]:-}"
        if [ -n "$v_k0" ] && [ -n "$v_k3" ]; then
            v_k0m=$(_median "$v_k0"); v_k3m=$(_median "$v_k3")
            v_drop=$(awk "BEGIN {printf \"%.1f\", (${v_k3m}-${v_k0m})/${v_k0m}*100}")
            v_delta_abs=$(awk "BEGIN {printf \"%.2f\", ${v_k3m}-${v_k0m}}")
            v_floor="${FLOOR[$v_m]:-}"
            v_below_floor=false
            if [ -n "$v_floor" ]; then
                if awk -v d="$v_drop" -v f="$v_floor" 'BEGIN {exit !(d >= 0 && d < f)}'; then
                    v_below_floor=true
                fi
            fi
            status=$(_verdict3 "$v_drop" "$v_t")
            if [ "$v_below_floor" = true ]; then
                status="INVALID"
            fi
            case "$status" in
                PASS)    echo "  ${GREEN}PASS${NC} $v_m: +${v_drop}% (Δ${v_delta_abs} ns/op) <= ${v_t}% threshold (floor ${v_floor:-n/a}%)"; verdict_pass=$((verdict_pass+1));;
                FAIL)    echo "  ${RED}FAIL${NC} $v_m: +${v_drop}% (Δ${v_delta_abs} ns/op) > ${v_t}% threshold"; verdict_fail=$((verdict_fail+1));;
                INVALID)
                    if [ "$v_below_floor" = true ]; then
                        echo "  ${YELLOW}INVALID${NC} $v_m: +${v_drop}% below launch-to-launch noise floor ${v_floor}% (indistinguishable from drift, rerun)"
                    else
                        echo "  ${YELLOW}INVALID${NC} $v_m: K3<K0 by $(awk -v d="${v_drop}" 'BEGIN{printf "%.1f", (d<0?-d:d)}')% (noise-dominated)"
                    fi
                    verdict_invalid=$((verdict_invalid+1));;
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

    # Perf-B ftrace 逐格对账（info，不参与 verdict）：
    #   Δns/op(实测) ≈ hooks_per_op(该格) × hook_ns_p50(该路径)
    # 数量级吻合则微基准差值可归因到 hook，不吻合提示测量异常。
    # hooks_per_op 只测 f1 格（与流数无关），f16 格沿用同 path×size 计数
    local ft_cell ft_path ft_hooks ft_ns ft_delta b_delta ft_k0m ft_k3m
    local any_xcheck=0
    echo ""
    echo "  ftrace cross-check (per cell):"
    for ft_cell in "${bench_cells[@]}"; do
        # cell = <path>_<size>f<flows> → path×size 部分
        ft_path="${ft_cell%f*}"           # "udp4_64"（f1 与 f16 共用）
        ft_hooks="${values[K3|ftrace_hooks_per_op_${ft_path}f1_vals]:-}"
        ft_hooks=$(printf '%s' "$ft_hooks" | awk '{print $1}')
        # 单次耗时按路径取（cell 前缀去 _size）
        local ft_ponly="${ft_path%%_*}"   # "udp4"
        ft_ns="${values[K3|ftrace_hook_ns_p50_${ft_ponly}_vals]:-}"
        ft_ns=$(printf '%s' "$ft_ns" | awk '{print $1}')
        ft_k0m=$(_med_of K0 "bench_${ft_cell}_ns_per_op")
        ft_k3m=$(_med_of K3 "bench_${ft_cell}_ns_per_op")
        if [ -n "$ft_hooks" ] && [ -n "$ft_ns" ] && [ -n "$ft_k0m" ] && [ -n "$ft_k3m" ]; then
            ft_delta=$(awk -v h="$ft_hooks" -v n="$ft_ns" 'BEGIN {printf "%.0f", h * n}')
            b_delta=$(awk -v a="$ft_k0m" -v b="$ft_k3m" 'BEGIN {printf "%.0f", b - a}')
            any_xcheck=1
            echo "    ${ft_cell}: measured Δ=${b_delta} ns/op, predicted ≈ ${ft_hooks} hooks × ${ft_ns}ns = ${ft_delta} ns/op"
        fi
    done
    if [ "$any_xcheck" = 0 ]; then
        echo "    (no ftrace hooks/hook-ns data — K3 log missing ftrace metrics?)"
    fi

    # Perf-C 每 socket 内存：degradation = K3-K0 (bytes)，阈值 192
    # 阈值 192 = 72(struct net_delayacct) + 56(SLAB_HWCACHE_ALIGN 64B 对齐填充) + 64(余量)
    # /proc/slabinfo 第 4 列是 s->size（含 64 字节缓存行对齐），非 s->object_size（原始 struct）
    # TCP slab 用 SLAB_HWCACHE_ALIGN（tcp.c kmem_cache_create），ON struct 增加 72B 后
    # 跨 64B 边界 → 对齐填充 56B → slab delta 128B。原始 struct 开销仅 72B（<= 80 理论阈值）。
    v_m="sock_objsize_bytes"; v_t=192
    THRESHOLDS[$v_m]="${v_t}B"
    local k0_sock k3_sock
    # tr -d '\r': QEMU 串口输出为 \r\n，提取的值末尾带 \r 会导致
    # grep -qE '^[0-9]+$' 失败，内存 delta 误显示为 "-"
    # grep -oE '^PERF: sock_objsize_bytes_run1=[0-9]+': 只取数值前缀，
    # 防串口污染（run#179: "2240[ 3.87] input: ..." 拼接内核日志）
    k0_sock=$(grep -oE "^PERF: sock_objsize_bytes_run1=[0-9]+" "$k0_file" | head -1 | cut -d= -f2 | tr -d '\r')
    k3_sock=$(grep -oE "^PERF: sock_objsize_bytes_run1=[0-9]+" "$k3_file" | head -1 | cut -d= -f2 | tr -d '\r')
    if [ -n "$k0_sock" ] && [ -n "$k3_sock" ] && \
       echo "$k0_sock" | grep -qE '^[0-9]+$' && echo "$k3_sock" | grep -qE '^[0-9]+$'; then
        v_drop=$((k3_sock - k0_sock))
        status=$(_verdict3 "$v_drop" "$v_t")
        case "$status" in
            PASS)    echo "  ${GREEN}PASS${NC} sock_objsize: +${v_drop} bytes <= ${v_t} threshold (raw struct ~72B + slab align)"; verdict_pass=$((verdict_pass+1));;
            FAIL)    echo "  ${RED}FAIL${NC} sock_objsize: +${v_drop} bytes > ${v_t} threshold"; verdict_fail=$((verdict_fail+1));;
            INVALID) echo "  ${YELLOW}INVALID${NC} sock_objsize: K3<K0 (noise-dominated)"; verdict_invalid=$((verdict_invalid+1));;
        esac
    else
        status="SKIP"
        echo "  ${YELLOW}SKIP${NC} sock_objsize: no data"
        verdict_skip=$((verdict_skip+1))
    fi
    VERDICTS[$v_m]="$status"

    # ---- 信息性指标（ftrace/dump，不影响 verdict）----
    # K3 的导出开销直接由 Perf-D dump_per_call_us 量化，对比表中已含列

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
    echo "Full logs: $LOG_DIR/perf-{K0,K0R,K3,K3R,K0B}-${TIMESTAMP}.log"

    # ---- 打印对比表（verdict 计算完成后，回填真实 Thresh/Verdict）----
    # Δns/op 列 = 每包 CPU 成本（主指标，绝对量）；Δ% 列 = 相对开销量级
    # bench 格显示短名（去 bench_ 前缀与 _ns_per_op 后缀）
    echo ""
    echo "+-----------------------------------------------------------------------------------------------+"
    echo "|              NET_DELAYACCT Per-Packet CPU Cost Matrix (K0 vs K3)                              |"
    echo "+-----------------------------------------------------------------------------------------------+"
    printf "| %-28s | %9s | %9s | %7s | %8s | %6s | %-7s |\n" \
        "Cell (path_size_flows)" "K0" "K3" "Δns/op" "Δ%" "Thresh" "Verdict"
    echo "+-----------------------------------------------------------------------------------------------+"
    local entry _t_metric _t_lbl
    for entry in "${table_metrics[@]}"; do
        _t_metric="${entry%%:*}"
        _t_lbl="$_t_metric"
        [[ "$_t_lbl" == bench_* ]] && _t_lbl="${_t_lbl#bench_}" && _t_lbl="${_t_lbl%_ns_per_op}"
        case "$_t_lbl" in
            ftrace_hooks_per_op_*) _t_lbl="hooks/${_t_lbl#ftrace_hooks_per_op_}";;
            ftrace_hook_ns_p50_*)  _t_lbl="hookns/${_t_lbl#ftrace_hook_ns_p50_}";;
        esac
        printf "| %-28s | %9s | %9s | %7s | %8s | %6s | %-7s |\n" \
            "$_t_lbl" "${SUM_MED0[$_t_metric]:-SKIP}" "${SUM_MED3[$_t_metric]:-SKIP}" \
            "${SUM_ABS[$_t_metric]:--}" "${SUM_D03[$_t_metric]:--}" \
            "${THRESHOLDS[$_t_metric]:--}" "${VERDICTS[$_t_metric]:-info}"
    done
    echo "+-----------------------------------------------------------------------------------------------+"
    echo ""

    # 生成结构化摘要报告（Markdown + CSV）
    # 回填 threshold/verdict：按 table_metrics 顺序从存储数组重组摘要行
    SUMMARY_ROWS=""
    for entry in "${table_metrics[@]}"; do
        m_metric="${entry%%:*}"
        SUMMARY_ROWS+="${m_metric}	${SUM_UNIT[$m_metric]}	${SUM_RAW0[$m_metric]}	${SUM_RAW3[$m_metric]}	${SUM_MED0[$m_metric]}	${SUM_MED3[$m_metric]}	${SUM_D03[$m_metric]}	${THRESHOLDS[$m_metric]:--}	${VERDICTS[$m_metric]:-info}"$'\n'
    done
    write_summary_files "$SUMMARY_ROWS" "$k0_mode" "${k3_mode:--}"

    # ---- 噪声地板节（多对同二进制启动，20260817）----
    # 每对 = 同一 bzImage 的两次 QEMU 启动，|Δ| = 启动放置 + 时段漂移 +
    # 测量噪声。floor = 全部可用对的最大值（保守上界）。
    # floor >= 静态阈值的指标标 NOISY（该环境下判定不可信）；verdict 段已
    # 用 floor 把 |Δ| 低于地板的差异降级 INVALID。数据积累多轮后再校准阈值。
    local _any_floor=""
    local _nf_cell
    for _nf_cell in "${bench_cells[@]}"; do
        [ -n "${FLOOR[bench_${_nf_cell}_ns_per_op]:-}" ] && _any_floor=1
    done
    if [ -n "$_any_floor" ]; then
        echo "+----------------------------------------------------------------------------------------------------------+"
        echo "| Noise Floor (same-binary launch pairs, floor = max |delta|)                                              |"
        echo "+----------------------------------------------------------------------------------------------------------+"
        printf "| %-26s | %-46s | %7s | %6s | %-6s |\n" \
            "Metric" "pairs (|delta|%)" "floor" "Thresh" "Usable"
        echo "+----------------------------------------------------------------------------------------------------------+"
        local nf_metric nf_floor nf_thr nf_ok
        local floor_md="" floor_csv=""
        # 静态阈值须与 verdict 段一致（sock_objsize 确定性无噪声，不在此列）
        for _nf_cell in "${bench_cells[@]}"; do
            nf_metric="bench_${_nf_cell}_ns_per_op"
            nf_thr=25
            nf_floor="${FLOOR[$nf_metric]:-}"
            if [ -n "$nf_floor" ]; then
                nf_ok=$(awk -v f="$nf_floor" -v t="$nf_thr" \
                    'BEGIN {print (f < t) ? "YES" : "NOISY"}')
            else
                nf_floor="-"; nf_ok="-"
            fi
            printf "| %-26s | %-46s | %7s | %6s | %-6s |\n" \
                "$_nf_cell" "${FLOOR_DETAIL[$nf_metric]:--}" "$nf_floor" "$nf_thr" "$nf_ok"
            floor_md+="| ${nf_metric} | ${FLOOR_DETAIL[$nf_metric]:--} | ${nf_floor}% | ${nf_thr}% | ${nf_ok} |"$'\n'
            floor_csv+="${nf_metric}__noise_floor	${SUM_UNIT[$nf_metric]:--}	${FLOOR_DETAIL[$nf_metric]:--}	-	-	-	${nf_floor}%	${nf_thr}%	FLOOR"$'\n'
        done
        echo "+----------------------------------------------------------------------------------------------------------+"
        echo "Note: NOISY = floor >= threshold -> K0->K3 verdict for this metric is noise-dominated."
        echo "Note: verdict already treats |K0->K3 delta| < floor as INVALID (indistinguishable from launch drift)."
        echo ""

        # 追加到 Markdown / CSV 摘要
        local summary_md_path="$LOG_DIR/perf-summary-${TIMESTAMP}.md"
        local summary_csv_path="$LOG_DIR/perf-summary-${TIMESTAMP}.csv"
        {
            echo ""
            echo "## Noise Floor (same-binary launch pairs)"
            echo ""
            echo "| Metric | pairs (\\|delta\\|%) | floor | Thresh | Usable |"
            echo "|---|---|---|---|---|"
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
  K3: ON 内核，检测开启 + dump 导出计时（最坏情形，需 get_sockdelays）
  （K2 已移除 20260817：与 K3 同 bzImage 且 bench 阶段一致，纯冗余）

Options:
  --skip-build              复用已有 bzImage-on/off（不重新构建内核）
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
  # K0 vs K3（默认）
  $0 --skip-build --strict=warn
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
    echo "Modes: K0 (OFF) + K3 (ON, with dump query)"
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

    # Step 4: QEMU 运行各模式（交错重复启动，20260817）
    #
    # 根因（run#178 实证）：同二进制启动间漂移 ~10%（K2↔K3 同 bzImage 差
    # 10.7-12.8%），单次启动内 5 轮中位数却只有 ~1% —— 噪声全部来自
    # "每次 QEMU 启动"的宿主放置差异（QEMU vCPU 线程被 VM 调度器随机
    # 放置到不同 VM CPU/物理核）。对策：
    #   1) 宿主侧绑核（下方 PERF_PIN_CPU）：所有启动用同一 CPU
    #   2) 交错重复：K0/K3 各启动 2 次，时漂对两者等权；K0R/K3R 结果
    #      并入 K0/K3 参与中位数，同时提供同二进制启动对给噪声地板
    # 宿主绑核 CPU 选择：online ∩ allowed 交集的最大号（避开 CPU0 的
    # IRQ/内核线程聚集），逐个降序用 taskset 试探（某些环境 status 与实际
    # 可用不一致：如 allowed=0-127 但 online 仅 0-3，绑 127 直接 EINVAL）。
    # 仅剩 CPU0 或全部不可绑时不绑。
    PERF_PIN_CPU=""
    _online=$(cat /sys/devices/system/cpu/online 2>/dev/null || true)
    _allowed=$(awk '/^Cpus_allowed_list/ {print $2}' /proc/self/status 2>/dev/null || true)
    _cands=$(awk -v on="${_online:-0-0}" -v al="${_allowed:-0-0}" 'BEGIN {
        n1 = split(on, O, ","); for (i = 1; i <= n1; i++) { split(O[i], r1, "-"); for (c = r1[1]; c <= r1[2]; c++) online[c] = 1 }
        n2 = split(al, A, ","); for (i = 1; i <= n2; i++) { split(A[i], r2, "-"); for (c = r2[1]; c <= r2[2]; c++) allowed[c] = 1 }
        for (c = 0; c < 1024; c++) if (online[c] && allowed[c]) print c
    }' | sort -rn)
    for _c in $_cands; do
        [ "$_c" -lt 1 ] && break
        if taskset -c "$_c" true 2>/dev/null; then
            PERF_PIN_CPU="$_c"
            break
        fi
    done
    if [ -n "$PERF_PIN_CPU" ]; then
        echo "QEMU vCPU pin target: host CPU $PERF_PIN_CPU (online: ${_online:-?}, allowed: ${_allowed:-?})"
    else
        echo "NOTE: no pinnable CPU >0 (single-CPU or restricted), QEMU runs unpinned"
    fi

    # WARM 预热启动（run#179 实证）：批次前 1-2 次 QEMU 启动处于慢态
    # （tcprw 15769/15078 vs 稳定区 11073-11697，+30%），属频率/缓存预热
    # 瞬态 → 一次 1 轮的丢弃启动吸收瞬态，正式样本全部落在稳定区。
    # WARM 日志落盘但不参与解析/判定。
    run_perf_in_qemu "$BZIMAGE_OFF" "WARM" "K0" 1
    echo ""

    run_perf_in_qemu "$BZIMAGE_OFF" "K0" "K0"
    echo ""
    # K3: ON 内核，检测开启 + dump 导出计时（最坏情形口径）
    run_perf_in_qemu "$BZIMAGE_ON" "K3" "K3"
    echo ""
    # K0R/K3R: 交错重复（同二进制第二次启动，合并进 K0/K3 并构成地板对）
    run_perf_in_qemu "$BZIMAGE_OFF" "K0R" "K0"
    echo ""
    run_perf_in_qemu "$BZIMAGE_ON" "K3R" "K3"
    echo ""
    # K0B: 同 OFF 内核批次末尾再跑一遍：K0(首) vs K0B(尾) 提供首尾长程
    # 漂移地板对（与 K0-K0R/K3-K3R 一起取最大值 = 噪声地板）
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

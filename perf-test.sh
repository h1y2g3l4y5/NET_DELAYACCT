#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# perf-test.sh — NET_DELAYACCT 性能基准测试编排脚本（host 侧）
#
# 20260819 v3 同 boot A/B（static key 运行时开关）：
#   v2 跨 boot 对比（K0=OFF 内核 vs K3=ON 内核）有两重不可归因性：
#     1. 二进制布局差异：ON 内核 struct sock +128B → 对象布局/cache
#        局部性变化，性能影响可正可负（"ON 比 OFF 快"假象的根源），
#        与 hook 开销混叠无法分离
#     2. 启动间漂移：QEMU vCPU 线程宿主放置随机，同二进制启动间
#        |Δ| 实测 10%+，高于多数格信号（1400B/65000B 格 <3%）
#   对策：内核补丁新增 net_delayacct.enabled 运行时开关（static key），
#   ON 内核单次 boot 内交错翻转 OFF/ON 测 24 格矩阵：
#     - 二进制逐字节相同 → 布局差异归零，Δ = 纯 hook 开销
#     - 同 boot 差分 → 启动间漂移被消除，残余噪声仅轮间抖动 ~1%
#     - 信号（64B 格 +5-20%）>> 噪声（~1%），信噪比恢复
#
# boot 编排（6 次 → 2 次）：
#   boot1 K0 : OFF 内核（CONFIG_NET_DELAYACCT=n）→ 仅 slab 基线
#              （sock_objsize 编译期确定值，跨 boot 对比零噪声）
#   boot2 AB : ON 内核 → 同 boot A/B 全套（bench AB 矩阵 + ftrace
#              对账 + slab + dump）
#   WARM/K0R/K3R/K0B 预热与重复启动全部移除：同 boot 差分对启动间
#   漂移免疫，无需交错重复；K0 boot 天然预热频率/缓存
#
# 判定口径（逐格）：
#   Δns/op = median(on) − median(off)，Δ% = Δns / off × 100
#   Δ% > +25%          → FAIL（开销超阈值）
#   Δ% ∈ [−5%, +25%]   → PASS（小幅负值为轮间统计涨落）
#   Δ% < −5%           → INVALID（on 显著快于 off 物理不可能：
#                         开关未生效 / 测量异常，建议检查）
#   slab：K0 vs AB 绝对差 ≤ 192B（跨 boot 确定性）
#
# 流程：
#   1. 构建 ON 内核 (CONFIG_NET_DELAYACCT=y) → bzImage-on（AB boot）
#   2. 构建 OFF 内核 (CONFIG_NET_DELAYACCT=n) → bzImage-off（K0 boot）
#   3. 创建 perf initramfs（bench-net 静态编译 + run-perf-tests.sh + get_sockdelays）
#   4. QEMU(-smp 1, 宿主侧绑核) K0 → AB 两次启动
#   5. 解析对比并生成报告
#
# 用法: ./perf-test.sh [--skip-build] [--runs=3] ...
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
# 单次 QEMU 时长预算（-smp 1）：
#   K0 boot：boot ~10s + slab 1s ≈ 15s（KVM）/ ~130s（TCG）
#   AB boot：boot ~10s + bench 6 块×24 格×~1.3s ≈ 190s + ftrace ~15s
#            + dump ~5s ≈ 220s（KVM）；TCG ~3x ≈ 500s
# KVM 300s / TCG 700s：TCG boot ~120s + bench 同量级（自动校准按
# wall time）+ 慢速 ftrace buffer 操作，700s 含余量
QEMU_TIMEOUT_KVM="${QEMU_TIMEOUT_KVM:-300}"
QEMU_TIMEOUT_TCG="${QEMU_TIMEOUT_TCG:-700}"

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

    # get_sockdelays 二进制 + 依赖（含 libmnl）— AB 模式 Perf-D 必需
    # AB 模式通过主动调用 get_sockdelays 计量导出开销；缺此二进制时
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
        echo "Packed get_sockdelays (for AB mode)"
    else
        echo "${YELLOW}WARNING: get_sockdelays not built, AB dump timing will be SKIPped${NC}"
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

# $1 = kernel_img, $2 = mode_label (K0/AB),
# $3 = AB 对数(传给 guest 的 perf_runs cmdline 参数，默认 PERF_RUNS)
run_perf_in_qemu() {
    local kernel_img="$1"
    local mode_label="$2"
    local runs="${3:-${PERF_RUNS:-3}}"
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
        # OFF/ON 的 ns/op 差值即插桩开销（分辨率 ~0.1%）。
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

# 解析 AB boot（ON 内核）的 PERF: *_runN= 行 → "<前缀>|<metric>=<val>"
#   bench_<cell>_ns_per_op_off_runN → OFF|bench_<cell>_ns_per_op
#   bench_<cell>_ns_per_op_on_runN  → ON|bench_<cell>_ns_per_op
#   其余（ftrace_*/dump_*/sock_objsize_*）→ AB|<metric>
# 注意：key 去掉 _ns_per_op_{off,on}_run 后缀后仍含 bench_ 前缀，
# 直接回拼 _ns_per_op 即可，不能再加 bench_（否则 bench_bench_ 双前缀，
# 且 cell 名与 ftrace_hooks_per_op_<cell> 错位导致对账失配）
parse_ab_results() {
    local file="$1"
    local key val
    while IFS='=' read -r key val; do
        # 去掉 "PERF: " 前缀
        key="${key#PERF: }"
        case "$key" in
            *_ns_per_op_off_run*)
                key="${key%_ns_per_op_off_run*}"
                echo "OFF|${key}_ns_per_op=${val}" ;;
            *_ns_per_op_on_run*)
                key="${key%_ns_per_op_on_run*}"
                echo "ON|${key}_ns_per_op=${val}" ;;
            *_run*)
                key="${key%_run*}"
                echo "AB|${key}=${val}" ;;
        esac
    done < <(grep "^PERF:" "$file" | grep "_run")
}

# 解析 K0 boot（OFF 内核）的 PERF: *_runN= 行 → "K0|<metric>=<val>"
# K0 boot 仅产出 sock_objsize（slab 基线），其余指标 SKIP 被下游过滤
parse_k0_results() {
    local file="$1"
    local key val
    while IFS='=' read -r key val; do
        key="${key#PERF: }"
        key="${key%_run*}"
        echo "K0|${key}=${val}"
    done < <(grep "^PERF:" "$file" | grep "_run")
}

# 计算 delta 绝对值（字节），用于 sock_objsize_bytes
# $1 = baseline (K0), $2 = compared (AB/ON)
calc_delta_abs() {
    local base="$1" comp="$2"
    awk "BEGIN {printf \"%+d\", ${comp}-${base}}"
}

# 同 boot A/B 三态判定（回显 PASS/FAIL/INVALID）
#   $1 = Δ%（on 相对 off），$2 = PASS 上限阈值（25），$3 = 负容差（-5）
#   Δ% > 上限            → FAIL（hook 开销超阈值）
#   Δ% ∈ [负容差, 上限]  → PASS（小幅负值 = 轮间统计涨落，同 boot 差分
#                           下噪声仅 ~1-3%，5% 容差覆盖 65000B 摊薄格）
#   Δ% < 负容差          → INVALID（on 显著快于 off 物理不可能：开关
#                           未生效 / 测量异常，非噪声——同 boot 下噪声
#                           已被差分消除，不存在 v2 时代"噪声掩盖信号"
#                           的 INVALID 语义）
_verdict_ab() {
    if awk "BEGIN {exit !(${1} < ${3})}"; then
        echo INVALID
    elif awk "BEGIN {exit !(${1} > ${2})}"; then
        echo FAIL
    else
        echo PASS
    fi
}

# slab 三态判定（跨 boot 确定性对比，K0 vs AB）
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

# 生成 Markdown + CSV 结构化摘要报告
# 参数: $1 = 摘要数据行（每行 tab 分隔 9 列）:
#       metric unit off_raw on_raw off_med on_med delta threshold verdict
#       $2 = AB boot 模式（AB=正常；ON_NOSWITCH=旧内核防呆降级）
write_summary_files() {
    local summary_data="$1"
    local ab_mode="$2"

    # CSV
    {
        echo "metric,unit,off_raw,on_raw,off_median,on_median,delta_off_on,threshold,verdict"
        while IFS=$'\t' read -r metric unit off_raw on_raw off_med on_med d_offon threshold verdict; do
            [ -z "$metric" ] && continue
            printf '"%s","%s","%s","%s",%s,%s,%s,%s,%s\n' \
                "$metric" "$unit" "$off_raw" "$on_raw" \
                "$off_med" "$on_med" \
                "$d_offon" \
                "$threshold" "$verdict"
        done <<< "$summary_data"
    } > "$SUMMARY_CSV"

    # Markdown
    {
        echo "# 性能测试摘要报告（同 boot A/B）"
        echo ""
        echo "- **时间戳**: ${TIMESTAMP}"
        echo "- **AB boot 模式**: ${ab_mode:-unknown}（ON 内核，static key 运行时开关）"
        echo "- **AB 对数**: ${PERF_RUNS}（每对 = OFF 块 + ON 块，各 24 格全矩阵）"
        echo "- **K0 boot**: OFF 内核，仅 slab 基线（sock_objsize 编译期确定值）"
        echo ""
        echo "## 指标详情"
        echo ""
        echo "| 指标 | 单位 | OFF | ON | OFF→ON 差值 | 阈值 | 判定 |"
        echo "|------|------|-----|----|------------|------|------|"
        while IFS=$'\t' read -r metric unit off_raw on_raw off_med on_med d_offon threshold verdict; do
            [ -z "$metric" ] && continue
            echo "| $metric | $unit | $off_med | $on_med | $d_offon | $threshold | $verdict |"
        done <<< "$summary_data"
        echo ""
        echo "## Delta 计算方向"
        echo ""
        echo "- bench ns/op: (ON - OFF) / OFF * 100（同 boot 同二进制差分，"
        echo "  正值 = hook 开销导致的每循环耗时增加）"
        echo "- Socket 对象大小: ON 内核 - OFF 内核（字节，跨 boot 编译期确定值）"
        echo ""
        echo "## 判定说明"
        echo ""
        echo "- 主判定基于同 boot A/B 的 Perf-A 矩阵微基准（bench_<path>_<size>"
        echo "  f<flows> ns/op，4 路径 × 3 尺寸 × 2 压力 = 24 格）：ON 内核单次"
        echo "  boot 内经 net_delayacct.enabled 运行时开关交错翻转 OFF/ON 各"
        echo "  ${PERF_RUNS} 块，二进制逐字节相同 → Δ = 纯 hook 开销，启动间"
        echo "  漂移与布局差异均被消除"
        echo "- Δ% ∈ [-5%, +25%] → PASS（小幅负值为轮间统计涨落；Δ% 随尺寸"
        echo "  1/size 摊薄属预期物理规律，65000B 格 Δ% 可低至 ~1%）"
        echo "- Δ% < -5% → INVALID：on 显著快于 off 物理不可能，提示开关未"
        echo "  生效 / 测量异常（非噪声——同 boot 差分下噪声仅 ~1-3%）"
        echo "- ftrace 对账为 info：Δns/op(实测) 应与 hooks/op × 单次 hook 耗时"
        echo "  数量级吻合，用于把微基准差值归因到 hook 开销"
        echo "- dump_per_call_us 为 info：含 fork+exec 的全量导出 wall time"
        echo "  （空 socket 表口径）"
    } > "$SUMMARY_MD"

    echo "摘要报告:"
    echo "  Markdown: $SUMMARY_MD"
    echo "  CSV: $SUMMARY_CSV"
}

compare_and_report() {
    log_section "Performance Comparison Report (same-boot A/B)"

    local k0_file="$LOG_DIR/perf-K0-${TIMESTAMP}.log"
    local ab_file="$LOG_DIR/perf-AB-${TIMESTAMP}.log"

    if [ ! -f "$ab_file" ]; then
        echo "${RED}Missing AB result file (ON kernel boot produced no data)${NC}"
        PERF_EXIT=2
        return 1
    fi
    if [ ! -f "$k0_file" ]; then
        echo "${YELLOW}WARNING: K0 (OFF kernel) log missing — slab baseline unavailable${NC}"
    fi

    # 解析两个 boot 的 PERF 行到 values 数组
    #   OFF|/ON|bench_<cell>_ns_per_op : 同 boot A/B 差分样本（AB boot）
    #   AB|ftrace_*/dump_*/sock_objsize : AB boot 信息指标
    #   K0|sock_objsize                 : OFF 内核 slab 基线
    declare -A values
    # 摘要表存储：按 metric 存各列，verdict 段回填 threshold/verdict 后统一生成摘要行
    declare -A SUM_UNIT SUM_RAWOFF SUM_RAWON SUM_MEDOFF SUM_MEDON SUM_ABS
    declare -A SUM_DON VERDICTS THRESHOLDS

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
        parse_ab_results "$ab_file"
        [ -f "$k0_file" ] && parse_k0_results "$k0_file"
    )
    if [ "$dropped" -gt 0 ]; then
        echo "${YELLOW}WARNING: dropped ${dropped} corrupted (non-numeric) PERF samples — serial console interleaving${NC}"
    fi

    # boot 模式检测（PERF: mode=AB 为预期；ON_NOSWITCH = 旧内核防呆降级）
    local ab_mode
    ab_mode=$(grep "^PERF: mode=" "$ab_file" | head -1 | cut -d= -f2 | tr -d '\r')
    echo "AB boot: mode=${ab_mode:-unknown}"
    if [ "${ab_mode:-}" != "AB" ]; then
        echo "${RED}AB boot reports mode='${ab_mode:-unknown}', expected 'AB'${NC}"
        if [ "${ab_mode:-}" = "ON_NOSWITCH" ]; then
            echo "${RED}  → ON kernel lacks net_delayacct.enabled runtime switch (stale bzImage without static key patch?)${NC}"
        fi
    fi
    # 开关往返自检结果
    if grep -q "^PERF: switch_check=fail" "$ab_file" 2>/dev/null; then
        echo "${RED}switch_check=fail: runtime switch flip failed — A/B data unreliable${NC}"
    elif ! grep -q "^PERF: switch_check=ok" "$ab_file" 2>/dev/null; then
        echo "${YELLOW}WARNING: switch_check marker not found in AB log${NC}"
    fi
    echo ""

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

    # ---- 矩阵格动态发现（bench_<cell>_ns_per_op，cell=<path>_<size>f<flows>）----
    # 以 OFF 侧出现的键为准（同 boot OFF/ON 样本成对）；顺序按字母排序
    # （同路径格相邻：tcp4_* / tcp6_* / udp4_* / udp6_*）
    local bench_cells=()
    while IFS= read -r _cell; do
        [ -n "$_cell" ] && bench_cells+=("$_cell")
    done < <(printf '%s\n' "${!values[@]}" | sed -n 's/^OFF|bench_\(.*\)_ns_per_op_vals$/\1/p' | sort -u)
    if [ "${#bench_cells[@]}" -eq 0 ]; then
        echo "${RED}No bench matrix cells found in AB log (expected bench_<path>_<size>f<flows>_ns_per_op_off/on)${NC}"
        echo "${RED}  → likely stale bzImage-on (no static key patch) or bench-net missing${NC}"
        PERF_EXIT=2
        return 1
    fi
    echo "Matrix cells: ${#bench_cells[@]} (paths x sizes x flows)"

    # 构建要显示的指标列表
    # 格式: "metric:unit:direction"，direction: increase/abs/info
    #   bench_*：Perf-A 矩阵微基准（动态发现），verdict 主判定
    #   sock_objsize：Perf-C slab，K0 vs AB 跨 boot 确定性判定
    #   ftrace_hooks_per_op_*：Perf-B 逐格 hook 计数，info
    #   ftrace_hook_ns_*：Perf-B 逐路径单次耗时，info
    #   dump_*：Perf-D 导出计时，info
    local table_metrics=()
    local _bc
    for _bc in "${bench_cells[@]}"; do
        table_metrics+=("bench_${_bc}_ns_per_op:ns/op:increase")
    done
    table_metrics+=("sock_objsize_bytes:bytes:abs")
    # ftrace 对账指标仅 AB boot 产出，键存在即显示
    local _fk
    while IFS= read -r _fk; do
        [ -n "$_fk" ] && table_metrics+=("${_fk}:hooks:info")
    done < <(printf '%s\n' "${!values[@]}" | sed -n 's/^AB|\(ftrace_hooks_per_op_.*\)_vals$/\1/p' | sort -u)
    while IFS= read -r _fk; do
        [ -n "$_fk" ] && table_metrics+=("${_fk}:ns:info")
    done < <(printf '%s\n' "${!values[@]}" | sed -n 's/^AB|\(ftrace_hook_ns_p50_.*\)_vals$/\1/p' | sort -u)
    # dump 计时（含 fork+exec 口径）
    if [ -n "${values[AB|dump_per_call_us_vals]:-}" ]; then
        table_metrics+=("dump_per_call_us:us:info")
    fi

    # ---- 收集摘要列（verdict 段计算完成后再统一打印）----
    # 摘要行格式（tab 分隔 9 列）:
    # metric unit off_raw on_raw off_med on_med delta_off_on threshold verdict
    local SUMMARY_ROWS=""
    local entry m_metric m_unit m_dir
    local off_med on_med off_raw on_raw
    local d_offon

    for entry in "${table_metrics[@]}"; do
        m_metric="${entry%%:*}"
        local _rest="${entry#*:}"
        m_unit="${_rest%%:*}"
        m_dir="${_rest##*:}"

        # bench 格：OFF|/ON| 前缀（同 boot 差分对）
        # sock_objsize：K0|（OFF 内核 boot）vs AB|（ON 内核 boot）
        # info（ftrace/dump）：仅 AB| 有值，OFF 列显示 "-"
        if [ "$m_metric" = "sock_objsize_bytes" ]; then
            off_raw=$(_raw_of K0 "$m_metric")
            on_raw=$(_raw_of AB "$m_metric")
            off_med=$(_med_of K0 "$m_metric")
            on_med=$(_med_of AB "$m_metric")
        elif [ "$m_dir" = "info" ]; then
            off_raw="-"
            on_raw=$(_raw_of AB "$m_metric")
            off_med="-"
            on_med=$(_med_of AB "$m_metric")
        else
            off_raw=$(_raw_of OFF "$m_metric")
            on_raw=$(_raw_of ON "$m_metric")
            off_med=$(_med_of OFF "$m_metric")
            on_med=$(_med_of ON "$m_metric")
        fi

        # 计算 deltas
        if [ -n "$off_med" ] && [ -n "$on_med" ] && [ "$off_med" != "-" ]; then
            if [ "$m_dir" = "abs" ]; then
                d_offon=$(calc_delta_abs "$off_med" "$on_med")
            else
                d_offon=$(awk -v a="$off_med" -v b="$on_med" \
                    'BEGIN {if(a+0>0) printf "%+.1f%%", (b-a)/a*100; else print "N/A"}')
            fi
        else
            d_offon="-"
        fi

        # 存入摘要数组：threshold/verdict 在 verdict 段回填，最后统一生成摘要行
        SUM_UNIT[$m_metric]="$m_unit"
        SUM_RAWOFF[$m_metric]="$off_raw"
        SUM_RAWON[$m_metric]="$on_raw"
        SUM_MEDOFF[$m_metric]="${off_med:-SKIP}"
        SUM_MEDON[$m_metric]="${on_med:-SKIP}"
        SUM_DON[$m_metric]="$d_offon"
        # Δns/op：bench 格的每包 CPU 成本（主指标，绝对量）
        if [[ "$m_metric" == bench_* ]] && [ -n "$off_med" ] && [ -n "$on_med" ]; then
            SUM_ABS[$m_metric]=$(awk -v a="$off_med" -v b="$on_med" \
                'BEGIN {printf "%+.0f", b-a}')
        else
            SUM_ABS[$m_metric]="-"
        fi
    done

    echo ""
    echo "Pass criteria (same-boot A/B):"
    echo "  Perf-A matrix bench ns/op OFF→ON:   Δ% within [-5%, +25%] per cell (24 cells)"
    echo "  Perf-C Per-socket memory:           <= 192 bytes (slab-aligned, raw struct ~72B)"
    echo "  (ftrace 对账: Δns/op ≈ hooks_per_op × hook_ns_p50，逐格交叉验证，info 级不判定)"
    echo ""

    # ---- 自动判定（三态：PASS / FAIL / INVALID）----
    # 同 boot A/B：二进制逐字节相同，on 显著快于 off 物理不可能
    #   Δ% > +25%    → FAIL（hook 开销超阈值）
    #   [-5%, +25%]  → PASS（小幅负值 = 轮间统计涨落，同 boot 差分下
    #                  噪声仅 ~1-3%，5% 容差覆盖 65000B 摊薄格）
    #   Δ% < -5%     → INVALID（开关未生效 / 测量异常，非噪声）
    echo "Verdict (same-boot OFF → ON):"
    local verdict_pass=0 verdict_fail=0 verdict_invalid=0 verdict_skip=0 status
    local v_m v_t v_tol=-5 v_off v_on v_offm v_onm v_drop v_delta_abs v_cell v_spread

    # Perf-A 矩阵微基准（逐格）：
    # 理论 hook 开销：64B 格 ~5-20%（信号最强），1400B 格 ~1-3%，
    # 65000B 格 ~0.5-1.5%（GSO 摊薄，同 boot 差分下仍可分辨）
    # off 样本轮间极差 (max-min)/min% 作为残余噪声参考随行输出
    for v_cell in "${bench_cells[@]}"; do
        v_m="bench_${v_cell}_ns_per_op"; v_t=25
        THRESHOLDS[$v_m]="[-5,${v_t}]%"
        v_off="${values[OFF|${v_m}_vals]:-}"; v_on="${values[ON|${v_m}_vals]:-}"
        if [ -n "$v_off" ] && [ -n "$v_on" ]; then
            v_offm=$(_median "$v_off"); v_onm=$(_median "$v_on")
            v_drop=$(awk -v a="$v_offm" -v b="$v_onm" \
                'BEGIN {if(a+0>0) printf "%.1f", (b-a)/a*100; else print "0"}')
            v_delta_abs=$(awk -v a="$v_offm" -v b="$v_onm" \
                'BEGIN {printf "%.2f", b-a}')
            # off 样本轮间极差%（≥2 样本才有意义；残余噪声指示）
            v_spread=$(printf '%s\n' $v_off | sort -n | awk '
                {a[NR]=$1}
                END {
                    if (NR < 2 || a[1]+0 <= 0) {print "-"; exit}
                    printf "%.1f", (a[NR]-a[1])/a[1]*100
                }')
            status=$(_verdict_ab "$v_drop" "$v_t" "$v_tol")
            case "$status" in
                PASS)    echo "  ${GREEN}PASS${NC} $v_m: ${v_drop}% (Δ${v_delta_abs} ns/op) within [-5%,${v_t}%] (off spread ${v_spread}%)"; verdict_pass=$((verdict_pass+1));;
                FAIL)    echo "  ${RED}FAIL${NC} $v_m: +${v_drop}% (Δ${v_delta_abs} ns/op) > ${v_t}% threshold"; verdict_fail=$((verdict_fail+1));;
                INVALID) echo "  ${YELLOW}INVALID${NC} $v_m: ${v_drop}% (on faster than off by >5% — switch not effective? measurement anomaly)"; verdict_invalid=$((verdict_invalid+1));;
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
    local ft_cell ft_path ft_hooks ft_ns ft_delta b_delta ft_offm ft_onm
    local any_xcheck=0
    echo ""
    echo "  ftrace cross-check (per cell):"
    for ft_cell in "${bench_cells[@]}"; do
        # cell = <path>_<size>f<flows> → path×size 部分
        ft_path="${ft_cell%f*}"           # "udp4_64"（f1 与 f16 共用）
        ft_hooks="${values[AB|ftrace_hooks_per_op_${ft_path}f1_vals]:-}"
        ft_hooks=$(printf '%s' "$ft_hooks" | awk '{print $1}')
        # 单次耗时按路径取（cell 前缀去 _size）
        local ft_ponly="${ft_path%%_*}"   # "udp4"
        ft_ns="${values[AB|ftrace_hook_ns_p50_${ft_ponly}_vals]:-}"
        ft_ns=$(printf '%s' "$ft_ns" | awk '{print $1}')
        ft_offm=$(_med_of OFF "bench_${ft_cell}_ns_per_op")
        ft_onm=$(_med_of ON "bench_${ft_cell}_ns_per_op")
        if [ -n "$ft_hooks" ] && [ -n "$ft_ns" ] && [ -n "$ft_offm" ] && [ -n "$ft_onm" ]; then
            ft_delta=$(awk -v h="$ft_hooks" -v n="$ft_ns" 'BEGIN {printf "%.0f", h * n}')
            b_delta=$(awk -v a="$ft_offm" -v b="$ft_onm" 'BEGIN {printf "%.0f", b - a}')
            any_xcheck=1
            echo "    ${ft_cell}: measured Δ=${b_delta} ns/op, predicted ≈ ${ft_hooks} hooks × ${ft_ns}ns = ${ft_delta} ns/op"
        fi
    done
    if [ "$any_xcheck" = 0 ]; then
        echo "    (no ftrace hooks/hook-ns data — AB log missing ftrace metrics?)"
    fi

    # Perf-C 每 socket 内存：degradation = AB-K0 (bytes)，阈值 192
    # 阈值 192 = 72(struct net_delayacct) + 56(SLAB_HWCACHE_ALIGN 64B 对齐填充) + 64(余量)
    # /proc/slabinfo 第 4 列是 s->size（含 64 字节缓存行对齐），非 s->object_size（原始 struct）
    # TCP slab 用 SLAB_HWCACHE_ALIGN（tcp.c kmem_cache_create），ON struct 增加 72B 后
    # 跨 64B 边界 → 对齐填充 56B → slab delta 128B。原始 struct 开销仅 72B（<= 80 理论阈值）。
    # 数据源：values 数组（K0| = OFF 内核 boot 基线，AB| = ON 内核 boot），
    # 非纯数值样本（串口污染）已在解析段被丢弃，这里直接取中位数即可
    v_m="sock_objsize_bytes"; v_t=192
    THRESHOLDS[$v_m]="${v_t}B"
    local k0_sock k3_sock
    k0_sock=$(_med_of K0 "$v_m")
    k3_sock=$(_med_of AB "$v_m")
    if [ -n "$k0_sock" ] && [ -n "$k3_sock" ]; then
        v_drop=$((k3_sock - k0_sock))
        status=$(_verdict3 "$v_drop" "$v_t")
        case "$status" in
            PASS)    echo "  ${GREEN}PASS${NC} sock_objsize: +${v_drop} bytes <= ${v_t} threshold (raw struct ~72B + slab align)"; verdict_pass=$((verdict_pass+1));;
            FAIL)    echo "  ${RED}FAIL${NC} sock_objsize: +${v_drop} bytes > ${v_t} threshold"; verdict_fail=$((verdict_fail+1));;
            INVALID) echo "  ${YELLOW}INVALID${NC} sock_objsize: ON<OFF (measurement anomaly — compile-time constant)"; verdict_invalid=$((verdict_invalid+1));;
        esac
    else
        status="SKIP"
        echo "  ${YELLOW}SKIP${NC} sock_objsize: no data (K0=${k0_sock:-none}, AB=${k3_sock:-none})"
        verdict_skip=$((verdict_skip+1))
    fi
    VERDICTS[$v_m]="$status"

    # ---- 信息性指标（ftrace/dump，不影响 verdict）----
    # ON 态的导出开销直接由 Perf-D dump_per_call_us 量化，对比表中已含列

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
                if [ "$evaluated" -gt 0 ] && [ $((verdict_invalid * 2)) -gt "$evaluated" ]; then
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
    echo "Full logs: $LOG_DIR/perf-{K0,AB}-${TIMESTAMP}.log"

    # ---- 打印对比表（verdict 计算完成后，回填真实 Thresh/Verdict）----
    # Δns/op 列 = 每包 CPU 成本（主指标，绝对量）；Δ% 列 = 相对开销量级
    # bench 格显示短名（去 bench_ 前缀与 _ns_per_op 后缀）
    # sock_objsize 行：Δ 列显示字节差（编译期确定值）；info 行 Δ 列为 "-"
    echo ""
    echo "+-------------------------------------------------------------------------------------------------+"
    echo "|          NET_DELAYACCT Per-Packet CPU Cost Matrix (same-boot OFF vs ON)                         |"
    echo "+-------------------------------------------------------------------------------------------------+"
    printf "| %-28s | %9s | %9s | %7s | %8s | %8s | %-7s |\n" \
        "Cell (path_size_flows)" "OFF" "ON" "Δns/op" "Δ%" "Thresh" "Verdict"
    echo "+-------------------------------------------------------------------------------------------------+"
    local entry _t_metric _t_lbl _t_abs _t_pct
    for entry in "${table_metrics[@]}"; do
        _t_metric="${entry%%:*}"
        _t_lbl="$_t_metric"
        [[ "$_t_lbl" == bench_* ]] && _t_lbl="${_t_lbl#bench_}" && _t_lbl="${_t_lbl%_ns_per_op}"
        case "$_t_lbl" in
            ftrace_hooks_per_op_*) _t_lbl="hooks/${_t_lbl#ftrace_hooks_per_op_}";;
            ftrace_hook_ns_p50_*)  _t_lbl="hookns/${_t_lbl#ftrace_hook_ns_p50_}";;
        esac
        if [ "$_t_metric" = "sock_objsize_bytes" ]; then
            _t_abs="${SUM_DON[$_t_metric]:--}"; _t_pct="-"
        elif [[ "$_t_metric" == bench_* ]]; then
            _t_abs="${SUM_ABS[$_t_metric]:--}"; _t_pct="${SUM_DON[$_t_metric]:--}"
        else
            _t_abs="-"; _t_pct="-"
        fi
        printf "| %-28s | %9s | %9s | %7s | %8s | %8s | %-7s |\n" \
            "$_t_lbl" "${SUM_MEDOFF[$_t_metric]:-SKIP}" "${SUM_MEDON[$_t_metric]:-SKIP}" \
            "$_t_abs" "$_t_pct" \
            "${THRESHOLDS[$_t_metric]:--}" "${VERDICTS[$_t_metric]:-info}"
    done
    echo "+-------------------------------------------------------------------------------------------------+"
    echo ""

    # 生成结构化摘要报告（Markdown + CSV）
    # 回填 threshold/verdict：按 table_metrics 顺序从存储数组重组摘要行
    SUMMARY_ROWS=""
    for entry in "${table_metrics[@]}"; do
        m_metric="${entry%%:*}"
        SUMMARY_ROWS+="${m_metric}	${SUM_UNIT[$m_metric]}	${SUM_RAWOFF[$m_metric]:-SKIP}	${SUM_RAWON[$m_metric]:-SKIP}	${SUM_MEDOFF[$m_metric]:-SKIP}	${SUM_MEDON[$m_metric]:-SKIP}	${SUM_DON[$m_metric]:--}	${THRESHOLDS[$m_metric]:--}	${VERDICTS[$m_metric]:-info}"$'\n'
    done
    write_summary_files "$SUMMARY_ROWS" "$ab_mode"
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
  K0: OFF 内核（CONFIG_NET_DELAYACCT=n）— 仅 slab 基线
  AB: ON 内核，同 boot A/B（static key 运行时开关交错翻转 OFF/ON，
      bench 24 格矩阵 + ftrace 对账 + slab + dump）
  （v2 的 K2/K3 跨 boot 对比已废弃 20260819：二进制布局差异与启动间
   漂移不可归因，"ON 比 OFF 快" 假象源于此）

Options:
  --skip-build              复用已有 bzImage-on/off（不重新构建内核）
  --runs=N                  AB 对数（默认 3，每对 = OFF 块 + ON 块各 24 格，
                              每格自动校准 ~1s）
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
  # 同 boot A/B（默认）
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
    echo "=== NET_DELAYACCT Performance Test (same-boot A/B) $(date) ==="
    echo "Linux source: $LINUX_SRC"
    echo "Log dir: $LOG_DIR"
    echo "Boots: K0 (OFF kernel, slab baseline) + AB (ON kernel, same-boot A/B)"
    echo "AB pairs: $PERF_RUNS (each pair = OFF block + ON block, 24-cell matrix)"
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

    # Step 4: QEMU 运行（v3 同 boot A/B，boot 编排 2 次）
    #
    # v2 的 WARM/K0R/K3R/K0B 交错重复启动全部移除：同 boot 差分对启动间
    # 漂移免疫（OFF/ON 样本来自同一次启动，交错块起始状态逐对交替使
    # 时漂对两态等权），宿主侧绑核仅用于降低轮间抖动。
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

    # boot1 K0: OFF 内核 → 仅 slab 基线（顺带预热宿主频率/缓存，替代 v2 WARM）
    run_perf_in_qemu "$BZIMAGE_OFF" "K0" 1
    echo ""
    # boot2 AB: ON 内核 → 同 boot A/B 全套（bench AB 矩阵 + ftrace + slab + dump）
    run_perf_in_qemu "$BZIMAGE_ON" "AB" "$PERF_RUNS"
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

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# 性能对比测试：CONFIG_NET_DELAYACCT=n (基线) vs CONFIG_NET_DELAYACCT=y (开启)
#
# 工作流程：
#   1. 接收两个内核镜像路径 (kernel-a: 基线, kernel-b: 开启)
#   2. 分别使用 QEMU 引导每个内核
#   3. 在 VM 内运行 iperf3 (吞吐) 和 netperf (延迟) 基准测试
#   4. 收集结果并生成对比表
#   5. 输出到 stdout 和 tests/reports/perf-<date>.txt
#
# 用法: ./baseline-vs-enabled.sh <kernel-a-bzImage> <kernel-b-bzImage>
#
# 环境变量（可选）：
#   QEMU_BIN       - QEMU 可执行文件路径 (默认 qemu-system-x86_64)
#   QEMU_MEM       - VM 内存大小 (默认 2G)
#   QEMU_CPUS      - VM CPU 数量 (默认 2)
#   INITRAMFS      - initramfs 镜像路径 (必须包含 iperf3/netperf)
#   IPERF_HOST     - 外部 iperf3 服务端地址 (若不使用本地回环)
#   NETPERF_HOST   - 外部 netperf 服务端地址

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="$SCRIPT_DIR/../reports"
DATE_STR=$(date +%Y%m%d)
REPORT_FILE="$REPORT_DIR/perf-${DATE_STR}.txt"

# 参数检查
if [ $# -lt 2 ]; then
	echo "Usage: $0 <kernel-a-bzImage> <kernel-b-bzImage>"
	echo "  kernel-a: CONFIG_NET_DELAYACCT=n (baseline)"
	echo "  kernel-b: CONFIG_NET_DELAYACCT=y (enabled)"
	exit 1
fi

KERNEL_A="$1"
KERNEL_B="$2"

# 验证内核镜像存在
for kern in "$KERNEL_A" "$KERNEL_B"; do
	if [ ! -f "$kern" ]; then
		echo "ERROR: kernel image not found: $kern"
		exit 1
	fi
done

# QEMU 配置
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
QEMU_MEM="${QEMU_MEM:-2G}"
QEMU_CPUS="${QEMU_CPUS:-2}"
INITRAMFS="${INITRAMFS:-}"

# 检查 QEMU 可用
if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
	echo "ERROR: QEMU not found: $QEMU_BIN"
	echo "  Install qemu-system-x86_64 or set QEMU_BIN environment variable."
	exit 1
fi

# 创建报告目录
mkdir -p "$REPORT_DIR"

# 基准测试参数
IPERF_DURATION=30
IPERF_HOST="${IPERF_HOST:-127.0.0.1}"
NETPERF_HOST="${NETPERF_HOST:-127.0.0.1}"

echo "============================================"
echo "  Performance Comparison: baseline vs enabled"
echo "  Date: $(date)"
echo "  Kernel A (baseline): $KERNEL_A"
echo "  Kernel B (enabled):  $KERNEL_B"
echo "  Report: $REPORT_FILE"
echo "============================================"
echo ""

# 运行单个内核的基准测试
# 参数: $1 = 内核镜像路径, $2 = 标签 (baseline/enabled)
run_benchmarks() {
	local kernel="$1"
	local label="$2"
	local result_file
	result_file=$(mktemp)

	echo "--- Running benchmarks with $label kernel ---"

	# 构造 QEMU 命令
	local qemu_args=(
		"$QEMU_BIN"
		"-kernel" "$kernel"
		"-m" "$QEMU_MEM"
		"-smp" "$QEMU_CPUS"
		"-nographic"
		"-no-reboot"
	)

	if [ -n "$INITRAMFS" ]; then
		qemu_args+=("-initrd" "$INITRAMFS")
		qemu_args+=("-append" "console=ttyS0 rdinit=/bin/sh")
	fi

	# 在 VM 内运行的测试脚本
	# 通过串口输出结果，格式为 BENCH:<name>=<value>
	local vm_script
	vm_script=$(cat <<'VMEOF'
#!/bin/sh
# 等待网络就绪
sleep 2

# TCP 吞吐测试
if command -v iperf3 >/dev/null 2>&1; then
    iperf3 -c IPERF_HOST_PLACEHOLDER -t IPERF_DURATION_PLACEHOLDER -J > /tmp/iperf_tcp.json 2>&1
    if [ -f /tmp/iperf_tcp.json ]; then
        bps=$(cat /tmp/iperf_tcp.json | grep -o '"bits_per_second":[0-9.]*' | tail -1 | cut -d: -f2)
        rtt=$(cat /tmp/iperf_tcp.json | grep -o '"mean"[0-9.]*' | head -1 | cut -d: -f2)
        echo "BENCH:tcp_throughput_bps=$bps"
        echo "BENCH:tcp_rtt_us=$rtt"
    fi
fi

# netperf TCP_RR 延迟测试
if command -v netperf >/dev/null 2>&1; then
    result=$(netperf -H NETPERF_HOST_PLACEHOLDER -t TCP_RR -- -r 1,1 2>&1)
    latency=$(echo "$result" | grep -oE '[0-9.]+$' | tail -1)
    echo "BENCH:tcp_rr_latency_us=$latency"
fi

echo "BENCH:done=1"
VMEOF
)

	# 替换占位符
	vm_script=${vm_script//IPERF_HOST_PLACEHOLDER/$IPERF_HOST}
	vm_script=${vm_script//IPERF_DURATION_PLACEHOLDER/$IPERF_DURATION}
	vm_script=${vm_script//NETPERF_HOST_PLACEHOLDER/$NETPERF_HOST}

	# 如果没有 initramfs，使用本地直接运行的方式
	if [ -z "$INITRAMFS" ]; then
		echo "  [INFO] No initramfs specified, running benchmarks locally."
		echo "  [WARN] Ensure you are running on the correct kernel."

		# TCP 吞吐测试
		if command -v iperf3 >/dev/null 2>&1; then
			iperf3 -s -D 2>/dev/null || true
			sleep 1
			local iperf_out
			iperf_out=$(iperf3 -c "$IPERF_HOST" -t "$IPERF_DURATION" -J 2>&1 || true)
			local tcp_bps tcp_rtt
			tcp_bps=$(echo "$iperf_out" | grep -o '"bits_per_second":[0-9.]*' | tail -1 | cut -d: -f2 || echo "0")
			tcp_rtt=$(echo "$iperf_out" | grep -o '"mean":[0-9.]*' | head -1 | cut -d: -f2 || echo "0")
			echo "BENCH:tcp_throughput_bps=$tcp_bps" | tee -a "$result_file"
			echo "BENCH:tcp_rtt_us=$tcp_rtt" | tee -a "$result_file"
			pkill -f "iperf3 -s" 2>/dev/null || true
		fi

		# netperf 延迟测试
		if command -v netperf >/dev/null 2>&1; then
			netperf -H "$NETPERF_HOST" -t TCP_RR -- -r 1,1 > /tmp/netperf_rr.txt 2>&1 || true
			local rr_latency
			rr_latency=$(grep -oE '[0-9.]+$' /tmp/netperf_rr.txt | tail -1 || echo "0")
			echo "BENCH:tcp_rr_latency_us=$rr_latency" | tee -a "$result_file"
		fi
	else
		# 使用 QEMU 引导内核并运行测试
		echo "  Booting kernel with QEMU..."
		echo "$vm_script" > /tmp/vm_bench_script.sh
		chmod +x /tmp/vm_bench_script.sh

		# 运行 QEMU，超时 120 秒
		timeout 120 "${qemu_args[@]}" -serial mon:stdio 2>&1 | \
			grep "^BENCH:" > "$result_file" || true
	fi

	echo "  Results for $label:"
	cat "$result_file"
	echo ""

	# 输出结果变量
	echo "$result_file"
}

# 解析结果文件
# 参数: $1 = 结果文件路径, $2 = 指标名称
get_metric() {
	local file="$1"
	local metric="$2"
	grep "^BENCH:${metric}=" "$file" | tail -1 | cut -d= -f2 || echo "N/A"
}

# 格式化吞吐量为可读单位
format_throughput() {
	local bps=$1
	if [ "$bps" = "N/A" ] || [ -z "$bps" ]; then
		echo "N/A"
		return
	fi
	# 转换为 Gbps
	local gbps
	gbps=$(echo "scale=2; $bps / 1000000000" | bc 2>/dev/null || echo "N/A")
	echo "${gbps} Gbps"
}

# 运行两组测试
RESULT_A=$(run_benchmarks "$KERNEL_A" "baseline")
RESULT_B=$(run_benchmarks "$KERNEL_B" "enabled")

# 提取指标
TCP_BPS_A=$(get_metric "$RESULT_A" "tcp_throughput_bps")
TCP_BPS_B=$(get_metric "$RESULT_B" "tcp_throughput_bps")
TCP_RTT_A=$(get_metric "$RESULT_A" "tcp_rtt_us")
TCP_RTT_B=$(get_metric "$RESULT_B" "tcp_rtt_us")
TCP_RR_A=$(get_metric "$RESULT_A" "tcp_rr_latency_us")
TCP_RR_B=$(get_metric "$RESULT_B" "tcp_rr_latency_us")

# 生成对比表
generate_table() {
	cat <<TABLE_EOF
============================================================
            Performance Comparison Table
============================================================
Metric                 | Baseline (n)    | Enabled (y)     | Delta
-----------------------|-----------------|-----------------|--------
TCP Throughput         | $(printf '%-15s' "$(format_throughput "$TCP_BPS_A")") | $(printf '%-15s' "$(format_throughput "$TCP_BPS_B")") | -
TCP RTT (us)           | $(printf '%-15s' "${TCP_RTT_A:-N/A}") | $(printf '%-15s' "${TCP_RTT_B:-N/A}") | -
TCP_RR Latency (us)    | $(printf '%-15s' "${TCP_RR_A:-N/A}") | $(printf '%-15s' "${TCP_RR_B:-N/A}") | -
============================================================
TABLE_EOF
}

# 输出到 stdout 和报告文件
{
	echo "============================================"
	echo "  NET_DELAYACCT Performance Report"
	echo "  Date: $(date)"
	echo "  Kernel A (baseline, CONFIG_NET_DELAYACCT=n): $KERNEL_A"
	echo "  Kernel B (enabled, CONFIG_NET_DELAYACCT=y):  $KERNEL_B"
	echo "  iperf3 duration: ${IPERF_DURATION}s"
	echo "  QEMU: $QEMU_BIN, mem=$QEMU_MEM, cpus=$QEMU_CPUS"
	echo "============================================"
	echo ""
	generate_table
	echo ""
	echo "Raw values:"
	echo "  TCP throughput (bps): A=$TCP_BPS_A  B=$TCP_BPS_B"
	echo "  TCP RTT (us):         A=$TCP_RTT_A  B=$TCP_RTT_B"
	echo "  TCP_RR latency (us):  A=$TCP_RR_A  B=$TCP_RR_B"
} | tee "$REPORT_FILE"

echo ""
echo "Report saved to: $REPORT_FILE"

# 清理临时文件
rm -f "$RESULT_A" "$RESULT_B" /tmp/vm_bench_script.sh 2>/dev/null || true

exit 0

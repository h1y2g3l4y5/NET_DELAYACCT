#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# 辅助函数库，供 net-delayacct selftests 使用。
# 包含 test_pass/test_fail、网络命名空间管理、命令/配置检查等工具函数。
# 此文件通过 source 引入，不直接执行。

# 计数器：记录通过/失败的用例数
TEST_PASS_COUNT=0
TEST_FAIL_COUNT=0

# 输出 PASS 信息并递增通过计数
test_pass() {
	TEST_PASS_COUNT=$((TEST_PASS_COUNT + 1))
	echo "[PASS] $1"
}

# 输出 FAIL 信息并递增失败计数，随后以非零状态退出
test_fail() {
	TEST_FAIL_COUNT=$((TEST_FAIL_COUNT + 1))
	echo "[FAIL] $1"
	exit 1
}

# 创建网络命名空间用于隔离测试
# 用法: setup_ns <ns_name>
setup_ns() {
	local ns_name=$1

	ip netns add "$ns_name" 2>/dev/null || true
	ip netns exec "$ns_name" ip link set lo up 2>/dev/null || true
}

# 清理网络命名空间
# 用法: cleanup_ns <ns_name>
cleanup_ns() {
	local ns_name=$1

	ip netns del "$ns_name" 2>/dev/null || true
}

# 检查命令是否可用，不可用则跳过测试（exit code 4 = kselftest skip）
# 用法: require_cmd <command_name>
require_cmd() {
	local cmd=$1

	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "SKIP: required command '$cmd' not found"
		exit 4
	fi
}

# 检查内核配置选项是否启用
# 用法: require_kernel_config <CONFIG_OPTION>
# 检查路径优先级：/proc/config.gz > /boot/config-$(uname -r)
require_kernel_config() {
	local config=$1
	local config_src=""

	if [ -f /proc/config.gz ]; then
		config_src="/proc/config.gz"
	elif [ -f "/boot/config-$(uname -r)" ]; then
		config_src="/boot/config-$(uname -r)"
	fi

	if [ -z "$config_src" ]; then
		echo "SKIP: cannot find kernel config to verify $config"
		exit 4
	fi

	case "$config_src" in
		*.gz)
			if ! zcat "$config_src" 2>/dev/null | grep -q "^${config}=y"; then
				echo "SKIP: kernel config $config not enabled"
				exit 4
			fi
			;;
		*)
			if ! grep -q "^${config}=y" "$config_src" 2>/dev/null; then
				echo "SKIP: kernel config $config not enabled"
				exit 4
			fi
			;;
	esac
}

# 查找 get_sockdelays 二进制文件路径
# 优先使用环境变量 GET_SOCKDELAYS，否则在常见路径中搜索
# 用法: find_get_sockdelays
find_get_sockdelays() {
	# Use ${VAR:-} to be safe under 'set -u' — the variable may be unset
	# when GET_SOCKDELAYS is not exported in the environment (e.g. local
	# QEMU tests).  Without this, the -n test below triggers
	# "unbound variable" and aborts before we can search for the binary.
	if [ -n "${GET_SOCKDELAYS:-}" ] && [ -x "${GET_SOCKDELAYS:-}" ]; then
		return 0
	fi

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

	local candidates=(
		"$script_dir/../../../userspace/get_sockdelays/get_sockdelays"
		"$script_dir/../../userspace/get_sockdelays/get_sockdelays"
		"$script_dir/../../../tools/net/get_sockdelays"
		"$(command -v get_sockdelays 2>/dev/null)"
	)

	local candidate
	for candidate in "${candidates[@]}"; do
		if [ -n "$candidate" ] && [ -x "$candidate" ]; then
			GET_SOCKDELAYS="$candidate"
			return 0
		fi
	done

	echo "SKIP: get_sockdelays binary not found"
	echo "  Set GET_SOCKDELAYS environment variable to its path."
	exit 4
}

# 检查 net_delayacct generic netlink family 是否在内核中注册
# 通过实际调用 get_sockdelays 验证（不依赖 /proc/net/genetlink）
require_net_delayacct_family() {
	if ! "$GET_SOCKDELAYS" -p 1 >/dev/null 2>&1; then
		# get_sockdelays failed — could be missing genl family or other issue
		local err
		err=$("$GET_SOCKDELAYS" -p 1 2>&1 || true)
		echo "SKIP: net_delayacct genl family not accessible: $err"
		exit 4
	fi
}

# 打印测试摘要
# 用法: print_summary
print_summary() {
	echo ""
	echo "=== Test Summary ==="
	echo "Passed: $TEST_PASS_COUNT"
	echo "Failed: $TEST_FAIL_COUNT"
	if [ "$TEST_FAIL_COUNT" -gt 0 ]; then
		return 1
	fi
	return 0
}

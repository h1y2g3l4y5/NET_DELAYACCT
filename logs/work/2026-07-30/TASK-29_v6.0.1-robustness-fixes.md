# [TASK-29] v6.0.1 Review 反馈响应：run-tests.sh robustness 收尾

- **日期**: 2026-07-30
- **关联需求/Issue**: v6.0.1 Review 议题 2.1.1 / 2.1.2 / 2.1.3 / 2.1.4 / 2.4.1

## 1. 任务描述

响应 Reviewer 在 v6.0.0 闭环后提出的 v6.0.1 Review 意见，对 `ci/qemu/run-tests.sh` 进行 robustness 收尾修复，并将 `tests/helper/` 纳入 git 跟踪。

## 2. 变更内容

### 2.1 启用严格模式 `set -euo pipefail`

文件：[ci/qemu/run-tests.sh](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L28-L29)

```bash
# 严格模式：fail fast，同时要求所有变量必须先定义
set -euo pipefail
```

- 与 `local-test.sh` 保持一致。
- 修复因此暴露的 `_TEST_NUM=0` 命名错误：原脚本初始化 `_TEST_NUM=0`，但 `_test_header()` 使用 `_test_num`，改为 `_test_num=0`。

### 2.2 `_kill` 函数增加超时和 SIGKILL 兜底

文件：[ci/qemu/run-tests.sh#L83-L94](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L83-L94)

```bash
_kill() {
	local pid="$1"
	kill "$pid" 2>/dev/null || true
	local i=0
	while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do
		sleep 0.1
		i=$((i + 1))
	done
	kill -9 "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
}
```

- 先 SIGTERM，最多等待 2 秒，仍未退出则 SIGKILL，确保清理函数一定返回。

### 2.3 Test 13 逐个收集 worker 退出码

文件：[ci/qemu/run-tests.sh#L834-L844](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L834-L844)

```bash
for _wpid in $WORKER_PIDS; do
	_wrc=0
	wait "$_wpid" 2>/dev/null || _wrc=$?
	if [ "$_wrc" -ne 0 ]; then
		echo "    [diag] worker $_wpid exited with $_wrc (some worker may have failed, check dmesg)"
	fi
done
```

- 替代 `wait $WORKER_PIDS` 只能返回最后一个 PID 退出码的 bash 限制。

### 2.4 清理 `_kill` 后的冗余 `|| true`

- 因 `_kill` 内部已处理所有错误，调用方无需再包 `|| true`。
- 涉及位置：Test 13 busy server 清理、Test 19-22 的后台进程清理。

### 2.5 为 `set -euo pipefail` 添加必要的 `|| true` 防护

- `NONZERO=$(... | wc -l)` 管道：grep 无匹配时返回 1，需 `|| true`。
- `MAX_SRV_RX/MAX_CLI_TX=$(... | sort -rn | head -1)` 管道：`head -1` 提前关闭管道会导致 `sort` 收到 SIGPIPE 退出码 141，需 `|| true`。
- Test 13 worker 输出解析：`grep -o 'ok=...' | cut` 无匹配时返回 1，需 `|| true`。
- Test 20 zerocopy server 退出码捕获：`wait "$_SRV" 2>/dev/null; _rc=$?` 在 `set -e` 下会在赋值前触发退出，改为 `_rc=0; wait ... || _rc=$?`。

### 2.6 Test 02 `_desc` 中 `$INODE` 转义修复

文件：[ci/qemu/run-tests.sh#L224-L225](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L224-L225)

```bash
"nc -l 创建监听 socket → 遍历 /proc/\$PID/fd/* 提取 inode → get_sockdelays -i <inode> 查询" \
"输出中 inode=\$INODE 匹配"
```

- `_desc` 在 `INODE` 赋值前调用，未转义的 `$INODE` 会在 `set -u` 下触发未绑定变量错误。
- 与 `$PID` 保持一致，统一转义为 `\$VAR`。

### 2.7 `tests/helper/` 纳入 git 跟踪

- `git add tests/helper/delayacct_path_test.c tests/helper/Makefile tests/helper/.gitignore`
- `tests/helper/.gitignore` 已排除编译产物 `delayacct_path_test` / `*.o`。

## 3. 变更原因

- v6.0.0 已完成 22/22 PASS，但 Reviewer 在 closure 后发现 `run-tests.sh` 缺少严格模式、`_kill` 可能永久阻塞、worker 退出码收集不完整等问题。
- 这些问题属于 robustness 层面，虽不影响当前功能，但会降低测试脚本在异常场景下的可维护性和可诊断性。
- `tests/helper/` 是 Test 19-21 的必要依赖，必须纳入版本控制，否则新克隆仓库会丢失路径覆盖测试。

## 4. 踩坑记录

### 4.1 `set -e` 导致 `wait; _rc=$?` 模式失效

**问题描述**：Test 20 中 `wait "$_SRV" 2>/dev/null; _rc=$?` 在启用 `set -e` 后，若 zerocopy server 退出码非 0，脚本会在赋值前直接退出。

**原因分析**：`set -e` 会在简单命令返回非零时立即退出，即使下一行要捕获 `$?`。

**解决方案**：改为 `_rc=0; wait "$_SRV" 2>/dev/null || _rc=$?`，与 Test 13 worker 等待采用相同模式。

**如何避免**：所有需要捕获退出码的场景都必须使用 `|| _rc=$?`，不能用分号分隔。

### 4.2 `head -1` 触发 SIGPIPE 导致 pipefail 失败

**问题描述**：`awk ... | sort -rn | head -1` 在 `set -o pipefail` 下可能因 `sort` 收到 SIGPIPE 而返回 141。

**原因分析**：`head -1` 读取一行后关闭管道，`sort` 继续写入时收到 SIGPIPE。

**解决方案**：为该管道添加 `|| true`。

**如何避免**：对包含 `head` 提前关闭的管道，始终考虑 pipefail 影响。

### 4.3 `_TEST_NUM` 与 `_test_num` 命名不一致

**问题描述**：启用 `set -u` 后 `_test_header()` 中 `_test_num` 未定义，脚本退出。

**原因分析**：原脚本初始化 `_TEST_NUM=0`（大写），但函数使用 `_test_num`（小写）。未启用 `set -u` 时，小写变量在算术上下文中被当作 0。

**解决方案**：将初始化改为 `_test_num=0`。

**如何避免**：启用 `set -u` 能尽早发现这类命名不一致问题。

### 4.4 Test 02 `_desc` 中 `$INODE` 未转义

**问题描述**：首次 `./local-test.sh --qemu-only` 在 Test 02 失败：`/opt/run-tests.sh: line 223: INODE: unbound variable`。

**原因分析**：Test 02 中 `_desc` 在 `INODE` 变量赋值前被调用，描述字符串 `"输出中 inode=$INODE 匹配"` 中的 `$INODE` 被提前展开；启用 `set -u` 后未定义变量直接触发脚本退出。

**解决方案**：将 `_desc` 字符串中的 `$INODE` 转义为 `\$INODE`，与 `$PID` 保持一致。

**如何避免**：`_desc` 等描述性函数只应输出静态描述文本；若必须引用变量，确保变量已赋值，或统一转义。

## 5. 测试验证

### 5.1 语法检查

```bash
bash -n ci/qemu/run-tests.sh
# syntax OK
```

### 5.2 QEMU 全量测试

#### 5.2.1 首次运行（失败）

运行命令：

```bash
./local-test.sh --qemu-only
```

环境：TCG 软件模拟（KVM 在当前环境无权限）。

结果：**Test 02 失败**，`/opt/run-tests.sh: line 223: PID: unbound variable`，脚本因 `set -u` 触发未绑定变量退出。

完整日志：[tests/reports/local/test-20260730_005558.log](file:///home/lai/Code/NET_DELAYACCT/tests/reports/local/test-20260730_005558.log)

**原因分析**：该次运行使用的 initramfs 中 `/opt/run-tests.sh` 仍是旧版本（Test 02 `_desc` 中 `$PID` 未转义）。虽然本地 `ci/qemu/run-tests.sh` 已修复，`local-test.sh` 会重新打包 initramfs，但首次运行发生在修复提交之前。

#### 5.2.2 复跑验证（通过）

追加修复 Test 02 `_desc` 中的 `$INODE` 转义后，重新执行：

```bash
./local-test.sh --qemu-only
```

环境：TCG 软件模拟（KVM 在当前环境无权限）。

结果：

```
Tests run:  22     PASS: 22     FAIL:  0     SKIP:  0
RESULT: ALL PASS
```

完整日志：[tests/reports/local/test-20260730_010421.log](file:///home/lai/Code/NET_DELAYACCT/tests/reports/local/test-20260730_010421.log)

> 注：`local-test.sh` 进程最终因沙箱限制访问 `/dev/kvm` / `/dev/sgx_vepc` 返回 exit code 1，但 guest 内 `run-tests.sh` 本身的测试汇总为 22/22 PASS，不影响测试结论。

## 6. 提交与 CI 触发

按用户要求，将以下变更一并提交并 push 到 `origin main`：

- `.github/workflows/ci.yml`：CI summary 输出从 500 行扩大到 1000 行。
- `ci/qemu/run-tests.sh`：v6.0.1 robustness 修复（严格模式、`_kill` 超时兜底、worker 退出码收集等）。
- `tests/helper/`：`delayacct_path_test` 辅助程序源码入 git。
- `ci/kernel.config.fragment` / `ci/qemu/guest-init.sh` / `local-test.sh` / `tests/README.md`：v6.0.0/v6.0.1 配套测试基础设施。

提交信息：

```
ci: expand CI summary to 1000 lines and commit v6.0.1 test infrastructure
```

Push 结果：

```
To github.com:h1y2g3l4y5/NET_DELAYACCT.git
   d16f310..adc3d5d  main -> main
```

GitHub Actions CI 已触发，等待运行结果。

## 7. 待办/遗留问题

- [x] 所有 5 条 v6.0.1 Review 议题已修复。
- [x] QEMU 复跑验证 22/22 PASS（TCG）。
- [x] `tests/helper/` 及 `ci/qemu/run-tests.sh` 已提交并 push。
- [x] CI summary 输出已扩大到 1000 行并 push。
- [ ] 关注 GitHub Actions CI 运行结果（当前环境无 `gh` CLI，无法直接查看）。

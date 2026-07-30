# 审查报告 - v6.0.1 [闭环完成]

- **审查日期**: 2026-07-30
- **闭环日期**: 2026-07-30
- **审查范围**: v6.0.0 闭环后对 `ci/qemu/run-tests.sh` 的补充审查；同时确认 `tests/helper/` 版本控制状态
- **审查人**: Reviewer
- **总体评分**: 8.5/10

---

## 一、审查概览

| 审查项 | 评分 | 说明 |
|--------|------|------|
| 代码质量 | 8/10 | v6.0.0 修复后整体清晰，但缺少严格模式和清理超时兜底 |
| 设计合理性 | 9/10 | 22 项测试设计合理，无结构性问题 |
| 测试覆盖 | 9/10 | 已覆盖声明的 splice/zerocopy/corked/IPv6 路径 |
| 文档/日志质量 | 8/10 | 文档完整；review/summary 日志、helper 源码未入版本控制 |
| **综合评分** | **8.5/10** | minor robustness fixes needed |

---

## 二、审查详情

### 2.1 代码质量 (8/10)

#### 优点
- v6.0.0 修复后 Test 13 并发查询、Test 20 zerocopy RX 等关键路径实现清晰。
- 失败诊断机制（`_show_output` / `_output`）完整，对 QEMU 内调试友好。

#### 问题
| # | 严重度 | 问题描述 | 建议 | Worker反馈 |
|---|--------|----------|------|-------------|
| 1 | 中 | `run-tests.sh` 未启用 `set -euo pipefail` | 见下文「问题 2.1.1」 | 接受 |
| 2 | 中 | `_kill` 函数在进程不响应 SIGTERM 时会永久阻塞 | 见下文「问题 2.1.2」 | 接受 |
| 3 | 低 | `wait $WORKER_PIDS` 只能捕获最后一个 PID 的退出码 | 见下文「问题 2.1.3」 | 接受 |
| 4 | 低 | 多处 `|| true` 在 `_kill` 后冗余 | 见下文「问题 2.1.4」 | 接受 |

### 2.2 设计合理性 (9/10)

#### 优点
- 22 项测试覆盖矩阵与实现一致，无结构性设计问题。

#### 问题
无。

### 2.3 测试覆盖 (9/10)

#### 优点
- 已覆盖 sendmsg/recvmsg 主路径及 splice/zerocopy/corked/IPv6 专项路径。

#### 问题
无。

### 2.4 文档/日志质量 (8/10)

#### 优点
- `tests/README.md` 对 22 项测试的原理、断言、时序依赖说明充分。

#### 问题
| # | 严重度 | 问题描述 | 建议 | Worker反馈 |
|---|--------|----------|------|-------------|
| 1 | 中 | `tests/helper/` 源码目录未纳入 git 跟踪 | 见下文「问题 2.4.1」 | 接受 |

---

## 三、分项问题展开

### 问题 2.1.1 — `run-tests.sh` 未启用严格模式

**现象**
- [`ci/qemu/run-tests.sh`](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh) 全文没有任何 `set` 选项；`grep -n "set -"` 无输出。
- 作为对比，[`local-test.sh:20`](file:///home/lai/Code/NET_DELAYACCT/local-test.sh#L20) 已使用 `set -euo pipefail`。

**为什么是问题**
- 缺少 `set -e` 时，中间命令意外失败不会导致脚本退出，而是继续执行，后续断言可能基于错误状态运行。
- 缺少 `set -u` 时，变量名拼写错误会静默展开为空字符串，是最难排查的 bug 来源之一。
- 缺少 `set -o pipefail` 时，管道中只要最后一个命令成功，前面命令的失败会被掩盖。

**触发条件**
- initramfs 资源受限导致 `mktemp -d` 失败；
- busybox applet 行为差异导致某个命令返回非零；
- 脚本维护过程中引入变量名 typo；
- 管道命令（如 `grep | awk`）前半段失败但后半段成功。

**后果**
- 测试可能以奇怪的方式 FAIL 或产生误导性输出；
- 调试时需要额外定位“到底是哪一步失败了”。

**修法**
1. 在脚本开头（`export PATH` 之后）添加 `set -euo pipefail`。
2. 对预期可能失败的命令显式处理：`|| true`、条件判断、`if command; then ... fi` 等。
3. 启用后必须跑一次完整 QEMU 测试，确认没有预期外失败。

**为什么这么修**
- 测试脚本应该“fail fast”，让错误尽早暴露；同时显式处理预期可失败的路径，避免静默吞错。
- 与 `local-test.sh` 保持一致，降低维护者心智负担。

---

### 问题 2.1.2 — `_kill` 函数在进程不响应 SIGTERM 时会永久阻塞

**现象**
- [`ci/qemu/run-tests.sh#L81-L84`](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L81-L84)：
  ```bash
  _kill() {
  	kill "$1" 2>/dev/null || true
  	wait "$1" 2>/dev/null || true
  }
  ```

**为什么是问题**
- `_kill` 先发送 SIGTERM，然后无条件 `wait`。如果目标进程陷入 D 状态、忽略 SIGTERM 或卡住，`wait` 将永远阻塞。
- 虽然 QEMU 外层有 `timeout`，但挂死后只能被强制终止，丢失具体是哪个测试挂死的诊断信息。

**触发条件**
- `iperf3` 或 `delayacct_path_test` 子进程异常卡住；
- 网络栈死锁导致进程无法被 SIGTERM 终止；
- 进程被外部工具（如 strace）attach。

**后果**
- 整个 `run-tests.sh` 挂死，最终由 QEMU timeout 强行结束；
- 无法从日志判断是哪一个测试/进程导致挂死。

**修法**
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

**为什么这么修**
- 测试清理函数必须保证最终能结束，不能依赖被清理进程“配合”退出；
- 等待 2 秒后强制 SIGKILL 是 shell 测试脚本中常见的兜底策略。

---

### 问题 2.1.3 — `wait $WORKER_PIDS` 只能捕获最后一个 PID 的退出码

**现象**
- [`ci/qemu/run-tests.sh#L828-L832`](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L828-L832)：
  ```bash
  _WAIT_RC=0
  wait $WORKER_PIDS 2>/dev/null || _WAIT_RC=$?
  if [ "$_WAIT_RC" -ne 0 ]; then
      echo "    [diag] wait returned $_WAIT_RC (some worker may have failed, check dmesg)"
  fi
  ```

**为什么是问题**
- bash 的 `wait pid1 pid2 ...` 返回**最后一个**被等待 PID 的退出状态。如果非最后一个 worker 异常退出，而最后一个正常退出，`_WAIT_RC` 仍为 0，`[diag]` 消息会漏报。

**触发条件**
- Test 13 的 8 个 worker 中较早崩溃的某个。

**后果**
- worker 异常退出的诊断信息不完整；
- 依赖 `_CRASH` 计数器（检查输出文件是否存在）作为补充检测，但如果崩溃 worker 已经写入了不完整输出文件，`_CRASH` 也不会触发。

**修法**
- 方案 A（推荐）：循环逐个 `wait` 每个 worker PID 并收集退出码：
  ```bash
  for _wpid in $WORKER_PIDS; do
      _rc=0
      wait "$_wpid" 2>/dev/null || _rc=$?
      if [ "$_rc" -ne 0 ]; then
          echo "    [diag] worker $_wpid exited with $_rc"
      fi
  done
  ```
- 方案 B：保持现状，但在注释中明确说明 bash `wait` 多 PID 的语义限制，并依赖 `_CRASH` 计数器兜底。

**为什么这么修**
- 方案 A 能完整收集每个 worker 的退出状态，不依赖 bash 的“最后一个 PID”语义；
- 方案 A 与现有 `_CRASH` 计数器互补，提高可观测性。

---

### 问题 2.1.4 — 多处 `|| true` 在 `_kill` 后冗余

**现象**
- 例如 [`ci/qemu/run-tests.sh#L1259-L1260`](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L1259-L1260)：
  ```bash
  _kill "$_CLI" 2>/dev/null || true
  _kill "$_SRV" 2>/dev/null || true
  ```
- 类似模式在 Test 19-22 中多次出现。

**为什么是问题**
- `_kill` 内部已经对所有命令做了 `|| true`，外部再包一层 `2>/dev/null || true` 无功能意义，反而增加视觉噪音和维护成本。

**触发条件**
- 无功能影响，属于代码整洁度问题。

**后果**
- 阅读时容易误以为 `_kill` 本身可能失败并需要额外兜底。

**修法**
统一改为：
```bash
_kill "$_CLI"
_kill "$_SRV"
```

**为什么这么修**
- 清理函数内部已经处理错误，调用方应保持简洁；
- 如果 `_kill` 未来改进为返回错误码，调用方再根据需要处理。

---

### 问题 2.4.1 — `tests/helper/` 源码目录未纳入 git 跟踪

**现象**
- `git status --short tests/helper/` 显示为 `?? tests/helper/`，即 untracked。
- 该目录包含 `delayacct_path_test.c`、`Makefile` 等源文件，是 Test 19-21 的必要依赖。

**为什么是问题**
- 如果新克隆仓库或不慎 `git clean`，`tests/helper/` 会丢失，导致路径覆盖测试无法构建和运行。
- 当前 `local-test.sh` 和 CI 都依赖该目录生成 `delayacct_path_test` 二进制。

**触发条件**
- 新环境克隆仓库后首次运行测试；
- 执行 `git clean -fdx` 清理未跟踪文件。

**后果**
- Test 19-21 因缺少 helper 而 SKIP，失去对 splice/zerocopy/corked 路径的回归保护；
- 新贡献者可能不知道需要额外获取这些文件。

**修法**
1. 将 `tests/helper/` 下的所有文件加入 git 跟踪：
   ```bash
   git add tests/helper/
   git commit -m "..."
   ```
2. 在 `.gitignore` 中排除编译产物（如 `tests/helper/delayacct_path_test` 二进制），但保留源码和 Makefile。

**为什么这么修**
- 源码文件是项目构建和测试的必要组成部分，应当纳入版本控制；
- 编译产物不应入版本控制，需在 `.gitignore` 中排除。

---

## 四、突出问题总结

### 改进建议（建议采纳）
1. 为 `run-tests.sh` 启用 `set -euo pipefail` 并修复因此暴露的潜在问题。
2. 为 `_kill` 添加等待超时和 SIGKILL 兜底，防止清理挂死。
3. 将 `tests/helper/` 源码目录纳入 git 跟踪。

### 优化建议（可选）
1. 清理 `_kill` 后的冗余 `|| true`。
2. 考虑逐个收集 Test 13 worker 退出码，替代 bash 多 PID `wait` 的“最后一个”语义。

---

## 五、总体评价

v6.0.0 已高质量完成核心目标（22/22 PASS，0 SKIP）。v6.0.1 的目标是对 closure 后发现的 robustness 问题进行收尾修复。本次审查提出的 5 条议题均为中/低严重度，不涉及功能或架构变更。建议作为小版本快速处理，不重新打开 v6.0.0 主 Review。

---

## 六、下版本关注点

- v6.0.1 修复后需在 TCG/KVM 双场景复跑 22 项测试，确认 `set -euo pipefail` 无预期外失败。
- 关注 `_kill` 改进后是否仍然能干净清理所有后台进程。
- CI checkpatch 是否对新增 helper 源文件有风格要求（如 SPDX 头、无 trailing whitespace）。

---

## 七、闭环检查

| 状态 | 数量 | 问题编号 |
|------|------|----------|
| 已解决 | 5 | 2.1.1, 2.1.2, 2.1.3, 2.1.4, 2.4.1 |
| [待回应] | 0 | — |
| [讨论中] | 0 | — |

**[闭环完成]** — 2026-07-30

- Worker 已接受全部 5 条 Review 意见并完成代码修复。
- `./local-test.sh --qemu-only`（TCG 模式）验证 22/22 PASS，0 SKIP；完整日志见 `tests/reports/local/test-20260730_010421.log`。
- 修复过程中追加发现 Test 02 `_desc` 中 `$INODE` 未转义，已一并修复。
- `tests/helper/` 已 staged，待提交。
- 遗留：在 CI KVM runner 上复跑验证（当前环境无 KVM 权限）。

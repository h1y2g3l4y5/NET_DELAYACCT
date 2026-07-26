# TASK-06 修复 Reviewer v2.0.0 复审发现的 2 个新问题

- **日期**: 2026-07-27
- **关联 Review**: v2.0.0 (复审中 → 待闭环)

## 1. 任务描述

Reviewer 对 v2.0.0 修复进行代码核查后，确认 16/17 条议题已修复，但发现 **2 个新的高严重度问题**，均是上一轮修复引入或未闭环的：

1. **问题 2.1.6**：修复 2.1.2 时引入 `cmd_get_by_inode()` 锁序反转（ABBA 死锁）
2. **问题 2.2.3(a) 重开**：GSO 时间戳继承代码方向反 + 死代码，`__copy_skb_header` 不自动拷贝新字段

## 2. 变更内容

### 2.1 修复 2.1.6 — 锁序反转

**文件**: `kernel-patches/net-core-net-delayacct.c`

**变更**：
1. 在 `cmd_get_by_inode()` 函数顶部声明 `char comm[TASK_COMM_LEN];`（循环外）
2. 在 `task_lock(task)` 临界区（L420-426）增加 `memcpy(comm, task->comm, TASK_COMM_LEN)`，与拿 files 引用在同一个 task_lock 内完成
3. 删除命中分支里嵌套在 `files->file_lock` 内的 `task_lock(task)`/`task_unlock(task)`（旧 L458-463），直接使用循环外已拷贝的 `comm`

**锁序统一**：
- 修改前：`file_lock` → `task_lock`（反序，与 `iter_task_sockets` 的 `task_lock` → `file_lock` 相反）
- 修改后：`task_lock`（一次完成 comm 拷贝 + files 引用）→ `file_lock` → `rcu_read_unlock` → reply

### 2.2 修复 2.2.3(a) — GSO 时间戳继承

**文件**:
- `kernel-patches/skbuff_h-modification.patch` — 移动 `delayacct_start` 位置
- `kernel-patches/tx-instrumentation.patch` — 删除错误的 GSO 手动继承代码
- `kernel-patches/net-core-net-delayacct.c` — 更新注释

**变更**：

**(a) skbuff_h-modification.patch**

将 `delayacct_start` 从 `tstamp` 之后（L867，`headers` struct_group 外部）移到 `headers` struct_group 内部（`kcov_handle` 之后，`); /* end headers group */` 之前）。

```
旧位置 (L867): 在 tstamp union 之后，cb[] 之前
新位置 (L1044): 在 headers struct_group 内部，kcov_handle 之后
```

**(b) tx-instrumentation.patch**

删除 `dev_hard_start_xmit` 中的 GSO 手动继承代码（7 行）：
```c
// 删除：
/* Accumulate TX latency per-skb.  For GSO skbs, copy
 * the timestamp from the parent so that every segment
 * is accounted (see NET_DELAYACCT review issue 2.2.3).
 */
if (!skb->delayacct_start && skb->next &&
    skb_is_gso(skb))
    skb->delayacct_start = skb->next->delayacct_start;
```

保留：`net_delayacct_tx_end(skb->sk, skb);`（一行）。

**(c) net-core-net-delayacct.c 注释更新**

将 `tx_start()` 注释中 "each inheriting skb->sk and delayacct_start" 改为详细说明 `__copy_skb_header` 自动拷贝机制。

## 3. 变更原因

### 3.1 锁序反转根因

- 第一轮修复 2.1.2（task->comm 裸读）时，为在 `cmd_get_by_inode` 命中路径拷贝 comm，采用了"在 file_lock 内嵌套 task_lock"的做法
- `iter_task_sockets()` 的正确锁序是 `task_lock → task_unlock → file_lock`
- 反向顺序 `file_lock → task_lock` 与内核全局约定冲突，并发场景下 ABBA 死锁

### 3.2 GSO 继承根因

- `delayacct_start` 原本放在 `headers` struct_group **外部**（L867），`__copy_skb_header()` 只 `memcpy` `headers` 组的内容
- `skb_segment()` 通过 `__copy_skb_header` 创建子段，不会拷贝 `delayacct_start`，子段 `delayacct_start == 0`
- tx-instrumentation.patch 的手动继承代码有三重错误：
  1. **方向反**：从 `skb->next` 复制而非从父 skb
  2. **死条件**：`skb_is_gso(skb)` 在子段上永远为 false（GSO 已在 `validate_xmit_skb` 中完成）
  3. **逻辑上不可能工作**：GSO 在 `validate_xmit_skb()` 中完成、父 skb 被 `consume_skb` 释放，到 `dev_hard_start_xmit` 时父 skb 已不存在

## 4. 踩坑记录

### 坑 1: `git checkout -f` 不清理 untracked files

- **问题**: 重置 linux 树后，patch 创建的源文件（net/core/net-delayacct.c 等）仍然存在，导致 `git apply` 跳过 0005-0007 patch，使用了旧版代码
- **原因**: `git checkout -f` 只恢复 tracked files，patch 创建的新文件是 untracked
- **解决**: 必须 `git checkout -f && git clean -fd` 完整清理
- **如何避免**: 在 `local-test.sh` 的 `step_apply_patches` 开头增加清理逻辑，或在 CI/本地测试文档中明确此步骤

### 坑 2: sandbox 环境 TCG QEMU 无法在合理时间内完成

- **问题**: sandbox 禁止 KVM，TCG 软件模拟 + 完整内核启动 + 13 个测试超过 300s timeout，且无 qemu.log 输出
- **解决**: 编译验证通过后直接推 CI（CI 环境有 KVM，2 分钟内完成）
- **如何避免**: 本地开发时优先编译验证，QEMU 测试依赖 CI 的 KVM 环境

## 5. 测试验证

- 编译验证: `./local-test.sh --kernel-only` 通过（所有 10 个 patch apply 成功，内核 bzImage + 工具编译 OK）
- QEMU 测试: 本地 sandbox TCG 超时，依赖 CI KVM 环境验证
- review 确认: 修复方案已发给 reviewer 等待最终确认

## 6. 待办/遗留问题

- CI QEMU 测试结果待确认
- v2.0.0 17 条议题待 reviewer 最终闭环确认
- v2.1.0 未开始（fault-injection、GSO 统计对比、run-tests.sh 重构）

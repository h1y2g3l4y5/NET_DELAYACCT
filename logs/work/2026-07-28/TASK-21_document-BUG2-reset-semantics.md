# TASK-21 补充 BUG-2 RESET 语义文档

- **日期**: 2026-07-28
- **关联 Review**: v4.0.0
- **关联问题**: BUG-2 [P2] (从 P1 降级，共识为"设计特性，需文档化")
- **关联对话**: DLG-20260727-230000.md

## 1. 任务描述

v4.0.0 审查中 BUG-2 原定为 P1（RESET 命令竞态条件），经与 Reviewer 对话讨论，Reviewer 承认初始 TOCTOU 分析有误：
- `delta = ktime_get_ns() - skb->delayacct_start` 计算独立于 stats 状态，不存在数据丢失
- per-socket 原子性已由 `n->lock` spinlock 保证
- "全局快照不一致"是 `/proc/net/snmp`/`ss` 等多 socket 统计遍历的共性

最终共识：将 BUG-2 降级为 P2，定性为"设计特性，需文档化"，在头文件注释中明确 RESET 语义即可关闭。

## 2. 变更内容

### 2.1 UAPI 头文件 (`include/uapi/linux/net-delayacct.h`)

在 `NET_DELAYACCT_CMD_RESET` 枚举值后追加多行注释：

```c
NET_DELAYACCT_CMD_RESET,	/*
				 * Atomically zero stats per socket under its
				 * own spinlock, but does NOT guarantee a global
				 * atomic snapshot across all sockets. Non-zero
				 * values observed immediately after RESET are
				 * newly arrived packets during the traversal,
				 * which is expected behavior for "reset then
				 * observe" performance testing workflows.
				 */
```

### 2.2 内部头文件 (`include/net/net-delayacct.h`)

扩展 `net_delayacct_reset()` 的 kerneldoc 注释，从 4 行扩展为 17 行，详细说明：
- per-socket spinlock 保护下的原子性
- 不保证跨 socket 的全局原子快照
- 遍历期间新到达的包会被累加（预期行为）
- 与 `/proc/net/snmp`/`ss` 的行为一致
- 满足"清零后观察一段时间"的标准性能测试流程

### 2.3 standalone 头文件同步

- `kernel-patches/include-uapi-linux-net-delayacct.h` — 与源文件同步
- `kernel-patches/include-net-net-delayacct.h` — 与源文件同步
- `userspace/get_sockdelays/linux/net-delayacct.h` — 与源文件同步（用户态 `-I.` 回退）

### 2.4 Patch 文件更新

- **0005-net-add-uapi-header.patch**: 重新生成，77 → 85 insertions，commit message 补充 RESET 语义说明
- **0006-net-add-internal-header.patch**: 重新生成，189 → 200 insertions，commit message 补充 RESET 语义文档化说明
- **0007-net-core-add-module.patch**: 无需修改（代码逻辑无变化）

## 3. 变更原因

- **Reviewer 共识要求**：经对话确认 BUG-2 定性为"设计特性，需文档化"，文档补充是闭环的必要条件
- **避免用户误解**：RESET 命令的用户可能期望"全局原子清零"，明确文档可以避免支持请求和误报 bug
- **对齐内核惯例**：内核其他多对象统计框架（`/proc/net/snmp`、`ss`、netstat）同样不保证遍历原子性，文档化这一约定符合惯例

## 4. 踩坑记录

- **问题**：直接执行 `make -j$(nproc) bzImage` 时因 nfs 子目录增量编译报错（与本次修改无关）
- **原因**：之前后台编译中断导致部分目标文件状态不一致
- **解决方案**：使用项目提供的 `./local-test.sh --qemu-only` 脚本，它会自动从干净的补丁状态重建 initramfs 和内核
- **如何避免**：优先使用项目级测试脚本而非手动 make，确保构建环境一致

## 5. 测试验证

- trailing whitespace 清理：0005/0006 patch 均无 trailing whitespace ✓
- patch body vs source diff：0005 MATCH ✓，0006 MATCH ✓
- 内核模块编译：net/core/net-delayacct.o 编译通过 ✓
- 用户态工具编译：get_sockdelays 重编译成功 ✓
- QEMU 功能测试：**13/13 PASS, 0 FAIL, 0 SKIP** (TCG 模式, 137s) ✓
  - 并发查询压力：320 queries, ok=320 fail=0, no oops ✓

## 6. 待办/遗留问题

- ✅ 文档补充完成，无代码逻辑变更
- v4.0.0 所有议题已达成最终决议，等待 Reviewer 闭环验证
- ISSUE-3/ISSUE-5 共识延后至 v5.0.0

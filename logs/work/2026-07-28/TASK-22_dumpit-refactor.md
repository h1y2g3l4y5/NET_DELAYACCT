# TASK-22 dumpit 重构

- **日期**: 2026-07-28
- **关联 Review**: v5.0.0
- **关联问题**: ISSUE-3
- **关联 ITEM**: ITEM-01_dumpit-refactor.md

## 1. 任务描述

将 `NET_DELAYACCT_CMD_GET_BY_PID` 从 `doit` + 自定义 multi-message 协议改为标准 Generic Netlink `dumpit` 协议（`.start`/`.dumpit`/`.done` 三件套 + `cb->ctx`），消除手动 `NLM_F_MULTI` + `NLMSG_DONE` 处理。

## 2. 变更内容

### 2.1 内核源码 `net/core/net-delayacct.c`

**genl_ops 注册**：
- `GET_BY_PID` 从 `.doit = net_delayacct_cmd_get_by_pid` 改为 `.start`/`.dumpit`/`.done` 三件套
- `GET_BY_INODE` 保持 `.doit` 不变（单条回复）
- `RESET` 保持 `.doit` 不变

**新增函数**：
- `struct net_delayacct_dump_ctx`：dump 迭代状态（task/files/fd/pid/comm），40 字节，存入 `cb->ctx[48]` 内联数组
- `net_delayacct_dump_start()`：PID 解析 + netns 检查 + task/files 引用计数获取
- `net_delayacct_dump_by_pid()`：每次填充一个 socket 到 skb，自动处理消息分片
- `net_delayacct_dump_done()`：释放 task/files 引用计数

**移除函数**：
- `net_delayacct_cmd_get_by_pid()`（旧 doit handler）
- `net_delayacct_iter_task_sockets()`（旧遍历函数）
- `net_delayacct_emit_done()`（手动 NLMSG_DONE 发送）

**保留函数**：
- `net_delayacct_one_reply()`：仍被 `GET_BY_INODE` 的 doit handler 使用
- `net_delayacct_fill_sock()`：不变，被 dumpit 和 doit 共用

### 2.2 用户态工具 `userspace/get_sockdelays/get_sockdelays.c`

- `do_query()` 中，当 cmd 为 `NET_DELAYACCT_CMD_GET_BY_PID` 时添加 `NLM_F_DUMP` 标志
- `send_and_recv()` 接收逻辑不变（已兼容标准 dump 的 NLM_F_MULTI + NLMSG_DONE）

### 2.3 关键技术决策

**cb->ctx vs cb->args**：
- 内核 6.6 中 `struct netlink_callback` 的 `ctx` 是 `u8 ctx[48]` 内联数组（不是 `void *` 指针）
- 不需要 kzalloc/kfree，直接 cast 结构体到 `cb->ctx`
- 结构体大小 40 字节 < 48 字节限制
- 这与 ITEM-01 草案不同（草案假设 cb->ctx 是指针，需要 kzalloc）

**get_task_files() 不可用**：
- 内核 6.6 中 `get_task_files()` 未导出
- 使用 `task_lock(task); files = task->files; atomic_inc(&files->count); task_unlock(task);` 替代

**genl_info_dump() 返回 const**：
- `genl_info_dump(cb)` 返回 `const struct genl_info *`
- `.start` 中声明为 `const struct genl_info *info`

### 2.4 patch 文件同步

**kernel-patches/net-core-net-delayacct.c**：
- 从 `/home/lai/Code/linux-6.6/net/core/net-delayacct.c` 同步（694 → 760 行）

**kernel-patches/0007-net-core-add-module.patch**：
- 重新生成，反映 dumpit 重构后的完整源码
- diffstat 更新为 `760 insertions(+)`
- commit message 新增 dumpit 设计文档：
  - 说明 GET_BY_PID 使用 `.start/.dumpit/.done` + `cb->ctx` 内联数组
  - 说明 GET_BY_INODE 保持 doit（单条回复）
  - 说明 NLM_F_MULTI 分片和 NLMSG_DONE 由框架自动处理
  - 补充 locking order 文档
- 0 处 trailing whitespace（checkpatch CI 要求）
- 作者身份统一为 `laiguo-liang <2909269677@qq.com>`
- patch body 与源文件 `diff` 逐行比对一致

## 3. 变更原因

### 根因分析
v4.0.0 遗留 ISSUE-3 指出当前 `GET_BY_PID` 使用自定义 multi-message 协议，不符合 Generic Netlink dump 标准。

### 设计决策
1. 采用 `.start`/`.dumpit`/`.done` + `cb->ctx` 方案（Worker 提议，Reviewer 确认）
2. `cb->ctx` 内联数组而非堆分配（内核 6.6 API 实际行为）
3. 保留 `net_delayacct_one_reply` 给 `GET_BY_INODE` 使用（共识：inode 查询保持 doit）

## 4. 踩坑记录

### 坑1：cb->ctx 不是指针
- **问题描述**：ITEM-01 草案假设 `cb->ctx` 是 `void *` 指针，使用 `kzalloc` 分配
- **原因分析**：内核 6.6 中 `cb->ctx` 是 `u8 ctx[48]` 内联数组
- **解决方案**：直接 cast 结构体到 `cb->ctx`，不需要分配/释放
- **如何避免**：修改内核代码前必须查看实际结构体定义

### 坑2：genl_info_dump 返回 const
- **问题描述**：`genl_info_dump(cb)` 返回 `const struct genl_info *`，但代码声明为非 const
- **原因分析**：函数签名在 genetlink.h 中声明为 const 返回
- **解决方案**：改为 `const struct genl_info *info`

### 坑3：net_delayacct_one_reply 被删除但 GET_BY_INODE 仍引用
- **问题描述**：删除 `net_delayacct_one_reply` 后编译失败
- **原因分析**：`cmd_get_by_inode` 仍调用 `one_reply` 发送单条回复
- **解决方案**：保留 `one_reply` 函数，仅用于 `GET_BY_INODE` 的 doit handler

## 5. 测试验证

- [x] `net-delayacct.o` 单独编译通过（0 errors, 0 warnings，17:00 构建）
- [x] `net/core/built-in.a` 编译通过
- [x] 用户态工具编译通过
- [x] 完整 bzImage 编译通过（17:17 构建，包含 dumpit 重构）
- [x] patch 文件同步（0007-net-core-add-module.patch 重新生成，760 行，0 trailing whitespace）
- [x] patch body 与源文件逐行比对一致（`diff` 验证通过）
- [x] patch 作者身份统一为 'laiguo-liang'，Signed-off-by 一致
- [x] commit message 文档化 dumpit 设计决策（.start/.dumpit/.done + cb->ctx 内联数组，GET_BY_INODE 保持 doit）
- [x] QEMU 13 项回归测试全部通过（13/13 PASS, 0 FAIL, 0 SKIP）

## 6. QEMU 测试结果（2026-07-28 17:30）

**测试日志**: `tests/reports/local/test-20260728_172821.log`

| 测试项 | 结果 | 关键验证点 |
|--------|------|-----------|
| Test 1-10 | PASS | 基础查询/RESET/netns/计数语义无回归 |
| Test 11 (多 socket dump) | PASS | iperf3 server PID 318 的 TCP+UDP socket 全部正确返回，dumpit 分片正常 |
| Test 12 (边界条件) | PASS | PID 1/不存在 PID/-h/-V 均不崩溃，合理报错 |
| Test 13 (并发压力) | PASS | 16 workers × 20 = 320 次查询，无 oops/无死锁/无崩溃 |

**关键验证**：
- 标准 dumpit 协议下，多 socket 查询（Test 11）正确返回所有 TCP/UDP socket 统计
- 并发场景（Test 13）下 `cb->ctx` 内联数组无竞态问题
- `net_delayacct: framework registered v2 (family=28)` 正常注册
- 无 kernel panic/Oops/BUG

## 7. 待办/遗留问题

- TASK-22 已完成，ISSUE-3 可标记为"已修复-已验证"
- TASK-23（用户态过滤功能 ISSUE-5）可在 TASK-22 基础上开始
- TASK-24/25/26 对应 ISSUE-6（UAPI 注释）/ISSUE-7（测试补充）/过滤测试

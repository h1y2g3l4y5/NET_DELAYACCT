# TASK-23 修复 REV-1/REV-2（防御性 ctx 清零 + dumpit 完成返回 0）

- **日期**: 2026-07-28
- **关联 Review**: v5.0.0
- **关联问题**: REV-1 (P2), REV-2 (P3)
- **关联报告**: REVIEW_REPORT_v5.0.1_dumpit-fix-validation.md
- **关联 ITEM**: ITEM-02_defensive-ctx-init.md

## 1. 任务描述

修复 Reviewer 在 v5.0.1 复审中提出的两个问题：
- **REV-1 (P2)**: `net_delayacct_dump_start()` 应在入口处显式清零 `cb->ctx`，消除对框架 zero-init 的隐式依赖
- **REV-2 (P3)**: `net_delayacct_dump_by_pid()` 末尾应返回 0 而非 `skb->len`，避免一次无意义的空调用

## 2. 变更内容

### 2.1 内核源码 `net/core/net-delayacct.c`

**REV-1 修改（`.start` 入口处显式清零）**：

修改前（L302-L312）：
```c
static int net_delayacct_dump_start(struct netlink_callback *cb)
{
    const struct genl_info *info = genl_info_dump(cb);
    struct net_delayacct_dump_ctx *ctx;
    /* ... */
    if (!info->attrs[NET_DELAYACCT_A_PID])
        return -EINVAL;
    /* ... 其他错误返回路径 ... */
    ctx = (struct net_delayacct_dump_ctx *)cb->ctx;
    memset(ctx, 0, sizeof(*ctx));  /* 在可能返回之后才清零 */
```

修改后（L302-L320）：
```c
static int net_delayacct_dump_start(struct netlink_callback *cb)
{
    const struct genl_info *info = genl_info_dump(cb);
    struct net_delayacct_dump_ctx *ctx =
        (struct net_delayacct_dump_ctx *)cb->ctx;
    /* ... */

    /* Defensive: __netlink_dump_start() currently zeroes cb, but we
     * must not depend on that — .done() checks ctx->files/task for
     * NULL to decide whether to release references.  Clear ctx up
     * front so every early error-return path is safe.
     */
    memset(ctx, 0, sizeof(*ctx));

    if (!info->attrs[NET_DELAYACCT_A_PID])
        return -EINVAL;
```

同时删除 `.start` 末尾（原 L354-L355）重复的：
```c
ctx = (struct net_delayacct_dump_ctx *)cb->ctx;
memset(ctx, 0, sizeof(*ctx));
```

**REV-2 修改（`.dumpit` 末尾返回 0）**：

修改前（L443）：
```c
/* No more sockets to dump. */
return skb->len;
```

修改后（L448-L452）：
```c
/* No more sockets to dump.  Return 0 (not skb->len) to signal
 * dump completion immediately — the skb here is empty, so the
 * framework will not send it and will proceed to NLMSG_DONE.
 */
return 0;
```

### 2.2 patch 文件同步

- `kernel-patches/net-core-net-delayacct.c`: 从源文件同步（760 → 769 行）
- `kernel-patches/0007-net-core-add-module.patch`: 重新生成，769 insertions
- 0 trailing whitespace，作者统一 laiguo-liang，body 与 source diff MATCH

## 3. 变更原因

### REV-1 根因分析

当前代码依赖 `__netlink_dump_start()` 中的 `memset(cb, 0, sizeof(*cb))` 来保证 `cb->ctx` 初始为零。虽然：
1. 当前内核确实会 zero-init `cb`
2. `genl_start` 失败时 `genl_done` 不会被调用

但这是**隐式依赖框架实现细节**。防御性编程要求：
- `.done` 的 NULL 检查（`if (ctx->files)`/`if (ctx->task)`）应在所有路径下都安全
- 不依赖框架行为变更或模块移植场景

### REV-2 根因分析

`netlink_dump()` 逻辑：`.dumpit` 返回值 > 0 时框架发送 skb 并再次调用；返回值 <= 0 时停止。遍历完成后 skb 为空（`len == 0`），所以 `return skb->len` 等同于 `return 0`。但 `return 0` 语义更清晰，且避免框架多一次调用判断。

### 设计决策

两个修复都**接受** Reviewer 意见，无需对话：
- REV-1: 防御性清零，零功能影响，符合内核其他 dumpit 实现风格
- REV-2: 语义更清晰，零功能影响，减少一次无意义调用

## 4. 踩坑记录

本次修复无踩坑。两个修改都很直接，Reviewer 的修法建议准确可操作。

## 5. 测试验证

- [x] `net-delayacct.o` 编译通过（0 errors, 0 warnings，19:15 构建）
- [x] 源文件 0 trailing whitespace
- [x] patch 0007 重新生成（769 行），body 与 source MATCH
- [x] patch 作者统一 laiguo-liang
- [x] 完整 bzImage 编译通过（19:17 构建）
- [x] QEMU 13 项回归测试全部通过（13/13 PASS, 0 FAIL, 0 SKIP）

### QEMU 测试结果（2026-07-28 19:19）

**测试日志**: `tests/reports/local/test-20260728_191710.log`

| 测试项 | 结果 | 关键验证点 |
|--------|------|-----------|
| Test 1-10 | PASS | 基础查询/RESET/netns/计数语义无回归 |
| Test 11 (多 socket dump) | PASS | iperf3 server TCP+UDP socket 全部正确返回，REV-2 return 0 无影响 |
| Test 12 (边界条件) | PASS | PID 1/不存在 PID/-h/-V 均不崩溃 |
| Test 13 (并发压力) | PASS | 16 workers × 20 = 320 次查询，无 oops/无死锁 |

**关键验证**：
- REV-1 显式清零 `cb->ctx` 不影响正常路径行为
- REV-2 `return 0` 正确触发 dump 完成，无消息丢失
- `net_delayacct: framework registered v2 (family=28)` 正常注册
- 无 kernel panic/Oops/BUG

## 6. 待办/遗留问题

- TASK-23 已完成，REV-1/REV-2 可标记为"已修复-已验证"
- ISSUE-3 正式闭环，可开始 TASK-24（ISSUE-5 用户态过滤功能）

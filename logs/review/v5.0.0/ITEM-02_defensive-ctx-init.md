# 分项审查 - `.start` 应显式清零 `cb->ctx`（REV-1）

- **关联报告**: REVIEW_REPORT_v5.0.1_dumpit-fix-validation.md
- **审查日期**: 2026-07-28
- **严重度**: P2

## 变更概述

TASK-22 将 `NET_DELAYACCT_CMD_GET_BY_PID` 重构为标准 Generic Netlink dumpit，使用 `cb->ctx` 内联数组保存遍历状态。当前 `.start` 在多个错误返回路径之后才清零 `cb->ctx`，隐式依赖框架在调用 `.start` 前已将 `cb` 清零。

---

## 逐文件/逐路径分析

### 位置: `net/core/net-delayacct.c#L302-L361`

#### 现象

```c
static int net_delayacct_dump_start(struct netlink_callback *cb)
{
    const struct genl_info *info = genl_info_dump(cb);
    struct net_delayacct_dump_ctx *ctx;
    /* ... */

    if (!info->attrs[NET_DELAYACCT_A_PID])
        return -EINVAL;          /* cb->ctx 尚未清零 */

    pid = nla_get_u32(info->attrs[NET_DELAYACCT_A_PID]);

    rcu_read_lock();
    pidp = find_vpid(pid);
    if (!pidp) {
        rcu_read_unlock();
        return -ESRCH;           /* cb->ctx 尚未清零 */
    }
    /* ... 其他错误返回路径 ... */

    ctx = (struct net_delayacct_dump_ctx *)cb->ctx;
    memset(ctx, 0, sizeof(*ctx)); /* 第一次清零，在可能返回之后 */
    /* ... */
}
```

`.done` 在 L454-L465 中检查 `ctx->files` / `ctx->task` 非 NULL 才释放引用：

```c
if (ctx->files)
    put_files_struct(ctx->files);
if (ctx->task)
    put_task_struct(ctx->task);
```

#### 为什么是问题

`.done` 的 NULL 检查只有在 `cb->ctx` 初始为 0 时才安全。当前代码依赖 `__netlink_dump_start()` 中的 `memset(cb, 0, sizeof(*cb))`，这是一种隐式依赖：

1. 内核框架行为可能随版本变化
2. 模块移植到不 zero-init `cb` 的环境时会读取垃圾指针
3. 静态分析工具可能报 "use of uninitialized memory"

#### 触发条件

- 内核升级或 backport 后 `netlink_callback` 初始化逻辑变更
- 模块移植到其他内核版本
- `.start` 因 PID 不存在、netns 不匹配等原因提前返回

#### 后果

`.done` 中可能基于垃圾非零值调用 `put_files_struct()` / `put_task_struct()`，导致引用计数下溢、UAF 或 oops。

#### 修法

在 `.start` 入口处、任何返回之前显式清零 `cb->ctx`：

```c
static int net_delayacct_dump_start(struct netlink_callback *cb)
{
    const struct genl_info *info = genl_info_dump(cb);
    struct net_delayacct_dump_ctx *ctx =
        (struct net_delayacct_dump_ctx *)cb->ctx;

    /* Defensive: the framework currently zeroes cb, but we must not
     * depend on that for .done() to safely check ctx->files/task.
     */
    memset(ctx, 0, sizeof(*ctx));

    if (!info->attrs[NET_DELAYACCT_A_PID])
        return -EINVAL;
    /* ... */
}
```

并删除 `.start` 末尾重复的 `memset(ctx, 0, sizeof(*ctx));`。

#### 为什么这么修

- 消除对框架 zero-init 的隐式依赖
- 使 `.done` 的 NULL 检查在所有失败路径下都安全
- 不改变正常路径行为，零 ABI/功能影响
- 与内核其他 dumpit 实现风格一致

---

## 验收标准

- [ ] `.start` 在第一条语句后显式清零 `cb->ctx`
- [ ] 删除 `.start` 末尾重复的 `memset`
- [ ] 内核编译通过
- [ ] QEMU 13 项测试仍全部通过
- [ ] patch 0007 重新同步，0 trailing whitespace

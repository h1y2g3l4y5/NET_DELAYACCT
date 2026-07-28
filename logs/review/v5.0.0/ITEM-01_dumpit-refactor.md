# 分项审查 - dumpit 重构方案（ISSUE-3）

- **关联报告**: REVIEW_REPORT_v5.0.0_api-evolution.md
- **审查日期**: 2026-07-28
- **严重度**: P1

## 变更概述

将 `NET_DELAYACCT_CMD_GET_BY_PID` 从 `doit` + 自定义 multi-message 协议改为 `dumpit` + 标准 Netlink dump 协议，同时复用该 dumpit 基础为后续过滤功能（ISSUE-5）提供标准入口。

---

## 逐文件/逐路径分析

### 位置: `net/core/net-delayacct.c`

#### 现象

当前 `net_delayacct_cmd_get_by_pid()` 是一个 `doit` handler，它内部：
1. 找到目标 task 并持有 `files_struct`
2. 遍历 fd 表，对每个 socket 调用 `net_delayacct_one_reply()` 发送一条独立 genl 消息
3. 手动设置 `NLM_F_MULTI` 并发送 `NLMSG_DONE`

#### 为什么是问题

自定义 multi-message 协议绕过了 Generic Netlink dump 框架提供的标准机制：
- 内核不会自动处理 dump 过程中的消息分片和重传
- 没有标准的序列号/确认机制
- 用户态无法使用通用 dump 接收循环，必须特判 `NLM_F_MULTI` + `NLMSG_DONE`
- 大数据量时可靠性差，与 upstream 期望不符

#### 触发条件

- 查询持有大量 socket 的进程
- Netlink buffer 较小或内存紧张
- 用户态工具需要被移植到其他语言/框架

#### 后果

- 消息分片边界错误可能导致用户态解析失败
- 非标准协议增加维护成本和 upstream 阻力
- 后续过滤、分页等扩展缺乏标准基础

#### 修法

**1. 修改 `struct genl_ops` 注册**

```c
static const struct genl_ops net_delayacct_ops[] = {
    {
        .cmd = NET_DELAYACCT_CMD_GET_BY_PID,
        .start = net_delayacct_dump_start,
        .dumpit = net_delayacct_dump_by_pid,
        .done = net_delayacct_dump_done,
        .flags = GENL_ADMIN_PERM,
    },
    {
        .cmd = NET_DELAYACCT_CMD_GET_BY_INODE,
        .doit = net_delayacct_cmd_get_by_inode,
        .flags = GENL_ADMIN_PERM,
    },
    {
        .cmd = NET_DELAYACCT_CMD_RESET,
        .doit = net_delayacct_cmd_reset,
        .flags = GENL_ADMIN_PERM,
    },
};
```

**2. 新增 dump 上下文结构**

```c
struct net_delayacct_dump_ctx {
    struct task_struct *task;     /* held via get_task_struct */
    struct files_struct *files;   /* held via atomic_inc */
    unsigned int fd;              /* next fd to scan */
    u32 pid;
    char comm[TASK_COMM_LEN];
};
```

**3. `.start` 处理 PID 解析和引用计数**

```c
static int net_delayacct_dump_start(struct netlink_callback *cb)
{
    struct genl_info *info = genl_info_dump(cb);
    struct net_delayacct_dump_ctx *ctx;
    struct pid *pid;
    struct task_struct *task;
    struct files_struct *files;
    u32 upid;

    if (!info->attrs[NET_DELAYACCT_A_PID])
        return -EINVAL;

    upid = nla_get_u32(info->attrs[NET_DELAYACCT_A_PID]);
    pid = find_vpid(upid);
    if (!pid)
        return -ESRCH;

    task = get_pid_task(pid, PIDTYPE_PID);
    if (!task)
        return -ESRCH;

    files = get_task_files(task);  /* atomic_inc(&files->count) */
    if (!files) {
        put_task_struct(task);
        return -ESRCH;
    }

    ctx = kzalloc(sizeof(*ctx), GFP_KERNEL);
    if (!ctx) {
        put_files_struct(files);
        put_task_struct(task);
        return -ENOMEM;
    }

    ctx->task = task;
    ctx->files = files;
    ctx->pid = upid;
    get_task_comm(ctx->comm, task);
    cb->ctx = ctx;
    return 0;
}
```

**注意**：`get_task_files()` 在较新内核中可能不存在，需要确认当前内核版本（6.6）的 API。如果不可用，应使用 `task_lock(task); files = task->files; atomic_inc(&files->count); task_unlock(task);`。

**4. `.dumpit` 填充一个 socket**

```c
static int net_delayacct_dump_by_pid(struct sk_buff *skb,
                                     struct netlink_callback *cb)
{
    struct net_delayacct_dump_ctx *ctx = cb->ctx;
    struct files_struct *files = ctx->files;
    unsigned int fd = ctx->fd;
    struct fdtable *fdt;
    void *hdr;
    int ret = 0;

    if (!files)
        return 0;

    fdt = files_fdtable(files);

    while (fd < fdt->max_fds) {
        struct file *file = fdt->fd[fd++];
        struct sock *sk;

        if (!file)
            continue;

        sk = sock_from_file_safe(file);
        if (!sk)
            continue;

        /* 过滤检查（TASK-23 实现） */
        if (!net_delayacct_match_filter(sk, genl_info_dump(cb)))
            continue;

        hdr = genlmsg_put(skb, NETLINK_CB(cb->skb).portid, cb->nlh->nlmsg_seq,
                          &net_delayacct_family, NLM_F_MULTI,
                          NET_DELAYACCT_CMD_GET_BY_PID);
        if (!hdr) {
            /* skb 已满，返回当前 fd-1 以便下次重试 */
            ctx->fd = fd - 1;
            return skb->len;
        }

        ret = net_delayacct_fill_sock(skb, sk, ctx->pid, ctx->comm,
                                      sock_inode_for(sk));
        if (ret < 0) {
            genlmsg_cancel(skb, hdr);
            ctx->fd = fd - 1;
            return skb->len;
        }

        genlmsg_end(skb, hdr);
        ctx->fd = fd;
        return skb->len;
    }

    return skb->len;
}
```

**5. `.done` 释放资源**

```c
static int net_delayacct_dump_done(struct netlink_callback *cb)
{
    struct net_delayacct_dump_ctx *ctx = cb->ctx;

    if (!ctx)
        return 0;

    if (ctx->files)
        put_files_struct(ctx->files);
    if (ctx->task)
        put_task_struct(ctx->task);
    kfree(ctx);
    cb->ctx = NULL;
    return 0;
}
```

**6. 用户态工具更新**

当前用户态通过 `genlmsg_parse` + `NLM_F_MULTI` 特判接收多条消息。改为标准 dump 后，应使用 `mnl_socket_recvfrom()` 循环接收，直到 `NLMSG_DONE`：

```c
while ((ret = mnl_socket_recvfrom(nl, buf, sizeof(buf))) > 0) {
    ret = mnl_cb_run(buf, ret, seq, portid, data_cb, NULL);
    if (ret <= MNL_CB_STOP)
        break;
}
```

#### 为什么这么修

- `.start` 中集中处理错误返回，避免 dumpit 在无效状态下运行
- `cb->ctx` 保存复杂状态，`.done` 保证引用计数释放，符合内核资源管理惯例
- 每次 dumpit 只填充一个 socket，让 Generic Netlink 自动处理消息边界和分片
- 标准 dump 模式为未来添加过滤、分页、大查询提供稳定基础

---

## 关键边界条件

1. **`.start` 失败路径**：如果 `.start` 返回错误，`.dumpit` 不会被调用，但 `.done` 仍会被调用。`.done` 必须处理 `ctx == NULL`。

2. **用户态提前关闭 socket**：dump 中途用户态关闭 Netlink socket，内核仍会调用 `.done`，引用计数会被正确释放。

3. **fd 表在 dump 过程中变化**：`files_struct` 已被引用计数保护，但 fd 表内容可能变化（其他线程 close/open）。当前实现不处理动态变化，这是可接受的限制，但应在文档中说明。

4. **IPv6 socket 过滤**：`net_delayacct_match_filter()` 在处理地址比较时，需区分 `AF_INET` 和 `AF_INET6` 的地址长度。

---

## 验收标准

- [ ] `GET_BY_PID` 注册为 `.dumpit` handler
- [ ] `.start`/`.done` 正确获取/释放 task_struct/files_struct
- [ ] 单进程 512 个 socket 查询返回数量正确
- [ ] 用户态工具使用标准 dump 接收循环
- [ ] 现有 13 项 QEMU 测试全部通过
- [ ] patch 文件同步，无 trailing whitespace

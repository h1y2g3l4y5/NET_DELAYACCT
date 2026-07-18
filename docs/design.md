# NET_DELAYACCT 技术设计文档

> 适用内核版本：Linux 6.6
> Kconfig 选项：`CONFIG_NET_DELAYACCT`
> 用户态工具：`tools/net/get_sockdelays`
> 相关文档：`docs/research-delayacct.md`、`docs/protocol-stack.md`、`docs/requirement.md`

---

## 1. 项目背景与目标

### 1.1 项目背景

Linux 内核已为进程级资源等待时延提供了成熟的 `CONFIG_DELAYACCT` 框架，可以统计 CPU、IO、内存、swap 等场景下的任务阻塞时间，并通过 `taskstats` genl 接口暴露给用户态的 `getdelays` 工具消费。然而在网络子系统中，针对 socket 粒度的收发时延却长期缺少同等粒度、可观测、可被用户态消费的统计能力。运维与开发人员排查业务网络抖动、定位协议栈瓶颈时，只能依赖 `tcpdump`、`ss`、eBPF 等工具从侧面间接推断，存在使用门槛高、与业务进程关联弱、难以持续观测等问题。详细背景见 `docs/background.md`。

### 1.2 项目目标

本项目在 Linux 6.6 内核中参考 `CONFIG_DELAYACCT` 的设计思想，新增 `CONFIG_NET_DELAYACCT` 框架与配套用户态工具 `get_sockdelays`，目标是：

1. 为每个 `struct sock` 维护接收（RX）与发送（TX）方向的累计时延与报文计数，时间戳起始于报文进入协议栈入口（`__netif_receive_skb_core` 或 `tcp_sendmsg`/`udp_sendmsg`），终止于报文离开协议栈（`tcp_recvmsg`/`__skb_recv_udp` 拷贝前 或 `dev_hard_start_xmit` 调用驱动前）。
2. 通过 generic netlink family `net_delayacct` 暴露三个命令：`GET_BY_PID`、`GET_BY_INODE`、`RESET`，每个 socket 一条属性集合。
3. 提供用户态工具 `get_sockdelays`，支持按 PID、按 inode 查询并格式化输出每个 socket 的平均收发时延。
4. 严格遵循内核 coding-style，`CONFIG_NET_DELAYACCT` 关闭时所有插桩编译为空操作，`struct sock`/`struct sk_buff` 无新增字段，对未开启该选项的内核零 ABI/性能影响。
5. 按 `submitting-patches.rst` 拆分 patch 系列，目标投稿至 `netdev@vger.kernel.org`。

---

## 2. 总体架构

```
+==========================================================================+
|                              Kernel Space                                |
|                                                                          |
|   +-----------------+        +----------------------+                    |
|   | RX path         |        | TX path              |                    |
|   | __netif_receive |        | tcp_sendmsg          |                    |
|   | _skb_core       |        | udp_sendmsg          |                    |
|   |   |             |        |   |                  |                    |
|   |   v             |        |   v                  |                    |
|   | net_delayacct_  |        | net_delayacct_       |                    |
|   |   rx_start(skb) |        |   tx_start(skb)      |                    |
|   |   |             |        |   |                  |                    |
|   |   v             |        |   v                  |                    |
|   | tcp_recvmsg /   |        | dev_hard_start_xmit  |                    |
|   | __skb_recv_udp  |        |   |                  |                    |
|   |   |             |        |   v                  |                    |
|   |   v             |        | net_delayacct_       |                    |
|   | net_delayacct_  |        |   tx_end(sk, skb)    |                    |
|   |   rx_end(sk,skb)|        |                      |                    |
|   +---+-------------+        +---------+------------+                    |
|       |                                |                                 |
|       |  delta = now - skb->delayacct_start                            |
|       v                                v                                 |
|   +---+--------------------------------+------------+                    |
|   | struct net_delayacct (per sock)                 |                    |
|   |   spinlock_t lock;                              |                    |
|   |   struct net_delayacct_stats stats;             |                    |
|   |     rx_total_ns, rx_count, tx_total_ns, tx_count|                    |
|   |   ktime_t rx_start, tx_start;                   |                    |
|   |   bool rx_pending, tx_pending;                  |                    |
|   +---+--------------------------------------------+                    |
|       |                                                                 |
|       | embedded in struct sock (sk->sk_net_delayacct)                  |
|       v                                                                 |
|   +----------+         genl family "net_delayacct"                      |
|   | netlink |<----------------+------------------+                     |
|   |  genl   |   GET_BY_PID    |   GET_BY_INODE   | RESET               |
|   +----+----+                 |                   |                     |
|        |                      v                   v                     |
|        |     iterate task->files -> sock_from_file -> sk                |
|        |     read sk->sk_net_delayacct.stats under spinlock             |
|        |     fill nla: TYPE/LADDR/LPORT/RADDR/RPORT/COMM/PID/           |
|        |            RX_TOTAL_NS/RX_COUNT/TX_TOTAL_NS/TX_COUNT/INODE    |
|        |     genlmsg_unicast with NLM_F_MULTI + NLMSG_DONE             |
+========+=================================================================+
         |
         | AF_GENERIC_NETLINK socket
         v
+==========================================================================+
|                            User Space                                    |
|                                                                          |
|   tools/net/get_sockdelays                                               |
|     |                                                                    |
|     | 1. socket(AF_GENERIC_NETLINK, SOCK_RAW, NETLINK_GENERIC)           |
|     | 2. genl_ctrl_search_by_name("net_delayacct") -> family_id          |
|     | 3. genlmsg_put(... cmd=GET_BY_PID/GET_BY_INODE/RESET ...)          |
|     | 4. nla_put_u32(... PID/INODE ...)                                  |
|     | 5. sendto()                                                        |
|     | 6. recvmsg() loop until NLMSG_DONE                                 |
|     | 7. nla_parse + format output                                       |
|     v                                                                    |
|   stdout:                                                                |
|   TYPE  LADDR        LPORT  RADDR          RPORT  COMM      PID  \       |
|     RX(ns)  TX(ns)  RX#   TX#                                            |
|   TCP   10.0.0.1    443    192.168.1.5   54321  nginx     1234           |
|     1234   5678     100    200                                            |
+==========================================================================+
```

数据流方向：

- **写方向（统计）**：协议栈路径 → `skb->delayacct_start` → `net_delayacct_*_end` → per-sock 累加（spinlock 保护）。
- **读方向（查询）**：用户态 genl 请求 → 内核遍历 `task->files` 或按 inode 查 → 读 per-sock 统计 → nla 填充 → genl 回送。

---

## 3. 数据结构设计

### 3.1 UAPI 头文件 `include/uapi/linux/net-delayacct.h`

此文件必须只包含 UAPI 友好的类型（`__u8/__u16/__u32/__u64`），不依赖内核内部类型。

```c
/* SPDX-License-Identifier: GPL-2.0-only WITH Linux-syscall-note */
#ifndef _UAPI_LINUX_NET_DELAYACCT_H
#define _UAPI_LINUX_NET_DELAYACCT_H

/**
 * struct net_delayacct_stats - per-socket delay accounting statistics
 * @rx_total_ns: cumulative RX delay in nanoseconds
 * @rx_count:    number of RX packets accounted
 * @tx_total_ns: cumulative TX delay in nanoseconds
 * @tx_count:    number of TX packets accounted
 *
 * All fields are 64-bit and naturally aligned. avg_rx = rx_total_ns / rx_count
 * when rx_count > 0, otherwise undefined (user-space must print N/A).
 */
struct net_delayacct_stats {
    __u64 rx_total_ns;
    __u64 rx_count;
    __u64 tx_total_ns;
    __u64 tx_count;
};

/* Commands */
enum {
    NET_DELAYACCT_CMD_UNSPEC,
    NET_DELAYACCT_CMD_GET_BY_PID,     /* req:  PID   */
    NET_DELAYACCT_CMD_GET_BY_INODE,   /* req:  INODE */
    NET_DELAYACCT_CMD_RESET,          /* req:  (none), reset all socks */

    __NET_DELAYACCT_CMD_MAX,
    NET_DELAYACCT_CMD_MAX = __NET_DELAYACCT_CMD_MAX - 1,
};

/* Attributes */
enum {
    NET_DELAYACCT_A_UNSPEC,
    NET_DELAYACCT_A_TYPE,        /* u8:  IPPROTO_TCP / IPPROTO_UDP */
    NET_DELAYACCT_A_LADDR,       /* u32 (v4) or 16B (v6) */
    NET_DELAYACCT_A_LPORT,       /* u16, host byte order */
    NET_DELAYACCT_A_RADDR,       /* u32 (v4) or 16B (v6) */
    NET_DELAYACCT_A_RPORT,       /* u16, host byte order */
    NET_DELAYACCT_A_COMM,        /* string, TASK_COMM_LEN */
    NET_DELAYACCT_A_PID,         /* u32 */
    NET_DELAYACCT_A_RX_TOTAL_NS, /* u64 */
    NET_DELAYACCT_A_RX_COUNT,    /* u64 */
    NET_DELAYACCT_A_TX_TOTAL_NS, /* u64 */
    NET_DELAYACCT_A_TX_COUNT,    /* u64 */
    NET_DELAYACCT_A_INODE,       /* u64, sockfs inode number */

    __NET_DELAYACCT_A_MAX,
    NET_DELAYACCT_A_MAX = __NET_DELAYACCT_A_MAX - 1,
};

#define NET_DELAYACCT_GENL_NAME    "net_delayacct"
#define NET_DELAYACCT_GENL_VERSION 1

#endif /* _UAPI_LINUX_NET_DELAYACCT_H */
```

### 3.2 内核内部头文件 `include/net/net-delayacct.h`

```c
/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef _NET_NET_DELAYACCT_H
#define _NET_NET_DELAYACCT_H

#include <linux/ktime.h>
#include <linux/spinlock.h>
#include <linux/skbuff.h>
#include <uapi/linux/net-delayacct.h>

struct sock;

#ifdef CONFIG_NET_DELAYACCT

struct net_delayacct {
    spinlock_t                 lock;         /* 保护 stats 与 pending 字段 */
    struct net_delayacct_stats stats;
    ktime_t                    rx_start;     /* 暂未使用（RX start 在 skb 上） */
    ktime_t                    tx_start;     /* 暂未使用（TX start 在 skb 上） */
    bool                       rx_pending;
    bool                       tx_pending;
};

/* 在 struct sock 中嵌入: sk->sk_net_delayacct */

void net_delayacct_sock_init(struct sock *sk);
void net_delayacct_rx_start(struct sk_buff *skb);
void net_delayacct_rx_end(struct sock *sk, struct sk_buff *skb);
void net_delayacct_tx_start(struct sk_buff *skb);
void net_delayacct_tx_end(struct sock *sk, struct sk_buff *skb);
void net_delayacct_sock_reset(struct sock *sk);

static inline void net_delayacct_init(struct net_delayacct *n)
{
    spin_lock_init(&n->lock);
    n->stats.rx_total_ns = 0;
    n->stats.rx_count = 0;
    n->stats.tx_total_ns = 0;
    n->stats.tx_count = 0;
    n->rx_start = 0;
    n->tx_start = 0;
    n->rx_pending = false;
    n->tx_pending = false;
}

#else  /* !CONFIG_NET_DELAYACCT */

struct net_delayacct { /* empty placeholder, 0 bytes */ };

static inline void net_delayacct_sock_init(struct sock *sk) {}
static inline void net_delayacct_rx_start(struct sk_buff *skb) {}
static inline void net_delayacct_rx_end(struct sock *sk,
                                        struct sk_buff *skb) {}
static inline void net_delayacct_tx_start(struct sk_buff *skb) {}
static inline void net_delayacct_tx_end(struct sock *sk,
                                        struct sk_buff *skb) {}
static inline void net_delayacct_sock_reset(struct sock *sk) {}
static inline void net_delayacct_init(struct net_delayacct *n) {}

#endif /* CONFIG_NET_DELAYACCT */

#endif /* _NET_NET_DELAYACCT_H */
```

### 3.3 `struct sock` 嵌入

在 `include/net/sock.h` 的 `struct sock` 中嵌入字段：

```c
struct sock {
    /* ... existing fields ... */

#ifdef CONFIG_NET_DELAYACCT
    struct net_delayacct      sk_net_delayacct;
#endif
    /* ... */
};
```

`sock_init_data` 中调用 `net_delayacct_init(&sk->sk_net_delayacct)` 或 `net_delayacct_sock_init(sk)`。

### 3.4 `struct sk_buff` 新增字段

在 `include/linux/skbuff.h` 的 `struct sk_buff` 中新增：

```c
struct sk_buff {
    /* ... existing fields ... */

#ifdef CONFIG_NET_DELAYACCT
    ktime_t                   delayacct_start;  /* 0 = not stamped */
#endif
    /* ... */
};
```

`alloc_skb` / `__alloc_skb` / `build_skb` 等分配函数会 zero-initialize 整个 `sk_buff`，因此 `delayacct_start` 默认为 0，end 函数据此判断"未打点"并跳过。

### 3.5 字段汇总

| 字段位置 | 类型 | 用途 |
|----------|------|------|
| `struct sock::sk_net_delayacct.lock` | `spinlock_t` | 保护累加 |
| `struct sock::sk_net_delayacct.stats` | `struct net_delayacct_stats` | 累计统计 |
| `struct sock::sk_net_delayacct.rx_start/tx_start` | `ktime_t` | 备用（保留字段，当前未使用） |
| `struct sock::sk_net_delayacct.rx_pending/tx_pending` | `bool` | 备用（保留字段） |
| `struct sk_buff::delayacct_start` | `ktime_t` | 单包起始时间戳，跨上下文传递 |

`rx_start` / `tx_start` / `rx_pending` / `tx_pending` 在当前实现中保留但未使用，原因：RX/TX start 的时间戳必须挂在 skb 上以跨上下文，per-sock 字段无法承担。保留是为了未来若需要"per-sock 等待时间"统计（如 TCP wait for memory）时可扩展，避免再次修改 UAPI 头文件。

---

## 4. 插桩点表

### 4.1 完整插桩点

| 路径 | 文件 | 函数 | 调用接口 | 说明 |
|------|------|------|----------|------|
| RX start | `net/core/dev.c` | `__netif_receive_skb_core` | `net_delayacct_rx_start(skb)` | 函数入口处，紧接 rcu_read_lock 之后；对所有协议族生效 |
| RX end (TCP) | `net/ipv4/tcp.c` | `tcp_recvmsg` | `net_delayacct_rx_end(sk, skb)` | 调用 `skb_copy_datagram_iter` 之前 |
| RX end (UDP) | `net/ipv4/udp.c` | `__skb_recv_udp` | `net_delayacct_rx_end(sk, skb)` | 出队成功、返回 skb 之前 |
| TX start (TCP) | `net/ipv4/tcp.c` | `tcp_sendmsg` | `net_delayacct_tx_start(skb)` | 在 `tcp_sendmsg_locked` 内对每个新生成的 skb 打戳 |
| TX start (UDP) | `net/ipv4/udp.c` | `udp_sendmsg` | `net_delayacct_tx_start(skb)` | 在 `ip_make_skb` 之后、`udp_send_skb` 之前对 skb 打戳 |
| TX end | `net/core/dev.c` | `dev_hard_start_xmit` | `net_delayacct_tx_end(sk, skb)` | 在调用 `ops->ndo_start_xmit(skb, dev)` 之前 |

### 4.2 插桩点选择原则

- **单点覆盖广**：`__netif_receive_skb_core` 与 `dev_hard_start_xmit` 是所有 IPv4/IPv6 流量的共同汇聚点，单点插桩即可覆盖 TCP/UDP/RAW 等所有 L4 协议。
- **紧贴生命周期边界**：start 在协议栈"刚接收/刚生成 skb"的瞬间，end 在"即将离开协议栈"的瞬间，时延定义清晰。
- **避免 hot path 多次调用**：不在每个协议层都插桩，避免同一报文被打多次时间戳。

### 4.3 插桩代码示例

RX start（在 `__netif_receive_skb_core` 起始）：

```c
static int __netif_receive_skb_core(struct sk_buff **pskb, bool pfmemalloc,
                                    struct packet_type **ppt_prev)
{
    struct sk_buff *skb = *pskb;
    /* ... existing code ... */

    net_delayacct_rx_start(skb);   /* <-- 新增 */

    rcu_read_lock();
    /* ... ptype_all 遍历、L3 分发 ... */
}
```

RX end（在 `tcp_recvmsg` 出队后、拷贝前）：

```c
int tcp_recvmsg(struct sock *sk, struct msghdr *msg, size_t len,
                int flags, int *addr_len)
{
    /* ... */
    while (/* ... */) {
        skb = skb_peek(&sk->sk_receive_queue);
        /* ... */
        net_delayacct_rx_end(sk, skb);   /* <-- 新增 */
        if (skb_copy_datagram_iter(skb, offset, &msg->msg_iter, used))
            goto out;
        /* ... */
    }
}
```

TX start（在 `tcp_sendmsg_locked` 中生成新 skb 后）：

```c
int tcp_sendmsg_locked(struct sock *sk, struct msghdr *msg, size_t size)
{
    /* ... */
    skb = sk_stream_alloc_skb(sk, 0, sk->sk_allocation, first_skb);
    /* ... */
    net_delayacct_tx_start(skb);   /* <-- 新增 */
    /* ... */
    tcp_skb_entail(sk, skb);
}
```

TX end（在 `dev_hard_start_xmit` 中调用驱动前）：

```c
static inline int dev_hard_start_xmit(struct sk_buff *skb, struct net_device *dev,
                                      struct netdev_queue *txq)
{
    /* ... */
    net_delayacct_tx_end(skb->sk, skb);   /* <-- 新增 */
    rc = ops->ndo_start_xmit(skb, dev);
    /* ... */
}
```

### 4.4 关闭选项时的编译期消除

所有 `net_delayacct_*` 接口在 `CONFIG_NET_DELAYACCT=n` 时为 `static inline` 空函数（见 3.2 节）。编译器在 `-O2` 下会完全消除调用，最终二进制与原生 6.6 内核字节级一致（除 `struct sk_buff` 与 `struct sock` 的字段位置不变化，因为 `#ifdef` 让字段也不存在）。

---

## 5. Generic Netlink 协议

### 5.1 Family 注册

```c
static const struct nla_policy net_delayacct_policy[NET_DELAYACCT_A_MAX + 1] = {
    [NET_DELAYACCT_A_TYPE]        = { .type = NLA_U8 },
    [NET_DELAYACCT_A_LADDR]       = { .type = NLA_BINARY, .len = 16 },
    [NET_DELAYACCT_A_LPORT]       = { .type = NLA_U16 },
    [NET_DELAYACCT_A_RADDR]       = { .type = NLA_BINARY, .len = 16 },
    [NET_DELAYACCT_A_RPORT]       = { .type = NLA_U16 },
    [NET_DELAYACCT_A_COMM]        = { .type = NLA_NUL_STRING, .len = TASK_COMM_LEN - 1 },
    [NET_DELAYACCT_A_PID]         = { .type = NLA_U32 },
    [NET_DELAYACCT_A_RX_TOTAL_NS] = { .type = NLA_U64 },
    [NET_DELAYACCT_A_RX_COUNT]    = { .type = NLA_U64 },
    [NET_DELAYACCT_A_TX_TOTAL_NS] = { .type = NLA_U64 },
    [NET_DELAYACCT_A_TX_COUNT]    = { .type = NLA_U64 },
    [NET_DELAYACCT_A_INODE]       = { .type = NLA_U64 },
};

static const struct genl_small_ops net_delayacct_ops[] = {
    {
        .cmd  = NET_DELAYACCT_CMD_GET_BY_PID,
        .doit = net_delayacct_get_by_pid,
        /* 可加 .dumpit 用于遍历所有 sock */
    },
    {
        .cmd  = NET_DELAYACCT_CMD_GET_BY_INODE,
        .doit = net_delayacct_get_by_inode,
    },
    {
        .cmd  = NET_DELAYACCT_CMD_RESET,
        .doit = net_delayacct_reset,
    },
};

static struct genl_family net_delayacct_family __ro_after_init = {
    .name           = NET_DELAYACCT_GENL_NAME,        /* "net_delayacct" */
    .version        = NET_DELAYACCT_GENL_VERSION,     /* 1 */
    .maxattr        = NET_DELAYACCT_A_MAX,
    .policy         = net_delayacct_policy,
    .module         = THIS_MODULE,
    .ops            = net_delayacct_ops,
    .n_ops          = ARRAY_SIZE(net_delayacct_ops),
    .resv_start_op  = NET_DELAYACCT_CMD_RESET + 1,
    .netnsok        = true,
};

static int __init net_delayacct_init_module(void)
{
    return genl_register_family(&net_delayacct_family);
}
subsys_initcall(net_delayacct_init_module);
```

### 5.2 请求与响应

#### 请求格式

```
+------------------------------------------+
| struct nlmsghdr                          |  nlmsg_type  = family_id
|                                          |  nlmsg_flags = NLM_F_REQUEST
|                                          |  nlmsg_len   = ...
+------------------------------------------+
| struct genlmsghdr                        |  cmd     = GET_BY_PID / GET_BY_INODE / RESET
|                                          |  version = 1
|                                          |  reserved = 0
+------------------------------------------+
| NLA: NET_DELAYACCT_A_PID (u32)           |  仅 GET_BY_PID 携带
+------------------------------------------+
| NLA: NET_DELAYACCT_A_INODE (u64)         |  仅 GET_BY_INODE 携带
+------------------------------------------+
```

#### 响应格式（多 socket 场景）

```
+------------------------------------------+
| struct nlmsghdr                          |  nlmsg_flags = NLM_F_MULTI
+------------------------------------------+
| struct genlmsghdr                        |
+------------------------------------------+
| NLA: NET_DELAYACCT_A_TYPE     (u8)       |
| NLA: NET_DELAYACCT_A_LADDR    (4 or 16B) |
| NLA: NET_DELAYACCT_A_LPORT    (u16)      |
| NLA: NET_DELAYACCT_A_RADDR    (4 or 16B) |
| NLA: NET_DELAYACCT_A_RPORT    (u16)      |
| NLA: NET_DELAYACCT_A_COMM     (string)   |
| NLA: NET_DELAYACCT_A_PID      (u32)      |
| NLA: NET_DELAYACCT_A_RX_TOTAL_NS (u64)   |
| NLA: NET_DELAYACCT_A_RX_COUNT    (u64)   |
| NLA: NET_DELAYACCT_A_TX_TOTAL_NS (u64)   |
| NLA: NET_DELAYACCT_A_TX_COUNT    (u64)   |
| NLA: NET_DELAYACCT_A_INODE     (u64)     |
+------------------------------------------+
... (重复，每个 socket 一条消息) ...
+------------------------------------------+
| struct nlmsghdr                          |  nlmsg_type  = NLMSG_DONE
|                                          |  nlmsg_flags = NLM_F_MULTI
+------------------------------------------+
| int error_code (0)                       |
+------------------------------------------+
```

### 5.3 内核命令处理流程

#### `NET_DELAYACCT_CMD_GET_BY_PID`

```c
static int net_delayacct_get_by_pid(struct sk_buff *skb,
                                    struct genl_info *info)
{
    struct sk_buff *reply;
    u32 pid;
    struct task_struct *task;
    struct files_struct *files;
    struct fdtable *fdt;
    int fd, err = 0;

    if (!info->attrs[NET_DELAYACCT_A_PID])
        return -EINVAL;
    pid = nla_get_u32(info->attrs[NET_DELAYACCT_A_PID]);

    reply = genlmsg_new(NLMSG_DEFAULT_SIZE, GFP_KERNEL);
    if (!reply) return -ENOMEM;

    rcu_read_lock();
    task = find_task_by_vpid(pid);
    if (!task) { rcu_read_unlock(); kfree_skb(reply); return -ESRCH; }
    get_task_struct(task);
    rcu_read_unlock();

    task_lock(task);
    files = task->files;
    if (!files) { err = -ENOENT; goto unlock_task; }

    spin_lock(&files->file_lock);
    fdt = files_fdtable(files);
    for (fd = 0; fd < fdt->max_fds; fd++) {
        struct file *file = fdt->fd[fd];
        struct socket *sock;
        struct sock *sk;
        if (!file) continue;
        sock = sock_from_file(file);
        if (!sock) continue;
        sk = sock->sk;
        if (!sk) continue;
        if (sk->sk_family != AF_INET && sk->sk_family != AF_INET6)
            continue;
        /* 仅 TCP/UDP */
        if (sk->sk_protocol != IPPROTO_TCP && sk->sk_protocol != IPPROTO_UDP)
            continue;

        err = net_delayacct_fill_reply(reply, sk, task, pid, info->snd_portid,
                                       info->snd_seq);
        if (err) break;   /* skb 满了等 */
    }
    spin_unlock(&files->file_lock);
unlock_task:
    task_unlock(task);
    put_task_struct(task);

    /* 发送 NLMSG_DONE */
    genlmsg_end(reply, ...);
    genlmsg_reply(reply, info);   /* unicast */
    return err;
}
```

#### `NET_DELAYACCT_CMD_GET_BY_INODE`

按 inode 查找单个 sock，遍历方式与 GET_BY_PID 类似，但匹配 `SOCK_INODE(sock)->i_ino == inode` 后立即填充并返回。复杂度 O(N*M)（N 个 task，每个 M 个 fd），第一期可接受。第二期可加 per-netns inode 哈希表优化。

#### `NET_DELAYACCT_CMD_RESET`

遍历所有 net namespace 的所有 sock，调用 `net_delayacct_sock_reset(sk)`。具体实现可通过 `for_each_net(net)` + 遍历 net 内所有 sock 哈希桶（如 `tcp_hashinfo` / `udp_table`），或更通用的方式：枚举所有 task 的 fd 重置（与 GET_BY_PID 类似但写）。第一期采用枚举 fd 法，简单且与查询共用代码。

### 5.4 属性填充函数

```c
static int net_delayacct_fill_reply(struct sk_buff *skb, struct sock *sk,
                                    struct task_struct *task, u32 pid,
                                    u32 portid, u32 seq)
{
    void *hdr;
    struct net_delayacct_stats stats;
    u64 inode = 0;
    char comm[TASK_COMM_LEN];

    /* 1. genl 头 */
    hdr = genlmsg_put(skb, portid, seq, &net_delayacct_family,
                      NLM_F_MULTI, NET_DELAYACCT_CMD_GET_BY_PID);
    if (!hdr) return -EMSGSIZE;

    /* 2. 抓统计快照（持锁） */
    spin_lock(&sk->sk_net_delayacct.lock);
    stats = sk->sk_net_delayacct.stats;   /* struct 拷贝 */
    spin_unlock(&sk->sk_net_delayacct.lock);

    /* 3. inode */
    if (sk->sk_socket && sk->sk_socket->file)
        inode = sk->sk_socket->file->f_inode->i_ino;

    /* 4. comm */
    get_task_comm(comm, task);

    /* 5. 五元组与协议 */
    if (sk->sk_family == AF_INET) {
        __be32 laddr = sk->sk_rcv_saddr;
        __be32 raddr = sk->sk_daddr;
        if (nla_put(skb, NET_DELAYACCT_A_LADDR, sizeof(laddr), &laddr) ||
            nla_put(skb, NET_DELAYACCT_A_RADDR, sizeof(raddr), &raddr))
            goto nla_put_failure;
    } else {
        if (nla_put(skb, NET_DELAYACCT_A_LADDR, 16, &sk->sk_v6_rcv_saddr) ||
            nla_put(skb, NET_DELAYACCT_A_RADDR, 16, &sk->sk_v6_daddr))
            goto nla_put_failure;
    }
    if (nla_put_u8(skb,  NET_DELAYACCT_A_TYPE,        sk->sk_protocol) ||
        nla_put_u16(skb, NET_DELAYACCT_A_LPORT,       sk->sk_num)      ||
        nla_put_u16(skb, NET_DELAYACCT_A_RPORT,       ntohs(sk->sk_dport)) ||
        nla_put_string(skb, NET_DELAYACCT_A_COMM,     comm)            ||
        nla_put_u32(skb, NET_DELAYACCT_A_PID,         pid)             ||
        nla_put_u64_64bit(skb, NET_DELAYACCT_A_RX_TOTAL_NS, stats.rx_total_ns, 0) ||
        nla_put_u64_64bit(skb, NET_DELAYACCT_A_RX_COUNT,    stats.rx_count,    0) ||
        nla_put_u64_64bit(skb, NET_DELAYACCT_A_TX_TOTAL_NS, stats.tx_total_ns, 0) ||
        nla_put_u64_64bit(skb, NET_DELAYACCT_A_TX_COUNT,    stats.tx_count,    0) ||
        nla_put_u64_64bit(skb, NET_DELAYACCT_A_INODE,       inode,             0))
        goto nla_put_failure;

    genlmsg_end(skb, hdr);
    return 0;

nla_put_failure:
    genlmsg_cancel(skb, hdr);
    return -EMSGSIZE;
}
```

注意：

- 端口 `sk->sk_num` 为主机序，`sk->sk_dport` 为网络序，输出前需 `ntohs`。
- 属性中所有 `__u64` 字段使用 `nla_put_u64_64bit` 并指定 `padattr = 0`（NLA padding 由 netlink 框架处理）。
- 进程 comm 通过 `get_task_comm` 拷贝，避免直接读 `task->comm` 不安全。

---

## 6. 并发与锁设计

### 6.1 累加时（per-sock spinlock）

```c
void net_delayacct_rx_end(struct sock *sk, struct sk_buff *skb)
{
    ktime_t now, delta;
    struct net_delayacct *n = &sk->sk_net_delayacct;

    if (!skb->delayacct_start)
        return;   /* 未经过 start 打点 */

    now = ktime_get_ns();
    delta = now - skb->delayacct_start;

    spin_lock(&n->lock);
    n->stats.rx_total_ns += delta;
    n->stats.rx_count++;
    spin_unlock(&n->lock);

    skb->delayacct_start = 0;   /* 避免重复累加 */
}
```

- 用 `sk->sk_net_delayacct.lock`，**不使用** `sk->sk_lock.slock`（语义不同，可能死锁，见 `protocol-stack.md` 3.1 节）。
- 临界区极短，仅两次加法与赋值，争用概率低。
- spinlock 在 softirq 与 process 上下文都可安全使用（标准 `spin_lock` 即可，不需 `spin_lock_bh`，因为累加不与同 task 的接收路径竞争）。

### 6.2 遍历查询（RCU + task_lock + files_lock）

按 PID 遍历的锁层次：

```
1. rcu_read_lock()                  -- 保护 task_struct lookup
2. get_task_struct(task)            -- 增引用计数
3. rcu_read_unlock()
4. task_lock(task)                  -- 锁 task->files / task->mm
5. spin_lock(&files->file_lock)     -- 锁 fdtable
   ... 遍历 fd, sock_from_file(), 取 sk ...
   ... 读 sk->sk_net_delayacct.stats (per-sock spinlock) ...
6. spin_unlock(&files->file_lock)
7. task_unlock(task)
8. put_task_struct(task)
```

获取顺序严格自下而上，避免死锁。注意 `task_lock` 是 `spin_lock(&task->alloc_lock)` 的封装，与 `files->file_lock` 不在同一锁类。

### 6.3 skb 时间戳（无需锁）

- RX 路径：skb 从 NAPI softirq 一路传到 `tcp_recvmsg`，**整个生命周期单线程所有**（虽然跨 CPU 但不并发）。`skb->delayacct_start` 是标量赋值/读取，无需锁。
- TX 路径：skb 在进程上下文创建，clone/segment 时复制字段，最终在 `dev_hard_start_xmit` 读取。即使发生 softirq 重传，也是同一时刻只有一个写者。
- 唯一需要小心的场景：skb 被 `skb_shared` 后多路径并发使用（如 multicast）。本项目暂不处理 multicast，仅 `sk->sk_family == AF_INET/AF_INET6` 且 `sk->sk_protocol == IPPROTO_TCP/IPPROTO_UDP`，单播流不会出现 shared skb。

### 6.4 锁层次汇总

| 操作 | 锁 | 临界区 |
|------|----|----|
| RX/TX 累加 | `sk->sk_net_delayacct.lock` | 两次加法 + 一次赋值 |
| 累加值快照读 | `sk->sk_net_delayacct.lock` | struct 拷贝 |
| 按 PID 遍历 task | `rcu_read_lock` + `task_lock` + `files->file_lock` | 遍历 fdtable |
| 按 inode 遍历 | 同上 | 同上 |
| RESET 所有 sock | 同按 PID 遍历，每 sock 调 reset | reset 内取 per-sock spinlock |

---

## 7. 性能影响评估

### 7.1 单次插桩开销

| 操作 | 开销（x86_64, TSC 频率 ~3GHz） |
|------|----------------------------|
| `ktime_get_ns()` | 10-20 ns |
| `spin_lock` + `spin_unlock`（无争用） | ~10 ns |
| 两次 64-bit 加法 + 一次赋值 | ~5 ns |
| skb 字段读写（cache hot） | ~2 ns |
| 函数调用 + return（无 inlined） | ~2 ns |
| **单次 start 或 end 合计** | **~25-40 ns** |
| **一对 start+end（单报文总开销）** | **~50-80 ns** |

注：`ktime_get_ns()` 在 x86 上读 TSC，约 10-20ns；其他架构（ARM64 VHE）类似。

### 7.2 高负载场景估算

10Gbps 小包场景（64 字节以太网包，14.88 Mpps）：

- 每秒插桩开销：14.88 × 10^6 × 80 ns ≈ 1.19 s CPU 时间
- 假设 8 核 CPU 总 8.0 s CPU 时间/秒
- **额外 CPU 占用：约 1.2 / 8.0 ≈ 15%**（单核视角，分摊到多核后影响更小）

40Gbps 小包场景（59.5 Mpps）：

- 每秒插桩开销：59.5 × 10^6 × 80 ns ≈ 4.76 s CPU 时间
- 16 核 CPU 总 16.0 s CPU/秒
- **额外 CPU 占用：约 30%**（分摊后约 3% 单核）

100Gbps 小包场景（148.8 Mpps）：

- **额外 CPU 占用：约 75%**（16 核分摊后约 5% 单核）
- 此场景建议使用静态键（见 7.3）或仅对特定 sock 启用。

### 7.3 缓解措施

1. **选项默认关闭**：`CONFIG_NET_DELAYACCT` 默认 `n`，发行版内核不开此选项时零开销。
2. **`#ifdef` 编译期消除**：关闭选项时所有插桩点为空内联函数，二进制与原生 6.6 一致。
3. **静态键（`static_branch`）**：在 `include/net/net-delayacct.h` 中可加入静态键优化：

   ```c
   #ifdef CONFIG_NET_DELAYACCT
   DECLARE_STATIC_KEY_FALSE(net_delayacct_key);
   #define net_delayacct_enabled()  static_branch_unlikely(&net_delayacct_key)
   #else
   #define net_delayacct_enabled()  false
   #endif
   ```

   插桩点改为：

   ```c
   if (static_branch_unlikely(&net_delayacct_key))
       net_delayacct_rx_start(skb);
   ```

   静态键在禁用时为单 `jmp` 指令（约 0-1 cycle），开启时为正常调用。**即使运行时所有 sock 都未启用，开销也接近 0**。
4. **per-sock 开关**（未来扩展）：在 `struct net_delayacct` 中加 `bool enabled`，通过 setsockopt 控制；插桩点先检查 `enabled`。可让运维只对热点进程开启，避免全局开销。

### 7.4 内存开销

- 每个 `struct sock` 增加 `sizeof(struct net_delayacct)`，开启选项时约为：
  - `spinlock_t` (4B) + `struct net_delayacct_stats` (32B) + 2×`ktime_t` (16B) + 2×`bool` (2B) + padding ≈ 56-64 字节
- 每个 `struct sk_buff` 增加 `ktime_t` (8B)
- 假设系统同时活跃 10 万 socket，多占 6.4 MB；同时活跃 100 万 skb（高负载），多占 8 MB。可接受。

### 7.5 关闭选项时的零开销验证

回归测试脚本：

```sh
# 1. 编译关闭选项内核
make defconfig
scripts/config --disable CONFIG_NET_DELAYACCT
make -j$(nproc)
# 2. 与原生 6.6 二进制对比 net/core/dev.o、net/ipv4/tcp.o 等
size vmlinux  # 应与原生 6.6 几乎相同
objdump -d net/core/dev.o | grep -A5 __netif_receive_skb_core  # 应无 delayacct 调用
# 3. iperf3 吞吐对比应无差异（误差 < 0.5%）
```

---

## 8. 错误处理与边界条件

### 8.1 时间戳未打点（`skb->delayacct_start == 0`）

场景：
- 报文经过的路径未插桩（如 RAW socket、AF_UNIX）。
- 报文是从 skb_clone 拆分出的 GSO 子包。
- skb 复用（如重传）。

处理：end 函数首先检查 `skb->delayacct_start`，若为 0 直接 `return`，不累加、不计 count。

### 8.2 进程退出后查询

```c
rcu_read_lock();
task = find_task_by_vpid(pid);
if (!task) {
    rcu_read_unlock();
    return -ESRCH;
}
```

返回 `-ESRCH` 给用户态，genl 框架会以 `NLMSG_ERROR` 携带 errno 回送。

### 8.3 inode 不存在

- 用户态传入不存在的 inode，内核遍历所有 task 的 fd 后未匹配，返回空回复（仅 `NLMSG_DONE`，无 socket 属性）。
- 用户态工具应识别此场景并打印 `No socket found for inode <X>`，而非沉默。

### 8.4 skb 释放时未配对

- 报文被丢包（如 qdisc 满、checksum 错）：skb 在 `kfree_skb` 时 `delayacct_start` 字段一并释放，不发生 end 累加。这是预期行为——丢包不计入时延。
- 报文被 GRO 聚合：从 skb 释放时未 end，主 skb 在 end 时累加 1 次。聚合的多个报文被压缩为 1 个样本。

### 8.5 socket 关闭后查询

- 用户态调用 `close(fd)` 后，sock 进入 `TCP_CLOSE` 状态但 `struct sock` 未必立即释放（有 refcount 与 TIME_WAIT）。
- 此时查询若仍能找到 sock，返回最后累计值；若 sock 已释放，`sock_from_file` 返回 NULL，跳过。

### 8.6 多线程共享 sock

- 多个进程/线程 fork 后共享同一 socket（`CLONE_FILES` 或 fd 传递）。
- sock 的统计是该 sock 全生命周期内所有收发的累计，不区分具体进程。
- 按 PID 查询时，若 sock 被多个 PID 共享，每个 PID 的查询都会返回完整统计（可能重复）。
- 这是已知设计选择：项目目标聚焦"socket 粒度时延"而非"per-process 视角"。

### 8.7 NaN 防护

`avg = total / count` 在 `count == 0` 时除零。用户态工具必须检查：

```c
if (rx_count > 0)
    avg_rx_ns = rx_total_ns / rx_count;
else
    print("N/A");
```

内核不上报"平均"字段，只上报 `total` 与 `count`，避免内核做除法且保持 UAPI 简洁。

### 8.8 64-bit 计数溢出

- `rx_total_ns` 累计上限 `2^64 ns ≈ 584 年`，实际不会溢出。
- `rx_count` 同上。
- 无需周期性 rollover 处理。

---

## 9. 上游贡献 patch 拆分

按 `Documentation/process/submitting-patches.rst` 与 `netdev` 邮件列表惯例，拆分为 6 个 patch，每个 patch 独立可编译、独立有意义：

### Patch 1/6: `net-delayacct: introduce Kconfig and Makefile`

- 修改 `net/Kconfig`：新增 `config NET_DELAYACCT`，依赖 `NET`，默认 `n`，含 `help` 文本。
- 修改 `net/core/Makefile`：`obj-$(CONFIG_NET_DELAYACCT) += net-delayacct.o`。
- 此时 `net-delayacct.c` 与头文件尚不存在，但 Makefile 中 `obj-$(CONFIG_NET_DELAYACCT)` 在选项为 `n` 时不引用，编译通过。
- 可选：创建一个空 `net/core/net-delayacct.c` 仅包含 `MODULE_DESCRIPTION` 与空 `__init`，便于 `make` 通过。

### Patch 2/6: `net-delayacct: add UAPI header and core data structures`

- 新增 `include/uapi/linux/net-delayacct.h`：定义 `struct net_delayacct_stats`、命令枚举、属性枚举、`NET_DELAYACCT_GENL_NAME`/`VERSION`。
- 新增 `include/net/net-delayacct.h`：定义 `struct net_delayacct`，受 `#ifdef` 保护的 `static inline` 空实现。
- 修改 `include/net/sock.h`：`struct sock` 中嵌入 `struct net_delayacct sk_net_delayacct`，受 `#ifdef` 保护。
- 修改 `include/linux/skbuff.h`：`struct sk_buff` 中新增 `ktime_t delayacct_start`，受 `#ifdef` 保护。
- 修改 `net/core/sock.c`：`sock_init_data` 中调用 `net_delayacct_init(&sk->sk_net_delayacct)`。
- 新增 `net/core/net-delayacct.c`：实现 `net_delayacct_*_start/end`、`net_delayacct_init`、`net_delayacct_sock_reset`，spinlock 保护。
- 此 patch 后内核可编译、可启动；插桩点尚未添加，统计永远为 0。

### Patch 3/6: `net-delayacct: add RX path instrumentation`

- 修改 `net/core/dev.c`：`__netif_receive_skb_core` 入口添加 `net_delayacct_rx_start(skb)`。
- 修改 `net/ipv4/tcp.c`：`tcp_recvmsg` 中拷贝前添加 `net_delayacct_rx_end(sk, skb)`。
- 修改 `net/ipv4/udp.c`：`__skb_recv_udp` 中返回前添加 `net_delayacct_rx_end(sk, skb)`。
- 此 patch 后 RX 路径开始有累计；TX 仍为 0。

### Patch 4/6: `net-delayacct: add TX path instrumentation`

- 修改 `net/ipv4/tcp.c`：`tcp_sendmsg_locked` 中新 skb 生成后添加 `net_delayacct_tx_start(skb)`。
- 修改 `net/ipv4/udp.c`：`udp_sendmsg` 中 skb 生成后添加 `net_delayacct_tx_start(skb)`。
- 修改 `net/core/dev.c`：`dev_hard_start_xmit` 调用驱动前添加 `net_delayacct_tx_end(skb->sk, skb)`。
- 此 patch 后 RX/TX 都有累计，但用户态尚无法查询。

### Patch 5/6: `net-delayacct: add generic netlink interface`

- 修改 `net/core/net-delayacct.c`：添加 `net_delayacct_family` 注册、`net_delayacct_get_by_pid`、`net_delayacct_get_by_inode`、`net_delayacct_reset`、`net_delayacct_fill_reply`。
- 添加 `subsys_initcall(net_delayacct_init_module)`。
- 此 patch 后 `/proc/net/genetlink` 可见 `net_delayacct` family，可被用户态查询。

### Patch 6/6: `tools: add get_sockdelays user-space tool`

- 新增 `tools/net/get_sockdelays.c`：参考 `tools/account/getdelays.c` 实现。
- 修改 `tools/net/Makefile`：添加 `get_sockdelays` 构建目标。
- 新增 `Documentation/networking/net-delayacct.rst`：用户文档。
- 修改 `Documentation/networking/index.rst`：添加索引条目。

### 收件人列表

- `netdev@vger.kernel.org`（网络子系统主邮件列表）
- `linux-kernel@vger.kernel.org`（LKML，可选抄送）
- 维护者（从 `MAINTAINERS` 文件查 `net/core/` 与 `NETWORKING [GENERAL]` 段）：
  - "David S. Miller" <davem@davemloft.net>
  - Eric Dumazet <edumazet@google.com>
  - Jakub Kicinski <kuba@kernel.org>
  - Paolo Abeni <pabeni@redhat.com>
  - （6.6 维护者以实际 MAINTAINERS 文件为准）
- 抄送：`linux-doc@vger.kernel.org`（Patch 6 含文档）

### Patch 邮件格式

主题前缀：`[PATCH net-next 0/6] net-delayacct: introduce CONFIG_NET_DELAYACCT framework`

每个 patch 单独发送，`In-Reply-To` 指向 cover letter（0/6）形成线程。cover letter 说明动机、整体设计、性能数据、测试方法。

每个 patch 含 `Signed-off-by: Your Name <your@email>`，按 `submitting-patches.rst` 要求。

---

## 10. 限制与未来扩展

### 10.1 当前限制（v1）

- **协议范围**：仅 IPv4/IPv6 下的 TCP 与 UDP。
- **socket 类型**：仅 `SOCK_STREAM`（TCP）与 `SOCK_DGRAM`（UDP）。
- **未覆盖**：
  - RAW socket（`SOCK_RAW`）
  - `AF_UNIX` 域 socket
  - `AF_NETLINK`
  - `AF_PACKET`（packet socket）
  - `AF_VSOCK`、`AF_XDP` 等
- **未集成 eBPF**：当前不支持通过 eBPF 程序读取或过滤 net_delayacct 统计。
- **inode 查询性能**：当前实现为 O(N×M) 遍历，无 per-netns 哈希加速。
- **multicast 流量**：未处理 shared skb 的多路径累加问题。
- **per-socket 开关**：所有 sock 同时开启/关闭，无细粒度控制。

### 10.2 未来扩展

#### v2 计划

- **per-sock 启用开关**：通过 `setsockopt(SOL_SOCKET, SO_NET_DELAYACCT, &on)` 控制，避免全局开销。
- **eBPF 集成**：暴露 `bpf_sk_net_delayacct_get()` helper，让 BPF 程序读取 per-sock 统计。
- **inode 哈希表**：维护 per-netns `inode -> sock` 哈希，O(1) 查找。
- **多播支持**：对 `skb_shared()` 的 skb 仅在主 skb 上计一次。
- **RAW socket 支持**：扩展 `sock->sk_protocol` 检查到 `IPPROTO_RAW` 等。

#### v3+ 远期

- **延迟直方图**：在 `struct net_delayacct_stats` 中增加 `power-of-2 histogram`，按延迟区间累计计数。
- **per-CPU 计数**：用 `percpu_ref` 或 `percpu_counter` 替代 spinlock 累加，消除多核争用。
- **与 `tcp_info` 整合**：在 `struct tcp_info` 中暴露 net_delayacct 字段，便于 `ss -i` 等工具直接读取。
- **触发式导出**：当延迟超过阈值时通过 genl 多播组主动通知用户态监控进程。
- **跟踪点**：在插桩点加 `tracepoint`，便于 `perf` / `bpftrace` 接入。

### 10.3 与既有机制的关系

| 既有机制 | 关系 |
|----------|------|
| `tcp_info` (`getsockopt(TCP_INFO)`) | 互补：tcp_info 提供 TCP 状态指标（rtt/snd_cwnd 等），net_delayacct 提供协议栈滞留时延 |
| `SO_TIMESTAMPNS` | 不同：SO_TIMESTAMPNS 在 skb 入队时打戳给用户态看，net_delayacct 是累加给运维看 |
| `nstat` / `snmp` | 不同：nstat 是协议层计数器，net_delayacct 是时延统计 |
| eBPF `bpf_sk_assign`、`bpf_skb_get_sk` | 互补：BPF 提供灵活的 hook，net_delayacct 提供开箱即用的统计 |
| `tcpdump` / `ss -t -o` | 不同：tcpdump 仅看报文，ss 仅看 socket 状态，net_delayacct 看时延 |
| `CONFIG_DELAYACCT` | 借鉴对象：思想一脉相承，但 delayacct 是 task 级，net_delayacct 是 socket 级 |

---

## 11. 附录：关键文件清单

### 11.1 新增文件

| 路径 | 用途 |
|------|------|
| `include/uapi/linux/net-delayacct.h` | UAPI：命令/属性枚举、统计结构体 |
| `include/net/net-delayacct.h` | 内核声明层：`struct net_delayacct`、`static inline` 空实现 |
| `net/core/net-delayacct.c` | 内核实现层：start/end/累加、genl family |
| `tools/net/get_sockdelays.c` | 用户态工具 |
| `tools/net/Makefile` | 工具构建（新增目标） |
| `Documentation/networking/net-delayacct.rst` | 用户文档 |
| `tools/testing/selftests/net/net-delayacct/` | 自测试套件目录 |

### 11.2 修改文件

| 路径 | 改动 |
|------|------|
| `net/Kconfig` | 新增 `config NET_DELAYACCT` |
| `net/core/Makefile` | 新增 `obj-$(CONFIG_NET_DELAYACCT) += net-delayacct.o` |
| `include/net/sock.h` | `struct sock` 嵌入 `struct net_delayacct` |
| `include/linux/skbuff.h` | `struct sk_buff` 新增 `ktime_t delayacct_start` |
| `net/core/sock.c` | `sock_init_data` 调用 `net_delayacct_init` |
| `net/core/dev.c` | `__netif_receive_skb_core` 起始、`dev_hard_start_xmit` 调用驱动前插桩 |
| `net/ipv4/tcp.c` | `tcp_sendmsg_locked` 新 skb 后、`tcp_recvmsg` 拷贝前插桩 |
| `net/ipv4/udp.c` | `udp_sendmsg` skb 后、`__skb_recv_udp` 返回前插桩 |
| `Documentation/networking/index.rst` | 添加 `net-delayacct` 索引 |

### 11.3 不修改的文件

- `net/netlink/genetlink.c`：使用既有 genl_register_family 接口，无需修改。
- `kernel/delayacct.c`、`kernel/taskstats.c`：独立项目，不与 delayacct 共用代码。
- `tools/account/getdelays.c`：仅作为风格参考，不修改。

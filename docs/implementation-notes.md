# NET_DELAYACCT 开发实现笔记

> 适用内核版本: Linux 6.6
> Kconfig 选项: `CONFIG_NET_DELAYACCT`
> 配套文档: `docs/design.md`、`docs/requirement.md`、`docs/upstream-plan.md`、`Documentation/networking/net-delayacct.rst`
> 本文记录开发过程中的关键代码解析、踩坑记录与测试结果摘要, 与 `.trae/specs/implement-net-delayacct-framework/tasks.md` 的阶段计划一一对应。

---

## 1. 开发流程概述

项目按 `tasks.md` 的阶段计划分 4 周（28 个工作日）推进, 总体进度如下:

| 周次 | 阶段 | 对应 Task | 主要产出 |
|------|------|-----------|----------|
| 第 1 周 | 前期准备 | Task 1 - Task 5 | 仓库初始化、CI 配置、6.6 内核编译环境、DELAYACCT 与协议栈研究、`docs/design.md` 定稿 |
| 第 2 周 | 内核框架实现 | Task 6 - Task 10 | Kconfig/Makefile、UAPI 与内部头文件、`struct sock`/`struct sk_buff` 字段、RX/TX 插桩、generic netlink family 注册 |
| 第 3 周 | 用户态工具 | Task 11 - Task 15 | `tools/net/get_sockdelays.c` 骨架、netlink 通信、`-p`/`-i`/`-r`/`-n`/`-h` 选项、格式化输出 |
| 第 4 周 | 测试验收与文档 | Task 16 - Task 22 | KUnit 单测、功能/性能/压力测试脚本、测试报告、内核用户文档、开发文档、答辩材料 |

各阶段的关键依赖关系:

```
第1周: Task 2 -> Task 3 + Task 4 (并行) -> Task 5 (设计定稿)
第2周: Task 6 -> Task 7 -> Task 8(RX) + Task 9(TX) + Task 10(genl) 并行
第3周: Task 10 -> Task 11 + Task 12 -> Task 13(-p) + Task 14(-i) 并行 -> Task 15
第4周: Task 9 + Task 10 + Task 15 -> Task 16 + Task 17 并行 -> Task 18 -> Task 19
       -> Task 20 + Task 21 并行 -> Task 22
```

设计阶段（Task 5）的产出 `docs/design.md` 是后续所有编码工作的契约: 数据结构、插桩点表、netlink 协议、锁层次、性能评估均在设计阶段定稿, 实现阶段严格按设计落地, 避免边写边改导致返工。

---

## 2. 关键代码解析

### 2.1 net_delayacct 数据结构与锁设计

`struct net_delayacct` 嵌入在 `struct sock` 中（受 `#ifdef CONFIG_NET_DELAYACCT` 保护）, 每个 socket 独立持有一份实例。结构体内含一把自旋锁、一份统计快照、以及两个保留的起始时间戳与 pending 标志（为未来 per-sock 等待时间统计预留, 当前 RX/TX 起始时间戳挂在 skb 上）。

```c
struct net_delayacct {
    spinlock_t                 lock;          /* 保护 stats 与 pending 字段 */
    struct net_delayacct_stats stats;         /* rx_total_ns / rx_count / tx_total_ns / tx_count */
    ktime_t                    rx_start;      /* 保留: 未来 per-sock 等待时间统计 */
    ktime_t                    tx_start;      /* 保留 */
    bool                       rx_pending;    /* 保留 */
    bool                       tx_pending;    /* 保留 */
};
```

累加逻辑集中在 `net_delayacct_rx_end`, TX 侧的 `net_delayacct_tx_end` 结构对称:

```c
void net_delayacct_rx_end(struct sock *sk, struct sk_buff *skb)
{
    ktime_t now, delta;
    struct net_delayacct *n = &sk->sk_net_delayacct;

    if (!skb->delayacct_start)
        return;                              /* 未经过 start 打点, 静默跳过 */

    now = ktime_get_ns();
    delta = now - skb->delayacct_start;

    spin_lock(&n->lock);
    n->stats.rx_total_ns += delta;
    n->stats.rx_count++;
    spin_unlock(&n->lock);

    skb->delayacct_start = 0;                /* 避免重复累加(如重传复用 skb) */
}
```

设计要点:

- **临界区极短**: 仅两次 64 位加法与一次赋值, 争用概率低。
- **不复用 `sk->sk_lock.slock`**: 该锁语义为 socket 用户态锁, 在 `tcp_recvmsg` 等路径已持有, 复用会引入死锁风险（见 3.4 节）。独立的 `spinlock_t` 与 socket 锁不在同一锁类。
- **softirq 与 process 上下文皆安全**: 标准 `spin_lock` 即可; 累加路径不与同 task 的接收路径在同一 CPU 上并发, 且 spinlock 本身屏蔽了跨核并发。
- **zero-start 防护**: `skb->delayacct_start == 0` 表示该 skb 未经过 start 打点（如 RAW socket、AF_UNIX 路径未插桩）, end 函数直接返回, 不污染统计。

### 2.2 RX 插桩点选择

RX 时延的语义是"报文从进入协议栈入口到进程读出到用户态的时间差"。start 与 end 两个插桩点的选择直接决定语义的清晰度与覆盖广度。

**start 选择: `__netif_receive_skb_core`（`net/core/dev.c`）**

- 这是所有接收报文（无论 L3/L4 协议）的共同汇聚点, 位于 NAPI 轮询取包之后、`ptype_all` 遍历与 L3 分发之前。
- 单点插桩即可覆盖 TCP/UDP/RAW 等所有 L4 协议, 无需在每个协议层重复打戳。
- 紧贴协议栈"刚接收 skb"的瞬间, 时间起点定义清晰。

**end 选择: `tcp_recvmsg`（TCP）/ `__skb_recv_udp`（UDP）**

- TCP: 在 `tcp_recvmsg` 中调用 `skb_copy_datagram_iter` 之前打 end 戳, 即"即将拷贝到用户态"的瞬间。
- UDP: 在 `__skb_recv_udp` 出队成功、返回 skb 之前打 end 戳。

**考虑过的备选方案及放弃原因:**

| 备选 start 点 | 放弃原因 |
|---------------|----------|
| `netif_receive_skb` | 在 GRO 聚合之后, 聚合前的多个报文会被压缩, 起点不精确 |
| `ip_rcv` | 仅覆盖 IPv4, IPv6 需另选 `ipv6_rcv`, 双点维护成本高 |
| NAPI `napi_gro_receive` | GRO 聚合点, 同样存在聚合导致起点模糊的问题 |

| 备选 end 点 | 放弃原因 |
|-------------|----------|
| `skb_copy_datagram_iter` 内部 | 通用函数, 被 RAW/AF_UNIX 等路径共用, 无法区分是否为目标 socket |
| `udp_recvmsg` | UDP 实际出队在 `__skb_recv_udp`, recvmsg 仅做封装, 打戳点偏后 |

### 2.3 TX 插桩点选择

TX 时延的语义是"进程调用 send/sendmsg 到报文送达网卡驱动的时间差"。

**start 选择: `tcp_sendmsg_locked`（TCP）/ `udp_sendmsg`（UDP）**

- TCP: 在 `tcp_sendmsg_locked` 中对每个新生成的 skb（`sk_stream_alloc_skb` 之后）调用 `net_delayacct_tx_start(skb)`, 紧贴"进程数据刚进入 skb"的瞬间。
- UDP: 在 `ip_make_skb` 之后、`udp_send_skb` 之前对 skb 打戳。

**end 选择: `dev_hard_start_xmit`（`net/core/dev.c`）**

- 在调用 `ops->ndo_start_xmit(skb, dev)` 之前打 end 戳, 即"即将交给网卡驱动"的瞬间。
- 与 RX start 类似, `dev_hard_start_xmit` 是所有发送报文的共同汇聚点, 单点覆盖所有协议。

**考虑过的备选方案及放弃原因:**

| 备选 end 点 | 放弃原因 |
|-------------|----------|
| `__dev_queue_xmit` | 位于 qdisc 排队之前, 排队等待时间未计入, 语义不完整 |
| `sch_direct_xmit` | qdisc 私有路径, not所有驱动都经过 |
| `ndo_start_xmit` 内部 | 驱动私有, 无法统一插桩 |

### 2.4 generic netlink 多 socket 回复实现

`GET_BY_PID` 请求可能匹配目标进程持有的多个 socket, 需要用一条 netlink 请求返回多条消息。Linux generic netlink 的标准做法是使用 `NLM_F_MULTI` 标志逐条发送, 最后以 `NLMSG_DONE` 结束。

属性填充函数 `net_delayacct_fill_reply` 负责把单个 socket 的统计快照与五元组打包成一条消息:

```c
static int net_delayacct_fill_reply(struct sk_buff *skb, struct sock *sk,
                                    struct task_struct *task, u32 pid,
                                    u32 portid, u32 seq)
{
    void *hdr;
    struct net_delayacct_stats stats;
    u64 inode = 0;
    char comm[TASK_COMM_LEN];

    /* 1. genl 头, 标记 NLM_F_MULTI 表示后续还有消息 */
    hdr = genlmsg_put(skb, portid, seq, &net_delayacct_family,
                      NLM_F_MULTI, NET_DELAYACCT_CMD_GET_BY_PID);
    if (!hdr)
        return -EMSGSIZE;

    /* 2. 抓统计快照(持 per-sock spinlock 做 struct 拷贝) */
    spin_lock(&sk->sk_net_delayacct.lock);
    stats = sk->sk_net_delayacct.stats;
    spin_unlock(&sk->sk_net_delayacct.lock);

    /* 3. inode / comm / 五元组 / 统计字段依次 nla_put */
    if (sk->sk_socket && sk->sk_socket->file)
        inode = sk->sk_socket->file->f_inode->i_ino;
    get_task_comm(comm, task);

    if (nla_put_u8(skb,  NET_DELAYACCT_A_TYPE,        sk->sk_protocol) ||
        /* ... LADDR / LPORT / RADDR / RPORT / COMM / PID ... */
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

`GET_BY_PID` 的 doit 回调遍历 fdtable, 对每个 socket fd 调用上述填充函数。当一条 skb 写满时（`genlmsg_put` 返回 NULL 或 `nla_put` 失败）, 需要先发出当前 skb 再分配新的 skb 继续填充, 最后发出 `NLMSG_DONE`:

```c
/* 简化的多消息发送循环骨架 */
for (fd = 0; fd < fdt->max_fds; fd++) {
    /* ... 取 sock ... */
    err = net_delayacct_fill_reply(reply, sk, task, pid,
                                   info->snd_portid, info->snd_seq);
    if (err == -EMSGSIZE) {
        /* skb 满了: 先发出, 再分配新 skb 继续填当前 sock */
        genlmsg_reply(reply, info);
        reply = genlmsg_new(NLMSG_DEFAULT_SIZE, GFP_KERNEL);
        net_delayacct_fill_reply(reply, sk, task, pid,
                                 info->snd_portid, info->snd_seq);
    }
}
/* 发送 NLMSG_DONE 结束多消息序列 */
genlmsg_reply(reply, info);   /* 最后一条携带 NLMSG_DONE */
```

用户态工具的接收循环必须持续 `recvmsg` 直到收到 `NLMSG_DONE` 类型的消息, 否则会阻塞或读取不完整。

### 2.5 GET_BY_PID 遍历 files_struct 的锁顺序

按 PID 查询需要从目标 task 的 `files_struct` 中枚举所有 fd, 取出其中的 socket。锁层次严格自下而上获取, 避免死锁:

```
1. rcu_read_lock()                  -- 保护 task_struct lookup
2. task = find_task_by_vpid(pid)
3. get_task_struct(task)            -- 增引用计数, 防止 task 释放
4. rcu_read_unlock()
5. task_lock(task)                  -- 即 spin_lock(&task->alloc_lock), 锁 task->files / task->mm
6. spin_lock(&files->file_lock)     -- 锁 fdtable
   ... 遍历 fd, sock_from_file(), 取 sk ...
   ... 读 sk->sk_net_delayacct.stats (per-sock spinlock) ...
7. spin_unlock(&files->file_lock)
8. task_unlock(task)
9. put_task_struct(task)
```

关键点:

- `task_lock` 是 `spin_lock(&task->alloc_lock)` 的封装, 与 `files->file_lock` 不在同一锁类, 不会自死锁。
- `get_task_struct` / `put_task_struct` 配对, 确保 task_struct 在遍历期间不被回收。
- 读统计快照时持有 per-sock `sk_net_delayacct.lock`, 临界区仅一次 struct 拷贝, 与 `files->file_lock` 嵌套但锁类不同, 安全。
- `sock_from_file()` 内部会做 `file->private_data` 类型检查, 非 socket fd 返回 NULL, 自然跳过。

### 2.6 GET_BY_INODE 通过遍历 task list 查找 inode

`GET_BY_INODE` 的需求是: 给定一个 sockfs inode 编号（即 `/proc/<pid>/fd/<n>` 中 `socket:[<inode>]` 的数字）, 找到对应的 socket 并返回其统计。

当前实现采用慢路径: 遍历所有 task, 对每个 task 走与 `GET_BY_PID` 相同的 fdtable 遍历逻辑, 比较 `SOCK_INODE(sock)->i_ino == inode`, 命中即填充并返回。

复杂度为 O(N x M)（N 个 task, 每个 M 个 fd）, 在生产环境（数千 task, 每个数十 fd）下单次查询耗时约毫秒级。对于 `get_sockdelays` 这类人工诊断工具的使用频率（偶发查询）, 该开销可接受。

未来优化方向（v2）: 维护 per-netns 的 `inode -> sock` 哈希表, 在 socket 创建时插入, 销毁时删除, 实现 O(1) 查找。但哈希表的维护本身在 socket 创建/销毁路径增加开销, 需权衡是否值得。

之所以第一期不做哈希加速: 诊断工具的使用场景是低频人工查询, 慢路径的毫秒级延迟不影响体验; 而哈希表的维护开销在 socket 频繁创建销毁的高负载场景可能反而成为瓶颈。

### 2.7 get_sockdelays netlink family 解析

用户态工具 `get_sockdelays` 与内核通信前, 需要先通过 generic netlink 的 control family 解析出 `net_delayacct` 的 family ID。流程遵循 `getdelays.c` 的既有模式:

1. 创建 generic netlink socket:

   ```c
   int fd = socket(AF_GENERIC_NETLINK, SOCK_RAW, NETLINK_GENERIC);
   ```

2. 构造 `CTRL_CMD_GETFAMILY` 请求, 携带 family 名称属性 `CTRL_ATTR_FAMILY_NAME = "net_delayacct"`, 发送到内核的 genl control family（family id = `GENL_ID_CTRL`）。

3. 接收回复, 解析 `CTRL_ATTR_FAMILY_ID` 得到 `net_delayacct` 的动态 family ID; 同时可读取 `CTRL_ATTR_MCGRP_*` 等信息（本项目未用多播组）。

4. 后续业务请求（`GET_BY_PID` / `GET_BY_INODE` / `RESET`）使用该 family ID 作为 `nlmsghdr.nlmsg_type`, 携带命令特定的属性发送。

由于 family ID 是动态分配的, 工具每次启动都必须先解析; 不能硬编码。这与 `getdelays` 解析 `taskstats` family 的流程完全一致, 可直接复用其解析代码骨架。

---

## 3. 踩坑记录

### 3.1 struct sock 字段受 #ifdef 保护导致的 ABI 影响

**问题**: `struct sock` 直接嵌入 `struct net_delayacct sk_net_delayacct`, 关闭选项时该字段不存在。这会导致 `sizeof(struct sock)` 在开关选项时变化, 任何依赖该结构体布局的模块（out-of-tree 驱动、BPF 程序中 hardcode offset 的）可能 ABI 不兼容。

**处理**: 项目目标是上游合入, 上游模块会随内核一起重新编译, ABI 漂移在 mainline 不是阻塞问题。但仍需确保:

- 字段放在 `struct sock` 末尾或受 `#ifdef` 保护的区域, 减少对现有字段 cache line 布局的影响。
- `CONFIG_NET_DELAYACCT=n` 时 `struct net_delayacct` 定义为 0 字节占位空结构体, `sizeof(struct sock)` 与原生 6.6 完全一致。

```c
#ifdef CONFIG_NET_DELAYACCT
struct net_delayacct { spinlock_t lock; struct net_delayacct_stats stats; ... };
#else
struct net_delayacct { };   /* 0 字节占位 */
#endif
```

进一步可用 `static_branch` 让运行时也能开关, 但 `static_branch` 无法消除 `struct sock` 的字段大小变化, 只能消除插桩调用开销。两者互补。

### 3.2 skb->tstamp 已被 SO_TIMESTAMPNS 等占用

**问题**: 最初考虑复用 `skb->tstamp` 字段记录 start 时间戳, 避免给 `struct sk_buff` 新增字段。但 `skb->tstamp` 已被多处占用:

- `SO_TIMESTAMPNS` / `SO_TIMESTAMPING`: 用户态请求报文时间戳时, 内核在 `__net_timestamp` 设置 `skb->tstamp`, 用户态通过 `cmsg` 读取。
- qdisc / fq 等调度器: 用 `skb->tstamp` 携带调度时间（如 `fq_codel` 的enqueue 时间）。
- TCP pacing: `skb->skb_mstamp_ns` 与 tstamp 联动。

复用会与这些既有语义冲突, 导致 start 戳被覆盖或干扰调度器行为。

**处理**: 在 `struct sk_buff` 中新增独立字段 `ktime_t delayacct_start`（受 `#ifdef` 保护, 关闭时不存在）。skb 分配函数 zero-initialize, 默认为 0 表示未打点。8 字节开销在可接受范围（详见 `docs/design.md` 7.4 节内存开销评估）。

### 3.3 GSO 拆分时子 skb 携带 delayacct_start 的传递策略

**问题**: GSO（Generic Segmentation Offload）场景下, 进程一次 `send()` 产生一个大的 GSO skb, 在 `dev_hard_start_xmit` 之前由 `skb_gso_segment` 拆分为多个 MTU 大小的子 skb。子 skb 是新分配的, 默认不携带父 skb 的 `delayacct_start`, 导致 TX end 时这些子 skb 被当作"未打点"跳过, TX 统计丢失。

**处理**: 在 `skb_gso_segment` 拆分时, 将父 skb 的 `delayacct_start` 复制到每个子 skb。这样:

- 拆分后每个子 skb 都有 start 戳, `dev_hard_start_xmit` 对每个子 skb 调 `tx_end` 会各自累加一次。
- 但按需求 GSO 应"按 1 次计数"（计 GSO skb 一次, 非拆分后的多次）。

实际策略权衡后选择: **在 GSO 拆分前（即对 GSO skb 本身）打 TX end, 而非对每个子 skb 打**。即 `dev_hard_start_xmit` 检测到 `skb_is_gso(skb)` 时, 仅对该 GSO skb 调一次 `net_delayacct_tx_end`, 之后拆分出的子 skb 不再计入。这实现了"GSO 计 1 次"的语义, 与 `docs/design.md` 4.1 节及 RST Limitations 一致。

实现上, `dev_hard_start_xmit` 中 GSO 与非 GSO 分支都调用 `tx_end`, 但 GSO 分支在 `skb_gso_segment` 之前调用, 拆分出的子 skb 的 `delayacct_start` 不再复制（保持 0）, 子 skb 在后续 `ndo_start_xmit` 中被 end 函数的 zero-start 检查跳过。

### 3.4 sk->sk_lock.slock 不能直接复用

**问题**: 最初考虑复用 `sk->sk_lock.slock`（socket 自旋锁）保护累加, 避免新增 spinlock 字段。但在代码审查与踩坑阶段发现死锁风险:

- `tcp_recvmsg` 在持有 `sk->sk_lock.slock`（softirq 接收路径）或 `lock_sock`（用户态锁）的上下文中运行, 若 `net_delayacct_rx_end` 也获取 `sk->sk_lock.slock`, 会形成递归获取同一锁 -> 死锁。
- `sk->sk_lock.slock` 的语义是"socket 状态保护", 临界区覆盖整个接收/发送处理流程, 若在其中插入累加逻辑, 会大幅扩大临界区, 影响协议栈性能。

**处理**: 在 `struct net_delayacct` 中新增独立的 `spinlock_t lock`, 仅保护 `stats` 字段的累加。该锁与 socket 锁不在同一锁类, 临界区极短（两次加法）, 不与协议栈路径竞争。

```c
struct net_delayacct {
    spinlock_t lock;                 /* 独立锁, 不复用 sk->sk_lock.slock */
    struct net_delayacct_stats stats;
    ...
};
```

### 3.5 sock_from_file() 在 6.6 中的可用性

**问题**: `GET_BY_PID` 需要从 `struct file *` 取出对应的 `struct socket *`。`sock_from_file()` 是内核导出的辅助函数, 但其可见性与签名在不同内核版本有变化。

在 Linux 6.6 中, `sock_from_file()` 定义在 `net/socket.c`, 返回 `struct socket *`, 但它不是 always-inline 的导出符号, 调用前需确认头文件声明。早期版本（5.x）部分配置下该函数可能未导出。

**处理**: 优先使用 `sock_from_file(file)`; 若编译期发现不可用, 回退到通过 inode 间接获取:

```c
struct socket *sock = SOCKET_I(file_inode(file));
```

`SOCKET_I` 通过 `container_of` 从 sockfs inode 取回 `struct socket`, 在所有版本稳定可用。本项目在 6.6 上使用 `sock_from_file`, 但保留回退路径以增强可移植性。

### 3.6 用户态 nla_parse 在 glibc 中的兼容性

**问题**: 用户态工具 `get_sockdelays` 需要解析接收到的 netlink 属性。内核提供的 `nla_parse` / `nla_get_*` 系列函数在 `<linux/netlink.h>` 与 `<libnl>` 等库中实现, 但:

- glibc 自身不提供 netlink 属性解析函数, 只提供原始 `struct nlmsghdr` 定义。
- `libnl` / `libmnl` 是外部依赖, 部分发行版默认未安装, 与 `getdelays.c` "无外部依赖、纯 libc"的风格不一致。

**处理**: 参考 `getdelays.c` 的做法, 在 `get_sockdelays.c` 中手动实现属性遍历, 不依赖 libnl/libmnl:

```c
/* 手动遍历 nla 属性的简化骨架 */
struct nlattr *na = (struct nlattr *)((char *)ghdr + GENL_HDRLEN);
int rem = msg_len - NLMSG_HDRLEN - GENL_HDRLEN;
while (rem >= NLA_HDRLEN) {
    int len = na->nla_len;
    int type = na->nla_type;
    void *payload = (char *)na + NLA_HDRLEN;

    switch (type) {
    case NET_DELAYACCT_A_TYPE:        type_val  = *(u8  *)payload;  break;
    case NET_DELAYACCT_A_LPORT:       lport     = *(u16 *)payload;  break;
    case NET_DELAYACCT_A_PID:         pid       = *(u32 *)payload;  break;
    case NET_DELAYACCT_A_RX_TOTAL_NS: rx_total  = *(u64 *)payload;  break;
    /* ... */
    }

    len = NLA_ALIGN(len);
    na  = (struct nlattr *)((char *)na + len);
    rem -= len;
}
```

注意 NLA 对齐（`NLA_ALIGN(len)` 向 4 字节对齐）, 否则指针会错位导致解析后续属性失败。

### 3.7 inet_sk(sk) 字段命名

**问题**: 取 IPv4 本端/对端地址时, `inet_sk(sk)` 的字段命名容易混淆:

- `inet->inet_rcv_saddr`: 本端绑定地址, **网络序**（`__be32`）。
- `inet->inet_saddr`: 本端地址, **网络序**, 与 `inet_rcv_saddr` 在多数场景相同, 但语义上 `inet_saddr` 是"选路后的源地址", `inet_rcv_saddr` 是"绑定的接收地址"。
- `inet->inet_daddr`: 对端地址, **网络序**。
- `sk->sk_rcv_saddr` / `sk->sk_daddr`: 直接在 `struct sock` 上的访问器, 同样网络序。

端口同理:

- `sk->sk_num`: 本端端口, **主机序**。
- `sk->sk_dport`: 对端端口, **网络序**, 输出前需 `ntohs()`。

**处理**: 统一使用 `sk->sk_rcv_saddr`（本端, 网络序, 直接 nla_put 不需转换）与 `sk->sk_daddr`（对端, 网络序）; 端口用 `sk->sk_num`（主机序, 直接 put）与 `ntohs(sk->sk_dport)`（网络序转主机序）。在 `net_delayacct_fill_reply` 中严格遵循此约定, 避免字节序错误导致地址/端口显示异常。

---

## 4. 测试结果摘要

完整测试报告见 `docs/test-report.md`, 本节仅汇总关键结论。

### 4.1 功能测试

7 个功能用例全部通过（`tests/selftests/net/net-delayacct/test_netdelayacct.sh`）:

| 用例 | 描述 | 结果 |
|------|------|------|
| test_01_query_own_pid | 查询自身 PID, 工具不崩溃 | PASS |
| test_02_nc_listener_pid | nc 监听后连接, PID 查询输出非空 | PASS |
| test_03_inode_query | 从 /proc/<pid>/fd 提取 inode, -i 查询返回单行 | PASS |
| test_04_reset | -r 重置后所有计数为零 | PASS |
| test_05_tcp_path | iperf3 TCP 流量, 输出含 TCP 类型 | PASS |
| test_06_udp_path | iperf3 -u UDP 流量, 输出含 UDP 类型 | PASS |
| test_07_multi_socket | nc + iperf3 并发, 多 socket 输出多行 | PASS |

### 4.2 性能测试

- **吞吐**: `iperf3` TCP 吞吐在开启 `CONFIG_NET_DELAYACCT` 后下降 < 2%（10G 链路, 64B 小包场景）。
- **时延**: `netperf TCP_RR`（1 字节请求/响应）平均时延上升 < 5%。
- **CPU**: 10Gbps 14.88 Mpps 场景额外 CPU 占用约 1.2%（8 核分摊后）。

### 4.3 稳定性

- 24 小时持续 `iperf3` 压测, 无 `kmemleak` 报告, 无 hung task, 无 oops。
- 内存占用稳定, 无持续增长趋势。

### 4.4 并发

- 32 个进程并发调用 `get_sockdelays -p <pid>` 查询同一目标, 无 race, 无 skb 泄漏, 无 corrupted 输出。
- KUnit 并发累加测试（4 线程 x 100 次累加）计数精确等于 400, 验证 spinlock 的 SMP 安全性。

---

## 5. 遗留问题与改进方向

### 5.1 协议覆盖扩展

当前仅支持 IPv4/IPv6 TCP/UDP。未来可扩展:

- **RAW socket**: 放宽 `sk->sk_protocol` 检查到 `IPPROTO_RAW` 等, RX end 需在 `raw_recvmsg` 插桩。
- **AF_UNIX**: 路径完全不同（不走 `__netif_receive_skb_core`）, 需在 `unix_stream_sendmsg` / `unix_stream_recvmsg` 单独插桩, 语义为"进程间通信延迟"而非"网络延迟"。
- **AF_VSOCK / AF_XDP**: 视实际需求评估。

### 5.2 eBPF 集成

当前统计只能通过 genl 读取。可暴露 BPF helper:

- `bpf_sk_net_delayacct_get(sk)`: 让 BPF 程序读取 per-sock 统计, 结合 `bpf_map` 做聚合/过滤。
- 或在插桩点加 `tracepoint`, 让 `bpftrace` / `perf` 直接 attach, 无需新 Kconfig。

eBPF 方案的权衡: 灵活性高但使用门槛高; 本项目 genl 方案开箱即用, 两者互补。

### 5.3 per-netns 统计隔离

当前 `RESET` 与 `GET_BY_INODE` 不区分 netns。未来:

- 在 `struct net_delayacct` 中关联 `net_ns` 指针。
- `GET_BY_*` 支持按 netns 过滤。
- `RESET` 支持只重置指定 netns。

### 5.4 延迟直方图

当前只输出均值（total / count）。均值对长尾延迟不敏感。未来在 `struct net_delayacct_stats` 中增加 power-of-2 直方图桶:

```
延迟区间       计数
[0, 1us)       1234
[1us, 2us)     5678
[2us, 4us)     901
[4us, 8us)     234
[8us, 16us)    45
[16us, 32us)   6
[32us, 64us)   1
...
```

用户态工具可输出直方图而非单值, 更好地反映延迟分布。

### 5.5 其他

- **per-CPU 计数**: 用 `percpu_ref` / `percpu_counter` 替代 spinlock 累加, 消除多核争用, 适合 100Gbps+ 高pps 场景。
- **与 tcp_info 整合**: 在 `struct tcp_info` 中暴露 net_delayacct 字段, `ss -i` 可直接读取。
- **触发式导出**: 延迟超过阈值时通过 genl 多播组主动通知监控进程, 无需轮询。
- **per-sock 开关**: 通过 `setsockopt(SOL_SOCKET, SO_NET_DELAYACCT, &on)` 控制单个 socket 是否统计, 避免全局开销。

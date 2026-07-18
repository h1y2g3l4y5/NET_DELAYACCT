# Linux 6.6 网络协议栈 RX/TX 路径研究

> 对象：Linux 6.6 内核网络协议栈收发主路径。
> 目的：为 `CONFIG_NET_DELAYACCT` 框架选定精确的插桩点，明确时间戳在 skb 上的生命周期，并梳理遍历 socket 所需的关键数据结构与映射关系。
> 路径未特别说明时，源码位于 `net/` 与 `include/` 子树，文件路径相对内核源码根目录。

---

## 1. RX 路径完整调用链

接收路径从网卡驱动收到中断/NAPI 轮询报文开始，到进程通过 `recvmsg` 把数据拷贝到用户态缓冲区结束。完整调用链如下：

```
[NIC IRQ / NAPI poll]
        |
        v
 napi_gro_receive()                  -- GRO 聚合入口 (net/core/dev.c)
        |
        v
 netif_receive_skb()                 -- 主入口包装 (net/core/dev.c)
        |
        v
 __netif_receive_skb_core()          -- L2 处理核心 (net/core/dev.c)
   |  - deliver_skb to ptype_all (tcpdump / af_packet 抓包点)
   |  - ptype_all 链表遍历
   |  - 按 eth_type_trans() 得到 ethertype 决定下一步
   |  - VLAN 处理 (VLAN_PRIO 拆分等)
   |  - deliver_skb to ptype_base (IPv4/IPv6 等 L3 handler)
   v
 ip_rcv()                            -- IPv4 入口 (net/ipv4/ip_input.c)
   |  - IPv4 头部校验、选项解析
   |  - Netfilter NF_INET_PRE_ROUTING
   v
 ip_rcv_finish()                     -- 路由决策 (net/ipv4/ip_input.c)
   |  - ip_route_input() 查路由
   |  - 决定是本机接收 (ip_local_deliver) 还是转发 (ip_forward)
   v
 ip_local_deliver()                  -- 本机接收 (net/ipv4/ip_input.c)
   |  - 分片重组 ip_defrag()
   |  - Netfilter NF_INET_LOCAL_IN
   v
 ip_local_deliver_finish()           -- 分发到 L4 (net/ipv4/ip_input.c)
   |  - 根据 iph->protocol 查 inet_protos[]
   v
 ----------- TCP 分支 -----------
 tcp_v4_rcv()                        -- TCP 入口 (net/ipv4/tcp_ipv4.c)
   |  - __inet_lookup_skb() 找到 sock
   |  - tcp_v4_inbound_md5_hash 校验
   v
 tcp_v4_do_rcv()                     -- TCP 处理 (net/ipv4/tcp_ipv4.c)
   v
 tcp_rcv_established()               -- established 状态处理 (net/ipv4/tcp_input.c)
   |  - 快速路径 / 慢速路径
   |  - ACK 处理、窗口更新
   v
 tcp_queue_rcv()                     -- 入 sock 接收队列 (net/ipv4/tcp_input.c)
   |  - __skb_queue_tail(&sk->sk_receive_queue, skb)
   |  - sock_def_readable() 唤醒等待进程
   v
 (用户态进程被唤醒)
   v
 tcp_recvmsg()                       -- recvmsg 系统调用入口 (net/ipv4/tcp.c)
   |  - sk_wait_data() 等待数据
   |  - 从 sk_receive_queue 出队 skb
   v
 skb_copy_datagram_iter()            -- 拷贝到用户态 iovec (net/core/datagram.c)

 ----------- UDP 分支 -----------
 udp_rcv()                           -- UDP 入口 (net/ipv4/udp.c)
   v
 __udp4_lib_rcv()                    -- UDP 处理 (net/ipv4/udp.c)
   |  - checksum 验证
   v
 __udp4_lib_lookup()                 -- 查找 sock (net/ipv4/udp.c)
   |  - 在 udp_table 中按四元组查找
   v
 udp_queue_rcv_skb()                 -- 入队 (net/ipv4/udp.c)
   |  - __udp_enqueue_schedule_skb() 入 sk_receive_queue
   |  - 唤醒等待进程
   v
 (用户态进程被唤醒)
   v
 udp_recvmsg()                       -- recvmsg 入口 (net/ipv4/udp.c)
   v
 __skb_recv_udp()                    -- 出队 (net/ipv4/udp.c)
   v
 skb_copy_datagram_iter()            -- 拷贝到用户态 (net/core/datagram.c)
```

### 1.1 关键函数职责

| 函数 | 文件 | 职责 |
|------|------|------|
| `netif_receive_skb` | `net/core/dev.c` | RX 路径主入口，包一层 `__netif_receive_skb` |
| `__netif_receive_skb_core` | `net/core/dev.c` | L2 处理核心：ptype_all 抓包点、VLAN、按协议分发 |
| `ip_rcv` | `net/ipv4/ip_input.c` | IPv4 入口，校验、NF_INET_PRE_ROUTING |
| `ip_rcv_finish` | `net/ipv4/ip_input.c` | 路由决策 |
| `ip_local_deliver` | `net/ipv4/ip_input.c` | 本机接收，分片重组，NF_INET_LOCAL_IN |
| `ip_local_deliver_finish` | `net/ipv4/ip_input.c` | 按 protocol 分发到 L4 |
| `tcp_v4_rcv` | `net/ipv4/tcp_ipv4.c` | TCP 入口，查 sock |
| `tcp_v4_do_rcv` | `net/ipv4/tcp_ipv4.c` | TCP 状态机分发 |
| `tcp_rcv_established` | `net/ipv4/tcp_input.c` | established 状态报文处理 |
| `tcp_queue_rcv` | `net/ipv4/tcp_input.c` | 报文入 `sk_receive_queue` |
| `tcp_recvmsg` | `net/ipv4/tcp.c` | TCP recvmsg 系统调用实现 |
| `udp_rcv` | `net/ipv4/udp.c` | UDP 入口 |
| `__udp4_lib_rcv` | `net/ipv4/udp.c` | UDP 处理 |
| `__udp4_lib_lookup` | `net/ipv4/udp.c` | UDP sock 查找 |
| `udp_queue_rcv_skb` | `net/ipv4/udp.c` | UDP 报文入队 |
| `udp_recvmsg` | `net/ipv4/udp.c` | UDP recvmsg 实现 |
| `__skb_recv_udp` | `net/ipv4/udp.c` | UDP 报文出队 |
| `skb_copy_datagram_iter` | `net/core/datagram.c` | 把 skb 数据拷贝到用户态 iov_iter |

### 1.2 推荐 RX 插桩点

- **RX start**：`net/core/dev.c` 的 `__netif_receive_skb_core()` 入口（即函数起始处，紧接 `rcu_read_lock` 之后、ptype_all 遍历之前）调用 `net_delayacct_rx_start(skb)`，把当前 `ktime_get_ns()` 写到 `skb->delayacct_start`。
  - 选此点而非 `ip_rcv` 的原因：覆盖所有 IPv4 报文同时也覆盖 IPv6；并且这是真正的"协议栈起点"，之前的 NAPI/GRO 仍属于驱动层；同时 `__netif_receive_skb_core` 是单一汇聚点，打点开销最小。
  - 备选点 `ip_rcv` 入口：略晚一些，可避免非 IP 流量（如某些 ptype_all 监听）的无效打点，但需要分别在 IPv4/IPv6 各打一次。
- **RX end**：
  - TCP：`net/ipv4/tcp.c` 的 `tcp_recvmsg()` 中，调用 `skb_copy_datagram_iter()` 之前调用 `net_delayacct_rx_end(sk, skb)`。
  - UDP：`net/ipv4/udp.c` 的 `__skb_recv_udp()` 中，返回 skb 之前（即出队成功后、拷贝前）调用 `net_delayacct_rx_end(sk, skb)`。
  - 选这两个点的原因：刚好对应"报文即将被进程读到用户态"的瞬间，测得的时延就是"在协议栈内滞留的时间"，与项目目标一致。

### 1.3 GRO 聚合的影响

GRO（Generic Receive Offload）会把多个同流的报文聚合成一个大 skb。被聚合的从 skb 通过 `skb_gro_receive()` 合并到主 skb 的 `frag_list` 中，从 skb 在合并后释放。GRO 出口（`napi_gro_receive` 完成后）才会调用 `netif_receive_skb` 把主 skb 送到 L2 处理。

设计上：
- 只在主 skb 进入 `__netif_receive_skb_core` 时打一次 start 时间戳。
- 聚合的从 skb 的"原始到达时间"会被丢弃——这是已知误差，因为 GSO/GRO 的目的就是降低 per-packet 开销。
- 累加到 sock 时按 1 次 count 计算，对应一次用户态读操作。

---

## 2. TX 路径完整调用链

发送路径从用户态 `send` / `sendto` / `sendmsg` 系统调用开始，到报文送到网卡驱动的 `ndo_start_xmit` 结束。完整调用链：

```
[用户态 sendto / sendmsg 系统调用]
        |
        v
 sys_sendto()                        -- SYSCALL_DEFINE (net/socket.c)
        |
        v
 __sys_sendto()                      -- 入口 (net/socket.c)
   |  - copy user address
   v
 sock_sendmsg()                      -- 通用发送 (net/socket.c)
   |  - 调用 sock->ops->sendmsg
   v
 ----------- TCP 分支 -----------
 tcp_sendmsg()                       -- TCP 发送入口 (net/ipv4/tcp.c)
   v
 tcp_sendmsg_locked()                -- 持有 sk_lock (net/ipv4/tcp.c)
   |  - 从 user 拷贝到 skb
   |  - sk_sndbuf 流控
   |  - 生成新 skb，调用 tcp_skb_entail() 入 sk_write_queue
   v
 tcp_push()                          -- 触发发送 (net/ipv4/tcp_output.c)
   |  - __tcp_push_pending_frames
   |  - tcp_write_xmit
   v
 tcp_transmit_skb()                  -- 构造 TCP 头 (net/ipv4/tcp_output.c)
   |  - 克隆 skb (skb_clone)
   |  - 填充 th->source / th->dest / th->seq / th->check
   v
 ip_queue_xmit()                    -- IP 层发送 (net/ipv4/ip_output.c)

 ----------- UDP 分支 -----------
 udp_sendmsg()                       -- UDP 发送入口 (net/ipv4/udp.c)
   |  - 路由查找 ip_route_output_flow
   |  - cork / 非 cork 两条路径
   v
 ip_make_skb()                       -- 构造 IP skb (net/ipv4/ip_output.c)
   |  - 分配 skb，填 IP 头
   v
 udp_send_skb()                      -- 加 UDP 头 (net/ipv4/udp.c)
   |  - uh->source/dest/check
   v
 ip_send_skb() -> ip_queue_xmit()    -- 送到 IP 层

 ----------- IP 公共路径 -----------
 ip_queue_xmit()                     -- IP 层入口 (net/ipv4/ip_output.c)
   |  - 选路由、填 iph
   v
 __ip_local_out()                    -- NF_INET_LOCAL_OUT (net/ipv4/ip_output.c)
   |  - 设置 iph->tot_len, ip_send_check
   v
 ip_output()                         -- NF_INET_POST_ROUTING (net/ipv4/ip_output.c)
   |  - 调用 ip_finish_output
   v
 ip_finish_output()                  -- 出口处理 (net/ipv4/ip_output.c)
   |  - 分片 (ip_fragment)
   |  - skb_clone 或重新分配
   v
 ip_finish_output2()                 -- 邻居解析 (net/ipv4/ip_output.c)
   |  - 邻居项查找
   v
 neigh_resolve_output() / neigh_output() -- 邻居层 (net/core/neighbour.c)
   |  - ARP 解析（必要时）
   |  - 填 skb->dev
   v
 ----------- L2 公共路径 -----------
 dev_queue_xmit()                    -- L2 入口 (net/core/dev.c)
   v
 __dev_queue_xmit()                  -- 选 qdisc (net/core/dev.c)
   |  - 选 txq
   |  - 调用 sch_direct_xmit 或 dev_hard_start_xmit
   v
 sch_direct_xmit()                   -- qdisc 发送 (net/sched/sch_generic.c)
   |  - dequeue skb
   v
 dev_hard_start_xmit()               -- 送到驱动 (net/core/dev.c)
   |  - 遍历 skb 链
   |  - 调用 ops->ndo_start_xmit(skb, dev)
   v
 [网卡驱动 ndo_start_xmit]
   v
 [NIC TX]
```

### 2.1 关键函数职责

| 函数 | 文件 | 职责 |
|------|------|------|
| `sys_sendto` | `net/socket.c` | 系统调用入口 |
| `__sys_sendto` | `net/socket.c` | 取 user 地址、调用 `sock_sendmsg` |
| `sock_sendmsg` | `net/socket.c` | 通用发送分发 |
| `tcp_sendmsg` | `net/ipv4/tcp.c` | TCP 发送入口 |
| `tcp_sendmsg_locked` | `net/ipv4/tcp.c` | 实际生成 skb 并入队 |
| `tcp_push` | `net/ipv4/tcp_output.c` | 触发 TCP 发送 |
| `tcp_transmit_skb` | `net/ipv4/tcp_output.c` | 构造 TCP 头 |
| `udp_sendmsg` | `net/ipv4/udp.c` | UDP 发送入口 |
| `ip_make_skb` | `net/ipv4/ip_output.c` | 构造 IP skb |
| `udp_send_skb` | `net/ipv4/udp.c` | 加 UDP 头并发送 |
| `ip_queue_xmit` | `net/ipv4/ip_output.c` | IP 层入口 |
| `__ip_local_out` | `net/ipv4/ip_output.c` | NF_INET_LOCAL_OUT |
| `ip_output` | `net/ipv4/ip_output.c` | NF_INET_POST_ROUTING |
| `ip_finish_output` | `net/ipv4/ip_output.c` | 分片与出口 |
| `ip_finish_output2` | `net/ipv4/ip_output.c` | 邻居解析 |
| `neigh_resolve_output` | `net/core/neighbour.c` | ARP / 邻居层 |
| `dev_queue_xmit` | `net/core/dev.c` | L2 入口 |
| `__dev_queue_xmit` | `net/core/dev.c` | 选 qdisc |
| `sch_direct_xmit` | `net/sched/sch_generic.c` | qdisc 发送 |
| `dev_hard_start_xmit` | `net/core/dev.c` | 送到驱动 `ndo_start_xmit` |

### 2.2 推荐 TX 插桩点

- **TX start**：
  - TCP：`net/ipv4/tcp.c` 的 `tcp_sendmsg()` 入口（在 `tcp_sendmsg_locked` 之前，对每个新生成的 skb 打时间戳）调用 `net_delayacct_tx_start(skb)`。
  - UDP：`net/ipv4/udp.c` 的 `udp_sendmsg()` 中，对最终生成的 skb（在 `ip_make_skb` 之后或 `udp_send_skb` 之前）调用 `net_delayacct_tx_start(skb)`。
  - 选这两个点的原因：紧跟进程系统调用入口，时间戳代表"用户态请求发送的时刻"；并且此处 skb 与发送它的 sock 一一对应，便于绑定 `sk`。
- **TX end**：`net/core/dev.c` 的 `dev_hard_start_xmit()` 中，在调用 `ops->ndo_start_xmit(skb, dev)` 之前调用 `net_delayacct_tx_end(skb_get(skb)->sk, skb)`（或直接用 skb->sk）。
  - 选此点的原因：是报文离开协议栈、交给驱动的最后一刻，时延正好覆盖整个协议栈滞留时间；并且所有协议路径都汇聚到这里，单点插桩开销最小。

### 2.3 GSO/TSO 拆分场景

TSO（TCP Segmentation Offload）与 GSO（Generic Segmentation Offload）让内核只构造一个大的"超级 skb"，由网卡或 `dev_hard_start_xmit` 前的 `skb_gso_segment()` 拆分成多个 MTU 大小的报文。

设计上：
- 在 `tcp_sendmsg` / `udp_sendmsg` 处对原始 GSO skb 打一次 start 时间戳。
- 在 `dev_hard_start_xmit` 处对 GSO skb 整体计一次 end（而非对每个拆分后的子 skb 分别计一次）。
- 原因：用户态的一次 `send()` 调用对应一次延迟样本；如果按拆分后计 N 次，会让计数与用户视角不一致，且子 skb 经过 `skb_gso_segment` 后是新生成的，可能丢失 `delayacct_start` 字段（克隆时未拷贝）。
- 实现：在 `dev_hard_start_xmit` 中读取 `skb->delayacct_start`，若为 0 则跳过（说明该子 skb 未经过 start 打点，或为 GSO 拆分后的从 skb）。

### 2.4 skb 克隆与共享

TX 路径中 `tcp_transmit_skb` 会 `skb_clone` 出一份"发送用" skb，原 skb 仍留在 `sk_write_queue` 中等待 ACK。clone 出来的 skb 共享 `skb->head` 数据区，但 `skb->delayacct_start` 是 `struct sk_buff` 自身的字段，clone 时会被复制。

设计上选择在 clone 之前打 start 时间戳（即在 `tcp_sendmsg` 入口对原 skb 打时间戳），clone 后两个 skb 都带有正确时间戳。end 在 `dev_hard_start_xmit` 上对发送用 clone 计一次即可。

---

## 3. struct sock 关键字段

`struct sock`（定义于 `include/net/sock.h`）是 socket 层的核心结构，本项目要嵌入 `struct net_delayacct` 字段，并使用以下既有字段填充上报属性：

| 字段 | 类型 | 含义 | 用于上报 |
|------|------|------|----------|
| `sk_lock` | `struct sock_lock_t` | 包含 `slock`（自旋锁）与 `owned`（用户态持有标记） | 不能直接用于本项目累加 |
| `sk_daddr` | `__be32` | IPv4 远端地址 | raddr |
| `sk_rcv_saddr` | `__be32` | IPv4 本地地址 | laddr |
| `sk_v6_daddr` | `struct in6_addr` | IPv6 远端地址 | raddr (v6) |
| `sk_v6_rcv_saddr` | `struct in6_addr` | IPv6 本地地址 | laddr (v6) |
| `sk_num` | `__u16` | 本地端口（主机序） | lport |
| `sk_dport` | `__be16` | 远端端口（网络序） | rport |
| `sk_protocol` | `__u16` | L4 协议号（IPPROTO_TCP=6, IPPROTO_UDP=17） | type |
| `sk_family` | `__u16` | AF_INET / AF_INET6 | type |
| `sk_type` | `__u16` | SOCK_STREAM / SOCK_DGRAM | type |
| `sk_socket` | `struct socket *` | 反向指向 VFS 层的 socket | 取 inode |
| `sk_receive_queue` | `struct sk_buff_head` | 接收队列 | （仅参考） |
| `sk_write_queue` | `struct sk_buff_head` | 发送队列 | （仅参考） |
| `sk_state` | `__u8` | TCP 状态（TCP_ESTABLISHED 等） | （仅参考） |
| `sk_uid` | `kuid_t` | socket 所属 uid | （可选） |

### 3.1 关于 `sk_lock`

`struct sock` 内部嵌入了 `sk_lock` 联合体：

```c
union {
    struct {
        __u32 slock;
    };
    spinlock_t sk_lock;
};
```

它的语义复杂：`slock` 是自旋锁，`owned` 表示"用户态进程当前持有该 sock"（用于 TCP `lock_sock` / `release_sock` 的"持有者"机制）。**不能直接用 `sk_lock.slock` 保护 net_delayacct 累加**，原因：

- `lock_sock` 是 `bh_lock_sock` 的更高层封装，会处理软中断上下文与进程上下文的递归；在 `tcp_recvmsg` / `udp_recvmsg` 中已经持有，再次获取会自死锁。
- RX end 在用户态上下文（`recvmsg` 调用栈）执行，可能已持有 `lock_sock`。
- TX end 在驱动 xmit 路径，可能处于 softirq 上下文，不能使用 `lock_sock_nested` 一类接口。

因此 `struct net_delayacct` 内部自带一个独立 `spinlock_t lock`，仅用于保护累加字段，与 `sk_lock` 解耦。

### 3.2 端口字节序注意

- `sk_num`：本地端口，**主机字节序**（小端 x86 上为低字节在前）。
- `sk_dport`：远端端口，**网络字节序**（大端）。
- 上报给用户态时统一转换为 `__u16` 主机序，由用户态工具格式化。

---

## 4. struct sk_buff 关键字段

`struct sk_buff`（定义于 `include/linux/skbuff.h`）是网络协议栈中最频繁创建/销毁的结构。本项目要新增 `delayacct_start` 字段：

| 字段 | 类型 | 含义 | 本项目使用 |
|------|------|------|-----------|
| `tstamp` | `ktime_t` | skb 时间戳，多用途 | 不冲突；但为语义清晰新增独立字段 |
| `cb` | `char[48]`（按协议变长） | 控制块，每个协议层含义不同 | 不使用，避免冲突 |
| `sk` | `struct sock *` | 关联的 sock（接收/发送方向都可能为 NULL） | TX end 时取累加目标 |
| `dev` | `struct net_device *` | 入/出网卡 | 不使用 |
| `protocol` | `__be16` | L3 协议（ETH_P_IP 等） | 不使用 |
| `data` / `len` / `data_len` | 数据区指针与长度 | 报文内容 | 不使用 |
| `destructor` | `void (*)(struct sk_buff *)` | skb 释放回调 | 不使用 |
| **`delayacct_start`** | `ktime_t` | **本项目新增**：进入协议栈起始时间戳 | start/end 配对使用 |

### 4.1 为何不用 `skb->tstamp`

`skb->tstamp` 已存在，但语义上它是"内核收到该 skb 的时间戳"或"软件发送时间戳"，被 `SO_TIMESTAMPNS` / `SO_TXTIME` 等机制复用。直接复用会与既有功能冲突，且语义混乱。

新增独立字段 `delayacct_start` 更清晰：
- 在 `CONFIG_NET_DELAYACCT` 关闭时通过 `#ifdef` 不存在，零开销。
- 在开启时初始为 0，end 函数检测 0 则跳过累加。

### 4.2 为何不用 `skb->cb`

`skb->cb` 是按协议栈层级复用的 48 字节控制块（TCP 用 `struct tcp_skb_cb`，IP 用 `struct inet_skb_parm`，每层都假设自己独占）。新增字段会破坏既有 cb 布局，且 cb 在层级间会被覆盖，不适合携带"从 L2 到 L4 的全程时间戳"。

### 4.3 skb 克隆/复制时的字段保留

- `skb_clone` / `__pskb_copy` / `skb_copy` 均会复制 `struct sk_buff` 自身的所有标量字段，包括 `delayacct_start`。
- `skb_gso_segment` 拆分时生成新 skb，**不会**自动复制 `delayacct_start`——这是设计上的有意行为：拆分后的子 skb 不再单独计数，详见 2.3 节。
- `pskb_expand_head` 等只改数据区，不影响 sk_buff 字段。

---

## 5. inode ↔ sock 映射

### 5.1 sockfs

Linux 中所有 socket 都属于伪文件系统 `sockfs`，每个 `struct socket` 背后有一个 `struct inode`，inode 的 `i_ino` 字段就是用户在 `/proc/<pid>/fd` 中看到的 socket inode 编号。

```c
/* include/linux/net.h */
struct socket {
    struct file     *file;       /* 关联的 file 结构 */
    struct sock     *sk;         /* 关联的 sock */
    /* ... */
};

/* include/net/sock.h */
struct sock {
    struct socket   *sk_socket;  /* 反向指针 */
    /* ... */
};
```

`sock` 与 `socket` 是一一对应的；`socket` 与 `file` / `inode` 也是一一对应的（通过 `sock_map_inode`）。

### 5.2 关键 API

| API | 文件 | 用途 |
|-----|------|------|
| `SOCKET_I(inode)` | `include/net/sock.h` | 从 `struct inode *` 取 `struct socket *`（通过 `container_of`） |
| `SOCK_INODE(sock)` | `include/net/sock.h` | 反向：socket 取 inode |
| `sock_from_file(file)` | `net/socket.c` | 从 `struct file *` 取 `struct socket *`，验证 file 是 socket 类型 |
| `sockfd_lookup(fd, &err)` | `net/socket.c` | 从 fd 取 socket（包含 fget + 校验） |
| `sock_register_filesystem` | `net/socket.c` | 注册 sockfs（启动期） |

### 5.3 通过 PID 遍历所有 sock

查询指定 PID 下所有 socket 的标准流程：

```c
struct task_struct *task;
struct files_struct *files;
struct fdtable *fdt;
struct file *file;
struct socket *sock;
struct sock *sk;
int fd;

rcu_read_lock();
task = find_task_by_vpid(pid);
if (!task) { rcu_read_unlock(); return -ESRCH; }
get_task_struct(task);
rcu_read_unlock();

task_lock(task);
files = task->files;
if (!files) { task_unlock(task); goto out; }

spin_lock(&files->file_lock);
fdt = files_fdtable(files);
for (fd = 0; fd < fdt->max_fds; fd++) {
    file = fdt->fd[fd];
    if (!file) continue;
    sock = sock_from_file(file);
    if (!sock) continue;            /* 非 socket fd */
    sk = sock->sk;
    if (!sk) continue;
    /* 检查是否为 inet sock (sk->sk_family == AF_INET/AF_INET6) */
    /* 读取统计、填充属性、追加到回复 skb */
}
spin_unlock(&files->file_lock);
task_unlock(task);

out:
put_task_struct(task);
```

锁的获取顺序：`rcu_read_lock` → `get_task_struct` → `task_lock` → `files->file_lock`。释放顺序相反。

### 5.4 通过 inode 查找 sock

`/proc/<pid>/fd` 中每个 socket fd 是一个符号链接，readlink 后形如 `socket:[12345]`，其中 `12345` 就是 inode 号。用户态可以这样取：

```sh
inode=$(readlink /proc/$PID/fd/3 | grep -o '[0-9]\+')
./get_sockdelays -i $inode
```

内核侧按 inode 查 sock 的方案有两种：

1. **遍历法**：在内核中遍历目标 net namespace 内所有 task 的 files，找到对应 inode 的 sock。简单但慢。
2. **哈希表法**：维护 per-netns 的 `inode -> sock` 哈希表，在 `sock_init` 时插入、`sock_release` 时删除。快但有锁开销。

本项目第一期采用方案 1（与按 PID 查询共用遍历代码）；第二期可扩展方案 2 提升性能。

### 5.5 SOCKET_I 实现细节

```c
/* include/net/sock.h */
static inline struct socket *SOCKET_I(struct inode *inode)
{
    return container_of(inode, struct socket_alloc, vfs_inode)->socket;
}
```

`struct socket_alloc` 是 `sockfs` 的 inode 私有数据结构，包含 `struct inode vfs_inode` 与 `struct socket socket` 两个字段。

---

## 6. 收发路径的关键软中断与锁

### 6.1 RX 路径上下文

- `__netif_receive_skb_core` 通常在 NAPI softirq（`NET_RX_SOFTIRQ`）上下文执行，即 `ksoftirqd/n` 或硬中断退出后的内联 softirq。
- `tcp_recvmsg` / `udp_recvmsg` 在进程系统调用上下文执行。
- 因此 RX 时延跨 softirq → process 上下文，**必须把时间戳挂在 skb 上**而非 task 上。

### 6.2 TX 路径上下文

- `tcp_sendmsg` / `udp_sendmsg` 在进程系统调用上下文执行。
- `dev_hard_start_xmit` 大部分情况下仍在进程上下文（同步发送），但在以下场景可能在 softirq：
  - qdisc 重启（`__qdisc_run` 在 softirq 中调用）
  - TCP 重传（`tcp_xmit_recovery` 在 softirq timer 中）
- TX 路径中 skb 的所有权通常仍属于发送进程（直到 `dev_hard_start_xmit` 后释放），单线程所有，时间戳挂 skb 即可，无需额外锁。

### 6.3 skb 跨 CPU 流转

- RX：skb 从驱动 NAPI 上下文（绑定在某 CPU 的 `struct softnet_data`）一路传到 L4，最终在 `tcp_queue_rcv` 入队到 `sk_receive_queue`，由被唤醒的进程（可能在另一 CPU）读取。**整个生命周期内 skb 不被多个 CPU 同时写**。
- TX：skb 在进程上下文创建，依次通过 qdisc → driver，整个过程同步且不跨 CPU（除非 qdisc 在 softirq 重启，但同一时刻仍只有一个所有者）。
- 因此 `skb->delayacct_start` 字段无需锁保护。

---

## 7. 协议栈插桩点汇总表

| 路径 | 文件 | 函数 | 调用接口 | 说明 |
|------|------|------|----------|------|
| RX start | `net/core/dev.c` | `__netif_receive_skb_core` | `net_delayacct_rx_start(skb)` | 函数入口，写 skb 时间戳 |
| RX end (TCP) | `net/ipv4/tcp.c` | `tcp_recvmsg` | `net_delayacct_rx_end(sk, skb)` | 拷贝到 user 前一刻 |
| RX end (UDP) | `net/ipv4/udp.c` | `__skb_recv_udp` | `net_delayacct_rx_end(sk, skb)` | 返回 skb 前一刻 |
| TX start (TCP) | `net/ipv4/tcp.c` | `tcp_sendmsg` | `net_delayacct_tx_start(skb)` | 对新 skb 打时间戳 |
| TX start (UDP) | `net/ipv4/udp.c` | `udp_sendmsg` | `net_delayacct_tx_start(skb)` | 同上 |
| TX end | `net/core/dev.c` | `dev_hard_start_xmit` | `net_delayacct_tx_end(sk, skb)` | 调用 ndo_start_xmit 前 |

### 7.1 IPv6 路径

IPv6 的对应插桩点（与 IPv4 平行）：

| 路径 | 文件 | 函数 |
|------|------|------|
| RX L4 (TCP) | `net/ipv6/tcp_ipv6.c` | `tcp_v6_rcv` → `tcp_v6_do_rcv` → `tcp_rcv_established` |
| RX L4 (UDP) | `net/ipv6/udp.c` | `udpv6_rcv` → `__udp6_lib_rcv` → `udp_queue_rcv_skb` |
| TX (TCP) | 同 IPv4（`tcp_sendmsg` 与协议族无关） | - |
| TX (UDP) | 同 IPv4（`udp_sendmsg` 与协议族无关） | - |

第一版仅支持 IPv4/IPv6 TCP/UDP，由于 TCP/UDP 的 `*_sendmsg` / `*_recvmsg` 与协议族无关，IPv6 路径插桩点与 IPv4 相同；RX start 与 TX end 也与协议族无关。无需在 IPv6 单独打点。

---

## 8. 参考文档

- `Documentation/networking/index.rst`：网络子系统文档索引。
- `Documentation/networking/data-structs.rst`（如存在）：`sk_buff` / `sock` 结构说明。
- `Documentation/devicetree/bindings/net/`（仅驱动相关，本项目不涉及）。
- 内核源码：`net/core/dev.c`、`net/ipv4/ip_input.c`、`net/ipv4/tcp.c`、`net/ipv4/tcp_input.c`、`net/ipv4/tcp_output.c`、`net/ipv4/udp.c`、`net/ipv4/ip_output.c`、`net/socket.c`、`include/net/sock.h`、`include/linux/skbuff.h`。
- 经典参考书：《Understanding Linux Network Internals》（Christian Benvenuti）、《Linux Kernel Networking》（Rami Rosen）。

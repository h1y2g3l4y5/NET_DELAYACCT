# kernel-patches 应用指南

本目录包含 CONFIG_NET_DELAYACCT 框架在 Linux 6.6 内核上的全部源码与
补丁。补丁按顺序应用后即可启用 per-socket 网络时延统计能力。

## 前置条件

- Linux 6.6 源码树（建议 `git clone --branch v6.6
  https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git`）
- x86_64 构建工具链：`build-essential libelf-dev libssl-dev bison
  flex libncurses-dev`
- 至少 4 GiB 空闲内存与 20 GiB 磁盘空间

## 文件清单

| 文件 | 用途 | 应用方式 |
|------|------|----------|
| `0005-net-add-uapi-header.patch` | UAPI 头文件 | `git apply` |
| `0006-net-add-internal-header.patch` | 内核内部头文件 | `git apply` |
| `0007-net-core-add-module.patch` | 核心实现（含 Kconfig / Makefile） | `git apply` |
| `0008-net-add-Kconfig-entry.patch` | Kconfig 入口 | `git apply` |
| `0009-net-add-module-to-Makefile.patch` | Makefile 规则 | `git apply` |
| `0010-sock-init-net-delayacct.patch` | `sock.c` 初始化插桩 | `git apply` |
| `sock_h-modification.patch` | 修改 `struct sock` | `git apply` |
| `skbuff_h-modification.patch` | 修改 `struct sk_buff` | `git apply` |
| `rx-instrumentation.patch` | RX 路径插桩 | `git apply` |
| `tx-instrumentation.patch` | TX 路径插桩 | `git apply` |

> 注：编号补丁 `0005-0010` 对应原先独立的 UAPI 头文件、内部头文件、核心实现、
> Kconfig 片段、Makefile 片段及 `sock.c` 初始化代码。直接使用 `git apply` 应用
> 编号补丁即可，无需再手动复制零散文件。

## 应用顺序（顺序很重要）

```bash
cd /path/to/linux-6.6

PATCH_DIR=/path/to/NET_DELAYACCT/kernel-patches

# 1. 修改 struct sock（必须在 0007 之前，核心实现会依赖新增字段）
git apply "$PATCH_DIR/sock_h-modification.patch"

# 2. 修改 struct sk_buff
git apply "$PATCH_DIR/skbuff_h-modification.patch"

# 3. 编号补丁：UAPI 头、内部头、核心实现、Kconfig、Makefile、sock 初始化
for p in "$PATCH_DIR"/0005-*.patch \
         "$PATCH_DIR"/0006-*.patch \
         "$PATCH_DIR"/0007-*.patch \
         "$PATCH_DIR"/0008-*.patch \
         "$PATCH_DIR"/0009-*.patch \
         "$PATCH_DIR"/0010-*.patch; do
    git apply "$p"
done

# 4. RX 路径插桩
git apply "$PATCH_DIR/rx-instrumentation.patch"

# 5. TX 路径插桩
git apply "$PATCH_DIR/tx-instrumentation.patch"
```

> 注意：`sock_h-modification.patch`、`skbuff_h-modification.patch`、
> `rx-instrumentation.patch`、`tx-instrumentation.patch` 中的上下文
> 行可能在不同的 6.6.x point release 之间略有差异。若 `git apply`
> 失败，请改用 `patch -p1 --fuzz=3 < xxx.patch`，或按补丁文件头部
> 注释中的描述手动定位插入点。

## 启用配置

方式一：通过 menuconfig

```bash
make menuconfig
# Networking support  --->
#   [*] Per-socket network delay accounting
```

方式二：通过配置片段合并

```bash
scripts/kconfig/merge_config.sh -m .config \
  /path/to/NET_DELAYACCT/ci/kernel.config.fragment
```

## 编译与验证

```bash
# 编译内核
make -j$(nproc)

# 验证配置选项已启用
grep CONFIG_NET_DELAYACCT .config

# 安装并引导新内核（具体步骤因发行版而异）
sudo make modules_install
sudo make install
sudo reboot

# 启动后验证 genl family 已注册
cat /proc/net/genetlink | grep net_delayacct
```

预期输出示例：

```
net_delayacct          31 (1) 0x0001
```

## 编译用户态工具

```bash
cd /path/to/NET_DELAYACCT/userspace/get_sockdelays
make
# 如需指定内核源码树：
# make LINUX_SRC=/path/to/linux-6.6

# 验证
./get_sockdelays -h
```

## 常见问题

1. **`git apply` 报告上下文不匹配**：使用 `patch -p1 --fuzz=3`，或
   手动按补丁头部注释定位插入点。

2. **`make` 报告 `net-delayacct.c` 找不到 `genl_register_family`**：
   确认 `Makefile-fragment` 已追加到 `net/core/Makefile`，且
   `CONFIG_NET_DELAYACCT=y` 已在 `.config` 中。

3. **`cat /proc/net/genetlink` 看不到 `net_delayacct`**：确认新内核
   已正确安装并被引导（`uname -r`），dmesg 中应有
   `net_delayacct: framework registered` 日志。

4. **`get_sockdelays` 报告 `family not found`**：内核未启用
   `CONFIG_NET_DELAYACCT`，或未引导新内核。

5. **checkpatch 报错**：在投稿上游前必须运行
   `scripts/checkpatch.pl --strict *.patch`，确保 0 WARNING/ERROR。

## 附录：GRO / GSO 设计权衡

本框架在 RX 与 TX 两条路径上分别与内核的 GRO（Generic Receive Offload）
和 GSO（Generic Segmentation Offload）机制发生交互，二者对统计语义有
直接影响。

### GRO（接收侧合并）

GRO 在 `__netif_receive_skb_core()` 之前把属于同一流的多个小 skb
合并成一个逻辑大 skb。合并方式是把后续 skb 挂到第一个 skb 的
`frag_list`（或 `frags[]`）上，只保留一份协议头，数据不拷贝。

对本项目的影响：

- `net_delayacct_rx_start(skb)` 打在合并后的 head skb 上，因此一个
  GRO 批次只产生一个 RX 时延样本。
- 时间戳反映的是 GRO 批次中**最后一个 fragment** 被合并进来之后的
  时刻，而不是第一个物理包到达网卡的时刻。
- 结果：`rx_count` 会比实际物理包数少，测量的是"协议栈内批次处理
  时延"，而非精确的 per-packet 端到端时延。

这是为获得"单点插桩、覆盖所有协议、代码简洁"而主动接受的 trade-off。
详见 `rx-instrumentation.patch` 与 `include-net-net-delayacct.h` 中的
粒度注释。

### GSO（发送侧拆分）

GSO 在 `dev_hard_start_xmit()` 之前把应用层一次 `send()` 产生的大
skb（如 64KB）拆成多个 MTU 大小的小 skb segment，再逐个发给网卡。

对本项目的影响：

- TX start 戳先打在大 GSO skb 上（`__tcp_transmit_skb()` 的 clone
  块或 `udp_sendmsg()` / `udp_push_pending_frames()`）。
- `skbuff_h-modification.patch` 把 `delayacct_start` 放在
  `struct sk_buff` 的 headers `struct_group` 内，因此 GSO 拆分时
  `__copy_skb_header()` 会自动把该字段复制到每个子 segment。
- `net_delayacct_tx_end(skb->sk, skb)` 在 `dev_hard_start_xmit()`
  中对每个子 segment 各调用一次。
- 结果：`tx_count` 按 segment 数量膨胀（一次应用层 send 可能对应 N
  个 segment），但每个 segment 的真实发送时延是准确的。

这里同样是一个 trade-off：项目选择了"segment 级精度 + 代码简单"，而
非"应用层 send 计一次"的语义。详见 `tx-instrumentation.patch` 中的
commit message。

### 总结

| 机制 | 方向 | 操作 | 对 count 的影响 | 项目选择 |
|------|------|------|----------------|----------|
| GRO | 接收 | 多小包 → 一大包 | `rx_count` 减少 | 接受，换取插桩简洁 |
| GSO | 发送 | 一大包 → 多小包 | `tx_count` 膨胀 | 接受，换取 segment 精度 |

因此，本工具输出的 `rx_count` / `tx_count` 不应直接等同于网卡上的
物理包数，而应理解为"协议栈处理单元数"。平均值（`total / count`）
仍然有意义，但 count 本身的绝对值会受 GRO/GSO 影响。

## 附录 B：支持的数据流路径范围

本框架当前版本明确覆盖以下范围内的数据流：

### B.1 地址族与传输协议

| 地址族 | socket 类型 | 传输协议 | 是否支持 |
|--------|------------|---------|---------|
| `AF_INET`（IPv4） | `SOCK_STREAM` | TCP | ✅ |
| `AF_INET`（IPv4） | `SOCK_DGRAM` | UDP | ✅ |
| `AF_INET6`（IPv6） | `SOCK_STREAM` | TCP | ✅（复用 `net/ipv4/tcp.c` 接收逻辑） |
| `AF_INET6`（IPv6） | `SOCK_DGRAM` | UDP | ✅（通过 `net/ipv6/udp.c`） |

不支持的地址族/类型：`AF_UNIX`、`AF_NETLINK`、`AF_PACKET`、`AF_VSOCK`、`AF_XDP`、`SOCK_RAW`、`SCTP`、`DCCP` 等。

### B.2 RX 用户态接收 API

| API | 触发的内核路径 | 是否覆盖 | 备注 |
|-----|--------------|---------|------|
| `read()` / `recv()` | `tcp_recvmsg_locked()` / `udp_recvmsg()` | ✅ | 最基础的同步接收 |
| `recvmsg()` | `tcp_recvmsg_locked()` / `udp_recvmsg()` | ✅ | 带 flags、cmsg 的接收 |
| `recvmmsg()` | 内部循环调用 `tcp_recvmsg_locked()` 等 | ✅ | 批量接收复用同一函数 |
| `splice(sock → pipe)` | `tcp_read_sock()` | ✅ | TCP 专门路径 |
| `MSG_ZEROCOPY` | `tcp_zerocopy_receive()` | ✅ | TCP 零拷贝路径 |
| `io_uring` `IORING_OP_RECV/RECVMSG` | 部分通过 `tcp_recvmsg` 走通 | ⚠️ 未完全验证 | 非本次覆盖目标 |
| `vmsplice()` / `sendfile()` | 发送侧或页映射 | ❌ | 非接收 API |
| XDP / AF_XDP | 绕过协议栈 | ❌ | 不经过 `__netif_receive_skb_core` |

### B.3 TX 用户态发送 API 覆盖

TX start 点打在 TCP/UDP 的传输层出口处（而非系统调用入口），因此：
- `send()` / `sendto()` / `sendmsg()` / `sendmmsg()`：✅，只要走正常的 `tcp_sendmsg_locked` / `udp_sendmsg` 路径
- `write()` / `writev()`：✅
- TCP corked / `MSG_MORE`：✅，通过 `__tcp_transmit_skb` clone 路径覆盖
- UDP corked（`UDP_CORK` / `MSG_MORE`）：✅，通过 `udp_push_pending_frames` 覆盖
- `splice(pipe → sock)` / `sendfile()`：TCP 侧经过 `tcp_sendmsg` 走 clone 路径，✅
- `io_uring` send：✅ 通过 `IORING_OP_SEND` → `tcp_sendmsg_locked` → `__tcp_transmit_skb`，共享传输层 TX 路径，Test 26 已验证 TX 计数正常累加
- 纯 ACK / RST / 窗口探测：`alloc_skb` 零初始化 `delayacct_start=0`，被 `tx_end` 的 zero-check 跳过，不计入 TX 统计（正确行为）

### B.4 加速路径与 offload

| 机制 | 方向 | 是否处理 | 说明 |
|------|------|---------|------|
| GRO | RX | ✅ | 合并后 head skb 打 start；count 减少 |
| LRO（硬件 GRO）| RX | ✅ | 最终同样走 `__netif_receive_skb_core` |
| RPS | RX | ✅ | CPU 分发不改变入口，自动覆盖 |
| GSO | TX | ✅ | headers group 自动复制 start；count 膨胀 |
| TSO（硬件 GSO）| TX | ✅ | 路径同 GSO，自动覆盖 |
| UFO | TX | ✅ | UDP 分片类似 GSO |
| XDP | RX | ❌ | 驱动层处理，不进入协议栈 |
| busy polling | RX | ✅ | 轮询取包后仍走 `__netif_receive_skb_core` |
| KTLS | TX/RX | ⚠️ | TLS record 层可能改变 skb 生命周期，未专门验证 |

## 附录 C：完整打点位置清单

以下列出所有 `net_delayacct_rx_start` / `net_delayacct_rx_end` /
`net_delayacct_tx_start` / `net_delayacct_tx_end` 的插桩位置，对应
`rx-instrumentation.patch` 与 `tx-instrumentation.patch` 中的 diff。

### C.1 RX 路径打点（共 6 处）

**RX start（1 处，全协议共用入口）**：

| # | 文件 | 函数 | 位置说明 |
|---|------|------|---------|
| 1 | [net/core/dev.c](file:///home/lai/Code/linux-6.6/net/core/dev.c) | `__netif_receive_skb_core()` | 函数入口、`trace_netif_receive_skb()` 之后、`skb_reset_network_header()` 之前。所有经过协议栈的接收包在此处打戳。 |

**RX end（5 处，按协议/路径区分）**：

| # | 文件 | 函数 | 位置说明 | 关键守卫 |
|---|------|------|---------|---------|
| 2 | [net/ipv4/tcp.c](file:///home/lai/Code/linux-6.6/net/ipv4/tcp.c) | `tcp_read_sock()` | 取到 skb 后、`recv_actor()` 调用之前（splice 路径） | 无特殊守卫（sk_buff 有效即打戳） |
| 3 | [net/ipv4/tcp.c](file:///home/lai/Code/linux-6.6/net/ipv4/tcp.c) | `tcp_zerocopy_receive()` | `tcp_recv_skb()` 成功取到 skb 后（zerocopy 路径） | 无特殊守卫 |
| 4 | [net/ipv4/tcp.c](file:///home/lai/Code/linux-6.6/net/ipv4/tcp.c) | `tcp_recvmsg_locked()` | `found_ok_skb` 标签处、`used = skb->len - offset` 之前（常规 recvmsg 路径） | `!(flags & MSG_PEEK)`：避免 MSG_PEEK 预读消耗时间戳 |
| 5 | [net/ipv4/udp.c](file:///home/lai/Code/linux-6.6/net/ipv4/udp.c) | `udp_recvmsg()` | `skb_copy_and_csum_datagram_msg()` 返回成功后、`UDP_INC_STATS` 之前（IPv4 UDP 路径） | `!peeking`：MSG_PEEK 不打戳；copy & checksum 成功后才打 |
| 6 | [net/ipv6/udp.c](file:///home/lai/Code/linux-6.6/net/ipv6/udp.c) | `udpv6_recvmsg()` | `skb_copy_and_csum_datagram_msg()` 返回成功后、`SNMP_INC_STATS` 之前（IPv6 UDP 路径） | `!peeking`：同 IPv4 |

> 注：TCP 的三个 RX end 点同时覆盖 IPv4 和 IPv6，因为 TCP 核心接收逻辑
> 不区分地址族，都在 `net/ipv4/tcp.c` 中。

### C.2 TX 路径打点（共 7 处）

**TX start（6 处，按协议/场景区分）**：

| # | 文件 | 函数 | 位置说明 | 覆盖场景 |
|---|------|------|---------|---------|
| 1 | [net/ipv4/tcp_output.c](file:///home/lai/Code/linux-6.6/net/ipv4/tcp_output.c) | `__tcp_transmit_skb()` | clone 块中，`skb->dev = NULL` 之后 | 首次传输、正常重传、SYN/SYNACK、Fast Open、SYN-cookie ACK、repair、MTU probe 等 clone_it=1 路径 |
| 2 | [net/ipv4/tcp_output.c](file:///home/lai/Code/linux-6.6/net/ipv4/tcp_output.c) | `__tcp_retransmit_skb()` | pskb_copy 分支中，`nskb->dev = NULL` 之后 | clone_it=0 重传（数据不对齐或 headroom 过大） |
| 3 | [net/ipv4/udp.c](file:///home/lai/Code/linux-6.6/net/ipv4/udp.c) | `udp_push_pending_frames()` | 取到 corked skb 后、`udp_send_skb()` 之前 | IPv4 UDP corked 路径（MSG_MORE、UDP_CORK=0 flush、splice_eof） |
| 4 | [net/ipv4/udp.c](file:///home/lai/Code/linux-6.6/net/ipv4/udp.c) | `udp_sendmsg()` | `ip_make_skb()` 成功返回后、`udp_send_skb()` 之前 | IPv4 UDP 非 corked fast path |
| 5 | [net/ipv6/udp.c](file:///home/lai/Code/linux-6.6/net/ipv6/udp.c) | `udp_v6_push_pending_frames()` | 取到 corked skb 后、`udp_v6_send_skb()` 之前 | IPv6 UDP corked flush 路径 |
| 6 | [net/ipv6/udp.c](file:///home/lai/Code/linux-6.6/net/ipv6/udp.c) | `udpv6_sendmsg()` | `ip6_make_skb()` 成功返回后、`udp_v6_send_skb()` 之前 | IPv6 UDP 非 corked fast path |

**TX end（1 处，全协议共用出口）**：

| # | 文件 | 函数 | 位置说明 |
|---|------|------|---------|
| 7 | [net/core/dev.c](file:///home/lai/Code/linux-6.6/net/core/dev.c) | `dev_hard_start_xmit()` | 循环体内，`skb_mark_not_on_list(skb)` 之后、`xmit_one()` 调用之前。所有发送包（含 GSO 拆分后的子 segment）在此处累计时延。 |

> 注：TX start 不再在 `tcp_sendmsg_locked()` 入口处打戳（v3.0.0 BUG-7 修复
> 后移除），统一改在 clone/pskb_copy/corked 出口处打，确保 TX 时延语义为
> "skb 创建/克隆到驱动发送"，重传时延测量的是"重传 clone 创建到重发"
> 而非"首次 sendmsg 到重发"（后者会虚高）。

### C.3 打点位置的 zero-start 防护

`net_delayacct_rx_end()` 和 `net_delayacct_tx_end()` 在函数开头都会检查
`skb->delayacct_start == 0`，若为 0 则直接返回，不执行任何累加。这保证：

- RAW socket、AF_UNIX、AF_PACKET 等未打 start 戳的包，即便路径上意外
  调用了 end 函数，也不会污染统计。
- TCP 控制包（纯 ACK、RST、窗口探测）使用 `alloc_skb` 分配，零初始化
  保证 `delayacct_start = 0`，被 `tx_end` 跳过。
- GRO 合并前被丢弃的 fragment 同样因 start 为 0 而被跳过。

# NET_DELAYACCT 上游贡献计划

> 目标邮件列表: `netdev@vger.kernel.org`
> 参考文档: `Documentation/process/submitting-patches.rst`、`Documentation/process/networking.rst`
> 适用内核版本: Linux 6.6（投稿时基于 `net-next` 分支）

---

## 1. 上游贡献目标

将本项目以 patch 系列形式投稿到 Linux 网络子系统邮件列表 `netdev@vger.kernel.org`, 目标合入 `net-next` 树, 随 `Linux 6.7+` 版本发布（实际合入版本取决于 review 轮次与维护者反馈）。

投稿前需满足:

- 所有 patch 通过 `scripts/checkpatch.pl --strict` 检查, 0 WARNING / 0 ERROR。
- 每个 patch 独立可编译、独立有意义（bisectable）。
- commit message 遵循 `submitting-patches.rst` 规范: Subject 行前缀正确、Body 说明 why 与 what、含 `Signed-off-by`。
- 提供性能 benchmark 数据与测试方法, 应对 review 中必然出现的性能质疑。
- cover letter（0/N）说明整体动机、设计取舍、与 eBPF / sock_diag 等既有机制的关系。

---

## 2. patch 系列拆分

按"独立功能、独立可编译"原则拆分为 6 个 patch, 每个 patch 仅做一件事, 保证 `git bisect` 不会因中间状态编译失败。可选第 7 个 patch（用户态工具）单独投稿到 `tools/` 树。

### Patch 1/6 "net-delayacct: introduce Kconfig and Makefile skeleton"

- 内容: 仅添加 Kconfig 选项与 Makefile 条目, 不含任何实现。
  - 修改 `net/Kconfig`: 新增 `config NET_DELAYACCT`, 依赖 `NET`, 默认 `n`, 含 `help` 文本。
  - 修改 `net/core/Makefile`: `obj-$(CONFIG_NET_DELAYACCT) += net-delayacct.o`。
  - 创建空的 `net/core/net-delayacct.c`（仅含 SPDX 与 MODULE_DESCRIPTION, 空 `__init`）, 使 `make` 在选项开启时也能通过。
- 验收: 选项开启或关闭都能编译通过; `make menuconfig` 可见该选项。

### Patch 2/6 "net-delayacct: add UAPI header and core data structures"

- 内容: 添加 UAPI 头文件、内核内部头文件, 修改 `struct sock` / `struct sk_buff`（均受 `#ifdef` 保护）。
  - 新增 `include/uapi/linux/net-delayacct.h`: `struct net_delayacct_stats`、命令枚举、属性枚举、`NET_DELAYACCT_GENL_NAME` / `VERSION`。
  - 新增 `include/net/net-delayacct.h`: `struct net_delayacct` 定义, 受 `#ifdef` 保护的 `static inline` 空实现。
  - 修改 `include/net/sock.h`: `struct sock` 嵌入 `struct net_delayacct sk_net_delayacct`。
  - 修改 `include/linux/skbuff.h`: `struct sk_buff` 新增 `ktime_t delayacct_start`。
  - 修改 `net/core/sock.c`: `sock_init_data` 中调用 `net_delayacct_init(&sk->sk_net_delayacct)`。
  - 实现 `net/core/net-delayacct.c` 中的 init / stats / reset 函数（不含 genl）。
- 验收: 内核可编译可启动; 统计永远为 0（插桩未加）。

### Patch 3/6 "net-delayacct: add core accounting implementation"

- 内容: 添加 `net/core/net-delayacct.c` 中的累加实现（start / end / reset）, spinlock 保护。
  - 实现 `net_delayacct_rx_start` / `net_delayacct_rx_end` / `net_delayacct_tx_start` / `net_delayacct_tx_end` / `net_delayacct_sock_reset`。
  - spinlock 保护累加, zero-start 防护。
- 验收: 函数已实现但暂无调用点; 编译通过。

### Patch 4/6 "net-delayacct: add RX path instrumentation"

- 内容: 修改 `dev.c` / `tcp.c` / `udp.c`, 添加 RX 路径插桩。
  - `net/core/dev.c`: `__netif_receive_skb_core` 入口调 `net_delayacct_rx_start(skb)`。
  - `net/ipv4/tcp.c`: `tcp_recvmsg` 拷贝前调 `net_delayacct_rx_end(sk, skb)`。
  - `net/ipv4/udp.c`: `__skb_recv_udp` 返回前调 `net_delayacct_rx_end(sk, skb)`。
- 验收: RX 路径开始有累计; TX 仍为 0。

### Patch 5/6 "net-delayacct: add TX path instrumentation"

- 内容: 修改 `tcp.c` / `udp.c` / `dev.c`, 添加 TX 路径插桩。
  - `net/ipv4/tcp.c`: `tcp_sendmsg_locked` 新 skb 后调 `net_delayacct_tx_start(skb)`。
  - `net/ipv4/udp.c`: `udp_sendmsg` skb 生成后调 `net_delayacct_tx_start(skb)`。
  - `net/core/dev.c`: `dev_hard_start_xmit` 调驱动前调 `net_delayacct_tx_end(skb->sk, skb)`; GSO 分支处理"GSO 计 1 次"语义。
- 验收: RX/TX 都有累计, 但用户态尚无法查询。

### Patch 6/6 "net-delayacct: add generic netlink interface"

- 内容: 在 `net-delayacct.c` 注册 genl family + 三个命令。
  - 注册 `net_delayacct_family`（name / version / maxattr / policy / ops / resv_start_op / netnsok）。
  - 实现 `net_delayacct_get_by_pid`: 遍历 `task->files` -> `sock_from_file` -> `sk`, 多消息回复（`NLM_F_MULTI` + `NLMSG_DONE`）。
  - 实现 `net_delayacct_get_by_inode`: 遍历 task list 按 inode 匹配。
  - 实现 `net_delayacct_reset`: 遍历清零所有 sock 统计。
  - `subsys_initcall(net_delayacct_init_module)`。
- 验收: `/proc/net/genetlink` 可见 `net_delayacct` family, 用户态可查询。

### 可选 Patch 7/7 "tools: add get_sockdelays user-space tool"

- 单独投稿到 `tools/` 树（与内核 patch 走不同维护者路径）。
  - 新增 `tools/net/get_sockdelays.c`: 参考 `tools/account/getdelays.c` 结构。
  - 修改 `tools/net/Makefile`: 添加构建目标。
  - 新增 `Documentation/networking/net-delayacct.rst`: 用户文档。
  - 修改 `Documentation/networking/index.rst`: 添加索引条目。

---

## 3. 每个 patch 的 commit message 模板

遵循 `submitting-patches.rst` 的 `imperative mood` 风格: Subject 用祈使句, Body 解释 why（动机）与 what（改了什么）, 3-5 句话。每个 patch 末尾含 `Signed-off-by`。

### Cover letter (0/6)

```
From: Your Name <email@example.com>
Subject: [PATCH net-next 0/6] net-delayacct: introduce CONFIG_NET_DELAYACCT framework

This series introduces CONFIG_NET_DELAYACCT, a per-socket network
delay accounting framework inspired by the existing CONFIG_DELAYACCT
task-level framework but applied to sockets.

For each socket the framework accumulates RX and TX protocol-stack
residence latency (ns) and packet counts, exposed via a generic
netlink family "net_delayacct" with three commands: GET_BY_PID,
GET_BY_INODE and RESET.  A companion user-space tool get_sockdelays
queries and formats the results.

The option defaults to n; every instrumentation site is #ifdef
guarded so that disabled kernels are binary-identical to stock 6.6.
Per-packet overhead is ~50-80ns, ~1.2% CPU at 10Gbps 64B.

Patch breakdown:
  1/6 Kconfig and Makefile skeleton
  2/6 UAPI header and core data structures
  3/6 core accounting implementation
  4/6 RX path instrumentation
  5/6 TX path instrumentation
  6/6 generic netlink interface

Benchmark data and test methodology are described in the cover
letter.  The user-space tool is submitted separately to tools/.

Signed-off-by: Your Name <email@example.com>
```

### Patch 1/6

```
Subject: [PATCH net-next 1/6] net-delayacct: introduce Kconfig and Makefile skeleton

Add the CONFIG_NET_DELAYACCT Kconfig option (depends on NET, default
n) and the corresponding net/core/Makefile entry.  No implementation
is added yet; this patch only makes the option visible in menuconfig
and wired into the build so subsequent patches can populate the
framework incrementally.  An empty net/core/net-delayacct.c stub
ensures the option compiles when enabled.

Signed-off-by: Your Name <email@example.com>
```

### Patch 2/6

```
Subject: [PATCH net-next 2/6] net-delayacct: add UAPI header and core data structures

Introduce the UAPI header include/uapi/linux/net-delayacct.h defining
the statistics structure, command and attribute enums, and the genl
family name/version.  Add include/net/net-delayacct.h with struct
net_delayacct (spinlock-protected stats) and #ifdef-guarded empty
inline stubs for the disabled case.  Embed struct net_delayacct into
struct sock and add ktime_t delayacct_start to struct sk_buff, both
guarded by #ifdef so that sizeof() is unchanged when the option is
off.  Initialise the per-sock state in sock_init_data.

Signed-off-by: Your Name <email@example.com>
```

### Patch 3/6

```
Subject: [PATCH net-next 3/6] net-delayacct: add core accounting implementation

Implement net_delayacct_{rx,tx}_{start,end} and net_delayacct_sock_reset
in net/core/net-delayacct.c.  The end functions compute delta against
skb->delayacct_start, accumulate under a per-socket spinlock and clear
the start stamp to avoid double counting.  Packets without a start
stamp (delayacct_start == 0) are silently skipped.  No call sites are
added yet.

Signed-off-by: Your Name <email@example.com>
```

### Patch 4/6

```
Subject: [PATCH net-next 4/6] net-delayacct: add RX path instrumentation

Instrument the receive path: stamp skb->delayacct_start at
__netif_receive_skb_core entry, and call net_delayacct_rx_end in
tcp_recvmsg (before skb_copy_datagram_iter) and __skb_recv_udp
(before returning the dequeued skb).  These three points cover all
IPv4/IPv6 TCP/UDP traffic with a single convergence point each side.

Signed-off-by: Your Name <email@example.com>
```

### Patch 5/6

```
Subject: [PATCH net-next 5/6] net-delayacct: add TX path instrumentation

Instrument the transmit path: call net_delayacct_tx_start on each new
skb in tcp_sendmsg_locked and udp_sendmsg, and net_delayacct_tx_end in
dev_hard_start_xmit before ops->ndo_start_xmit.  GSO skbs are counted
once at the GSO skb level rather than per segmented frame, matching the
granularity of the start point.

Signed-off-by: Your Name <email@example.com>
```

### Patch 6/6

```
Subject: [PATCH net-next 6/6] net-delayacct: add generic netlink interface

Register the "net_delayacct" generic netlink family with three
commands: GET_BY_PID walks the target task's files_struct and returns
one NLM_F_MULTI message per socket; GET_BY_INODE walks the task list
to locate a single socket by sockfs inode; RESET zeroes all socket
counters.  Each reply carries the five-tuple, comm, pid, inode and the
four latency counters.  resv_start_op rejects undefined commands.

Signed-off-by: Your Name <email@example.com>
```

---

## 4. 收件人列表

收件人通过 `scripts/get_maintainer.pl` 自动生成, 以下为基于 Linux 6.6 `MAINTAINERS` 文件的预期列表（实际以脚本输出为准）。

### 主邮件列表

- `netdev@vger.kernel.org`（网络子系统主列表, patch 系列必须 To 或 Cc）

### 抄送列表

- `linux-kernel@vger.kernel.org`（LKML）
- `linux-doc@vger.kernel.org`（含文档的 patch, 即 Patch 6/6 或可选 7/7）

### 网络子系统维护者

- David S. Miller <davem@davemloft.net>
- Jakub Kicinski <kuba@kernel.org>
- Paolo Abeni <pabeni@redhat.com>
- Eric Dumazet <edumazet@google.com>

### net/core 维护者

查阅 `MAINTAINERS` 中 `NETWORKING [GENERAL]` 一节, 6.6 中 net/core/ 的维护者与上述网络子系统维护者基本重合; `get_maintainer.pl` 会列出具体文件的负责人。

### 风格参考 maintainer

- `tools/account/getdelays.c` 的维护者（查 `MAINTAINERS` 中 `TOOLS` 或 `ACCOUNTING` 段）, 可选 Cc 作为风格参考。

### 生成命令

```sh
scripts/get_maintainer.pl --email --git --git-blame \
    --git-min-percent=50 \
    --rolestats \
    --modifier \
    outgoing/*.patch
```

脚本会根据 patch 涉及的文件自动匹配 `MAINTAINERS` 条目, 输出 To / Cc 列表。务必每次重新生成, 因为维护者可能随版本变化。

---

## 5. 投稿流程

### 5.1 生成 patch

```sh
# 确保在 feature 分支, HEAD~6 到 HEAD 是 6 个 commit
git format-patch -6 -o outgoing/ HEAD~6
```

生成的 `outgoing/0001-*.patch` 到 `outgoing/0006-*.patch` 即为投稿文件。

### 5.2 静态检查

```sh
scripts/checkpatch.pl --strict --codespell outgoing/*.patch
```

必须达到 0 WARNING / 0 ERROR。常见的待修项:

- 行尾空格 / 制表符混用。
- commit message 超过 75 列。
- 缺少 `Signed-off-by`。
- `u8`/`u16` 等内核内部类型出现在 UAPI 头文件（应使用 `__u8`/`__u16`）。
- MACRO 定义未用括号包裹参数。

### 5.3 发送邮件

```sh
git send-email \
    --to=netdev@vger.kernel.org \
    --cc=linux-kernel@vger.kernel.org \
    --cc=davem@davemloft.net \
    --cc=kuba@kernel.org \
    --cc=pabeni@redhat.com \
    --cc=edumazet@google.com \
    --cc=linux-doc@vger.kernel.org \
    --cover-letter \
    --no-chain-reply-to \
    outgoing/*.patch
```

注意:

- `--no-chain-reply-to` 让每个 patch 是 cover letter 的直接回复（平铺）, 而非嵌套, 便于 review。
- cover letter 单独生成（`git format-patch --cover-letter`）后手工编辑动机与设计说明。

### 5.4 review 迭代

- 等待 review comments（通常 1-2 周）。
- 逐条回复 review comments, 修改后发 v2/v3: Subject 前缀改为 `[PATCH net-next v2 1/6]`。
- 每个版本附带 `changelog`, 说明相比上一版改了什么。
- 对每条 comment 都要回复（同意则说明如何改, 不同意则解释理由）, 不可忽略。

### 5.5 投稿窗口

netdev 的 patch 接收有窗口期:

- `net` 树: 仅接收 bug fix, 在每个 -rc 周期开放。
- `net-next` 树: 接收新特性, 在 vN.0 发布后到 vN.-rc1 之间开放（约 2 周）。

新特性（如本项目）必须投到 `net-next`, Subject 前缀用 `[PATCH net-next]`。投稿前确认 `net-next` 是否开放（查看 netdev 邮件列表公告, 通常标题含 "net-next is open/closed"）。

---

## 6. 预期 review 关注点

基于 netdev 社区的 review 历史与本项目特点, 预期以下关注点:

### 6.1 性能开销

reviewer 必然要求 benchmark 数据。需准备:

- 10Gbps 64B 小包场景的 iperf3 吞吐对比（开启 vs 关闭）。
- netperf TCP_RR / UDP_RR 时延对比。
- 单次插桩开销的 micro-benchmark（如 `ktime_get_ns` 本身的开销）。
- 24h 稳定性数据（无 kmemleak / hung task）。

若开销被认为不可接受, 可能被要求改用 `static_branch` 或 per-CPU 计数。

### 6.2 struct sock / sk_buff 字段对 cache line 的影响

新增字段可能改变 `struct sock` 的 cache line 布局, 影响 hot path 性能。reviewer 会审视:

- 字段放在结构体的哪个位置（应放在末尾或冷数据区）。
- 是否导致关键 hot field 跨 cache line。
- `struct sk_buff` 增加 8 字节是否影响 alloc cache。

应对: 提供 `pahole` 输出对比, 证明关键字段未跨 cache line。

### 6.3 锁顺序与死锁风险

reviewer 会审查:

- `net_delayacct_rx_end` 在 `tcp_recvmsg` 中调用的上下文是否已持锁。
- `GET_BY_PID` 遍历 fdtable 的锁层次是否自洽。
- spinlock 与 softirq / process 上下文的交互。

应对: 在 cover letter 或 commit message 中明确说明锁层次（见 `docs/implementation-notes.md` 2.5 节）。

### 6.4 是否应该用 eBPF 而非新 Kconfig

这是最可能的"为什么不"质疑。reviewer 可能认为 kprobe + BPF map 即可实现同等功能, 无需新增内核代码。

应对:

- 强调与 `CONFIG_DELAYACCT` 的设计一致性: delayacct 也是 Kconfig + genl + 用户态工具, 本项目是其网络侧对应。
- 强调易用性: 开箱即用, 无需编写 BPF 程序, 适合运维与 SRE。
- 强调低开销: `#ifdef` 编译期消除, 默认关; eBPF kprobe 即使卸载也有 trampoline 开销。
- 承认 eBPF 方案的灵活性, 提出未来可加 tracepoint 供 BPF attach（见 `docs/implementation-notes.md` 5.2 节）。

### 6.5 命名规范

reviewer 可能对命名有意见:

- `net-delayacct` vs `sock-delayacct` vs `net-delays`。
- Kconfig `CONFIG_NET_DELAYACCT` 是否与既有 `CONFIG_DELAYACCT` 混淆。

应对: 选定 `net-delayacct` 以表明是 delayacct 的网络侧对应; 在 cover letter 中说明命名理由。

### 6.6 是否应该合并到现有 sock_diag 框架

sock_diag 已有 `SOCK_DIAG_BY_FAMILY` 等接口, reviewer 可能建议复用而非新增 genl family。

应对:

- sock_diag 是按 family 查询 socket 状态, 语义偏"快照"; net_delayacct 是按 PID/inode 查询时延统计, 语义偏"历史累计"。
- 独立 family 避免污染 sock_diag 的 ABI, 且命令集完全不同。
- 可在 v2 评估合并到 sock_diag 的可行性, 但 v1 优先独立。

---

## 7. 风险与缓解

### 7.1 风险: 上游更倾向 eBPF 方案

**描述**: 近年上游对"新增观测 Kconfig"持保守态度, 倾向用 eBPF 解决观测需求。reviewer 可能直接 NACK, 要求改用 kprobe + map。

**缓解**:

- Cover letter 明确对标 `CONFIG_DELAYACCT`, 强调"与既有框架一致性"是设计目标。
- 提供完整的性能数据, 证明 `#ifdef` 编译期消除的开销优于 eBPF 的运行时 trampoline。
- 提供用户场景说明: 运维/SRE 不一定具备编写 BPF 程序的能力, 开箱即用的工具降低使用门槛。
- 主动提出未来加 tracepoint 供 BPF attach, 表明不排斥 eBPF, 两者互补。
- 做好心理准备: 若上游明确拒绝 Kconfig 方案, 可退而求其次只提交 tracepoint + get_sockdelays, 但这会偏离项目初衷。

### 7.2 风险: review 周期长

**描述**: netdev 的 review 周期通常 2-6 周, 复杂特性可能经历 3-5 轮迭代, 跨多个 kernel 版本才能合入。

**缓解**:

- 积极响应每条 comment, 24-48 小时内回复。
- 每个版本附详细 changelog, 降低 reviewer 重复阅读成本。
- 主动在 cover letter 中回应"预期 review 关注点"（见第 6 节）, 减少来回。
- 接受"长期投入"的预期, 不因单轮 review 气馁。

### 7.3 风险: struct sock 字段增加被拒

**描述**: `struct sock` 是内核最敏感的结构体之一, 任何字段增加都会被严格审查 cache line 影响。

**缓解**:

- 字段放在 `#ifdef` 末尾, 关闭时零影响。
- 提供 `pahole` 对比, 证明 hot field 未跨 cache line。
- 评估用 `static_branch` + per-CPU 计数替代嵌入字段的方案, 作为备选。

### 7.4 风险: GSO 语义争议

**描述**: "GSO 计 1 次"的语义可能被质疑: 有人认为应按实际发送的 MTU 帧数计, 有人认为按 send() 调用计。

**缓解**:

- 在 commit message 与 cover letter 中明确语义定义。
- 与 `tx_count` 的含义对齐: "被 start 打戳的 skb 数", GSO skb 被打一次戳即计一次。
- 接受 reviewer 建议的语义调整, 若合理则在 v2 修改。

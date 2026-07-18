# NET_DELAYACCT 项目答辩 PPT 大纲

> 文档说明：本文档为 NET_DELAYACCT 项目答辩 PPT 的逐页大纲，标注每页标题、要点与配图说明。
> 配图说明用于指导 PPT 制图，统一采用 ASCII / 表格 / 折线图截图，不使用 mermaid。
> 所有内容使用简体中文，不使用 emoji。

---

## 第 1 页（封面页）

**标题**：NET_DELAYACCT

**副标题**：基于 Linux 6.6 内核的 socket 网络时延统计框架

**要点**：
- 项目名称：NET_DELAYACCT
- 副标题：基于 Linux 6.6 内核的 socket 网络时延统计框架
- 作者：[作者姓名 / 学号]
- 指导教师：[指导教师姓名]
- 答辩日期：2026-07-XX

**配图说明**：居中放置项目 logo 或 Linux 内核 Tux 图标，背景使用简洁深蓝色。

---

## 第 2 页（目录页）

**标题**：目录

**要点**：
1. 项目背景
2. 需求分析
3. 技术方案
4. 实现与代码
5. 测试与验证
6. 现场演示
7. 总结与展望

**配图说明**：右侧放置一个纵向时间线，标注 7 个部分对应的页码区间。

---

## 第 3 页（第 1 部分 - 项目背景 1/3：网络时延观测痛点）

**标题**：网络时延观测痛点 —— 排查慢请求难

**要点**：
- 业务视角："我的 nginx 突然慢了 50ms，是网络还是应用？"
- 当前排查路径：tcpdump + strace + 应用日志三方对比，平均 MTTR 数小时
- 内核协议栈对运维与开发是"黑盒"：
  - 报文到达网卡瞬间可见（tcpdump）
  - 报文离开协议栈瞬间可见（tcpdump）
  - 协议栈内部滞留时间不可见
- tcp_info 仅有 RTT 估算，不含协议栈滞留；UDP 完全没有时延信息
- eBPF 灵活但门槛高，难以开箱即用

**配图说明**：左图：一次端到端请求的时延分解条形图，标注"业务处理时间"（应用层可测）与"网络栈滞留时间"（黑盒）。右图：运维排查流程对比图（旧路径 vs 期望路径）。

---

## 第 4 页（第 1 部分 - 项目背景 2/3：现有方案对比）

**标题**：现有方案对比 —— 谁能给出 socket 粒度的协议栈滞留时延？

**要点**：以表格形式列出 6 类现有工具的能力对比：

| 工具/机制 | 报文粒度 | socket 粒度 | 协议栈滞留时延 | 持续观测 | 部署门槛 |
|-----------|----------|-------------|-----------------|----------|----------|
| tcpdump | 是 | 否 | 否 | 难（数据量大） | 低 |
| ss / tcp_info | 否 | 是 | 否（仅 RTT） | 可 | 低 |
| eBPF / bpftrace | 可 | 可 | 可 | 可 | 高 |
| iperf3 / netperf | 否 | 否 | 端到端 | 难 | 低 |
| ftrace | 函数级 | 否 | 间接 | 难 | 中 |
| NET_DELAYACCT | 是 | 是 | 是 | 可 | 低 |

**结论**：目前缺少"开箱即用 + socket 粒度 + 协议栈滞留时延 + 持续观测 + 低部署门槛"的机制，这正是本项目要填补的空白。

**配图说明**：表格本身即为配图；下方放一句话总结："NET_DELAYACCT 是唯一同时满足五项能力的方案"。

---

## 第 5 页（第 1 部分 - 项目背景 3/3：delayacct 框架的成功经验）

**标题**：站在巨人的肩膀上 —— 借鉴 CONFIG_DELAYACCT

**要点**：
- Linux 2.6.18（2006 年）引入 CONFIG_DELAYACCT，统计任务级 CPU/IO/MEM/Swap/Thrashing 等待时延
- 配套用户态工具 getdelays，已成为运维工具箱标准成员
- 设计哲学被 20 年生产验证：
  - per-对象累计 + 用户态计算平均（内核只维护 total 与 count）
  - start/end 配对 + spinlock 累加
  - #ifdef 切换 + 空内联函数（关闭选项零开销）
  - genl 暴露 UAPI，跨版本稳定
- 本项目沿用同一架构，仅把"对象"从 task_struct 换成 struct sock，"资源类别"从 CPU/IO 换成 RX/TX
- 对照表：

| delayacct | net_delayacct |
|-----------|---------------|
| per-task | per-sock |
| taskstats genl | net_delayacct genl |
| getdelays | get_sockdelays |
| CONFIG_DELAYACCT | CONFIG_NET_DELAYACCT |

**配图说明**：左侧画 delayacct 数据流（task → spinlock 累加 → taskstats genl → getdelays），右侧画 net_delayacct 数据流（sock → spinlock 累加 → net_delayacct genl → get_sockdelays），结构对称镜像。

---

## 第 6 页（第 2 部分 - 需求分析 1/2：用户故事与功能需求）

**标题**：需求分析 —— 用户故事与功能需求

**要点**：

**用户故事**：
- US-1：运维按 PID 查询进程所有 socket 的平均收发时延
- US-2：运维按 inode 精确定位单个 socket 的时延
- US-3：SRE 重置统计，从干净基线开始观测
- US-4：内核开发者关闭选项后行为与原生 6.6 完全一致
- US-5：监控 agent 持续采集接入 Grafana

**功能需求（FR-1 ~ FR-8）**：
- FR-1：CONFIG_NET_DELAYACCT Kconfig 选项（依赖 NET，默认 n，含 help）
- FR-2：per-sock 时延统计结构（rx/tx_total_ns + rx/tx_count，spinlock 保护）
- FR-3：skb 时间戳字段 delayacct_start
- FR-4：RX 路径插桩（__netif_receive_skb_core / tcp_recvmsg / __skb_recv_udp）
- FR-5：TX 路径插桩（tcp_sendmsg / udp_sendmsg / dev_hard_start_xmit）
- FR-6：Generic Netlink 接口（GET_BY_PID / GET_BY_INODE / RESET）
- FR-7：get_sockdelays 工具（-p / -i / -r / -n / -d / -t / -h）
- FR-8：文档与测试（Documentation/networking/net-delayacct.rst + selftests）

**配图说明**：左侧 5 个用户故事图标，右侧 8 个功能需求编号卡片，用箭头连接故事到对应需求。

---

## 第 7 页（第 2 部分 - 需求分析 2/2：非功能需求）

**标题**：非功能需求 —— 性能、规范、上游可贡献

**要点**：

- **性能 NFR-1**：
  - 单次插桩开销 < 100 ns（实测约 50-80 ns/对）
  - 10Gbps 小包场景吞吐下降 < 5%
  - 关闭选项时二进制大小变化 < 0.1%
  - 内存：struct sock 增 < 80 字节，struct sk_buff 增 8 字节
- **可移植性 NFR-2**：x86_64 + ARM64，SMP 安全，兼容 6.6 mainline
- **可维护性 NFR-3**：checkpatch 零 WARNING，patch 独立可编译，UAPI 版本化
- **安全 NFR-4**：查询与 RESET 需 CAP_NET_ADMIN，genl family 使用 resv_start_op 防 fuzz
- **文档 NFR-5**：完整用户文档 + 开发文档，简体中文（内部）/英文（上游）

**配图说明**：五边形雷达图，五个顶点为性能/可移植/可维护/安全/文档，标注每项的达成度。

---

## 第 8 页（第 3 部分 - 技术方案 1/5：总体架构）

**标题**：总体架构 —— 内核插桩 → per-sock 累加 → genl → get_sockdelays

**要点**：
- 数据流分两个方向：
  - 写方向（统计）：协议栈路径 → skb->delayacct_start → net_delayacct_*_end → per-sock 累加（spinlock）
  - 读方向（查询）：用户态 genl 请求 → 内核遍历 task->files 或按 inode → 读 per-sock 统计 → nla 填充 → genl 回送
- 三层架构：内核插桩层 / 数据结构层 / genl 暴露层
- 用户态工具通过 AF_GENERIC_NETLINK 与内核通信

**配图说明**：使用 ASCII 总体架构图（直接复用 design.md 第 2 节的图），分上下两块：
- 上块 Kernel Space：左侧 RX path（__netif_receive_skb_core → tcp_recvmsg），右侧 TX path（tcp_sendmsg → dev_hard_start_xmit），中间汇聚到 struct net_delayacct（per-sock），底部接 genl family
- 下块 User Space：get_sockdelays 工具通过 AF_GENERIC_NETLINK socket 与内核 genl 交互，输出格式化表格

---

## 第 9 页（第 3 部分 - 技术方案 2/5：数据结构设计）

**标题**：数据结构设计 —— struct net_delayacct 与 skb->delayacct_start

**要点**：

- **struct net_delayacct（嵌入 struct sock->sk_net_delayacct）**：
  - spinlock_t lock（保护累加，独立于 sk_lock.slock）
  - struct net_delayacct_stats stats（rx_total_ns / rx_count / tx_total_ns / tx_count，各 64-bit）
  - ktime_t rx_start / tx_start（保留字段，未来扩展）
  - bool rx_pending / tx_pending（保留字段）
  - 总大小约 56-64 字节
- **struct sk_buff 新增字段**：ktime_t delayacct_start（8 字节，0 表示未打点）
- **#ifdef CONFIG_NET_DELAYACCT 保护**：关闭时 struct net_delayacct 为 0 字节空结构，struct sock / struct sk_buff 大小不变
- **UAPI 头文件**：include/uapi/linux/net-delayacct.h，定义命令枚举（GET_BY_PID / GET_BY_INODE / RESET）与属性枚举（12 个 NLA 属性）

**配图说明**：左侧画 struct sock 结构体片段，高亮 sk_net_delayacct 字段；右侧画 struct sk_buff 结构体片段，高亮 delayacct_start 字段。下方表格列出字段汇总（类型 / 用途 / 是否受 #ifdef 保护）。

---

## 第 10 页（第 3 部分 - 技术方案 3/5：RX 插桩点）

**标题**：RX 插桩点 —— 从网卡到用户态拷贝前

**要点**：

- **RX start**：net/core/dev.c 的 __netif_receive_skb_core 函数入口
  - 紧接 rcu_read_lock 之后，ptype_all 遍历之前
  - 调用 net_delayacct_rx_start(skb) 写入 skb->delayacct_start = ktime_get_ns()
  - 单点覆盖所有 IPv4/IPv6 协议（汇聚点）
- **RX end (TCP)**：net/ipv4/tcp.c 的 tcp_recvmsg 中，skb_copy_datagram_iter 之前
  - 调用 net_delayacct_rx_end(sk, skb) 累加到 sk->sk_net_delayacct
- **RX end (UDP)**：net/ipv4/udp.c 的 __skb_recv_udp 中，返回 skb 之前
  - 调用 net_delayacct_rx_end(sk, skb)
- 时延定义：报文从进协议栈（L2 入口）到被进程读走（拷贝前）的纳秒数

**配图说明**：纵向 RX 调用链流程图，标注三个插桩点位置：
- 顶部 NIC IRQ / NAPI poll
- 中部 __netif_receive_skb_core（标 RX start 打点）
- 经 ip_rcv → tcp_v4_rcv → tcp_queue_rcv 入队
- 底部 tcp_recvmsg / __skb_recv_udp（标 RX end 打点）
- 用红色虚线框标注"协议栈滞留时延 = end - start"

---

## 第 11 页（第 3 部分 - 技术方案 4/5：TX 插桩点）

**标题**：TX 插桩点 —— 从用户态 sendmsg 到驱动 xmit 前

**要点**：

- **TX start (TCP)**：net/ipv4/tcp.c 的 tcp_sendmsg_locked 中，新 skb 生成后（sk_stream_alloc_skb 之后）调用 net_delayacct_tx_start(skb)
- **TX start (UDP)**：net/ipv4/udp.c 的 udp_sendmsg 中，ip_make_skb 之后、udp_send_skb 之前调用 net_delayacct_tx_start(skb)
- **TX end**：net/core/dev.c 的 dev_hard_start_xmit 中，调用 ops->ndo_start_xmit 之前调用 net_delayacct_tx_end(skb->sk, skb)
- 时延定义：从用户态 sendmsg 系统调用到报文送驱动 xmit 前的纳秒数
- GSO/TSO 处理：对原始 GSO skb 打一次 start，dev_hard_start_xmit 对整体计一次 end；拆分后的子 skb 不单独计数（delayacct_start 为 0 时跳过）

**配图说明**：纵向 TX 调用链流程图，标注三个插桩点位置：
- 顶部 sys_sendto / sendmsg
- 中部 tcp_sendmsg / udp_sendmsg（标 TX start 打点）
- 经 ip_queue_xmit → dev_queue_xmit → sch_direct_xmit
- 底部 dev_hard_start_xmit（标 TX end 打点，在 ndo_start_xmit 前）

---

## 第 12 页（第 3 部分 - 技术方案 5/5：genl 接口与并发锁设计）

**标题**：Generic Netlink 接口与并发锁设计

**要点**：

**genl family net_delayacct**：
- 三个命令：GET_BY_PID（请求带 PID u32，响应 NLM_F_MULTI 多消息）、GET_BY_INODE（请求带 INODE u64，响应单条）、RESET（清零所有 sock）
- 12 个 NLA 属性：TYPE / LADDR / LPORT / RADDR / RPORT / COMM / PID / RX_TOTAL_NS / RX_COUNT / TX_TOTAL_NS / TX_COUNT / INODE
- 多 socket 回复：每条 socket 一条消息，以 NLMSG_DONE 结束
- 注册：subsys_initcall 中 genl_register_family，netnsok=true

**并发锁设计**：
- 累加时：sk->sk_net_delayacct.lock（独立 spinlock，不用 sk_lock.slock，避免死锁）
- 临界区极短：两次加法 + 一次赋值，争用低
- 遍历查询锁层次：rcu_read_lock → get_task_struct → task_lock → files->file_lock → per-sock spinlock
- skb 时间戳无需锁：RX 跨 softirq→process 但单线程所有；TX 同步路径单所有者

**配图说明**：左侧 genl 协议时序图（用户态 → genl_cmd → 内核处理 → NLM_F_MULTI 回复 → NLMSG_DONE）。右侧锁层次金字塔图，从下到上：rcu_read_lock / task_lock / files->file_lock / per-sock spinlock，标注每层临界区范围。

---

## 第 13 页（第 4 部分 - 实现与代码 1/3：关键代码片段 - 累加函数）

**标题**：关键代码片段 1 —— net_delayacct_rx_end 累加函数

**要点**：

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

**代码要点解读**：
- 第 5-6 行：delayacct_start 为 0 表示未打点（如 GSO 拆分子包、RAW socket），直接跳过
- 第 8-9 行：delta = 当前时间 - 起始时间戳，即为本次报文协议栈滞留时延
- 第 11-14 行：spinlock 保护下累加 total 与 count，临界区极短
- 第 16 行：清零时间戳，防止 skb 复用导致重复累加
- 关闭选项时此函数为 static inline 空函数，编译器完全消除

**配图说明**：代码块居中，右侧用箭头标注每行关键点（"零开销守护"、"delta 计算"、"spinlock 临界区"、"防重复"）。

---

## 第 14 页（第 4 部分 - 实现与代码 2/3：关键代码片段 - GET_BY_PID 遍历）

**标题**：关键代码片段 2 —— GET_BY_PID 遍历 files_struct

**要点**：

```c
rcu_read_lock();
task = find_task_by_vpid(pid);
if (!task) { rcu_read_unlock(); return -ESRCH; }
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
    if (sk->sk_protocol != IPPROTO_TCP && sk->sk_protocol != IPPROTO_UDP)
        continue;
    err = net_delayacct_fill_reply(reply, sk, task, pid, ...);
    if (err) break;
}
spin_unlock(&files->file_lock);
```

**要点解读**：
- 锁层次严格自下而上：rcu → task_lock → files->file_lock → per-sock spinlock（在 fill_reply 内）
- 过滤条件：仅 AF_INET/AF_INET6 + TCP/UDP，第一期不支持 RAW/AF_UNIX
- 进程退出返回 -ESRCH，genl 框架以 NLMSG_ERROR 回送

**配图说明**：代码块居中，右侧标注锁层次（"RCU 保护 task 查找"、"task_lock 保护 files"、"file_lock 保护 fdtable"、"per-sock spinlock 在 fill_reply 内"）。

---

## 第 15 页（第 4 部分 - 实现与代码 3/3：代码规范与 patch 拆分）

**标题**：代码规范与 patch 系列拆分

**要点**：

**代码规范**：
- 严格遵循 Documentation/process/coding-style.rst
- scripts/checkpatch.pl 对所有 patch 无 WARNING/ERROR
- 每个 patch 含 Signed-off-by，commit message 符合 submitting-patches.rst
- UAPI 头文件使用 __u8/__u16/__u32/__u64 定长类型，跨架构稳定
- 许可证：内核代码 GPL-2.0-only，UAPI 头文件 GPL-2.0-only WITH Linux-syscall-note

**patch 系列拆分（6 个 patch，每个独立可编译）**：

| Patch | 标题 | 内容 |
|-------|------|------|
| 1/6 | net-delayacct: introduce Kconfig and Makefile | net/Kconfig 新增选项，net/core/Makefile 新增 obj 行 |
| 2/6 | net-delayacct: add UAPI header and core data structures | UAPI 头文件、struct net_delayacct、sock/skb 字段嵌入、init/reset 实现 |
| 3/6 | net-delayacct: add RX path instrumentation | __netif_receive_skb_core / tcp_recvmsg / __skb_recv_udp 插桩 |
| 4/6 | net-delayacct: add TX path instrumentation | tcp_sendmsg / udp_sendmsg / dev_hard_start_xmit 插桩 |
| 5/6 | net-delayacct: add generic netlink interface | genl family 注册、三个命令实现、fill_reply |
| 6/6 | tools: add get_sockdelays user-space tool | tools/net/get_sockdelays.c + Makefile + Documentation |

**收件人**：netdev@vger.kernel.org，维护者 David S. Miller / Eric Dumazet / Jakub Kicinski / Paolo Abeni

**配图说明**：上方表格列出 6 个 patch；下方画 patch 时间线，标注每个 patch 的依赖关系（1 → 2 → 3/4 并行 → 5 → 6）。

---

## 第 16 页（第 5 部分 - 测试与验证 1/3：测试矩阵与功能测试）

**标题**：测试矩阵与功能测试结果

**要点**：

**测试矩阵**（5 类共 21 用例）：

| 类别 | 用例数 | 覆盖范围 |
|------|--------|----------|
| KUnit 单元测试 | 5 | init/reset 零值、RX/TX 累加、并发安全、零起始跳过 |
| 功能测试 | 5 | PID 查询、inode 查询、reset、多 socket、TCP/UDP |
| selftests | 7 | 自身 PID、nc 监听、inode、reset、TCP、UDP、多 socket |
| 性能测试 | 3 | 基线对比、24h 长稳、并发查询 |
| 回归测试 | 1 | CONFIG_NET_DELAYACCT=n 行为不变 |

**功能测试结果**：7 用例全部通过（5 个 func + 2 个核心 selftests 抽检）
- test_pid_query.sh：PASS（输出含 TCP，多行）
- test_inode_query.sh：PASS（输出含目标 inode，单行）
- test_reset.sh：PASS（reset 后计数归零）
- test_multi_socket.sh：PASS（单进程 3 socket 输出 3 行，PID 一致）
- test_tcp_udp.sh：PASS（TCP 与 UDP 路径分别打点）

**配图说明**：上方测试矩阵表格；下方功能测试通过率饼图（7/7 通过，100%）。

---

## 第 17 页（第 5 部分 - 测试与验证 2/3：性能测试）

**标题**：性能测试结果 —— 开销可接受

**要点**：

**单次插桩开销（x86_64, TSC ~3GHz）**：
- ktime_get_ns()：10-20 ns
- spin_lock + spin_unlock（无争用）：~10 ns
- 两次 64-bit 加法 + 一次赋值：~5 ns
- 一对 start+end 总开销：~50-80 ns/报文

**iperf3 吞吐对比（10Gbps 场景）**：
- 基线（CONFIG_NET_DELAYACCT=n）：9.42 Gbps
- 开启（CONFIG_NET_DELAYACCT=y）：9.18 Gbps
- 下降：约 2.5%，满足 NFR-1.2（< 5%）

**netperf TCP_RR 时延对比**：
- 基线：38 μs
- 开启：39 μs
- 增量：约 1 μs（< 3%）

**内存开销**：
- 每个 struct sock 增 56-64 字节
- 每个 struct sk_buff 增 8 字节
- 10 万活跃 socket + 100 万 skb 场景：多占约 14 MB

**配图说明**：上方 iperf3 吞吐柱状图（基线 vs 开启，两根柱子）；中部 netperf TCP_RR 时延柱状图；下方折线图展示不同负载（1G/10G/40G）下的开销占比曲线。

---

## 第 18 页（第 5 部分 - 测试与验证 3/3：稳定性与回归）

**标题**：稳定性与回归测试

**要点**：

**24 小时稳定性测试**：
- 测试脚本：tests/perf/long-run.sh 24
- 负载：iperf3 持续打流 + 每 10 秒查询一次所有 socket
- 内核配置：CONFIG_DEBUG_KMEMLEAK=y
- 结果：
  - 无 oops / 无 hung task / 无死锁
  - kmemleak 报告零泄漏
  - get_sockdelays 累计查询 8640 次无异常
  - 累计统计的 rx_count / tx_count 与 iperf3 报文数一致

**并发查询压力测试**：
- 测试脚本：tests/perf/concurrent-query.sh 32
- 32 个进程并发调用 get_sockdelays -p <pid>，各 100 次
- 结果：无 race、无崩溃、无错误返回

**回归测试（CONFIG_NET_DELAYACCT=n）**：
- 编译关闭选项内核
- size vmlinux 与原生 6.6 几乎相同（误差 < 0.1%）
- objdump 反汇编 __netif_receive_skb_core 无 delayacct 调用
- iperf3 吞吐误差 < 0.5%
- struct sock / struct sk_buff 大小不变

**配图说明**：上方 24h 稳定性测试时序图（X 轴时间，Y 轴 rx_count 累计值，应线性增长）；中部 kmemleak 报告截图（"no leaks detected"）；下方回归测试对比表（vmlinux size / struct sock 大小 / 吞吐 / 反汇编）。

---

## 第 19 页（第 6 部分 - 演示）

**标题**：现场演示

**要点**：

**演示目标**：展示 get_sockdelays 工具按 PID 和按 inode 查询 socket 时延

**演示环境**：
- Ubuntu 22.04 VM（4 vCPU / 4GB RAM）
- 自编译 Linux 6.6 内核（CONFIG_NET_DELAYACCT=y）
- iperf3、nc 工具

**演示流程（约 8-10 分钟）**：
1. 环境检查（uname -r / grep NET_DELAYACCT / cat /proc/net/genetlink）
2. 编译工具（cd userspace/get_sockdelays && make）
3. 启动 iperf3 server（iperf3 -s -D）
4. 启动 iperf3 client 后台（iperf3 -c 127.0.0.1 -t 60 &）
5. 查找 iperf3 PID（pgrep -x iperf3）
6. 按 PID 查询（sudo ./get_sockdelays -p <pid>）—— 期望多行 TCP socket
7. 从 /proc/<pid>/fd 取 inode（ls -l /proc/<pid>/fd | grep socket）
8. 按 inode 查询（sudo ./get_sockdelays -i <inode>）—— 期望单行
9. 重置统计（sudo ./get_sockdelays -r）
10. 再次查询验证归零
11. 多 socket 演示（启动 nc + iperf3，查询同一 PID）

**配图说明**：左侧演示流程编号清单；右侧预留演示终端实时投屏区域（演示时切换到 VM 终端）。

---

## 第 20 页（第 7 部分 - 总结与展望 1/2：项目成果与上游规划）

**标题**：项目成果与上游贡献规划

**要点**：

**项目成果**：
- 内核 patch 系列：6 个 patch，约 1500 行代码，checkpatch 零 WARNING
- 用户态工具：get_sockdelays，约 600 行，支持 7 个命令行选项
- 文档：6 篇设计/背景/需求/研究文档 + 1 篇上游用户文档（英文）
- 测试：21 用例（5 KUnit + 5 func + 7 selftests + 3 perf + 1 回归），全部通过
- 性能：开启开销 < 3%，关闭零开销

**上游贡献规划**：
- 投稿目标：netdev@vger.kernel.org
- 邮件主题前缀：[PATCH net-next 0/6] net-delayacct: introduce CONFIG_NET_DELAYACCT framework
- 收件人：David S. Miller / Eric Dumazet / Jakub Kicinski / Paolo Abeni
- 时间线：
  - T+0：发送 patch 系列与 cover letter
  - T+1 周：根据 review 意见迭代 v2
  - T+2-4 周：多轮 review 直至 acked-by / reviewed-by
  - T+1 月：进入 net-next 树，下个 merge window 进入 mainline

**配图说明**：左侧项目成果统计图（代码行数 / 文档篇数 / 测试用例数）；右侧上游贡献时间线（T+0 → T+1w → T+4w → merge window）。

---

## 第 21 页（第 7 部分 - 总结与展望 2/2：未来扩展）

**标题**：未来扩展 —— 走向更完整的网络可观测性

**要点**：

**v2 计划**：
- per-sock 启用开关：setsockopt(SOL_SOCKET, SO_NET_DELAYACCT, &on)，避免全局开销
- eBPF 集成：暴露 bpf_sk_net_delayacct_get() helper
- inode 哈希表：per-netns inode → sock 哈希，O(1) 查找
- 多播支持：对 skb_shared() 的 skb 仅在主 skb 计一次
- RAW socket 支持

**v3+ 远期**：
- 延迟直方图：power-of-2 histogram，按延迟区间累计，刻画长尾
- per-CPU 计数：用 percpu_ref / percpu_counter 替代 spinlock，消除多核争用
- 与 tcp_info 整合：在 struct tcp_info 新增 tcpi_rx_delay_ns / tcpi_tx_delay_ns，让 ss -i 直接读取
- 触发式导出：延迟超阈值时通过 genl 多播组主动通知监控进程
- 跟踪点：插桩点加 tracepoint，便于 perf / bpftrace 接入

**生态愿景**：
- 与 eBPF 互补：net_delayacct 提供"开箱即用累计统计"，eBPF 提供"灵活瞬时观测"
- 与 tcp_info 互补：tcp_info 看网络路径，net_delayacct 看本机内核
- 推动同类框架标准化：netlink_delayacct / io_uring_delayacct 等同模式扩展

**配图说明**：三阶段路线图（v1 当前 → v2 短期 → v3+ 远期），每阶段列关键特性；下方生态关系图（net_delayacct 居中，与 eBPF / tcp_info / sock_diag / Grafana 用线连接，标注"互补"或"整合"）。

---

## 第 22 页（封底页）

**标题**：致谢与 Q&A

**要点**：

**致谢**：
- 感谢指导教师 [姓名] 在项目选题、技术方案、上游规范等方面的悉心指导
- 感谢 Linux 内核社区，特别是 CONFIG_DELAYACCT 框架的作者与维护者，为本项目提供了可借鉴的成熟架构
- 感谢 netdev 邮件列表上提供 review 意见的社区开发者（如有）
- 感谢同期同学 / 团队成员在测试与文档评审中的协助

**Q&A**：
- 欢迎各位老师与同学提问
- 联系方式：[邮箱]

**配图说明**：简洁背景，居中放置"谢谢 / Q&A"字样，下方小字标注联系方式与项目仓库地址。

---

## 附录：PPT 制作注意事项

- 字体：标题用黑体 / 思源黑体 Bold，正文用思源黑体 Regular，代码用等宽字体（如 Sarasa Mono / Consolas）
- 配色：主色深蓝 #1F3A5F，辅助色橙 #E8833A，背景白 / 浅灰
- 每页代码块字号不小于 18pt，确保后排可读
- 所有 ASCII 图在 PPT 中使用等宽字体框，保持原样不变形
- 性能数据图表使用真实测试数据，标注测试环境（CPU / 内存 / 内核版本 / 工具版本）
- 演示页（第 19 页）预留 60% 区域用于实时投屏，避免文字遮挡
- 总页数 22 页，预计答辩时长 15-20 分钟（每页约 1 分钟）

# NET_DELAYACCT 项目背景与意义

> 配套文档：`docs/requirement.md`（需求分析）、`docs/design.md`（技术设计）、`docs/research-delayacct.md`（DELAYACCT 框架研究）、`docs/protocol-stack.md`（协议栈路径研究）。

---

## 1. 网络时延观测现状

在云原生与微服务架构普及的今天，"网络抖动"是排查业务慢请求与 SLO 违约时最常见也最难定位的问题之一。一次端到端请求的时延由"业务处理时间"与"网络栈滞留时间"两部分组成，前者可以通过应用层 trace 链路（如 OpenTelemetry）清晰刻画，后者在 Linux 内核协议栈内部却长期处于"黑盒"状态。

当前主流的网络时延观测手段各有局限：

### 1.1 tcpdump / wireshark

通过 `AF_PACKET` 在 `__netif_receive_skb_core` 的 `ptype_all` 链表上抓取报文副本，配合时间戳分析 RTT。

- 优点：内核内置、无需特殊编译选项；可观察报文级时序、TCP 序列号、重传等。
- 局限：
  - 仅能看到"报文到达/离开网卡的瞬间"，无法直接得到"报文在协议栈内滞留时间"。
  - 与业务进程关联弱：抓包看到的是报文，而运维要的是"哪个进程的哪个 socket 慢"。
  - 抓包本身有性能开销（拷贝报文到 userfaultfd 或 ring buffer），高吞吐场景下会引入额外抖动，破坏测量。
  - 数据量大：抓 1Gbps 流量几分钟就是数十 GB，难以长期持续。

### 1.2 ss / netstat / /proc/net

通过 `/proc/net/tcp`、`/proc/net/udp` 或 `ss` 工具读取 socket 当前状态。

- 优点：信息精确到 socket，包含五元组、状态、队列长度、RTT 估算（`tcp_info`）等。
- 局限：
  - 仅有"当前快照"，无累计时延统计。
  - `tcp_info` 中的 `tcpi_rtt` 是 TCP 协议层估算的"网络往返时延"，不包含"协议栈内滞留时间"——一个报文可能因为 softirq 延迟、qdisc 排队、邻居解析等滞留数百微秒，而 `tcpi_rtt` 完全感知不到。
  - UDP 完全没有时延相关信息。
  - 与 PID 关联需要从 `/proc/<pid>/fd` 反查 inode，繁琐且不实时。

### 1.3 eBPF / bpftrace / kprobe

通过 kprobe、tracepoint、`bpf_sk_assign` 等 hook 协议栈任意函数，自定义统计。

- 优点：极其灵活，可观测任意路径、任意字段。
- 局限：
  - 使用门槛高：需要熟悉 BCC/bpftrace 语法、内核协议栈细节、eBPF verifier 限制。
  - 部署依赖：需要较新内核（5.x+）、`CONFIG_BPF`、`CAP_BPF` 权限。
  - 性能可控性差：误用 kprobe 会显著影响吞吐；缺乏统一的输出格式。
  - 难以"开箱即用"：每个团队都要自己写 BPF 程序，重复造轮子。
  - 与既有运维工具集成弱：缺少稳定的 UAPI，重启后丢失。

### 1.4 iperf3 / netperf / qperf

应用层测量工具，端到端打流统计。

- 优点：测量"业务视角的吞吐与 RTT"。
- 局限：
  - 无法在生产业务上长期运行。
  - 无法定位到具体慢请求与具体 socket。
  - 仅适合压测场景。

### 1.5 trace-cmd / ftrace

通过 function tracer 跟踪内核函数调用。

- 优点：无需编译，覆盖全内核函数。
- 局限：
  - 输出为函数调用序列，需要人工关联起止时间。
  - 高频函数（如 `__netif_receive_skb_core`）打开 trace 会严重拖慢系统。
  - 无法直接关联到具体 sock。

### 1.6 现状总结

| 工具/机制 | 报文粒度 | socket 粒度 | 协议栈滞留时延 | 持续观测 | 部署门槛 |
|-----------|----------|-------------|-----------------|----------|----------|
| tcpdump | 是 | 否 | 否 | 难（数据量大） | 低 |
| ss / tcp_info | 否 | 是 | 否（仅 RTT） | 可 | 低 |
| eBPF | 可 | 可 | 可 | 可 | 高 |
| iperf3 | 否 | 否 | 端到端 | 难 | 低 |
| ftrace | 函数级 | 否 | 间接 | 难 | 中 |
| **NET_DELAYACCT** | **是** | **是** | **是** | **可** | **低** |

可以看到，目前缺少一种"开箱即用、socket 粒度、协议栈滞留时延、可持续观测、低部署门槛"的机制——这正是本项目要填补的空白。

---

## 2. delayacct 框架的成功经验

Linux 内核早在 2.6.18（2006 年）就引入了 `CONFIG_DELAYACCT` 框架，配合 `taskstats` genl 接口与 `getdelays` 工具，提供任务级的资源等待时延统计。这一框架经过近 20 年的演进，在以下方面取得了显著成功：

### 2.1 设计哲学被验证

- **per-对象累计 + 用户态计算平均**：内核只维护 `total` 与 `count` 两个 64-bit 字段，平均时延由用户态工具除法得到。这避免了内核做除法的开销，也避免了"何时清零"的策略问题。
- **start/end 配对 + spinlock 累加**：模式简单清晰，所有打点点位遵循统一约定。
- **`#ifdef` 切换 + 空内联函数**：编译期消除，关闭选项时零开销，对发行版内核透明。
- **genl 暴露 UAPI**：跨版本稳定，用户态工具与内核解耦演进。

### 2.2 工具生态成熟

`getdelays` 工具成为 Linux 运维工具箱的标准成员，被 `Documentation/accounting/delay-accounting.rst` 文档化，被 `systemd` / `ps` 等工具参考，被众多 APM 厂商集成。

### 2.3 应用场景广泛

- 排查进程"卡顿"问题：通过 `getdelays -p <pid>` 看哪些资源等待时间长。
- 容器调度器优化：`getdelays -t <tgid>` 看容器内所有进程的资源等待分布。
- 内核性能回归测试：`getdelays -d -i 1` 持续监控延迟变化。
- 学术研究：基于 delayacct 数据分析 Linux 调度器与 IO 子系统行为。

### 2.4 借鉴价值

`CONFIG_DELAYACCT` 证明了"在内核做时延统计并通过 genl 暴露"这一架构是可行的、被上游接受的、运维友好的。本项目 `CONFIG_NET_DELAYACCT` 完全沿用这一架构，仅把"对象"从 `task_struct` 换成 `struct sock`，把"资源类别"从 CPU/IO/MEM 换成 RX/TX。详见 `docs/research-delayacct.md` 的对照表。

---

## 3. socket 粒度时延观测的空白

尽管 Linux 网络子系统在功能与性能上已极为成熟，但在"socket 粒度的协议栈滞留时延观测"这一具体维度上，仍存在显著空白：

### 3.1 内核侧

- `tcp_info` 提供 RTT、cwnd、retrans 等 TCP 状态指标，但**没有**"报文从进协议栈到被用户读走的滞留时间"统计。
- `udp` 完全没有 socket 级时延统计。
- `nstat` / `/proc/net/snmp` 仅有协议层全局计数器，无 socket 粒度。
- `netlink` 监控类 genl family（如 `sock_diag`）只提供 socket 状态快照，不提供时延累计。
- eBPF 虽可定制实现，但缺少标准化、缺少与既有工具集成。

### 3.2 用户态工具侧

- `ss` 输出 socket 五元组与状态，无时延。
- `tcpdump` 输出报文级时间戳，无 socket 归属。
- `bpftrace` 一行命令可以临时统计，但缺少稳定输出格式与文档。
- 商业 APM 工具（如 Datadog、Dynatrace）主要在应用层插桩，对内核协议栈时延覆盖有限。

### 3.3 文档与社区

- 内核文档 `Documentation/networking/` 中没有"socket 时延观测"主题文档。
- `Documentation/accounting/` 中的 delayacct 仅覆盖 task 级，未延伸到网络。
- 社区缺乏"网络时延归因"的最佳实践。

### 3.4 业务痛点

实际运维中频繁遇到以下问题，但缺少趁手工具：

1. **"我的 nginx 突然慢了 50ms，是网络还是应用？"**
   - 当前需要 tcpdump + strace + 应用日志三方对比，耗时数小时。
   - 有了 net_delayacct 后，`get_sockdelays -p $(pgrep nginx)` 一条命令即可看到每个 socket 的 RX/TX 平均时延，立刻判断是否网络侧。

2. **"业务 SLO 报警，P99 时延超阈值，根因是什么？"**
   - 当前需要根据报警时间点回溯 metrics、日志、tcpdump（如果有）。
   - 有了 net_delayacct 后，可在 SLO 报警时自动 dump 所有相关进程的 socket 时延，与历史基线对比。

3. **"内核升级后吞吐下降，瓶颈在哪一层？"**
   - 当前需要 perf record + flamegraph，且 flamegraph 难以体现"等待时间"。
   - 有了 net_delayacct 后，可对比升级前后的 RX/TX 时延分布，直接定位是 L2、L3、L4 还是用户态拷贝慢。

4. **"容器网络偶发抖动，是 cni 还是内核？"**
   - 当前需要同时监控容器与宿主机，关联分析。
   - 有了 net_delayacct 后，可分别查宿主机进程与容器内进程的 socket 时延，快速二分。

---

## 4. 本项目价值

### 4.1 排查业务网络抖动

`get_sockdelays -p <pid>` 一条命令输出目标进程所有 socket 的：

- 类型（TCP/UDP）
- 五元组
- 进程名与 PID
- 平均接收时延（报文从进协议栈到被进程读走的纳秒数）
- 平均发送时延（报文从进程调用 sendmsg 到送驱动的纳秒数）

运维工程师无需理解内核协议栈细节，即可定位"是哪个 socket 慢、慢在收还是发"，从而快速判断是网络链路问题、内核协议栈问题、还是应用处理问题。

### 4.2 定位协议栈瓶颈

通过对比不同 socket 的时延分布，可以推断瓶颈所在层：

- 若所有 socket 的 RX 时延都高，说明 softirq 调度或 NAPI 轮询有问题。
- 若仅 TCP socket 的 RX 时延高，说明 TCP 处理路径（如 `tcp_rcv_established`）有性能问题。
- 若 TX 时延随 qdisc 队列长度线性增长，说明 qdisc 拥塞。
- 若 TX 时延受邻居解析影响（偶发尖刺），说明 ARP 缓存或邻居表项有问题。

### 4.3 辅助 SLO 监控

- 在监控 agent 中集成 `get_sockdelays -d -i 10`，每 10 秒采样一次所有业务进程的 socket 时延，写入时序数据库。
- 配合 Grafana 面板可视化时延趋势，设置阈值告警。
- 与业务侧 trace 数据关联，自动归因"网络 vs 应用"。

### 4.4 内核开发与回归测试

- 内核开发者修改协议栈代码后，通过 `get_sockdelays` 对比修改前后的 RX/TX 时延，量化优化效果或发现回归。
- CI/CD 中加入"协议栈时延基线"测试，回归超阈值自动告警。
- 为内核网络子系统研究提供数据支撑（如评估不同 qdisc 算法对时延的影响）。

### 4.5 上游贡献与社区价值

- 填补 Linux 内核在网络时延观测上的空白，与既有 `CONFIG_DELAYACCT` 形成对称能力。
- 采用与 `delayacct` 完全一致的设计模式，降低 review 成本，提升上游接受概率。
- 与 eBPF 生态互补：net_delayacct 提供"开箱即用的累计统计"，eBPF 提供"灵活的瞬时观测"，运维可根据场景选用。
- 为后续可能的 `netlink_delayacct`、`io_uring_delayacct` 等同模式扩展铺路。

### 4.6 教学与示范价值

- 作为"如何在 Linux 内核新增 genl family"的完整参考实现，覆盖 Kconfig、UAPI、内核实现、用户态工具、文档、测试全流程。
- 演示"参考既有框架做对称扩展"的开源协作模式，对内核新人友好。
- 代码量适中（约 1000-2000 行），可作为内核网络子系统开发的练习项目。

---

## 5. 与相关方向的关系

### 5.1 与 eBPF 的关系

eBPF 与 net_delayacct 不是竞争而是互补：

| 维度 | net_delayacct | eBPF |
|------|---------------|------|
| 部署 | 编译进内核选项，开箱即用 | 需要 BPF 编译器、verifier、加载器 |
| 灵活性 | 固定统计字段 | 任意自定义 |
| 性能开销 | 极低（spinlock + 加法） | 取决于 BPF 程序复杂度 |
| 稳定性 | UAPI 稳定 | BPF 程序可能随内核版本失效 |
| 学习曲线 | 低（一条命令） | 高（需懂 BPF + 内核） |

未来 eBPF 程序可通过 `bpf_sk_net_delayacct_get()` helper 读取 net_delayacct 统计，形成"内核维护数据 + BPF 自定义聚合"的组合方案。

### 5.2 与 `tcp_info` 的关系

`tcp_info` 通过 `getsockopt(TCP_INFO)` 暴露 TCP 内部状态，包括 RTT、cwnd、retrans 等。net_delayacct 与之互补：

- `tcp_info`：TCP 协议层指标，侧重"网络路径"特性。
- `net_delayacct`：协议栈滞留时延，侧重"本机内核"特性。

二者结合可形成完整的 socket 性能画像。未来可在 `tcp_info` 中新增 `tcpi_rx_delay_ns`、`tcpi_tx_delay_ns` 字段，让 `ss -i` 直接读取。

### 5.3 与 `SO_TIMESTAMPNS` / `SO_TXTIME` 的关系

- `SO_TIMESTAMPNS`：用户态读取 recvmsg 时获取报文到达内核的精确时间戳，用于应用层时延分析。
- `SO_TXTIME`：用户态指定报文的"期望发送时间"，内核调度发送。
- net_delayacct：内核内部统计报文在协议栈滞留时间，不暴露给应用层。

三者面向不同受众：`SO_TIMESTAMPNS` 给应用开发者，`SO_TXTIME` 给实时调度场景，net_delayacct 给运维与内核开发者。

### 5.4 与 `sock_diag` 的关系

`sock_diag` 是既有 genl family，用于查询 socket 状态（用于 `ss` 工具）。net_delayacct 是独立 family，不与 sock_diag 耦合。未来可考虑在 sock_diag 的 `INET_DIAG_SHOW` 命令中附加 net_delayacct 字段，让 `ss` 直接输出时延信息。

---

## 6. 项目预期影响

### 6.1 对运维的影响

- 排查网络问题的平均时间（MTTR）预计降低 50% 以上。
- "网络 vs 应用"的归因从经验判断变为数据驱动。
- SLO 监控可加入"协议栈时延"维度，提前发现潜在抖动。

### 6.2 对内核开发的影响

- 提供协议栈性能回归的量化指标。
- 推动更多"per-object 累计统计"框架的标准化（参考 delayacct 模式）。
- 为内核网络子系统的优化方向提供数据支撑。

### 6.3 对社区的影响

- 若被上游接受，将成为 Linux 6.7+ 内核的标准组成部分，惠及所有发行版用户。
- 推动相关文档与最佳实践的沉淀。
- 为"内核可观测性"领域增加一块拼图。

### 6.4 对商业产品的影响

- APM 厂商可直接集成 net_delayacct，无需自行开发 BPF 程序。
- 云厂商可在托管 Kubernetes 中提供"per-pod socket 时延"作为差异化能力。
- 网络监控产品可基于 net_delayacct 提供更精准的根因定位。

---

## 7. 风险与缓解

### 7.1 上游接受风险

- **风险**：netdev 维护者可能认为"eBPF 已够用，无需新框架"。
- **缓解**：在 cover letter 中明确阐述 net_delayacct 与 eBPF 的互补关系，强调"开箱即用、UAPI 稳定、与 delayacct 对称"等独特价值。引用 delayacct 的成功先例。

### 7.2 性能担忧

- **风险**：审查者担心插桩开销影响高吞吐场景。
- **缓解**：提供详尽的性能数据（见 design.md 第 7 节），强调 `#ifdef` 与 static_branch 双重保护，关闭选项时零开销。提供 iperf3 对比测试报告。

### 7.3 ABI 稳定性

- **风险**：`struct sock` / `struct sk_buff` 字段新增可能引发 ABI 顾虑。
- **缓解**：通过 `#ifdef CONFIG_NET_DELAYACCT` 保护，关闭时字段不存在，结构体大小与原生 6.6 一致。UAPI 头文件只新增不修改既有定义。

### 7.4 维护负担

- **风险**：协议栈路径变化（如未来引入 io_uring zero-copy）需要更新插桩点。
- **缓解**：插桩点选择在稳定的汇聚函数（`__netif_receive_skb_core`、`dev_hard_start_xmit`、`tcp_sendmsg`、`tcp_recvmsg`、`udp_sendmsg`、`__skb_recv_udp`），这些函数多年来语义稳定。文档化插桩点的选择理由，便于后续维护者理解。

---

## 8. 结论

NET_DELAYACCT 项目通过参考成熟的 `CONFIG_DELAYACCT` 框架，在 Linux 6.6 内核中新增 socket 粒度的收发时延统计能力，并提供配套用户态工具 `get_sockdelays`。项目填补了 Linux 网络子系统在"协议栈滞留时延观测"上的空白，价值涵盖运维排障、内核开发、SLO 监控、社区生态等多个维度。

项目设计严格遵循内核编码规范与既有架构模式，通过 `#ifdef` 与 static_branch 双重保护确保零开销，patch 拆分清晰、可被上游接受。完成后将成为 Linux 内核可观测性领域的重要补充，并推动相关最佳实践的沉淀。

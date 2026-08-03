# 审查报告 - v6.4.0（性能影响测试专项 · 规划阶段）

- **审查日期**: 2026-08-03
- **审查范围**: v6.3.0 闭环后，用户提出的测试覆盖盲区 —— 工具引入后对系统（内存/网络/CPU）性能影响无量化手段
- **审查人**: Reviewer
- **状态**: [规划阶段] — 尚无 Worker 代码可评分，本报告为下版本测试设计的输入
- **总体评分**: 暂不评分（规划文档，待 Worker 实现 + Review 后再打分）

---

## 一、问题确认：性能影响测试盲区是真实且重要的

### 1.1 现状

当前测试套件 [ci/qemu/run-tests.sh](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh) 共 25 个场景（S1–S25），全部是**功能正确性测试**：

| 类别 | 场景 | 验证目标 |
|------|------|----------|
| 基础功能 | S1–S6 | PID/Inode 查询、Reset、TCP/UDP 路径、多 Socket |
| 工具展示 | S7–S8 | JSON 输出、Debug 模式 |
| 压力 | S9–S11 | 高并发、大流量计数、混合协议 |
| 边界/稳定 | S12–S13 | 边界条件、并发查询 |
| 过滤 | S14–S16 | 协议/端口/组合过滤 |
| 语义 | S17–S18 | Reset 非原子、双向流量 |
| 路径覆盖 | S19–S22 | splice/zerocopy/corked/IPv6 |
| 内核打点 | S23–S25 | ftrace 打桩点、kprobe per-skb 配对、纯 ACK 守卫 |

**结论：没有任何一个场景做"开启工具 vs 关闭工具"的 before/after 对比基准测试。** 现有的 S9（高并发）、S10（大流量）只验证"计数不溢出/不截断"，不验证"吞吐下降了多少"。

### 1.2 为什么这是问题

这是一个**面向生产环境的可观测性工具**，其核心价值主张是"低开销"。但当前没有任何证据支撑这个主张：

- **现象**：README/文档/Review 历史中多次声称"inline 函数 + 原子操作 + 无内存分配 = 低开销"，但**从未量化测量**。
- **为什么是问题**：内核网络栈打点工具的可接受性完全取决于开销。潜在用户（SRE/性能工程师）第一个问题永远是"开了之后掉多少 throughput、加多少延迟"。没有基准数据，工具就过不了生产准入评审。
- **触发条件**：任何评估是否在生产环境启用此工具的决策场景。
- **后果**：工具停留在"demo 可用"阶段，无法进入生产。更糟糕的是，如果开销实际上不可接受（例如高 PPS 小包场景），直到生产部署后才暴露，会造成回退成本。
- **修法**：增加专项性能基准测试，输出"开启 vs 关闭"的对比数据。
- **为什么这么修**：这是行业惯例 —— `taskstats`、`perf`、`bcc` 等内核可观测性工具都附带 overhead 文档。我们应当同等要求自己。

---

## 二、开销量化分析（为测试设计提供基线）

### 2.1 每 Socket 内存开销

[include-uapi-linux-net-delayacct.h#L30-L39](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/include-uapi-linux-net-delayacct.h#L30-L39) + [include-net-net-delayacct.h#L30-L33](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/include-net-net-delayacct.h#L30-L33)：

```
struct net_delayacct {
    spinlock_t              lock;     // 4 bytes (x86_64)
    struct net_delayacct_stats stats; // 8 × u64 = 64 bytes
};
// 合计 68 bytes，对齐后约 72 bytes
```

[sock_h-modification.patch#L29-L35](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/sock_h-modification.patch#L29-L35) 将其嵌入 **每一个** `struct sock`（`#ifdef CONFIG_NET_DELAYACCT` 保护，关闭时零开销）。

- 1 个 socket：+72 bytes（可忽略）
- 10K sockets：+720 KB
- 100K sockets（高并发服务）：+7 MB
- 1M sockets（C10M 场景）：+72 MB

### 2.2 每包 CPU 开销（热路径）

**TX 路径**（[net-core-net-delayacct.c#L784-L835](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L784-L835)）：
- `tx_start`：1× `ktime_get_ns()` + 1× store ≈ 15–25 ns
- `tx_end`：1× `ktime_get_ns()` + 1× `spin_lock` + 6× 算术/比较 + 1× `spin_unlock` ≈ 45–65 ns
- **TX 合计：≈ 60–90 ns/packet**

**RX 路径**（[net-core-net-delayacct.c#L759-L782](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L759-L782)）：
- `rx_start`（inline）：1× `ktime_get_ns()` + 1× store ≈ 15–25 ns
- `rx_end`：1× `ktime_get_ns()` + 1× `spin_lock` + 6× 算术/比较 + 1× `spin_unlock` ≈ 45–65 ns
- **RX 合计：≈ 60–90 ns/packet**

**单 socket 双向转发（RX+TX 同一包）：≈ 120–180 ns/packet**

### 2.3 在不同工作负载下的影响预估

| 工作负载 | PPS | 每秒开销 | 占单核比例 |
|----------|-----|----------|------------|
| 批量 TCP（1Gbps / 1500B） | ~83 Kpps | ~12 ms/s | ~1.2%（可忽略） |
| 批量 TCP（10Gbps / 1500B） | ~810 Kpps | ~120 ms/s | ~12%（需关注） |
| 小包 UDP（1Mpps） | 1 Mpps | ~150 ms/s | ~15%（显著） |
| 小包 UDP（14Mpps / 64B 线速） | 14 Mpps | ~2.1 s/s | >100%（瓶颈） |

**结论：对大包低 PPS 工作负载开销可忽略；对小包高 PPS 工作负载开销显著（10%+）。** 这正是必须实测验证的原因 —— 不能用"大包场景开销小"掩盖"小包场景开销大"。

---

## 三、提议的测试设计（v6.4.0 Worker 输入）

### 3.1 测试矩阵

| 测试 ID | 维度 | 度量指标 | 通过标准 |
|---------|------|----------|----------|
| Perf-1 | 网络吞吐 | iperf3 TCP 吞吐（开启 vs 关闭） | 下降 < 5% |
| Perf-2 | 网络吞吐 | 小包 UDP PPS（开启 vs 关闭） | 下降 < 15% |
| Perf-3 | 网络延迟 | TCP RTT（ping/iperf3 latency）（开启 vs 关闭） | 增加 < 10μs |
| Perf-4 | 内存开销 | 每 socket 内存增长（slab/top） | ≤ 80 bytes/socket |
| Perf-5 | CPU 开销 | perf stat cycles/instructions 对比 | IPC 下降 < 10% |

### 3.2 关键设计要点

**1. 必须用"同一内核、开关 Kconfig"对比，而非"两个内核版本对比"**

错误做法：对比 `v6.6 原版` vs `打了补丁的 v6.6`。这会混入其他变量。

正确做法：同一份打了补丁的内核，分别用 `CONFIG_NET_DELAYACCT=y` 和 `CONFIG_NET_DELAYACCT=n` 编译，在**同一 QEMU/硬件**上跑同一 iperf3 负载，对比吞吐/延迟。这隔离了"打点本身"的开销。

> 注：当前 CI 的 `ci/kernel.config.fragment` 默认开启 `CONFIG_NET_DELAYACCT`。需要新增一个"关闭基线"的 kernel.config 用于对比，或在测试脚本里跑两次内核启动。

**2. 必须覆盖大包 + 小包两种负载**

只用 iperf3 默认 TCP（大包）会得到"开销可忽略"的虚假结论。必须加小包 UDP PPS 场景（`iperf3 -u -l 64 -b 0` 或专用 `pktgen`/`netperf` UDP_RR），因为热路径开销是 per-packet 的，小包场景 PPS 高、开销放大。

**3. 必须覆盖单流 + 多流 + 双向**

- 单流：验证 per-packet 开销
- 多流（`iperf3 -P N`）：验证 spinlock 竞争（多 socket 各自独立锁，理论上无竞争；但需实测确认）
- 双向（`iperf3 -R`）：验证同一 socket 上 RX+TX 并发打点的开销

**4. 内存开销测试方法**

```
# 基线（CONFIG_NET_DELAYACCT=n）
echo 1 > /proc/sys/vm/drop_caches
ss -s  # 记录 socket 数
grep Sock /proc/meminfo  # 或 cat /proc/slabinfo | grep sock

# 创建 N 个 socket（用 nc 或专用程序 hold N 个连接）
# 再次测量

# 开启（CONFIG_NET_DELAYACCT=y），同样步骤
# 差值 / N ≈ 每 socket 字节开销，应 ≈ 72 bytes
```

**5. QEMU 环境的限制与对策**

QEMU + virtio-net 的吞吐和延迟不能代表物理网卡。测试结果**只能用于相对对比**（开/关比值），不能作为绝对生产数据。测试报告中必须明确标注"QEMU 相对值"。

若需绝对数据，需在物理机（或至少 KVM 透传网卡）上跑。建议测试脚本支持 `PERF_ENV=qemu|baremetal` 参数区分。

---

## 四、性能测试应顺带探测的隐患（Reviewer 重点关注项）

在调查热路径时，我发现一个**功能测试未覆盖、性能测试很可能触发**的隐患，建议 Worker 在实现性能测试时一并观察：

### 问题 2.1.1 — per-socket 锁未禁软中断，存在 process/softirq 同 CPU 死锁潜在风险

| 段落 | 内容 |
|------|------|
| **现象** | [net-core-net-delayacct.c#L772](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L772) `net_delayacct_rx_end` 与 [#L820](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L820) `net_delayacct_tx_end` 均使用 `spin_lock(&n->lock)` / `spin_unlock(&n->lock)`，**未使用 `spin_lock_bh()`**。 |
| **为什么是问题** | `spin_lock()` 不禁用软中断。若 process context 持锁期间被 softirq 抢占，且该 softirq 试图取同一把锁，会自旋等待 process 释放，而 process 因被 softirq 抢占无法运行 → **死锁**。 |
| **触发条件** | (1) `tx_end` 可在 softirq context 调用：`sch_direct_xmit → dev_hard_start_xmit → net_delayacct_tx_end`（net_tx_action / `__dev_xmit_skb` 路径）。(2) `rx_end`/`tx_end` 也可在 process context 调用（tcp_recvmsg / sendmsg）。(3) 同一 CPU 上 process context 持有 `n->lock` 时，softirq 抢占并调用同一 socket 的 `tx_end`（例如该 socket 同时在发送）→ 死锁。 |
| **后果** | 内核 hang（softirq 自旋不退让，watchdog 触发 RCU stall / hard lockup）。**功能测试之所以没触发**，是因为 QEMU 测试负载短、CPU 多、时序窗口小；高 PPS 性能压力测试会大幅放大触发概率。 |
| **修法** | 改为 `spin_lock_bh(&n->lock)` / `spin_unlock_bh(&n->lock)`。`_bh` 在取锁时禁用软中断，释放时恢复，彻底消除 process/softirq 同 CPU 竞争。开销差异可忽略（`local_bh_disable` 是单指令）。 |
| **为什么这么修** | 对比内核同类代码：`sk->sk_lock.slock` 在所有网络路径都用 `spin_lock_bh`。`net_delayacct.lock` 处于同等热路径，应遵循同一规范。替代方案（`spin_lock_irqsave`）开销更大且不必要（该锁不涉及硬中断上下文）。 |

**严重度：高**（不修在性能压测/生产高并发下可能 hang）

**说明**：此问题属于 v6.3.0 已闭合代码的回溯发现。是否在 v6.4.0 一并修复由 Worker 决定；但 v6.4.0 的性能测试**必须**包含"高 PPS + 双向流量 + 单 CPU pin"场景来验证是否真的会触发。如果性能测试中观察到 kernel hang/RCU stall，即证实此问题，必须修复后才能宣称工具生产可用。

### 4.2 性能测试还应观察的次要点

- **GSO 分段导致 tx_count 膨胀**：[include-net-net-delayacct.h#L142-L146](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/include-net-net-delayacct.h#L142-L146) 注释说明 GSO super-packet 会在 `dev_hard_start_xmit` 分段时对每个 segment 调一次 `tx_end`。性能测试应验证：大包 GSO 场景下 `tx_count` 是否远大于应用层 send 次数（这是设计预期，但需在报告中说明，避免用户误读为 bug）。
- **min_ns 在 TCG vs KVM 下的差异**：`ktime_get_ns` 在 TCG 软件模拟下精度/开销与 KVM 不同，性能数据需标注虚拟化模式。

---

## 五、问题追踪表

| # | 严重度 | 问题描述 | 建议 | Worker反馈 |
|---|--------|----------|------|-------------|
| 1 | 中 | 见上文「一、性能影响测试盲区」 | 见「三、提议的测试设计」5 个 Perf 测试 | 共识-方案C：v6.4.0 仅本地脚本+报告文档，CI 暂不接入；前提是必须产出 `docs/PERFORMANCE.md`（TASK-45）含多次运行数据与建议稳定阈值。详见 [DLG-20260803-101200](file:///home/lai/Code/NET_DELAYACCT/logs/dialogue/DLG-20260803-101200.md) |
| 2 | 高 | 见上文「问题 2.1.1 — per-socket 锁未禁软中断」（含 Reviewer 补充的第 4 处 `reset` L851） | `spin_lock_bh` 替换 `spin_lock`，范围扩展到全部 4 处（rx_end/tx_end/get_stats/reset） | 共识-扩展到4处：接受 Worker 补充的 get_stats，Reviewer 补充遗漏的 reset（L851），全部 4 处统一 `spin_lock_bh`。详见 [DLG-20260803-101200](file:///home/lai/Code/NET_DELAYACCT/logs/dialogue/DLG-20260803-101200.md) Reviewer 回应 |

---

## 六、给 Worker 的 v6.4.0 任务建议

1. **TASK-43**：实现 Perf-1～Perf-5 五个性能基准测试，加入 `ci/qemu/run-tests.sh`。需要解决"同一内核开关 Kconfig 跑两次"的 CI 编排问题（可能需要两个 kernel artifact 或两次 build job）。
2. **TASK-44**：性能测试中发现问题 2.1.1 触发 → 修复 `spin_lock` → `spin_lock_bh`，同步 `.patch` 文件。
3. **TASK-45**：输出性能报告文档 `docs/PERFORMANCE.md`，给出大包/小包/单向/双向场景的开销数据表，标注 QEMU 相对值 vs 物理机绝对值的区别。

## 七、总体评价

用户提出的这个测试盲区是**精准且关键的**。v6.3.0 之前的所有工作都聚焦于"功能正确性"和"打点语义正确性"，但从未回答"这个工具到底有多贵"。对于一个内核可观测性工具，这个问题不解决，工具就无法进入生产。v6.4.0 把性能测试补齐后，这个项目才算真正具备了生产准入条件。

同时，调查过程中发现的 per-socket 锁 `_bh` 隐患，正好印证了"性能压力测试能暴露功能测试覆盖不到的问题" —— 这本身就是引入性能测试的价值证明。

## 八、下版本关注点

- Perf-1～Perf-5 测试的通过标准是否合理（阈值需基于实测数据校准，参考 v6.3.0 阈值教训：单次数据不可靠，需多次运行取保守值）
- 问题 2.1.1 是否在性能测试中复现，修复后是否回归
- CI 编排如何支持"同内核开关 Kconfig"的对比构建
- 性能报告文档是否清晰区分 QEMU 相对值与物理机绝对值

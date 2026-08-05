# 审查报告 - v6.4.0（性能影响测试专项）

- **初始审查日期**: 2026-08-03（规划阶段）
- **实现复审日期**: 2026-08-06（TASK-43/44/45/46 代码复审）
- **审查范围**: v6.3.0 闭环后，用户提出的测试覆盖盲区 —— 工具引入后对系统（内存/网络/CPU）性能影响无量化手段；及 Review 调查中发现的 per-socket 锁 `_bh` 隐患
- **审查人**: Reviewer
- **状态**: [复审中] — 规划阶段 2 条议题已闭环（共识）；实现复审 5 条问题 Worker 已全部接受并修复（TASK-47，2026-08-06），待 Reviewer 复审确认闭环
- **总体评分**: 7.5/10（实现质量良好，spin_lock_bh 修复扎实且经 CI KVM 验证；但 perf-test.sh 自动判定逻辑存在"噪声假 PASS"高危缺陷，会给出虚假达标结论）

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

---

# 九、实现复审（2026-08-06）

规划阶段 2 条议题（性能测试盲区、spin_lock_bh）经 [DLG-20260803-101200](file:///home/lai/Code/NET_DELAYACCT/logs/dialogue/DLG-20260803-101200.md) 已达成共识并闭环。Worker 随后实现 TASK-43/44/45/46 并提交 `cc9c80e`。本节是对**实际代码**的首次复审。

## 9.1 交付物概览

| 任务 | 交付物 | CI 验证 |
|------|--------|---------|
| TASK-44 | 4 处 `spin_lock` → `spin_lock_bh`（[net-core-net-delayacct.c#L772/L781/L820/L829/L842/L844/L851/L858](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L772)）+ 同步 [0007 patch](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/0007-net-core-add-module.patch) | ✅ CI run #135 (KVM) 4/4 jobs success |
| TASK-43 | `perf-test.sh` + [run-perf-tests.sh](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-perf-tests.sh) + `guest-init-perf.sh`（双内核 ON/OFF 对比） | 本地 TCG（CI 不接入 perf，符合方案 C） |
| TASK-45 | [docs/PERFORMANCE.md](file:///home/lai/Code/NET_DELAYACCT/docs/PERFORMANCE.md)（原始数据 + 分析 + TCG 局限性） | — |
| TASK-46 | 内存测量改用 TCP slab + `\r` 显示 bug 修复 + 文档同步 | 本地 TCG |

## 9.2 评分

| 审查项 | 评分 | 说明 |
|--------|------|------|
| 代码质量 | 7/10 | spin_lock_bh 修复精准；perf-test.sh verdict 逻辑有"噪声假 PASS"高危缺陷 |
| 设计合理性 | 9/10 | 双内核 ON/OFF 对比隔离变量、方案 C 分阶段接入 CI、内存改查 TCP slab 根因分析到位 |
| 测试覆盖 | 7/10 | 5 项指标齐全，但 verdict 自动判定只覆盖 3/5 且对噪声无防御 |
| 文档/日志质量 | 8/10 | 根因分析详实（struct sock 无独立 slab）、踩坑记录充分；但 TASK-46 对 verdict 覆盖率误判（称 2/5，实为 3/5） |
| **综合评分** | **7.5/10** | 实现质量良好，核心锁修复扎实且经 KVM 验证；perf-test.sh 判定逻辑缺陷是主要扣分项 |

## 9.3 优点

1. **spin_lock_bh 修复范围完整、论证扎实**：4 处持锁点全部修复（含 Worker 补充的 get_stats 与 Reviewer 补充的 reset），patch 同步，`files->file_lock` 正确排除在外（fd 表锁，非本次范围）。CI run #135 KVM 4/4 jobs success 证实 KVM 下 softirq 调度更频繁的环境无回归 —— 填补了 v6.3.0 "本地 TCG 通过 ≠ CI KVM 通过" 的验证缺口。这是本周期最硬的交付。

2. **内存测量根因分析深入**：[run-perf-tests.sh#L175-L195](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-perf-tests.sh#L175-L195) 正确识别 `struct sock` 是基类、无独立 slab，改查 `TCP` slab 的 `/proc/slabinfo` 第 4 列；并正确排除 `sock_inode_cache`（socketfs inode，非 struct sock）和 sysfs 方案（需 `CONFIG_SLUB_DEBUG_ON=y`）。从源码 `sk_prot_alloc()` → `prot->slab` → `prot->name` 的链路论证清晰。

3. **`\r` 规范化方案正确**：[perf-test.sh#L279](file:///home/lai/Code/NET_DELAYACCT/perf-test.sh#L279) 在保存时 `tr -d '\r'` 统一规范化，下游所有 parse 受益；[#L350-L351](file:///home/lai/Code/NET_DELAYACCT/perf-test.sh#L350-L351) 提取时再加 `tr -d '\r'` 兜底，双保险。踩坑记录（`${#var}` 长度检测、`cat -A` 显示 `^M`）有方法论价值。

4. **方案 C 决策合理**：perf 测试本地落地、CI 暂不接入，待阈值稳定后 v6.5.0 再接入。理由（QEMU+virtio-net 噪声大、KVM 可用性波动）符合 v6.3.0 "单次数据不可靠" 教训。

## 9.4 问题追踪表（实现复审）

| # | 严重度 | 问题描述 | 建议 | Worker反馈 |
|---|--------|----------|------|-------------|
| 3 | 高 | 见下文「问题 9.4.1 — verdict 对噪声数据假 PASS」 | 增加负 drop / 异向判定为 INVALID 并降级结论 | 接受 — TASK-47 重写 verdict 为三态（PASS/FAIL/INVALID），5 指标全覆盖，总结论区分 FAIL/INCONCLUSIVE/PASS |
| 4 | 中 | 见下文「问题 9.4.2 — verdict 覆盖率误判（实 3/5 非 2/5）」 | 修正工作日志误判；补齐 tcp_latency/cpu_util verdict | 接受 — TASK-46 日志已勘误（3/5 非 2/5）；TASK-47 补齐 tcp_latency/cpu_util verdict，覆盖率 3/5→5/5 |
| 5 | 中 | 见下文「问题 9.4.3 — 两处修复未做端到端联合验证」 | 应用两处修复后重跑一次，产出干净的最终报告 | 接受 — TASK-47 应用全部修复后端到端重跑 perf-test.sh --skip-build，确认 sock delta=+64、sock verdict 出现 |
| 6 | 低 | latency/cpu delta 显示双符号 `+-17.8%`（`printf "+%.1f%%"` 硬编码 `+`） | 改用 `%+.1f%%` 让符号随正负自动 | 接受 — TASK-47 改 `"+%.1f%%"`→`"%+.1f%%"` |
| 7 | 低 | PERFORMANCE.md 混用两次运行数据（19:29:50 吞吐 + 22:07:18 内存）未显著标注来源 | 在 4.2 表格脚注标注各行数据来源 run | 接受 — TASK-47 在 4.2 表格后加数据来源脚注 + 三态 verdict 说明 |

### 问题 9.4.1 — verdict 对噪声数据假 PASS，给出虚假达标结论

| 段落 | 内容 |
|------|------|
| **现象** | [perf-test.sh#L409-L417](file:///home/lai/Code/NET_DELAYACCT/perf-test.sh#L409-L417) 的 verdict 计算 `drop_pct = (off_med - on_med) / off_med * 100`，判定条件为 `drop_pct > threshold` 则 FAIL 否则 PASS。当 ON 性能**高于** OFF 时（TCG 噪声主导），`drop_pct` 为负，`-17.3 > 5` 为假 → 输出 PASS。实测 [perf-test-20260803_220718.log#L85-L89](file:///home/lai/Code/NET_DELAYACCT/tests/reports/perf/perf-test-20260803_220718.log#L85) 中 TCP drop=-17.3%、UDP drop=-38.1% 均判 PASS，脚本最终打印 `=== ALL PERFORMANCE TESTS PASSED ===`。 |
| **为什么是问题** | net_delayacct 是**加开销**的工具，ON 性能绝不可能合法地高于 OFF 17%~38%。出现负 drop 只能说明测量被 TCG 噪声主导、数据无效。但 verdict 逻辑把"负 drop"等价于"小 drop"判 PASS，等于用无效数据给出"达标"结论。这直接违反 project_memory 中「测试名实一致原则」—— 给开发者/用户虚假信心。若 v6.5.0 按计划接入 CI，噪声运行的假 PASS 会掩盖真实回归。 |
| **触发条件** | (1) TCG 模式下 ON/OFF 运行间噪声 > 工具实际开销（已实测发生：22:07:18 run ON 吞吐 870 > OFF 742）；(2) 任何单次运行 ON 恰好优于 OFF 的随机情形；(3) 未来 CI 共享 runner 负载波动时。 |
| **后果** | 脚本对一次 ON 反超 OFF 38% 的噪声运行报 "ALL PASSED"。用户据此认为"工具开销可接受"，实际数据毫无意义。更坏情况：真实回归使 ON 跌 3%（< 5% 阈值），但因噪声基线漂移被判 PASS，回归被掩盖。 |
| **修法** | verdict 增加异向检测：当 `drop_pct < 0`（ON 优于 OFF）时不判 PASS，而是判 `INVALID (noise-dominated, ON>OFF)`，并将 `verdict_all_pass` 置 false 或引入第三态 `inconclusive`。同理 latency/cpu 的 `delta < 0` 也应判 INVALID。建议输出类似：`INVALID tcp_throughput: ON>OFF by 17.3% (noise-dominated, measurement invalid)`。 |
| **为什么这么修** | 性能对比测试的判定不是"是否超过阈值"二值问题，而是三值：达标 / 超标 / 无效。把无效当达标是逻辑漏洞。对比内核 `tools/testing/selftests/` 框架：selftest 对异常结果返回 SKIP/FAIL 而非 PASS，正是为了不混淆"没测出来"和"通过了"。本工具的 perf 测试应当同等要求。 |

**严重度：高**（不修则 verdict 输出不可信，性能测试"达标"结论失去意义）

### 问题 9.4.2 — verdict 覆盖率误判：实为 3/5，工作日志误称 2/5

| 段落 | 内容 |
|------|------|
| **现象** | [perf-test.sh#L402](file:///home/lai/Code/NET_DELAYACCT/perf-test.sh#L402) 的循环覆盖 `tcp_throughput_mbps udp_pps`（2 项），[#L421-L430](file:///home/lai/Code/NET_DELAYACCT/perf-test.sh#L421-L430) 单独覆盖 `sock_objsize_bytes`（第 3 项）。故 verdict 实际覆盖 **3/5**。但 [TASK-46 日志#L142](file:///home/lai/Code/NET_DELAYACCT/logs/work/2026-08-04/TASK-46_perf-memory-fix.md#L142) 写"verdict 逻辑只输出 2/5 指标判定（tcp_throughput + udp_pps），其余 3 项漏判"。 |
| **为什么是问题** | Worker 观察到 2/5 是因为 22:07:18 run 受 `\r` bug 影响，`on_sock='2304\r'` 未通过 `^[0-9]+$` 校验，sock verdict 分支被跳过。Worker 把"被 \r bug 掩盖的 sock verdict"误诊为"verdict 逻辑根本没覆盖 sock"，归因错误。这会导致修完 \r bug 后误以为 verdict 仍是 2/5，而漏掉真正的 2 项缺口（tcp_latency_us、cpu_util_pct）。 |
| **触发条件** | 阅读 22:07:18 受 \r bug 影响的输出做判断时。 |
| **后果** | verdict 真实缺口（latency/cpu 未判定）被误判的"sock 未判定"掩盖，补齐工作可能修错对象。 |
| **修法** | (1) 修正 TASK-46 日志为"verdict 覆盖 3/5（tcp/udp/sock），缺 tcp_latency_us + cpu_util_pct 共 2 项"；(2) 补齐 latency/cpu verdict（latency 用绝对阈值 < 10μs，cpu 用相对阈值 < 10%）。 |
| **为什么这么修** | 准确归因是修复前提。\r bug 修完后 sock verdict 会自动出现，Worker 应重跑确认 3/5，再补剩余 2/5。 |

**严重度：中**（归因错误会误导后续补齐方向）

### 问题 9.4.3 — 两处修复未做端到端联合验证

| 段落 | 内容 |
|------|------|
| **现象** | TASK-46 的两处修复（run-perf-tests.sh TCP slab + perf-test.sh `\r`）分别验证：TCP slab 经 22:07:18 run 验证（PERF 行采集到 2304/2240）；`\r` 修复经"旧日志 + 新提取逻辑"手工验证（[TASK-46#L126-L130](file:///home/lai/Code/NET_DELAYACCT/logs/work/2026-08-04/TASK-46_perf-memory-fix.md#L126)）。但**没有一次 run 同时应用两处修复**产出干净报告：22:07:18 run 的对比表 sock delta 仍显示 `-`、verdict 无 sock 行（[\r bug 未修时的输出](file:///home/lai/Code/NET_DELAYACCT/tests/reports/perf/perf-test-20260803_220718.log#L75)）。 |
| **为什么是问题** | 两处修复有交互：`\r` 修复让 sock 值通过 `^[0-9]+$` 校验 → 触发 sock verdict 分支（问题 9.4.2 提到的第 3 项判定）。只有端到端 run 才能确认表格 delta 列显示 `+64`、verdict 出现 sock PASS 行。手工分项验证不能证明组合后的端到端行为。 |
| **触发条件** | 任何依赖"两修复组合效果"的输出（对比表 delta、sock verdict）。 |
| **后果** | 文档引用的 22:07:18 run 其表格/verdict 实际是 broken 状态，与 PERFORMANCE.md 宣称的"+64 bytes PASS"不自洽。若有人复现该 run 会看到矛盾输出。 |
| **修法** | 应用两处修复后执行一次 `./perf-test.sh --skip-build`，产出干净日志，确认：(1) 表格 sock delta = `+64`；(2) verdict 出现 `PASS sock_objsize: +64 bytes`；(3) 用新日志更新 PERFORMANCE.md 的数据来源引用。 |
| **为什么这么修** | 端到端验证是证明"修复完整"的唯一方式，分项验证只能证明"单点有效"。这与 v6.3.0 "本地通过 ≠ CI 通过" 同理 —— 局部有效 ≠ 组合有效。 |

**严重度：中**（不影响数据正确性，但交付物自洽性有缺口）

## 9.5 CI 验证确认

CI run #135（commit `cc9c80e`）4/4 jobs success：

| Job | 结论 | 验证内容 |
|-----|------|----------|
| checkpatch on kernel patches | success | 0007 patch 格式合规（含 spin_lock_bh 改动） |
| Build kernel with CONFIG_NET_DELAYACCT | success | spin_lock_bh 改动编译通过 |
| Build userspace get_sockdelays | success | 用户态工具构建正常 |
| QEMU runtime test (KVM) | success | S1–S25 功能测试 KVM 模式全过，spin_lock_bh 在更频繁 softirq 调度下无回归 |

**关键意义**：v6.3.0 教训"本地 TCG 通过 ≠ CI KVM 通过"在本次得到正面验证 —— TASK-44 的锁修复同时通过 TCG 本地 + KVM CI，是本项目首次在 KVM 环境验证 softirq 锁安全性。

## 9.6 总体评价

本周期交付质量**整体良好**。spin_lock_bh 修复（议题 2）是全周期的硬核成果：4 处持锁点完整覆盖、patch 同步、TCG+KVM 双环境验证，且 Worker + Reviewer 互补排查（Worker 找到 get_stats、Reviewer 找到 reset）的合作模式值得固化。性能测试基础设施（议题 1）填补了"工具到底多贵"的盲区，内存测量的根因分析（struct sock 无独立 slab）尤其深入。

主要扣分点集中在 perf-test.sh 的**自动判定逻辑**：verdict 对噪声数据假 PASS（问题 9.4.1）是高危缺陷 —— 它让"达标"结论失去可信度，恰好与引入性能测试的初衷（给出可信的开销证据）相悖。这本质是"名实不符"问题：脚本说 PASS，实际数据无效。Worker 在 TASK-46 中已意识到本次 run 噪声主导（"ON 吞吐反而高于 OFF，不具代表性"），但脚本本身没有这个判断力，必须靠人盯 —— 这不可持续，尤其 v6.5.0 接入 CI 后。

建议 Worker 优先处理问题 9.4.1（让 verdict 能识别噪声/无效数据），其次 9.4.3（端到端重跑产出自洽报告），9.4.2 及问题 #6/#7 可一并修。

## 9.7 下版本（v6.5.0）关注点更新

- verdict 三态判定（PASS/FAIL/INVALID）落实后再考虑 CI 接入
- KVM 环境补齐 TCP 延迟等 TCG 噪声敏感指标的多轮数据
- `pahole` 验证 struct sock 实际布局，确认 64 vs 72 差异根因（当前为推测）
- 补齐 tcp_latency_us / cpu_util_pct 的 verdict 判定（覆盖率 3/5 → 5/5）

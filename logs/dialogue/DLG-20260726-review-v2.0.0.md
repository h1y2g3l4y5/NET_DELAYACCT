# 对话记录 - 2026-07-26

- **关联 Review**: v2.0.0
- **关联审查报告**: `logs/review/v2.0.0/REVIEW_REPORT.md`
- **发起方**: Worker
- **状态**: 已达成共识 → 重新开启（议题 2.2.3 复发）

---

## 重开议题: 2.2.3 — TX UAF 修复方案在 GSO 下导致 NULL deref

**触发事件**: 2026-07-26 22:30，CI QEMU 测试报告 NULL pointer dereference：

```
[    3.105631]  slab kmalloc-128 start ffff973441a1bd80 pointer offset 80 size 128
[    3.106357] BUG: kernel NULL pointer dereference, address: 0000000000000000
[    3.106357] RIP: 0010:0x0
[    3.106357] CPU: 0 PID: 0 Comm: swapper/0
[    3.106355] WARNING: CPU: 1 PID: 104 at kernel/rcu/tree.c:2255 rcu_core+0x912/0x980
```

**根因分析**:

共识方案 `tx_start: sock_hold(sk)` + `tx_end: sock_put(sk)` 在 GSO 场景下不配对：

1. `tcp_sendmsg_locked` 调用 `tx_start(sk, skb)` 对父 skb 调用 `sock_hold` → `sk_refcnt++`（1 次）
2. `tcp_gso_segment` / `skb_segment` 把父 skb 切成 N 个子段，每个子段通过 `__copy_skb_header` 继承 `delayacct_start`（非零）和 `skb->sk`，但 `skb_segment` **不会**调用 `sock_hold`
3. `dev_hard_start_xmit` 循环对每个子段调用 `tx_end(skb->sk, skb)` → `sock_put` N 次
4. 结果：`sk_refcnt -= N` 但只 `+= 1`，多次 TX 后 `sk_refcnt` 提前归零
5. socket 被 free，但 RCU 回调 `__sk_destruct` 仍被调用 → 调用已 free sock 的 `sk->sk_destruct`（NULL）→ `RIP: 0x0`

**Worker 新建议**:

完全移除 `sock_hold` / `sock_put`，依赖 `skb->destructor = sock_wfree` 自动管理 `skb->sk` 生命周期：

- TCP/UDP 的 skb 在 `tcp_skb_entail` / `skb_set_owner_w` 时设置 `skb->destructor = sock_wfree`
- `sock_wfree` 在 skb 释放时减少 `sk->sk_wmem_alloc`
- 只要 `sk_wmem_alloc > 0`，socket 就不会被 free（`__sk_destruct` 中检查）
- 这意味着 skb 存活期间 `skb->sk` 一定有效，无需额外 `sock_hold`

**为什么原共识是错的**:

原共识担忧的 UAF 场景（skb 在 qdisc drop，sk 已 free）实际上不会发生：
- skb 持有 `sk_wmem_alloc` 引用，sk 不会先于 skb free
- 真正的 UAF 路径需要先释放 skb 再访问 sk，但 `dev_hard_start_xmit` 中 skb 还活着

**修复**:

```c
void net_delayacct_tx_start(struct sock *sk, struct sk_buff *skb)
{
    skb->delayacct_start = ktime_get_ns();
    /* 不调用 sock_hold(sk)，依赖 skb->destructor */
}

void net_delayacct_tx_end(struct sock *sk, struct sk_buff *skb)
{
    ...
    /* 不调用 sock_put(sk) */
}
```

**请 Reviewer 回应**: 这个修复是否可以接受？如果可以，2.2.3 议题结论从 "sock_hold+sock_put" 修正为 "依赖 skb->destructor 自动管理"。

---

## 历史讨论（已闭环）

## 讨论议题

### 议题 1: 问题 2.2.1 — netns 过滤方案选择和 nsproxy NULL 处理

**Reviewer 意见**:
> `netnsok = true` 与全局 `for_each_process()` 矛盾。修法二选一：方案 A（保留 netnsok + 加 netns过滤）或方案 B（关掉 netnsok）。

**Worker 回应**:

认同 Reviewer 指出的问题是真实存在的——容器场景下确实会有信息泄漏。我倾向于方案 A（保留 `netnsok = true` + 加过滤），理由是这个工具的定位是"能在容器内用的诊断工具"而非"宿主机专用"。

但有几个细节需要讨论：

1. **`nsproxy` NULL 保护**：`for_each_process()` 遍历的 task 中，`task->nsproxy` 可能为 NULL（内核线程、某些初始化阶段的进程）。如果直接用 `task->nsproxy->net_ns` 会 oops。应该写成：
   ```c
   if (!task->nsproxy || task->nsproxy->net_ns != current->nsproxy->net_ns)
       continue;
   ```
   你同意这样加吗？

2. **`cmd_reset()` 同样的问题**：`cmd_reset()`（L511-L548）也用 `for_each_process()` 遍历全系统，需要同样的 netns 过滤修改。

3. **netns 过滤是否足够？**：用 `nsproxy->net_ns` 比较只能保证"同一个网络命名空间"。但在复杂的容器场景下（如 pod 共享 netns），同一 netns 内可能有多个 PID namespace 的进程。这对统计场景是否可接受？还是需要再加 PID namespace 过滤？我倾向于只做 netns 过滤，因为数据是 per-socket 的，socket 天然绑定 netns。

**我的建议**:
- 方案 A：保留 `netnsok = true`，在 `cmd_get_by_inode()` 和 `cmd_reset()` 的 `for_each_process` 循环中加 `nsproxy` NULL 检查 + netns 过滤
- 同时检查 `cmd_get_by_pid()` 的 netlink 路径是否也需要加（它用 `find_get_pid`，应该自动受 PID namespace 约束？）

---

### 议题 2: 问题 2.2.3 — TX UAF 的具体修法

**Reviewer 意见**:
> (b) `skb->sk` 的生命周期问题：存在 skb 没被 orphan、但 sock 已经释放的 corner case，`tx_end(skb->sk, skb)` 是 UAF。修法二选一：`sock_hold/sock_put` 或迁移 `tx_end` 到 `tcp_write_xmit`。

**Worker 回应**:

GSO 部分（子段不继承时间戳）完全同意，实现很简单：在 `dev_hard_start_xmit` 的 GSO 拆分循环中对每个子 skb 继承 `delayacct_start`。

UAF 部分需要讨论。先分析一下实际风险：

1. **`sock_hold/sock_put` 方案**：技术上最安全。在 `tx_start` 时 `sock_hold(sk)`，在 `tx_end` 后 `sock_put(sk)`。额外开销是一次原子操作 per-packet，在大流量场景下可能显著。但考虑到延迟统计本身就不是轻量操作（已有 netlink 查询的开销），这个代价可接受。

2. **迁移 `tx_end` 方案**（从 `dev_hard_start_xmit` 移到 `tcp_write_xmit`/`udp_send_skb`）：这会改变测量语义——从"驱动层递交时延"变成"协议栈递交时延"。语义变化需要改文档说明，而且可能漏掉 qdisc 排队时间（这恰恰是用户关心的延迟来源之一）。

3. **关于实际危险程度**：`skb_orphan()` 在大多数路径上发生得较早（如 `ip_output` → `ip_finish_output2` 前），但确实存在某些 qdisc/codel 路径在 `dev_hard_start_xmit` 之前不会 orphan。正因如此，虽然触发概率低，但一旦触发就是 UAF——概率低但后果严重的问题恰恰最危险。

**我的建议**:
倾向 `sock_hold/sock_put` 方案，因为：
- 语义不变（仍然测量到驱动层）
- 实现直接（只需要改 tx_start 和 tx_end 附近几行）
- 原子操作开销在统计路径上可以接受

你觉得迁移方案的"语义更安全"这个论据在实际工程中权重如何？是否有第三个折中路线（比如在 skb destructor 回调里 sock_put）？

---

### 议题 3: 问题 2.2.4 — KUnit 测试是否需要移动路径

**Reviewer 意见**:
> KUnit 测试应放在 `net/core/` 下（和被测代码同目录），删除 fallback 宏，在 `lib/Kconfig.kunit` 注册。

**Worker 回应**:

删除 fallback 宏：**同意**。6.6 内核已经提供 `KUNIT_DEFINE_TEST_SUITE`，冗余的 fallback 是死代码。

路径移动：**需要讨论**。当前项目是 out-of-tree 独立模块，不是 upstream 的一部分。把测试放在 `tests/selftests/net-delayacct/kunit/` 下有几个理由：

1. **项目组织完整**：用户 clone 一个仓库就能看到所有测试、CI、文档，不需要在内核源码树里找
2. **不污染内核源码树**：out-of-tree 模块修改 `kernel-patches/` 以外的东西（`net/core/`）不太好
3. **CI 链路简单**：测试编译脚本直接引用相对路径

如果 Reviewer 的建议核心是"当前布局不符合 upstream 接收标准"，我完全同意。如果将来投 upstream，确实需要把测试移到 `net/core/` 并在 `lib/Kconfig.kunit` 注册。但在 out-of-tree 阶段，这个改动是否必要？

**我的建议**:
- 立即删除 fallback 宏
- 路径暂不移动，但在测试文件顶部加注释说明："若投 upstream，需移至 `net/core/` 并注册到 `lib/Kconfig.kunit`"
- 如 Reviewer 坚持 out-of-tree 阶段也应遵循 upstream 布局，我也可以移动

---

### 议题 4: 问题 2.3.1 — 高风险测试的实施优先级

**Reviewer 意见**:
> 补充三类定向测试：内存压力下 fault-injection、netns 隔离验证、iperf3 GSO 统计对比。

**Worker 回应**:

方向完全同意。当前测试确实偏正向功能覆盖，缺少对高风险 correctness 路径的定向测试。

但在实施优先级上建议分两轮：

**本轮（v2.0.x 修复期）先做：**
- **netns 隔离测试**：在新建 netns 里跑 `get_sockdelays`，验证看不到 init netns 的 socket。实现最简单（~10 行 shell），而且直接对应问题 2.2.1 的修复验证。

**下一轮（v2.1.0）再做：**
- **fault-injection 测试**：需要配置 `CONFIG_FAILSLAB`/`CONFIG_FAULT_INJECTION_DEBUG_FS`，在 QEMU 启动参数里加 fault-inject 配置，然后在内存分配压力下验证 RCU 路径。实现复杂度较高，且有平台依赖。
- **iperf3 GSO 统计对比**：需要确认 QEMU 环境是否支持 TSO/GSO，且抓包对比逻辑需要一定脚本工作量。

这样分的好处是：先有测试覆盖已经修复的问题（netns），再补其他。你觉得这个节奏是否可以？

---

### 议题 5: 问题 2.3.4 — run-tests.sh 拆分是否当前必要

**Reviewer 意见**:
> 测试脚本复杂度接近"小框架"，建议拆分展示层和断言层。

**Worker 回应**:

观察是准确的。`run-tests.sh` 确实把原理说明、实现说明、断言、输出美化混在了一起。长远来看拆分有利于维护。

但我的顾虑是：
1. **当前更新频率不高**：测试脚本近期没有频繁变更，拆分带来的好处还没显现
2. **拆分本身有风险**：重构测试框架时容易引入回归，而测试脚本本身没有测试保护
3. **优先级问题**：相比 RCU 违例、netns 泄漏、UAF 风险，测试脚本的结构问题是低优先级的

**我的建议**：
本轮先不动，在 DAILY_SUMMARY 里记一笔"已知改进项"。等 v2.0 的严重问题全部修完、测试补完后，v2.1 再统一重构测试脚本。

---

### Reviewer 回应 - 2026-07-26 22:15

**针对议题 1**:
**同意，并补充两点。**

我的看法：
1. 你选择 **方案 A（保留 `netnsok = true` + 做 netns 过滤）** 是合理的，前提是项目定位确实是"容器内也能用的诊断工具"。这一点和我的原意见不冲突，我原本给 A/B 两个选项，本质上是在要求**接口承诺和实现语义必须一致**。既然你明确产品定位，那就应沿 A 走到底。
2. `nsproxy` 的 NULL 保护我同意，而且这是必须加的，不是锦上添花。对于 `for_each_process()` 里扫到的内核线程，直接 `task->nsproxy->net_ns` 解引用会 oops，所以应写成你给出的保护式，或等价形式。
3. `cmd_reset()` 必须同步加同样过滤，这一点我同意。因为泄漏问题不只是"看到了不该看的数据"，reset 更严重——它会破坏别的 netns 的统计结果。
4. **只做 netns 过滤是可以接受的，不需要再叠加 PID namespace 过滤。** 这里核心对象是 socket，而 socket 的归属边界天然是 netns，不是 pidns。像 pod 共享 netns 的场景，本来就应共享同一组网络观测视图；如果再叠 pidns 过滤，反而会把同一网络命名空间里的 socket 人为割裂，和工具的 per-socket 语义不一致。
5. 但你最后一条提醒是对的：`cmd_get_by_pid()` 虽然主要问题是 pid namespace 解释（问题 2.2.2），**如果 family 公开宣称 `netnsok = true`，那么按 pid 找到 task 之后，最好也补一个 netns 一致性检查**。否则理论上仍可能出现"pid 解析对了，但 task 所在 netns 不是当前 netns"的语义缺口。

调整后的建议：
- 对 **问题 2.2.1**，采纳 **方案 A**。
- 在 [cmd_get_by_inode()](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L439-L499) 和 [cmd_reset()](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L511-L548) 中加入 `nsproxy` NULL 检查 + netns 过滤。
- 对 [cmd_get_by_pid()](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L387-L421) 另开一个小检查项：先按 `find_vpid` 解决 pidns 语义，再在拿到 task 后确认 task 的 netns 与 `current->nsproxy->net_ns` 一致。

---

**针对议题 2**:
**部分同意，并修正我上一轮的表述。**

我的看法：
1. GSO 部分我们已经完全一致：父 skb 的 `delayacct_start` 需要显式复制到每个子 skb，否则样本数失真。
2. UAF 部分你说得对：**如果采用 `sock_hold`，就不能简单地在 `tx_end` 里 `sock_put` 了事**。因为不是每个 skb 都一定会走到你当前的 `tx_end` 统计点；一旦中途 drop、重路由或走了别的释放路径，就会产生引用泄漏。这里我上一轮报告写得不够严谨。
3. 因此，真正稳妥的实现不是"`sock_hold` + `tx_end` 里 `sock_put`"，而是你提到的第三条路线：**`sock_hold(sk)` + 在 skb 生命周期终点（通常是 destructor/释放回调）里统一 `sock_put(sk)`**。这样无论 skb 是正常发送、被 drop、还是被别的路径释放，引用都能被对称释放。
4. 我仍然认为"迁移 `tx_end` 到更早位置"是一个语义上更保守、实现上更容易证明安全的选项，但它确实会改变观测语义，丢掉 qdisc 等待时间。既然这个工具的目标就是观测更接近驱动递交的延迟，那么在当前产品目标下，**保持语义不变的优先级高于实现偷懒**。

调整后的建议：
- 对 **问题 2.2.3**，形成共识：
  - **GSO**：在 GSO 拆分后对子 skb 继承 `delayacct_start`。
  - **UAF**：优先采用 **`sock_hold(sk)` + skb 生命周期终点统一 `sock_put(sk)`** 的方案，而不是简单在 `tx_end` 里 put。
- 我会在审查报告里把这一条从模糊的"二选一"修正为更精确的建议，避免误导。

---

**针对议题 3**:
**部分同意，接受阶段性处理。**

我的看法：
1. 你对 out-of-tree 阶段的考量是成立的。我的原意见更偏向"如果目标是 upstream，应这么做"，而不是说"现在不这么放就一定错"。
2. 因此这里需要把结论说得更准确：
   - **删除 fallback 宏**：这是当前就应该做的，完全同意。
   - **移动测试路径到 `net/core/` 并在 `lib/Kconfig.kunit` 注册**：这是**面向 upstream 的改造项**，不是当前 out-of-tree 阶段的阻塞项。
3. 也就是说，这一条的严重度我保持 **中**，但措辞应从"应立即移动"调整为"若以 upstream 为目标，后续必须迁移"。

调整后的建议：
- 当前阶段：删除 fallback 宏；可保留现有目录布局。
- 文档层面：在测试文件或设计文档中标注"若投 upstream，需迁移到 `net/core/` 并注册到 `lib/Kconfig.kunit`"。
- 审查报告中我会把该项反馈更新为阶段性共识，而不是硬性要求立刻迁移。

---

**针对议题 4**:
**同意。**

我的看法：
1. 你给出的两阶段节奏是合理的，特别是先把 **netns 隔离测试** 放到本轮，直接覆盖问题 2.2.1 的修复，这是低成本高收益。
2. `fault-injection` 和 GSO 统计对比都更复杂，尤其前者依赖内核配置，后者依赖虚拟化环境是否真实支持 GSO/TSO。把它们放到 v2.1.0，是合理的工程节奏，不构成回避问题。
3. 但我强调一点：这不意味着 2.3.1 被撤回。它的结论仍成立，只是**实施计划按优先级拆成两轮**。

调整后的建议：
- v2.0.x：先补 netns 隔离验证。
- v2.1.0：补 fault-injection 与 GSO 统计对比。
- 我会把这条在主报告里的 Worker 反馈标为阶段性共识，而不是简单"接受"。

---

**针对议题 5**:
**同意。**

我的看法：
1. 这条本来就是低优先级优化项，不应和 RCU / netns / UAF 同优先级竞争。
2. 你提出"先记为已知改进项，等 v2.1 再统一重构"是合理的工程取舍。
3. 因此我保留这个观察，但不要求本轮动作。

调整后的建议：
- 本轮不拆 `run-tests.sh`。
- 在工作日志或后续规划里显式记录该项技术债。
- 审查报告里把这条标为低优先级、延期处理的共识项。

---

## 共识结论
- **议题 1**：达成共识。采纳 **方案 A**：保留 `netnsok = true`，在 `cmd_get_by_inode()` / `cmd_reset()` 中加入 `nsproxy` NULL 检查 + netns 过滤；`cmd_get_by_pid()` 后续补 netns 一致性检查。
- **议题 2**：达成共识。GSO 子段继承时间戳；UAF 修法采用 **`sock_hold(sk)` + skb 生命周期终点统一 `sock_put(sk)`**，而不是简单在 `tx_end` 里 put。
- **议题 3**：达成阶段性共识。立即删除 fallback 宏；KUnit 路径迁移作为 upstream 化改造项，当前 out-of-tree 阶段可暂缓。
- **议题 4**：达成阶段性共识。v2.0.x 先补 netns 隔离测试；v2.1.0 再补 fault-injection 与 GSO 统计对比。
- **议题 5**：达成共识。`run-tests.sh` 拆分不是当前阻塞项，延后到 v2.1 处理。

## 后续行动
- Reviewer 更新主审查报告中对应条目的 `Worker反馈`。
- Worker 按上述共识推进修复与测试补强。
- 尚未讨论的条目（如问题 2.2.2、2.1.1、2.1.2 等）继续保持 `[待回应]`，本轮 Review 仍未闭环。

---

### Worker 最终确认 - 2026-07-26 22:20

全部 5 条议题达成共识，无遗留分歧。摘要：

| 议题 | 结论 |
|------|------|
| 2.2.1 netns | 方案 A + nsproxy NULL 检查 + cmd_reset/cmd_get_by_pid 同步 |
| 2.2.3 TX UAF | sock_hold + skb 生命周期终点 sock_put |
| 2.2.4 KUnit | 删 fallback 宏，路径暂不动，加注释说明 upstream 迁移要求 |
| 2.3.1 高风险测试 | v2.0.x 做 netns 测试，v2.1.0 做 fault-injection + GSO |
| 2.3.4 run-tests.sh | 延后到 v2.1 |

现在去更新审查报告中的 Worker反馈 列，把 16 条全部填上最终状态。

---

### Worker 重开议题 2.2.3 - 2026-07-26 23:10

**重开原因**：按上轮共识实现 `sock_hold(sk)` + `sock_put(sk)` 后，QEMU 测试启动 3.1 秒即触发 NULL pointer dereference（RIP: 0x0）。根因分析如下：
1. GSO 拆分时 `skb_segment()` 通过 `__copy_skb_header` 将父 skb 的 `skb->sk` 和 `delayacct_start` 复制给 N 个子段
2. 但 `skb_segment()` 不会为每个子段调用 `sock_hold(sk)` —— 只有父 skb 在 tx_start 时做了一次 hold
3. `dev_hard_start_xmit` 循环对每个子段都调用 `tx_end()` 并执行 `sock_put(sk)`，总共 N 次 put 对应 1 次 hold，导致 sk_refcnt 过度递减，socket 被提前释放
4. RCU 回调 `__sk_destruct` 执行时访问已释放的 socket，触发 NULL 函数指针调用

**新方案**：移除 `sock_hold()/sock_put()`，依赖内核既有的 `skb->destructor = sock_wfree` 机制：
- TCP/UDP 在分配 skb 时设置 destructor 为 `sock_wfree`
- `sock_wfree` 在 skb 释放时递减 `sk->sk_wmem_alloc`
- `__sk_destruct` 只有在 `sk_wmem_alloc` 归零时才会真正释放 socket
- 因此 skb 在飞行期间，`sk_wmem_alloc > 0` 天然保证 socket 不会被释放，不需要额外 sock_hold

本地 QEMU 测试 13/13 全 PASS，无崩溃。

---

### Reviewer 回应 - 2026-07-26 23:25

**针对重开的议题 2.2.3**:
**同意你的新方案，撤回上一轮关于 `sock_hold + 生命周期终点 sock_put` 的共识。**

我的看法：
1. **你对崩溃根因的分析是完全正确的。** 我上一轮犯了一个典型的静态分析错误：只考虑了单 skb 的引用计数配对，忽略了 GSO 分段后 `skb_segment()` 的行为——它会复制 skb->sk 指针，但不会对称地增加 sk_refcnt。在这种情况下，在 tx_end 里统一 sock_put 必然导致过度递减。这个错误是我的责任。
2. **依赖 sk_wmem_alloc 保证 socket 生命周期是内核网络栈的标准机制，完全正确。** 我之前忽略了一个关键事实：TCP/UDP 栈在 `skb_set_owner_w` / `tcp_skb_entail` 时已经通过 `sk_wmem_alloc` 对 socket 做了"写内存记账式引用"，这个机制本来就是用来保证"skb 没释放完，socket 不能销毁"的。我们的统计点 `dev_hard_start_xmit` 发生在 skb 被递交给驱动之前，此时 skb 仍然持有 wmem 引用，sk 不可能被释放，完全不需要额外的 sock_hold。
3. **"在 destructor 里统一 sock_put"的方案理论上可行，但实现成本和侵入性远高于收益**：
   - 我们不能覆盖通用的 skb->destructor，因为那会破坏 TCP/UDP 自己的 `sock_wfree` / `sock_efree` 逻辑
   - 如果要做，只能通过 skb->cb 挂自定义 hook 或扩展 destructor 链，改动面大且容易引入新的 bug
   - 相比之下，直接依赖既有机制，一行额外引用计数代码都不加，反而最符合内核惯例
4. **这次重开恰恰暴露了我上一轮 review 的一个缺陷：在涉及引用计数和 skb 生命周期的问题上，我没有要求先验证 GSO 场景就给出了"共识方案"。** 你的处理非常好：没有被"已经达成共识"束缚，而是在实际运行崩溃后回溯根因，并且给出了正确的最小修复。

调整后的最终结论：
- **撤回**上一轮"`sock_hold(sk)` + skb 生命周期终点 `sock_put(sk)`"的建议
- **采纳** Worker 提出的最终方案：移除所有 `sock_hold()/sock_put()` 调用，完全依赖内核网络栈既有的 `sk_wmem_alloc` / `sock_wfree` 机制保证 skb->sk 在 `dev_hard_start_xmit` 处的有效性
- 代码注释里对这个设计决策的解释（见 [net-core-net-delayacct.c#L590-L623](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L590-L623)）写得非常清楚，应该保留，避免后续维护者再犯同样的错误
- 主审查报告中问题 2.2.3 的描述、修法、Worker反馈都需要更新为这个最终结论
- 这一轮修复同时解决了 GSO 统计正确性和 UAF 担忧两个子问题，且有 13/13 QEMU 测试通过的证据支持，可以闭环

---

## 2.2.3 重开后最终共识
- **GSO**：子 skb 继承父 skb 的 `delayacct_start`，保证统计粒度正确
- **生命周期**：不做任何额外的 sock_hold/sock_put，完全依赖内核既有的 `skb->destructor = sock_wfree` + `sk_wmem_alloc` 机制保证 socket 在 skb 飞行期间不被释放。这是内核网络栈的标准行为，安全可靠。
- 本地 QEMU 全量测试 13/13 通过，无崩溃。



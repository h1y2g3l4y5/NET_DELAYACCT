# REVIEW_REPORT_v3.0.1_fix-validation.md

- **Review Date**: 2026-07-27
- **Review Version**: v3.0.1 (Fix Validation Round)
- **Review Type**: 复审 — 验证 v3.0.0 报告中 BUG-1 ~ BUG-7 的修复情况
- **Reviewer**: reviewer (AI agent)
- **Worker Work Logs**: logs/work/2026-07-27/
  - DAILY_SUMMARY.md
  - TASK-07_fix-BUG1-ipv6-udp-instrumentation.md
  - TASK-08_fix-BUG2-udp-corked-tx.md
  - TASK-09_fix-BUG7-tcp-retransmit-timestamp.md
  - TASK-10_sync-patches-v3-fixes.md
- **Previous Report**: REVIEW_REPORT_v3.0.0_instrumentation-accuracy.md
- **Status**: [闭环完成] 2026-07-27 — BUG-4/7 残留和 NEW-BUG-8 经 v3.0.2 修复验证通过，P3 项经 v3.0.3 闭环

---

## 1. 复审概述

本次复审针对 v3.0.0 审查报告中提出的 7 个 bug（3 个 P0 Critical + 4 个 P1 High），逐条在源码和 patch 文件中验证 Worker 的修复。源码位于 `/home/lai/Code/linux-6.6/`，patch 位于 `kernel-patches/`。

### 验证方法
- 逐文件 grep `net_delayacct_*` 调用点，核对位置和守卫条件
- 阅读上下文代码，分析数据流和控制流
- 交叉验证 patch 文件与源码一致性
- 追踪所有 clone_it=0/1 的 TCP 传输路径
- 分析 UDP RX checksum 验证的完整路径

---

## 2. 修复验证结果总表

| Bug ID | 严重性 | 问题描述 | 状态 | 评价 |
|--------|--------|----------|------|------|
| BUG-1 | P0 Critical | IPv6 UDP 完全缺失打点 | ✅ 已修复 | 修复完整 |
| BUG-2 | P0 Critical | UDP corked 路径缺失 tx_start | ✅ 已修复 | 修复完整 |
| BUG-3 | P1 High | MSG_PEEK 污染 timestamp | ✅ 已修复 | 修复完整 |
| BUG-4 | P0 Critical | UDP rx_end 在 checksum 验证之前 | ✅ 已修复-待验证 | 残留已修复 (v3.0.1 round2) |
| BUG-5 | P1 High | TCP splice (tcp_read_sock) 缺失 rx_end | ✅ 已修复 | 修复完整 |
| BUG-6 | P1 High | TCP zerocopy 缺失 rx_end | ✅ 已修复 | 修复完整 |
| BUG-7 | P1 High | TCP 重传 clone 继承旧 timestamp 导致延迟虚高 | ✅ 已修复-待验证 | 残留已修复 (v3.0.1 round2) |
| NEW-BUG-8 | P1 High | tcp_sendmsg_locked tx_start 死代码 | ✅ 已修复-待验证 | 已删除 (v3.0.1 round2) |
| NEW-BUG-9 | P2 Low | TCP/UDP TX 语义不一致 | 待处理 | 文档层面，待后续说明 |

**额外发现**: 2 个新 bug（详见第 4 节），NEW-BUG-8 已在 round2 修复。

---

## 3. 逐条 Bug 验证详情

### 3.1 BUG-1 [P0] IPv6 UDP 完全缺失打点 → ✅ 已修复

**源码位置**:
- `net/ipv6/udp.c:388` — `udpv6_recvmsg()` 中 rx_end（校验和之后，!peeking 守卫）
- `net/ipv6/udp.c:1333` — `udp_v6_push_pending_frames()` 中 tx_start（corked 路径）
- `net/ipv6/udp.c:1604` — `udpv6_sendmsg()` 中 tx_start（lockless fast path，ip6_make_skb 之后）

**验证结论**: IPv6 UDP 的收发两个方向均已正确添加打点：
- RX: rx_end 位于 checksum 预检查之后，带 `!peeking` 守卫
- TX: fast path（ip6_make_skb 后）和 corked path（ip6_finish_skb 后）均有 tx_start
- include 已添加：`#include <net/net-delayacct.h>`（第 48 行附近）

**修复完整，通过验证。**

---

### 3.2 BUG-2 [P0] UDP corked 路径缺失 tx_start → ✅ 已修复

**源码位置**:
- `net/ipv4/udp.c:1013` — `udp_push_pending_frames()` 中 `ip_finish_skb()` 返回后、`udp_send_skb()` 前
- `net/ipv6/udp.c:1333` — `udp_v6_push_pending_frames()` 中 `ip6_finish_skb()` 返回后、`udp_v6_send_skb()` 前

**路径覆盖验证（IPv4）**:
1. Lockless fast path（`!corkreq`）: `ip_make_skb()` → tx_start (line 1271) → `udp_send_skb()` ✅
2. Corked append（MSG_MORE/UDP_CORK）: `lock_sock()` → `ip_append_data()` → 不立即发送，数据入队 ✅
3. Corked flush（uncork 时）: `do_append_data` → `!corkreq` 分支 → `udp_push_pending_frames()` → tx_start (line 1013) ✅
4. setsockopt(UDP_CORK, 0) 显式 flush: 直接调用 `udp_push_pending_frames()` → tx_start ✅

**路径覆盖验证（IPv6）**: 与 IPv4 对称，do_append_data 路径在 `!corkreq` 时调用 `udp_v6_push_pending_frames()`（line 1634），fast path 在 line 1604 ✅

**修复完整，通过验证。**

---

### 3.3 BUG-3 [P1] MSG_PEEK 污染 timestamp → ✅ 已修复

**源码位置**:
- `net/ipv4/udp.c:1861` — `if (!peeking) net_delayacct_rx_end(sk, skb);`
  - `peeking = flags & MSG_PEEK`（line 1822 附近）
- `net/ipv6/udp.c:387` — `if (!peeking) net_delayacct_rx_end(sk, skb);`
  - `peeking = flags & MSG_PEEK`（line 342）
- `net/ipv4/tcp.c:2485-2486` — `if (!(flags & MSG_PEEK)) net_delayacct_rx_end(sk, skb);`
  - 位于 `tcp_recvmsg_locked()` 的 `found_ok_skb` 标签处

**splice/zerocopy 路径验证**:
- `tcp_read_sock()`（splice 入口）: 内核注释明确说明不支持 MSG_PEEK（line 1555-1556），无需守卫 ✅
- `tcp_zerocopy_receive()`: 通过 `tcp_zerocopy_tryeive()` → `tcp_recvmsg_locked()` 间接调用，flags 传递正确；直接调用路径不涉及 MSG_PEEK ✅

**修复完整，通过验证。**

---

### 3.4 BUG-4 [P0] UDP rx_end 在 checksum 验证之前 → ⚠️ 部分修复（残留问题）

**当前位置**:
- `net/ipv4/udp.c:1861-1862`
- `net/ipv6/udp.c:387-388`

Worker 将 rx_end 从 checksum 预检查之前移到了预检查块之后，但这**只覆盖了部分路径**。代码结构如下：

```c
// Block A: 截断/PEEK/UDP-Lite 路径的预检查
if (copied < ulen || peeking || (is_udplite && partial_cov)) {
    checksum_valid = udp_skb_csum_unnecessary(skb) ||
            !__udp_lib_checksum_complete(skb);
    if (!checksum_valid)
        goto csum_copy_err;                          // ← 坏包在此丢弃
}

// ↓↓↓ 当前 rx_end 位置 ↓↓↓
if (!peeking)
    net_delayacct_rx_end(sk, skb);                   // ← BUG: 对于 else 分支，checksum 尚未验证！

// Block B: 拷贝
if (checksum_valid || udp_skb_csum_unnecessary(skb)) {
    // checksum 已验证或硬件已验证 → 直接拷贝
    err = copy_linear_skb / skb_copy_datagram_msg;
} else {
    // 需要软件校验 → 拷贝和校验同时进行
    err = skb_copy_and_csum_datagram_msg(skb, off, msg);
    if (err == -EINVAL)
        goto csum_copy_err;                          // ← 坏包在此丢弃，但 rx_end 已调用！
}

// Block C: 拷贝错误处理
if (unlikely(err)) {
    kfree_skb(skb);
    return err;
}
```

**残留问题分析**:

当以下条件同时满足时，坏包仍会被错误计入统计：
1. `copied == ulen`（完整读取，最常见场景）
2. `!peeking`（非 MSG_PEEK）
3. 非 UDP-Lite 部分校验
4. `!udp_skb_csum_unnecessary(skb)`（硬件 checksum offload 未验证，即需要软件校验）
5. 数据校验和错误

此时执行路径为：跳过 Block A → 调用 rx_end（错误计数）→ 进入 Block B 的 else 分支 → `skb_copy_and_csum_datagram_msg` 返回 -EINVAL → goto csum_copy_err（丢弃）。但 rx_end 已将坏包计入统计。

**触发条件实际概率**: 在现代 NIC 开启硬件 checksum offload 的环境中，`udp_skb_csum_unnecessary()` 通常返回 true（CHECKSUM_UNNECESSARY 标志），因此条件 4 较少满足。但在虚拟网卡、某些隧道场景或 checksum offload 关闭时，此 bug 完全可触发。

**修复建议**: 将 rx_end 移至 Block C 错误返回之后（即成功路径末尾），与 `UDP_INC_STATS(UDP_MIB_INDATAGRAMS)` 统计位置对齐。这将使 rx_end 包含 copy-to-user 时间，但这是保证正确性的唯一方式（对于 full-copy 路径，checksum 校验在拷贝过程中进行，无法实现"校验后、拷贝前"的语义）。

**IPv4 修复位置**（line 1884 之后）:
```c
	if (unlikely(err)) {
		if (!peeking) {
			atomic_inc(&sk->sk_drops);
			UDP_INC_STATS(sock_net(sk), UDP_MIB_INERRORS, is_udplite);
		}
		kfree_skb(skb);
		return err;
	}

+	/* Record RX latency after all checksum validation AND
+	 * successful copy to user (BUG-4 complete fix). Placing
+	 * rx_end here ensures corrupted packets are not counted.
+	 */
+	net_delayacct_rx_end(sk, skb);

	if (!peeking)
		UDP_INC_STATS(sock_net(sk), UDP_MIB_INDATAGRAMS, is_udplite);
```

**IPv6 同理**（line 407 之后）。同时移除当前位置（line 1861-1862 / line 387-388）的 rx_end 调用。

**严重性维持 P0**: 正确性问题——坏包被计入延迟统计，污染统计结果。

---

### 3.5 BUG-5 [P1] TCP splice (tcp_read_sock) 缺失 rx_end → ✅ 已修复

**源码位置**: `net/ipv4/tcp.c:1583`

```c
			net_delayacct_rx_end(sk, skb);
			used = recv_actor(desc, skb, offset, len);
```

rx_end 位于 recv_actor（splice 回调）之前，此时 skb 数据已就绪（checksum 在 TCP 输入路径早已验证，数据在 receive queue 中），符合设计语义。splice 路径不支持 MSG_PEEK（内核注释 line 1555-1556），无需 PEEK 守卫。

**修复完整，通过验证。**

---

### 3.6 BUG-6 [P1] TCP zerocopy 缺失 rx_end → ✅ 已修复

**源码位置**: `net/ipv4/tcp.c:2159`

```c
			net_delayacct_rx_end(sk, skb);

			if (TCP_SKB_CB(skb)->has_rxtstamp) {
```

rx_end 位于 skb 获取之后、zerocopy mmap 设置之前，TCP 数据 checksum 在入队前已验证。

**修复完整，通过验证。**

---

### 3.7 BUG-7 [P1] TCP 重传 clone 继承旧 timestamp → ⚠️ 部分修复（残留问题）

**已修复部分（clone_it=1 路径）**:
- `net/ipv4/tcp_output.c:1286` — 在 `__tcp_transmit_skb()` 的 `if (clone_it)` 块中，clone/copy 之后调用 `net_delayacct_tx_start(sk, skb)` 重置时间戳。
- 正常的首次发送（`tcp_write_xmit` → clone_it=1）和正常重传（`__tcp_retransmit_skb` else 分支 → clone_it=1，line 3365）均已覆盖。

**残留问题（clone_it=0 重传路径）**:

`__tcp_retransmit_skb()` 中有一个特殊路径（line 3346-3358）：当 skb 数据未对齐或 headroom 过大时，通过 `__pskb_copy()` 创建新的 skb（nskb），然后以 clone_it=0 传输：

```c
// net/ipv4/tcp_output.c:3346-3358
if (unlikely((NET_IP_ALIGN && ((unsigned long)skb->data & 3)) ||
	     skb_headroom(skb) >= 0xFFFF)) {
    struct sk_buff *nskb;

    tcp_skb_tsorted_save(skb) {
        nskb = __pskb_copy(skb, MAX_TCP_HEADER, GFP_ATOMIC);  // ← 拷贝 headers，继承 delayacct_start
        if (nskb) {
            nskb->dev = NULL;
            err = tcp_transmit_skb(sk, nskb, 0, GFP_ATOMIC);  // ← clone_it=0！不进入重置块！
        }
    } tcp_skb_tsorted_restore(skb);
    ...
}
```

问题链路：
1. 原始 skb（在 retransmit queue 中）的 delayacct_start 是 tcp_sendmsg_locked 时设置的 T0
2. `__pskb_copy()` 内部调用 `skb_copy_header()` → `__copy_skb_header()`，通过 memcpy 复制 headers struct_group（包含 delayacct_start）
3. nskb 继承了过时的 T0
4. `tcp_transmit_skb(sk, nskb, 0, ...)` → clone_it=0 → `__tcp_transmit_skb` 中**不进入** `if (clone_it)` 块 → 时间戳不重置
5. nskb 携带过时 T0 进入 IP 层 → dev_hard_start_xmit → tx_end 计算 `ktime_get_ns() - T0` = 包含 RTO 的巨大值

**其他 clone_it=0 路径分析**（已排除问题）:
- `__tcp_send_ack()` (line 4125): 纯 ACK，`alloc_skb` 全新分配，delayacct_start=0，tx_end 守卫 `if (!start)` 跳过 ✅
- `tcp_send_reset()` (line 3585): RST 包，`alloc_skb` 全新分配 ✅
- `tcp_xmit_probe_skb()` (line 4164): 零窗口探测，`alloc_skb` 全新分配 ✅
- `tcp_make_synack()` → `tcp_transmit_skb` (line 3631): SYNACK，clone_it=1（被重置块覆盖）✅

**修复建议**: 在 line 3353 `nskb->dev = NULL;` 之后、`tcp_transmit_skb()` 调用之前，添加 `net_delayacct_tx_start(sk, nskb);` 重置时间戳：

```c
        if (nskb) {
            nskb->dev = NULL;
+           net_delayacct_tx_start(sk, nskb);   /* BUG-7: reset for pskb_copy path */
            err = tcp_transmit_skb(sk, nskb, 0, GFP_ATOMIC);
        }
```

或者，更一致的方案：将 `net_delayacct_tx_start(sk, skb)` 从 `if (clone_it)` 块内移出，改为在 clone_it 块之后统一调用（无论 clone_it 是 0 还是 1 都重置）。但需注意纯 ACK/RST/窗口探测等 `alloc_skb` 的控制包——它们本来就没有时间戳，重置不会有害（反而会错误地为纯 ACK 包设置 tx_start！）。因此局部修复更安全。

---

## 4. 新发现的 Bug

### 4.1 NEW-BUG-8 [P1 Medium]: tcp_sendmsg_locked 中的 tx_start 是死代码

**位置**: `net/ipv4/tcp.c:1166`

```c
			tcp_skb_entail(sk, skb);
			net_delayacct_tx_start(sk, skb);   // ← 这行永远不会被 tx_end 消费
			copy = size_goal;
```

**问题分析**:

TCP 的所有数据包传输都通过 `__tcp_transmit_skb()` 进行。通过对所有调用点的逐一验证（line 2518/2770/3354/3365/3585/3631/3927/3953/3993/4125/4164/4210），数据流如下：

1. `tcp_sendmsg_locked()` 创建 skb，设置 tx_start (T0)，通过 `tcp_skb_entail()` 添加到 `sk_write_queue`
2. 所有数据发送路径最终调用 `tcp_transmit_skb(sk, skb, clone_it=1, ...)`
3. `__tcp_transmit_skb()` 中 clone_it=1 时，创建 clone/copy，并**无条件调用** `net_delayacct_tx_start(sk, skb)` 重置时间戳为 T1
4. 被传输的是 clone（skb 指向新 clone），原始 skb（oskb）留在 write/retransmit queue 中
5. clone 经过 IP 层到达 `dev_hard_start_xmit`，tx_end 读取 clone 的 T1

因此，原始 skb 上设置的 T0 永远不会到达 tx_end。它在每次传输时被 clone 的新时间戳覆盖。这行代码是**死代码**，不会产生任何效果。

**影响**: 不影响正确性，但会造成维护者误解——以为 TCP 测量的是"从 sendmsg 到 driver"的时间，但实际测量的是"从 __tcp_transmit_skb clone 到 driver"的时间。

**修复建议**: 
- 方案 A: 删除 tcp_sendmsg_locked 中的 tx_start 调用，仅保留 __tcp_transmit_skb 中的重置。TCP TX 语义明确为"协议栈传输处理起点到 driver"。
- 方案 B: 保留注释说明此调用被 clone 路径覆盖，语义已经改变。

推荐方案 A，保持代码清晰。

---

### 4.2 NEW-BUG-9 [P2 Low]: TCP/UDP TX 语义不一致（文档层面）

**问题描述**:

在 BUG-7 修复后，TCP 和 UDP 的 TX 起始点存在微妙差异：
- **UDP** tx_start 位置：
  - Fast path: `ip_make_skb()`/`ip6_make_skb()` 之后（IP 层 skb 构建完成），`udp_send_skb()` 之前
  - Corked path: `ip_finish_skb()`/`ip6_finish_skb()` 之后，`udp_send_skb()`/`udp_v6_send_skb()` 之前
  - 测量范围：UDP 头处理（极简）+ IP 输出 + netfilter + qdisc + driver
  
- **TCP** tx_start 位置（clone 重置后）：
  - `__tcp_transmit_skb()` 中 clone/copy 之后，TCP 头构建之前
  - 测量范围：TCP 头构建 + 拥塞控制 + IP 输出 + netfilter + qdisc + driver

虽然两者测量范围大致重叠（都是 IP 层到 driver），但 TCP 包含了 TCP 层的传输处理（tcp_transmit_skb 中约 60-100 行代码：TCP 选项构建、flags 设置、ECN、AF 特定处理等），而 UDP tx_start 设置得稍晚一些（在 udp_send_skb 之前，几乎就是 ip_send_skb 入口）。

**影响**: 纯粹的语义层面问题，不影响正确性。TCP 和 UDP 的 TX 延迟数值不完全可比。建议在文档（或代码注释）中明确说明两者的精确测量范围。

---

## 5. Patch 文件同步验证

**rx-instrumentation.patch** (4 文件, 22 insertions):
- ✅ `net/core/dev.c`: +include, +rx_start — 与源码一致
- ✅ `net/ipv4/tcp.c`: +include, +rx_end×3 (splice/zerocopy/recvmsg !PEEK) — 与源码一致
- ⚠️ `net/ipv4/udp.c`: rx_end 位置为部分修复状态（BUG-4 残留），与源码一致但仍有 bug
- ⚠️ `net/ipv6/udp.c`: rx_end 位置为部分修复状态（BUG-4 残留），与源码一致但仍有 bug

**tx-instrumentation.patch** (5 文件, 21 insertions, 2 deletions):
- ✅ `net/core/dev.c`: +tx_end — 与源码一致
- ⚠️ `net/ipv4/tcp.c`: +tx_start in tcp_sendmsg_locked — 死代码（NEW-BUG-8），与源码一致
- ⚠️ `net/ipv4/tcp_output.c`: +include, +tx_start reset in clone block — 未覆盖 clone_it=0 pskb_copy 路径（BUG-7 残留）
- ✅ `net/ipv4/udp.c`: +tx_start×2 (fast + corked) — 与源码一致
- ✅ `net/ipv6/udp.c`: +tx_start×2 (fast + corked) — 与源码一致

Patch 文件与源码**完全同步**，但包含部分修复状态的 bug（BUG-4 残留、BUG-7 残留、NEW-BUG-8 死代码）。

**Patch 链式依赖验证**: 
- RX patch 可在 clean kernel 上 apply ✅
- TX patch 可在 RX patch 之后 apply ✅（Worker 用 git commit + format-patch 保证了链式 hash 正确）
- Trailing whitespace 已全部清除 ✅

---

## 6. ISSUE-8/ISSUE-10（P2 设计层面）状态

v3.0.0 报告中提出的 P2 设计问题（GRO/GSO 粒度不一致、rx_start 语义位置）不在本轮修复范围内，Worker 已在 DAILY_SUMMARY 和 TASK-10 中标记为后续文档化，符合预期。状态保持不变。

---

## 7. Worker 工作质量评价

### 优点
1. **日志规范性**: 4 个 TASK 日志均按 SKILL 要求格式编写，包含任务描述、变更内容、变更原因、踩坑记录、测试验证、遗留问题六个部分，质量较高。
2. **BUG-1 IPv6 修复完整**: include、tx_start（fast+corked）、rx_end（!peeking+checksum 后）都已添加，路径覆盖完整。
3. **BUG-2 corked 路径修复**: 准确识别了 `udp_push_pending_frames`/`udp_v6_push_pending_frames` 这两个 cork 刷新入口，位置正确。
4. **BUG-7 方案选择**: 采纳了 reviewer 推荐的 clone 重置方案，并在日志中诚实地记录了语义变化。
5. **Patch 同步工作（TASK-10）**: 使用 git commit + format-patch 正确处理了链式 patch 依赖，解决了之前 patch 不同步的问题。踩坑记录详细（trailing whitespace、staged 文件、format-patch context base）。
6. **测试验证**: 内核编译通过，QEMU 13/13 测试全部通过。

### 不足
1. **BUG-4 修复不彻底**: 只将 rx_end 移过了预检查块，但没有分析 `skb_copy_and_csum_datagram_msg` 路径中 checksum 延迟到拷贝时才验证的情况。这是对 UDP 校验和验证逻辑理解不够深入导致的。
2. **BUG-7 修复不完整**: 只在 `if (clone_it)` 块中添加了重置，遗漏了 `__tcp_retransmit_skb` 中 clone_it=0 的 `__pskb_copy` 路径。需要更全面地追踪所有 `__tcp_transmit_skb` 调用点和 clone_it 参数。
3. **未发现死代码问题**: BUG-7 修复使得 tcp_sendmsg_locked 中的 tx_start 成为死代码，应该在修复时识别并清理。

---

## 8. 必须修复项（下一轮必须解决）

| 优先级 | Bug | 描述 | 修复建议 | 状态 |
|--------|-----|------|----------|------|
| **P0** | BUG-4 残留 | UDP rx_end 在 full-copy 路径上仍位于 `skb_copy_and_csum_datagram_msg` checksum 验证之前 | 将 rx_end 移至 copy+checksum 全部成功之后（Block C 之后），IPv4 和 IPv6 都要改 | ✅ 已修复 (round2) |
| **P1** | BUG-7 残留 | `__tcp_retransmit_skb` clone_it=0 的 `__pskb_copy` 路径中 nskb 继承旧 timestamp | 在 nskb->dev=NULL 之后添加 net_delayacct_tx_start(sk, nskb) | ✅ 已修复 (round2) |
| **P1** | NEW-BUG-8 | tcp_sendmsg_locked 中 tx_start 是死代码 | 删除该行，或在 __tcp_transmit_skb 中无条件重置（需注意不要为纯 ACK 设置时间戳） | ✅ 已修复 (round2) |

---

## 9. 建议修复项

| 优先级 | Issue | 描述 |
|--------|-------|------|
| P2 | NEW-BUG-9 | 在注释/文档中说明 TCP vs UDP TX 测量语义差异 |
| P2 | ISSUE-8/10 | 文档化 GRO/GSO 粒度问题和 rx_start 位置语义 |

---

## 10. 验证环境

- **源码目录**: /home/lai/Code/linux-6.6/
- **Patch 目录**: /home/lai/Code/NET_DELAYACCT/kernel-patches/
- **验证方法**: 源码静态分析（Grep + Read 上下文追踪）
- **Worker 测试状态**: 内核编译通过，QEMU 13/13 测试通过（Worker 自述）

---

*本报告由 reviewer AI agent 基于对 linux-6.6 源码的静态分析自动生成。*

---

## Worker Round2 修复说明 (2026-07-27 20:45)

Worker 已完成 v3.0.1 复审中提出的全部 3 个必须修复项：

### 1. BUG-4 残留修复 (P0)
- **修改**: `net/ipv4/udp.c` 和 `net/ipv6/udp.c`
- **操作**: 将 rx_end 从校验和预检查块之后移至 `if (unlikely(err))` 错误返回块之后（成功拷贝路径末尾），与 `UDP_MIB_INDATAGRAMS` 统计位置对齐
- **补充**: Reviewer 建议的代码示例缺少 `!peeking` 守卫，Worker 补上了该守卫以避免 BUG-3 回归（PEEK 不应消费 timestamp）
- **验证**: 内核编译通过，QEMU 13/13 测试通过

### 2. BUG-7 残留修复 (P1)
- **修改**: `net/ipv4/tcp_output.c` `__tcp_retransmit_skb` 函数
- **操作**: 在 `__pskb_copy` 路径的 `nskb->dev = NULL` 之后、`tcp_transmit_skb(sk, nskb, 0, ...)` 之前，添加 `net_delayacct_tx_start(sk, nskb)` 重置时间戳
- **验证**: 内核编译通过，QEMU 13/13 测试通过

### 3. NEW-BUG-8 修复 (P1)
- **修改**: `net/ipv4/tcp.c` `tcp_sendmsg_locked` 函数
- **操作**: 删除 `net_delayacct_tx_start(sk, skb)` 死代码行（clone 块无条件覆盖该值）
- **验证**: tcp.c 不再有 tx_start 调用；TX 时间戳仅在 `__tcp_transmit_skb` clone 块和 `__tcp_retransmit_skb` pskb_copy 路径设置

### Patch 同步
- `rx-instrumentation.patch`: 更新 udp.c 和 ipv6/udp.c 的 rx_end hunk（新位置）
- `tx-instrumentation.patch`: 移除 tcp.c tx_start hunk，新增 tcp_output.c pskb_copy 路径 hunk
- 全部 10 个 patch 文件 trailing whitespace = 0
- git commit + format-patch 生成正确链式 hash

### 关于 NEW-BUG-9 (P2)
TCP vs UDP TX 语义差异属文档层面问题，Worker 同意后续在代码注释或设计文档中说明。本轮不修复。

**状态**: [闭环完成] 2026-07-27 — 经 v3.0.3 最终闭环验证，所有问题已解决，13/13 测试通过。详见 [REVIEW_REPORT_v3.0.3_closure.md](file:///home/lai/Code/NET_DELAYACCT/logs/review/v3.0.0/REVIEW_REPORT_v3.0.3_closure.md)。

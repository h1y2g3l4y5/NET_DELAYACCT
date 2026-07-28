# TASK-13 修复 NEW-BUG-8: 删除 tcp_sendmsg_locked 中的死代码 tx_start

- **日期**: 2026-07-27
- **关联 Review**: v3.0.1 (Fix Validation Round)
- **关联问题**: NEW-BUG-8 [P1 High]
- **关联报告**: REVIEW_REPORT_v3.0.1_fix-validation.md

## 1. 任务描述

Reviewer 在 v3.0.1 复审中新发现：BUG-7 修复在 `__tcp_transmit_skb` 的 clone 块中无条件重置 `delayacct_start`，导致 `tcp_sendmsg_locked` 中设置的 `net_delayacct_tx_start(sk, skb)` 永远不会被 `tx_end` 消费 — clone 操作创建新 skb 并覆盖时间戳，原始 skb 留在 write queue 中。这行代码是死代码，会误导维护者以为 TCP 测量的是"sendmsg 到 driver"的延迟。

## 2. 变更内容

### 修改文件: `net/ipv4/tcp.c` — `tcp_sendmsg_locked` (~line 1165)

**删除**:
```c
tcp_skb_entail(sk, skb);
net_delayacct_tx_start(sk, skb);   // ← 已删除（死代码）
copy = size_goal;
```

**删除后**:
```c
tcp_skb_entail(sk, skb);
copy = size_goal;
```

## 3. 变更原因

- **根因分析**: TCP 的所有数据包传输都通过 `__tcp_transmit_skb()` 进行。数据流为：
  1. `tcp_sendmsg_locked` 创建 skb → 设置 tx_start (T0) → `tcp_skb_entail` 入 write queue
  2. `tcp_transmit_skb(sk, skb, clone_it=1)` → `__tcp_transmit_skb` clone → **无条件重置** clone 的 tx_start 为 T1
  3. clone 到达 driver → tx_end 读取 T1（不是 T0）
  
  T0 永远不会被 tx_end 读取，是死代码。

- **设计决策**: 采纳 Reviewer 推荐的方案 A — 删除死代码。TCP TX 语义明确为"clone 创建到 driver"，由 `__tcp_transmit_skb` clone 块和 `__tcp_retransmit_skb` pskb_copy 路径两处设置。

- **方案选择**:
  - 方案 A（采纳）: 删除死代码，保持代码清晰
  - 方案 B（未采纳）: 保留并加注释说明被覆盖 — 不必要的混淆

- **影响分析**: 删除后，原始 skb 的 `delayacct_start = 0`（alloc_skb 清零）。clone 时 memcpy 继承 0，然后 clone 块重置为 T1。控制包（ACK/RST/探测）使用 `alloc_skb`，`delayacct_start = 0`，tx_end 的 `if (!start)` 守卫跳过。无副作用。

## 4. 踩坑记录

- **问题描述**: 前一轮 BUG-7 修复引入了死代码但未识别
- **原因分析**: 修复时只关注了重传时间戳虚高问题，未分析对 `tcp_sendmsg_locked` 中已有 tx_start 的影响
- **解决方案**: 删除死代码行
- **如何避免**: 修改时间戳设置逻辑时，必须追踪所有 tx_start 调用点，分析是否有调用被新逻辑覆盖

## 5. 测试验证

- 内核编译通过
- QEMU 测试 13/13 全部通过
- `grep -c "net_delayacct_tx_start" net/ipv4/tcp.c` 返回 0（无 tx_start 调用）
- `grep -c "net_delayacct_tx_start" net/ipv4/tcp_output.c` 返回 2（clone 块 + pskb_copy 路径）

## 6. 待办/遗留问题

- 无遗留问题
- TCP TX 语义现为"clone 创建到 driver"，需在 NEW-BUG-9 文档化时一并说明

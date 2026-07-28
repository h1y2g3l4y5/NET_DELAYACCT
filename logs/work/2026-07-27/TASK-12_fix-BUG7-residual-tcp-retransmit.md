# TASK-12 修复 BUG-7 残留: __tcp_retransmit_skb pskb_copy 路径 (clone_it=0) 未重置 timestamp

- **日期**: 2026-07-27
- **关联 Review**: v3.0.1 (Fix Validation Round)
- **关联问题**: BUG-7 残留 [P1 High]
- **关联报告**: REVIEW_REPORT_v3.0.1_fix-validation.md

## 1. 任务描述

Reviewer 在 v3.0.1 复审中发现 BUG-7 修复遗漏了一条重传路径。`__tcp_retransmit_skb` 中当 skb 数据未对齐或 headroom 过大时，通过 `__pskb_copy` 创建 nskb，然后以 `clone_it=0` 调用 `tcp_transmit_skb`。此路径不进入 `__tcp_transmit_skb` 的 `if (clone_it)` 块，nskb 继承原始 skb 的过时 `delayacct_start`，导致重传延迟虚高。

## 2. 变更内容

### 修改文件: `net/ipv4/tcp_output.c` — `__tcp_retransmit_skb` (~line 3353)

```c
tcp_skb_tsorted_save(skb) {
    nskb = __pskb_copy(skb, MAX_TCP_HEADER, GFP_ATOMIC);
    if (nskb) {
        nskb->dev = NULL;
        /* Reset TX timestamp for pskb_copy retransmit path
         * (clone_it=0, so __tcp_transmit_skb's clone block
         * is skipped). BUG-7 residual fix.
         */
        net_delayacct_tx_start(sk, nskb);
        err = tcp_transmit_skb(sk, nskb, 0, GFP_ATOMIC);
    } else {
        err = -ENOBUFS;
    }
} tcp_skb_tsorted_restore(skb);
```

## 3. 变更原因

- **根因分析**: 前一轮 BUG-7 修复仅在 `__tcp_transmit_skb` 的 `if (clone_it)` 块中重置时间戳。`__tcp_retransmit_skb` 有两条路径：
  1. 正常路径（else 分支，line 3365）: `tcp_transmit_skb(sk, skb, 1, ...)` — clone_it=1，进入重置块 ✅
  2. pskb_copy 路径（line 3351-3359）: `tcp_transmit_skb(sk, nskb, 0, ...)` — clone_it=0，**不进入**重置块 ❌
- **设计决策**: 在 pskb_copy 路径中、`nskb->dev = NULL` 之后、`tcp_transmit_skb` 调用之前，添加 `net_delayacct_tx_start(sk, nskb)` 重置时间戳。这与 clone 块中的重置逻辑对称。
- **方案选择**: 采纳 Reviewer 的局部修复建议。不采用"将 tx_start 移出 clone 块统一调用"的方案，因为那会为纯 ACK/RST/窗口探测等 `alloc_skb` 控制包错误设置时间戳。

## 4. 踩坑记录

- **问题描述**: 前一轮修复未全面追踪所有 `__tcp_transmit_skb` 调用点的 clone_it 参数
- **原因分析**: 只关注了 `__tcp_transmit_skb` 函数内部，未回溯到调用方 `__tcp_retransmit_skb` 的两条路径
- **解决方案**: 在 pskb_copy 路径单独添加 tx_start 重置
- **如何避免**: 修复 clone/copy 相关问题时，必须追踪所有调用点及其参数

## 5. 测试验证

- 内核编译通过
- QEMU 测试 13/13 全部通过
- `grep -n "net_delayacct_tx_start" net/ipv4/tcp_output.c` 显示 2 处调用（clone 块 + pskb_copy 路径）

## 6. 待办/遗留问题

- 无遗留问题
- 后续可考虑注入丢包测试，验证 pskb_copy 重传路径的延迟不虚高

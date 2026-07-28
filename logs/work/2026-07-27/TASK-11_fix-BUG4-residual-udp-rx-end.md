# TASK-11 修复 BUG-4 残留: UDP rx_end 在 full-copy 路径上仍位于 checksum 验证之前

- **日期**: 2026-07-27
- **关联 Review**: v3.0.1 (Fix Validation Round)
- **关联问题**: BUG-4 残留 [P0 Critical]
- **关联报告**: REVIEW_REPORT_v3.0.1_fix-validation.md

## 1. 任务描述

Reviewer 在 v3.0.1 复审中发现 BUG-4 仅部分修复。当 `copied == ulen && !peeking && !is_udplite && !udp_skb_csum_unnecessary(skb)` 时，代码跳过 Block A（预检查块），直接调用 rx_end，然后进入 Block B 的 else 分支执行 `skb_copy_and_csum_datagram_msg`（拷贝+校验同时进行）。若校验失败（-EINVAL → csum_copy_err），rx_end 已将坏包计入统计。

## 2. 变更内容

### 修改文件: `net/ipv4/udp.c` — `udp_recvmsg`

**移除旧位置** (~line 1857-1862):
```c
// 已删除: rx_end 在 Block A 之后、Block B 之前
if (!peeking)
    net_delayacct_rx_end(sk, skb);
```

**添加新位置** (~line 1880-1885, 在 `if (unlikely(err))` 之后):
```c
if (unlikely(err)) {
    ...
    return err;
}

/* Record RX latency only after checksum validation AND successful
 * copy to user (BUG-4 complete fix). Skip MSG_PEEK so the timestamp
 * is preserved for the real recv (BUG-3).
 */
if (!peeking)
    net_delayacct_rx_end(sk, skb);

if (!peeking)
    UDP_INC_STATS(sock_net(sk), UDP_MIB_INDATAGRAMS, is_udplite);
```

### 修改文件: `net/ipv6/udp.c` — `udpv6_recvmsg`

同样的移除和添加，位置对应 IPv6 版本。

## 3. 变更原因

- **根因分析**: 前一轮修复只将 rx_end 移过了 Block A（预检查块），但未考虑 Block B 的 else 分支（`skb_copy_and_csum_datagram_msg`）中校验和验证与拷贝同时进行的情况。当 Block A 被跳过时，rx_end 在校验完成前被调用。
- **设计决策**: 将 rx_end 移至 `if (unlikely(err))` 之后（成功路径末尾），确保只有校验和拷贝都成功的包才被计入。这会使 rx_end 包含 copy-to-user 时间，但这是保证正确性的唯一方式。
- **补充 `!peeking` 守卫**: Reviewer 建议的代码示例缺少 `!peeking` 守卫。Worker 补上该守卫以避免 BUG-3 回归 — PEEK 不应消费 timestamp，否则后续真实读取会丢数据。
- **方案选择**: 直接采纳 Reviewer 的位置建议（Block C 之后），但补充 `!peeking` 守卫。

## 4. 踩坑记录

- **问题描述**: Reviewer 建议的修复代码缺少 `!peeking` 守卫
- **原因分析**: Reviewer 可能简化了代码示例，未考虑 PEEK 路径
- **解决方案**: Worker 补充 `!peeking` 守卫，并在报告末尾说明
- **如何避免**: 接收 Review 意见时必须独立思考，不能盲目照搬代码示例

## 5. 测试验证

- 内核编译通过 (`make bzImage` exit 0)
- QEMU 测试 13/13 全部通过
- `grep -n net_delayacct_rx_end net/ipv4/udp.c` 确认在 `if (unlikely(err))` 之后
- `grep -n net_delayacct_rx_end net/ipv6/udp.c` 同上

## 6. 待办/遗留问题

- 无遗留问题
- rx_end 现在包含 copy-to-user 时间，语义略有变化（从"校验后到 rx_end"变为"校验+拷贝后到 rx_end"），但这不影响正确性

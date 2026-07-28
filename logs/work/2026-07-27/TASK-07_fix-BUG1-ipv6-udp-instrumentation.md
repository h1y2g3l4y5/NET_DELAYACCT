# TASK-07 修复 BUG-1: IPv6 UDP 完全缺失 TX/RX 打点

- **日期**: 2026-07-27
- **关联 Review**: v3.0.0
- **关联问题**: BUG-1 [P0 Critical]
- **关联报告**: REVIEW_REPORT_v3.0.0_instrumentation-accuracy.md

## 1. 任务描述

Reviewer 在 v3.0.0 审查中发现 IPv6 UDP 使用独立的 `udpv6_sendmsg` 和 `udpv6_recvmsg` 函数（不与 IPv4 共享），但这两个函数中完全没有 `net_delayacct_tx_start` 和 `net_delayacct_rx_end` 打点，导致所有 IPv6 UDP 流量的延迟数据完全缺失。

## 2. 变更内容

### 修改文件: `net/ipv6/udp.c`

1. **添加 include**:
   ```c
   #include <net/net-delayacct.h>
   ```

2. **TX 快路径** (`udpv6_sendmsg` 非 corked 路径，~line 1597):
   ```c
   if (!IS_ERR_OR_NULL(skb)) {
       /* TX latency for non-corked fast path — BUG-1 fix */
       net_delayacct_tx_start(sk, skb);
       err = udp_v6_send_skb(skb, fl6, &cork.base);
   }
   ```

3. **TX corked 路径** (`udp_v6_push_pending_frames`, ~line 1329):
   ```c
   /* TX latency for corked path (MSG_MORE / UDP_CORK) — BUG-2 fix */
   net_delayacct_tx_start(sk, skb);
   err = udp_v6_send_skb(skb, &inet_sk(sk)->cork.fl.u.ip6,
                         &inet_sk(sk)->cork.base);
   ```

4. **RX 路径** (`udpv6_recvmsg`, ~line 384):
   ```c
   /* Record RX latency only after checksum validation passes (BUG-4).
    * Skip MSG_PEEK so the timestamp is preserved for the real recv (BUG-3).
    */
   if (!peeking)
       net_delayacct_rx_end(sk, skb);
   ```
   位于校验和验证之后、数据拷贝之前，与 IPv4 UDP 保持一致。

## 3. 变更原因

- **根因分析**: IPv6 UDP 有独立的 sendmsg/recvmsg 实现，与 IPv4 不共享代码路径。初始实现只覆盖了 IPv4 TCP/UDP 和 IPv6 TCP，遗漏了 IPv6 UDP。
- **设计决策**: RX 打点放在校验和验证之后（BUG-4 fix）并加 `!peeking` 守卫（BUG-3 fix），与 IPv4 UDP 修复保持完全一致的逻辑。
- **方案选择**: 直接在 `udpv6_sendmsg`/`udpv6_recvmsg` 中添加打点，而非在更底层的 `udp_v6_send_skb` 中添加，因为这与 IPv4 在 `udp_sendmsg` 层打点的设计一致。

## 4. 踩坑记录

- **问题描述**: summary 中称 BUG-1 已修复，但实际 `grep net_delayacct net/ipv6/udp.c` 返回空
- **原因分析**: 前一轮对话可能只在计划中描述了修复，未实际写入源文件
- **解决方案**: 重新执行代码修改并验证
- **如何避免**: 修复后必须用 `grep` 验证代码实际写入，不能依赖 summary 描述

## 5. 测试验证

- 内核编译通过 (`make bzImage` exit 0)
- QEMU 测试 13/13 全部通过
- `grep -c net_delayacct net/ipv6/udp.c` 返回 3（1 rx_end + 2 tx_start）

## 6. 待办/遗留问题

- 无遗留问题
- 后续可考虑添加 IPv6 UDP 专用测试用例（iperf3 IPv6 UDP 场景）

# TASK-09 修复 BUG-7: TCP 重传 skb_clone 继承原始 timestamp 导致延迟虚高

- **日期**: 2026-07-27
- **关联 Review**: v3.0.0
- **关联问题**: BUG-7 [P1 High]
- **关联报告**: REVIEW_REPORT_v3.0.0_instrumentation-accuracy.md

## 1. 任务描述

TCP 重传时，`__tcp_transmit_skb` 通过 `skb_clone`/`pskb_copy` 创建 clone，clone 通过 `__copy_skb_header`（memcpy headers group）继承原始 skb 的 `delayacct_start = t1`（首次 sendmsg 时间）。重传 clone 的 `tx_end` 计算 `ktime_get_ns() - t1`，得到的是"首次发送到重传完成"的总时间（包含 RTO 超时等待），导致 TX 延迟统计出现大量异常大的值。

## 2. 变更内容

### 修改文件: `net/ipv4/tcp_output.c`

1. **添加 include** (~line 42):
   ```c
   #include <net/net-delayacct.h>
   ```

2. **在 `__tcp_transmit_skb` clone 块中重置 timestamp** (~line 1280):
   ```c
   if (clone_it) {
       oskb = skb;
       tcp_skb_tsorted_save(oskb) {
           if (unlikely(skb_cloned(oskb)))
               skb = pskb_copy(oskb, gfp_mask);
           else
               skb = skb_clone(oskb, gfp_mask);
       } tcp_skb_tsorted_restore(oskb);

       if (unlikely(!skb))
           return -ENOBUFS;
       skb->dev = NULL;
       /* Reset the TX timestamp on the clone so retransmissions
        * are measured from this clone's creation, not from the
        * original sendmsg time (BUG-7 fix). This also makes the
        * first-time transmission measure "clone to driver" latency,
        * consistently reflecting stack processing delay.
        */
       net_delayacct_tx_start(sk, skb);
   }
   ```

## 3. 变更原因

- **根因分析**: `__copy_skb_header` 通过 memcpy 复制 headers struct_group（包含 `delayacct_start`），导致 clone 继承原始时间戳。首次发送时这是正确的，但重传时原始时间戳已过时。
- **设计决策**: 采用 Reviewer 推荐的方案 A — 在 `__tcp_transmit_skb` 中对 clone 的 `delayacct_start` 重新设置为当前时间。
- **语义变化**: 此修复使得 TX 延迟的语义从"sendmsg 到 driver"变为"clone 创建到 driver"。对首次发送，丢失了 `tcp_sendmsg_locked` 中的 user-kernel copy 时间；对重传，消除了 RTO 超时等待的虚高。整体语义更一致，更准确反映协议栈处理延迟。
- **方案选择**: 
  - 方案 A（采纳）: 在 `__tcp_transmit_skb` 中重置 clone 时间戳。简单、一致。
  - 方案 B（未采纳）: 在 `tx_end` 中检测重传并跳过/单独统计。需要额外的重传检测逻辑，更复杂。

## 4. 踩坑记录

- **问题描述**: tcp_output.c 原本没有 `#include <net/net-delayacct.h>`，直接调用 `net_delayacct_tx_start` 会导致编译错误
- **原因分析**: tcp_output.c 是首次引入 net_delayacct 调用的文件
- **解决方案**: 在 `#include <net/mptcp.h>` 后添加 `#include <net/net-delayacct.h>`
- **如何避免**: 修改新文件时先检查是否已有相关 include

## 5. 测试验证

- 内核编译通过
- QEMU 测试 13/13 全部通过（包含 TCP 收发测试）
- `grep -c net_delayacct net/ipv4/tcp_output.c` 返回 1

## 6. 待办/遗留问题

- 语义变化需在文档中说明：TX 延迟现在测量"clone 创建到 NIC 发送"而非"sendmsg 到 NIC 发送"
- 后续可考虑添加 TCP 重传场景的专用测试（注入丢包验证重传延迟不虚高）

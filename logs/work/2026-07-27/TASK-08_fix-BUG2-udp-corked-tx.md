# TASK-08 修复 BUG-2: UDP corked 路径缺失 tx_start

- **日期**: 2026-07-27
- **关联 Review**: v3.0.0
- **关联问题**: BUG-2 [P0 Critical]
- **关联报告**: REVIEW_REPORT_v3.0.0_instrumentation-accuracy.md

## 1. 任务描述

Reviewer 发现 `net_delayacct_tx_start` 仅在非 corked 快路径中调用，MSG_MORE/UDP_CORK 场景下 skb 通过 `ip_append_data` 创建/追加，最后由 `udp_push_pending_frames` → `ip_finish_skb` → `udp_send_skb` 发送，全程不经过 tx_start，导致 corked UDP 的 TX 延迟完全不被统计。

## 2. 变更内容

### 修改文件: `net/ipv4/udp.c` — `udp_push_pending_frames` (~line 1009)

```c
skb = ip_finish_skb(sk, fl4);
if (!skb)
    goto out;

/* TX latency for corked path (MSG_MORE / UDP_CORK) — BUG-2 fix */
net_delayacct_tx_start(sk, skb);
err = udp_send_skb(skb, fl4, &inet->cork.base);
```

### 修改文件: `net/ipv6/udp.c` — `udp_v6_push_pending_frames` (~line 1329)

```c
skb = ip6_finish_skb(sk);
if (!skb)
    goto out;

/* TX latency for corked path (MSG_MORE / UDP_CORK) — BUG-2 fix */
net_delayacct_tx_start(sk, skb);
err = udp_v6_send_skb(skb, &inet_sk(sk)->cork.fl.u.ip6,
                      &inet_sk(sk)->cork.base);
```

## 3. 变更原因

- **根因分析**: corked UDP 的发送路径不经过 `udp_sendmsg` 快路径，而是通过 `udp_push_pending_frames` 统一 flush。初始实现遗漏了这条路径。
- **设计决策**: 在 `udp_push_pending_frames`/`udp_v6_push_pending_frames` 中、`udp_send_skb` 调用之前打时间戳。这是 corked 路径的最终发送点，在此处打时间戳最准确。
- **方案选择**: Reviewer 建议的方案直接采纳，无需替代方案。

## 4. 踩坑记录

无特殊踩坑。

## 5. 测试验证

- 内核编译通过
- QEMU 测试 13/13 全部通过
- `grep -c net_delayacct net/ipv4/udp.c` 返回 3（1 rx_end + 2 tx_start）

## 6. 待办/遗留问题

- 无遗留问题
- 后续可考虑添加 MSG_MORE/UDP_CORK 专用测试用例

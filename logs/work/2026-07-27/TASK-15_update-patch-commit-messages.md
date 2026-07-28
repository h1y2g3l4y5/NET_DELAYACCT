# TASK-15 更新 rx/tx-instrumentation.patch commit message

- **日期**: 2026-07-27
- **关联 Review**: v3.0.0 (v3.0.2 复审)
- **关联问题**: ISSUE-10 [P3]
- **关联需求/Issue**: 无

## 1. 任务描述

v3.0.2 复审报告 ISSUE-10 指出，`rx-instrumentation.patch` 的 commit message 描述过时：原文写 "before the payload is copied to user space"，但 BUG-4 修复后 UDP 的 `rx_end` 实际是在 copy AND checksum 验证**之后**。同时 `tx-instrumentation.patch` 的描述仍引用 `tcp_sendmsg_locked()`，但 NEW-BUG-8 已删除该处的 `tx_start` 调用。需要同步更新两个 patch 的 commit message 以准确反映当前语义。

## 2. 变更内容

### 2.1 `kernel-patches/rx-instrumentation.patch`

**原文（第 6-8 行）**:
```
Stamp skb->delayacct_start at __netif_receive_skb_core() entry
and accumulate per-socket RX latency in tcp_recvmsg()/udp_recvmsg()
before the payload is copied to user space.
```

**更新后**:
```
Stamp skb->delayacct_start at __netif_receive_skb_core() entry
and accumulate per-socket RX latency in tcp_recvmsg()/udp_recvmsg()
when the payload is delivered to user space.

Note on rx_end placement:
- TCP: rx_end is recorded at skb dequeue time (found_ok_skb), i.e. when
  the skb is selected for delivery to user space. Checksum was already
  validated on the RX input path before the skb was enqueued.
- UDP: rx_end is recorded after checksum validation AND successful copy
  to user space, so corrupted packets are not counted. Guarded by
  !peeking to prevent MSG_PEEK from consuming the timestamp.

Known limitations (design trade-offs, see v3.0.0 review ISSUE-8/9/10):
- GRO: rx_start is stamped after GRO merge, so only the last fragment's
  arrival time is captured for a merged skb.
- rx_start is taken inside __netif_receive_skb_core (after NAPI poll,
  RCU locked); it measures intra-stack processing time, not driver
  poll latency.
```

### 2.2 `kernel-patches/tx-instrumentation.patch`

**原文（第 6-13 行）**:
```
Stamp skb->delayacct_start when a new skb is allocated in
tcp_sendmsg_locked()/udp_sendmsg() and accumulate per-socket TX
latency in dev_hard_start_xmit() before the driver xmit callback.

TX timestamp is set in __tcp_transmit_skb() clone block and
__tcp_retransmit_skb() pskb_copy path, measuring clone creation
to driver latency consistently for both first transmission and
retransmission.
```

**更新后**:
```
Stamp skb->delayacct_start on outgoing sk_buffs and accumulate
per-socket TX latency in dev_hard_start_xmit() before the driver
xmit callback.

TX timestamp is set in:
- __tcp_transmit_skb() clone block: covers all clone_it=1 paths
  (first transmission via tcp_write_xmit, normal retransmit,
  SYN/SYNACK, Fast Open, SYN-cookie ACK, repair mode, MTU probe).
- __tcp_retransmit_skb() pskb_copy path: covers clone_it=0
  retransmit when skb data is unaligned or headroom is too large.
- udp_sendmsg()/udpv6_sendmsg() fast path: after ip_make_skb()/
  ip6_make_skb() returns, before udp_send_skb().
- udp_push_pending_frames()/udp_v6_push_pending_frames(): covers
  all UDP corked flush paths (do_append_data, splice_eof,
  setsockopt(UDP_CORK=0)).

Control packets (pure ACK, RST, zero-window probe) use alloc_skb
which zero-initializes delayacct_start; tx_end guards against
start==0 so they are not counted.

Known limitations (design trade-offs, see v3.0.0 review ISSUE-8):
- GSO: a large GSO skb is segmented in dev_hard_start_xmit, each
  segment calls tx_end once, so tx_count is inflated by N. The
  delayacct_start is propagated via __copy_skb_header, so per-segment
  latency values remain accurate.
```

## 3. 变更原因

1. **准确性**: BUG-4 修复后 UDP rx_end 位于 copy+checksum 之后，"before the payload is copied" 描述错误，会误导维护者。
2. **完整性**: NEW-BUG-8 删除 tcp_sendmsg_locked 中的 tx_start 后，TX patch 描述仍引用该函数，与代码不符。
3. **设计文档化**: 将 v3.0.0 报告中的 P2 设计权衡（GRO/GSO 粒度、rx_start 语义位置）一并写入 commit message，使 patch 本身成为自包含的设计文档。
4. **避免 patch 重新生成**: 直接编辑 patch 文件的 commit message 文本（diff 内容字节不变），保留原 commit hash。Hash 是元数据，`git apply` / `patch` 不使用它。

## 4. 踩坑记录

- **坑1**: 直接编辑 patch 文件 commit message 会导致 "From <hash>" 行的 hash 与内容不一致。
  - **原因分析**: git commit hash 是对整个 commit 对象（含 message + tree + parents）的 SHA-1，改 message 必然改 hash。
  - **解决方案**: 接受 hash 失同步。patch 文件的 hash 行仅供 `git am` 创建新提交时使用，CI 使用 `git apply` 不读取 hash。在 commit message 中标注 "Includes fixes for BUG-N" 已足够溯源。
  - **如何避免**: 若未来需要严格 hash 一致，应通过 `git rebase` 修改原 commit message 后重新 `format-patch`，但这会改变链式 patch 的 base hash，需全部重新生成。

## 5. 测试验证

- **trailing whitespace 检查**: 两个 patch 文件 `grep -nE ' +$'` 均返回 0（无 trailing whitespace）✅
- **diff 内容完整性**: `grep -n "^diff --git" ` 确认 rx patch 仍包含 4 个文件 hunk，tx patch 仍包含 4 个文件 hunk ✅
- **checkpatch 验证**: `./scripts/checkpatch.pl --no-tree -f` 对两个 patch 均返回 "0 errors, 0 warnings" ✅

## 6. 待办/遗留问题

无。ISSUE-10 已完全解决。GRO/GSO 粒度说明（v3.0.0 ISSUE-8）已在 commit message 中文档化，同时也在 TASK-16 的头文件注释中详细说明。

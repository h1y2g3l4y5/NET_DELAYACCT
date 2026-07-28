# TASK-16 更新头文件语义注释 + 同步 0006 patch

- **日期**: 2026-07-27
- **关联 Review**: v3.0.0 (v3.0.2 复审)
- **关联问题**: 后续建议 #3（文档化语义）
- **关联需求/Issue**: 无

## 1. 任务描述

v3.0.2 复审报告"后续建议 #3"要求：在头文件注释中明确 `rx_start`/`rx_end`/`tx_start`/`tx_end` 的语义，特别是 GRO/GSO 粒度说明。当前 `include/net/net-delayacct.h` 的注释存在两个问题：
1. `net_delayacct_tx_start` 注释仍写 "Called at tcp_sendmsg / udp_sendmsg entry"，但 NEW-BUG-8 已删除 tcp_sendmsg_locked 中的 tx_start 调用，实际调用点已变。
2. 缺少 GRO/GSO 粒度、TCP/UDP rx_end 语义差异等设计权衡说明。

## 2. 变更内容

### 2.1 `include/net/net-delayacct.h`（位于 `/home/lai/Code/linux-6.6/`）

文件从 147 行扩展到 184 行（+37 行注释），代码逻辑零改动。

#### 2.1.1 `net_delayacct_rx_start` 注释更新

新增 GRO 位置说明和粒度说明：
```c
/**
 * net_delayacct_rx_start - stamp RX start time on an skb
 * @skb: the incoming &sk_buff
 *
 * Called at the protocol stack entry (__netif_receive_skb_core), which
 * sits after GRO merge and NAPI poll, inside the RCU read-side section.
 * The timestamp is carried in skb->delayacct_start and consumed by
 * net_delayacct_rx_end() when the payload is delivered to user space.
 *
 * Granularity note: when GRO merges multiple fragments into one skb,
 * rx_start is stamped on the merged skb and therefore captures the
 * arrival time of the last fragment, not the first.  This is a design
 * trade-off: we measure intra-stack processing latency, not driver
 * poll latency.
 */
```

#### 2.1.2 `net_delayacct_rx_end` 注释更新

新增 TCP/UDP 调用点语义差异说明：
```c
 * Call-site semantics (deliberate asymmetry between TCP and UDP):
 *  - TCP: rx_end is recorded at skb dequeue time (found_ok_skb in
 *    tcp_recvmsg_locked, tcp_read_sock splice path, tcp_zerocopy
 *    receive path).  Checksum was already validated on the RX input
 *    path before the skb was enqueued, so dequeue time == delivery
 *    time.  Guarded by !MSG_PEEK in tcp_recvmsg_locked.
 *  - UDP: rx_end is recorded after checksum validation AND successful
 *    copy to user space, so corrupted packets are not counted.  This
 *    is required because UDP software checksum verification may happen
 *    during copy (skb_copy_and_csum_datagram_msg).  Guarded by
 *    !peeking in udp_recvmsg/udpv6_recvmsg.
```

#### 2.1.3 `net_delayacct_tx_start` 注释更新

修正调用点描述（移除 tcp_sendmsg_locked 引用），列出所有实际调用点：
```c
 * Stamp the skb just before it enters the IP layer.  Call sites:
 *  - TCP: __tcp_transmit_skb() clone block (covers all clone_it=1
 *    paths: first transmission, normal retransmit, SYN/SYNACK, Fast
 *    Open, SYN-cookie ACK, repair mode, MTU probe) and the
 *    __tcp_retransmit_skb() pskb_copy path (clone_it=0 retransmit
 *    when skb data is unaligned or headroom is too large).
 *  - UDP: udp_sendmsg()/udpv6_sendmsg() fast path (after ip_make_skb/
 *    ip6_make_skb) and udp_push_pending_frames()/udp_v6_push_pending
 *    _frames() (covers all corked flush paths: do_append_data,
 *    splice_eof, setsockopt(UDP_CORK=0)).
 *
 * Control packets (pure ACK, RST, zero-window probe) are allocated
 * via alloc_skb which zero-initializes delayacct_start; tx_end guards
 * against start==0 so they are not counted.
```

#### 2.1.4 `net_delayacct_tx_end` 注释更新

新增 GSO 分段粒度说明：
```c
 * Granularity note: when a GSO super-packet is segmented in
 * dev_hard_start_xmit, each segment calls tx_end once, so tx_count is
 * inflated by the number of segments.  The delayacct_start is
 * propagated to each segment via __copy_skb_header, so per-segment
 * latency values remain accurate.
```

### 2.2 `kernel-patches/0006-net-add-internal-header.patch`

完整重新生成，保持全零 hash 风格（与 0005/0007/0008/0009/0010 一致）：
- diffstat: `147 +++...` → `184 +++...`
- hunk header: `@@ -0,0 +1,147 @@` → `@@ -0,0 +1,184 @@`
- body: 184 行（每行加 `+` 前缀，与源文件字节一致）

## 3. 变更原因

1. **注释准确性**: NEW-BUG-8 修复后 `tcp_sendmsg_locked` 不再调用 `tx_start`，原注释会误导维护者。
2. **设计文档化**: v3.0.0 报告中的 P2 设计权衡（GRO/GSO 粒度、rx_end 语义不对称）原本只存在于 review 报告中，现在写入头文件注释，让代码本身成为自包含的设计文档。
3. **patch 同步**: 头文件是 0006 patch 创建的，源码改动必须同步到 patch，否则 CI 构建的代码与开发树不一致。

## 4. 踩坑记录

- **坑1**: 手动编辑 patch 文件的 diffstat plus 数量容易算错。
  - **原因分析**: git 的 diffstat plus 数量按 (lines / total_scale) 缩放，不是简单的 line_count。
  - **解决方案**: 用 Python 脚本生成 patch，plus 数量按原比例缩放（147 lines → 35 plus，184 lines → 44 plus）。diffstat 仅是可视化，plus 数量精确与否不影响 `git apply`。
  - **如何避免**: 后续若需重新生成 patch，统一用脚本而非手动编辑。

- **坑2**: patch body 的行尾换行处理。
  - **原因分析**: Python `read().split('\n')` 会在末尾产生空字符串，`join` 时若不处理会产生多余空行。
  - **解决方案**: 脚本中显式 `pop()` 末尾空字符串，并用 `rstrip('\n')` 处理源文件。
  - **验证**: 用 Python 脚本逐行比对 patch body 与源文件，确认 184 行完全 MATCH。

## 5. 测试验证

- **patch body 与源文件一致性**: Python 脚本逐行比对，184 行全部 MATCH ✅
- **patch 应用测试**: 在 `/tmp/patch-test` 干净 git 仓库中 `git apply --check` + `git apply`，应用成功且内容与源文件 `diff -q` 无差异 ✅
- **checkpatch 验证**: `./scripts/checkpatch.pl --no-tree -f 0006-net-add-internal-header.patch` 返回 "0 errors, 0 warnings, 212 lines checked" ✅
- **trailing whitespace**: 0006 patch `grep -nE ' +$'` 返回 0 ✅
- **内核编译**: 由 TASK-17 的全量 `local-test.sh` 验证（仅注释改动，不影响编译）

## 6. 待办/遗留问题

- **NEW-BUG-9 (P2) TCP/UDP TX 语义不一致**: 已在 `net_delayacct_tx_start` 注释中说明 TCP 包含 `__tcp_transmit_skb` 内的 TCP 头构建处理，UDP tx_start 设置稍晚（几乎在 ip_send_skb 入口）。这属于文档层面，不影响正确性。后续若 Reviewer 要求更细致的语义对齐，可单独发起讨论。
- **rx_end 语义不对称**: 已在 `net_delayacct_rx_end` 注释中明确说明 TCP（dequeue time）和 UDP（copy+checksum success time）的差异及原因。这是设计选择，不需要修复。

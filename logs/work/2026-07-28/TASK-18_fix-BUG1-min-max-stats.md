# TASK-18 修复 BUG-1: 缺少延迟极值（min/max）统计

- **日期**: 2026-07-28
- **关联 Review**: v4.0.0
- **关联问题**: BUG-1 [P1]
- **关联需求/Issue**: v4.0.0 设计深度审查

## 1. 任务描述

v4.0.0 审查发现 `struct net_delayacct_stats` 仅有 `rx_total_ns`/`rx_count`/`tx_total_ns`/`tx_count` 四个字段，缺少延迟极值（min/max）统计。平均值会掩盖突发高延迟事件，无法识别尾部延迟（tail latency）毛刺，不满足生产性能分析需求。

本任务扩展统计结构，添加 min/max 字段，并在内核累加逻辑和用户态工具中同步实现。

## 2. 变更内容

### 2.1 UAPI 头文件 (`include/uapi/linux/net-delayacct.h`)

扩展 `struct net_delayacct_stats`，新增 4 个字段：

```c
struct net_delayacct_stats {
    __u64 rx_total_ns;
    __u64 rx_count;
    __u64 rx_min_ns;   /* 新增 */
    __u64 rx_max_ns;   /* 新增 */
    __u64 tx_total_ns;
    __u64 tx_count;
    __u64 tx_min_ns;   /* 新增 */
    __u64 tx_max_ns;   /* 新增 */
};
```

新增 4 个 Netlink 属性枚举：`NET_DELAYACCT_A_RX_MIN_NS`、`NET_DELAYACCT_A_RX_MAX_NS`、`NET_DELAYACCT_A_TX_MIN_NS`、`NET_DELAYACCT_A_TX_MAX_NS`。

文档注释补充 min/max 语义说明。

### 2.2 内部头文件 (`include/net/net-delayacct.h`)

`net_delayacct_init()` 中初始化 min/max：
```c
n->stats.rx_min_ns = U64_MAX;  /* 第一个样本总是更小 */
n->stats.tx_min_ns = U64_MAX;
```
max_ns 由 memset 清零，初始为 0，第一个样本总是更大。

### 2.3 内核模块 (`net/core/net-delayacct.c`)

`net_delayacct_rx_end()` 累加逻辑增加 min/max 更新：
```c
if (delta < n->stats.rx_min_ns)
    n->stats.rx_min_ns = delta;
if (delta > n->stats.rx_max_ns)
    n->stats.rx_max_ns = delta;
```

`net_delayacct_tx_end()` 同理。

`net_delayacct_reset()` 中重置 min/max：
```c
n->stats.rx_min_ns = U64_MAX;
n->stats.tx_min_ns = U64_MAX;
```

`net_delayacct_fill_sock()` 中增加 4 个 nla_put_u64_64bit 调用，向用户态传递 min/max。

### 2.4 用户态工具 (`userspace/get_sockdelays/get_sockdelays.c`)

解析新增的 4 个 Netlink 属性，在文本和 JSON 输出中显示 min/max：
```
RX  count=8        total=    12.345ms  average=    1.543ms  min=    0.123ms  max=    5.678ms
```

当 count==0 时，内核报告 min=U64_MAX/max=0，用户态归一化为 0 显示。

## 3. 变更原因

- **尾部延迟是网络性能分析的核心痛点**：平均值 1ms 可能意味着所有包 1ms（健康），或 99% 是 0.1ms + 1% 是 100ms（严重问题）
- **O(1) 复杂度**：min/max 只需两次比较，性能开销可忽略
- **无需保存所有样本**：相比直方图（HDR Histogram），min/max 是最小侵入式的极值统计
- **min_ns 初始化为 U64_MAX**：确保第一个样本总是更小，避免初始化为 0 时 min 永远为 0 的 bug

## 4. 踩坑记录

- **坑1**: count==0 时 min=U64_MAX 会导致用户态显示一个巨大的值
  - **原因**: memset 清零后 min 被设为 U64_MAX，如果没有包到达，min 保持 U64_MAX
  - **解决方案**: 用户态在 count==0 时将 min 归一化为 0 显示
  - **如何避免**: UAPI 文档注释中明确记录 "U64_MAX if no packets"

## 5. 测试验证

- 内核编译: PASS (exit 0, bzImage #53)
- QEMU 测试: **13/13 PASS, 0 FAIL, 0 SKIP** (TCG 模式, 132s)
- checkpatch: 0005 (0 errors, 96 lines), 0006 (0 errors, 220 lines), 0007 (0 errors, 728 lines)
- min/max 输出验证:
  - `RX count=4 total=9.999ms average=2.500ms min=0.877ms max=6.332ms` — min < avg < max ✓
  - `TX count=2041 total=86.977ms average=0.043ms min=0.006ms max=1.446ms` ✓
  - `RX count=73 total=91.088ms average=1.248ms min=0.312ms max=17.325ms` ✓
  - count=0 时 min=0.000ms max=0.000ms（U64_MAX 归一化）✓
- 并发压力测试: 320 queries, ok=320 fail=0, no oops ✓

## 6. 待办/遗留问题

- ✅ 已验证通过，无遗留问题
- 后续可考虑扩展标准差/分位数统计（v5.0.0）

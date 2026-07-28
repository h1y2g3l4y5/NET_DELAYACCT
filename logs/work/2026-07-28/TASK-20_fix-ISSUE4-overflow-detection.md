# TASK-20 修复 ISSUE-4: 64 位计数器溢出检测

- **日期**: 2026-07-28
- **关联 Review**: v4.0.0
- **关联问题**: ISSUE-4 [P2]
- **关联需求/Issue**: v4.0.0 设计深度审查

## 1. 任务描述

v4.0.0 审查指出 `rx_total_ns`/`tx_total_ns` 是 `__u64`，虽然理论溢出时间约 584 年（1Mpps @ 1ms/包），但在高吞吐场景（10 Mpps+）下缩短至 58 年，且虚拟化/容器环境可能长期运行。计数器溢出后回绕到 0，会导致监控告警误判"延迟突然下降"。

本任务添加溢出检测，在累加前检查是否会溢出，并通过 `pr_warn_once` 告警。

## 2. 变更内容

### 2.1 内核模块 (`net/core/net-delayacct.c`)

`net_delayacct_rx_end()` 累加前增加溢出检查：
```c
if (n->stats.rx_total_ns > U64_MAX - delta)
    pr_warn_once("net_delayacct: RX total_ns overflow on socket %p\n", sk);
n->stats.rx_total_ns += delta;
```

`net_delayacct_tx_end()` 同理：
```c
if (n->stats.tx_total_ns > U64_MAX - delta)
    pr_warn_once("net_delayacct: TX total_ns overflow on socket %p\n", sk);
n->stats.tx_total_ns += delta;
```

### 2.2 设计说明

- 使用 `pr_warn_once` 而非 `pr_warn`：避免高吞吐场景下日志洪泛，仅首次溢出时告警一次
- 检查在 spinlock 保护内：避免检查和累加之间的竞态
- 溢出后仍执行累加（回绕到小值）：不丢弃统计数据，仅告警让运维知晓
- 未使用 `atomic64_t` + 饱和算术：当前 spinlock 保护已足够，饱和算术会改变计数器语义

## 3. 变更原因

- **防御性编程**：即使概率极低（584 年），也应明确处理边界条件
- **pr_warn_once 选择**：高吞吐场景下每次包都检查，如果用 pr_warn 会导致日志洪泛；pr_warn_once 仅首次告警，运维可通过 `dmesg` 发现
- **不阻止累加**：溢出后回绕是 `__u64` 的自然行为，阻止累加会导致统计数据完全丢失，比回绕更糟糕
- **在 lock 内检查**：确保检查和累加是原子的，避免 TOCTOU

## 4. 踩坑记录

无新踩坑。overflow 检查是纯增量逻辑，不影响现有路径。

## 5. 测试验证

- 内核编译: PASS (exit 0, bzImage #53)
- QEMU 测试: **13/13 PASS, 0 FAIL, 0 SKIP** (TCG 模式, 132s)
- checkpatch: 0007 patch 0 errors, 0 warnings
- overflow 告警: 无（预期 — 584 年才溢出，测试场景无法触发）✓
- 并发压力测试: 320 queries, ok=320 fail=0, no oops ✓

## 6. 待办/遗留问题

- ✅ 已验证通过，无遗留问题
- 实际溢出场景难以构造测试（需要 584 年），仅验证代码路径编译通过且不影响正常功能
- 后续可考虑添加 `sysfs` 接口暴露溢出计数（v5.0.0）

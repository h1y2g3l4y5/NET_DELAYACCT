# [TASK-45] 性能报告文档 docs/PERFORMANCE.md

- **日期**: 2026-08-03
- **关联需求**: v6.4.0 Review 议题 1（方案 C 前提：必须产出含多次运行数据与建议稳定阈值的报告）
- **状态**: 完成

## 1. 任务描述

编写 `docs/PERFORMANCE.md` 性能报告文档，汇总 TASK-43 收集的 ON/OFF 对比
数据，分析 net_delayacct 引入的性能开销，给出通过/失败判定和后续计划。

## 2. 变更内容

### 新增文件

| 文件 | 说明 |
|------|------|
| `docs/PERFORMANCE.md` | 性能基准测试报告，含测试矩阵、环境、原始数据、对比分析、通过判定 |

## 3. 变更原因

v6.4.0 Review 议题 1 达成方案 C 共识：v6.4.0 性能测试仅落地为本地脚本+
报告文档，CI 暂不接入，**前提是必须产出 docs/PERFORMANCE.md 含多次运行
数据与建议稳定阈值**。本任务即满足该前提。

## 4. 踩坑记录

### 坑1：/proc/slabinfo 不可用 → 无法运行时测量 sock objsize

- **问题**: 内核使用 `CONFIG_SLUB=y`（非 SLAB），默认不提供 `/proc/slabinfo`；`/sys/kernel/slab/sock-*` 需要 `CONFIG_SLUB_DEBUG=y`，当前未启用
- **解决**: 改为通过 struct 定义理论计算：`spinlock_t (4) + padding (4) + net_delayacct_stats (64) = 72 bytes`
- **避免**: 测试内核配置中启用 `CONFIG_SLUB_DEBUG=y` 以支持运行时 slab 测量

### 坑2：TCP 延迟指标在 TCG 下无法有效判定

- **问题**: ON/OFF TCP 延迟差 768 μs，远超 10 μs 阈值，但理论开销仅 ~0.5 μs
- **原因**: TCG 模式下 loopback connect() 延迟本身 14000-17000 μs，波动 ±1500 μs，768 μs 差异在噪声范围
- **解决**: 报告中标注 "TCG 噪声" 并给出理论分析，待 KVM 环境补充数据
- **避免**: TCG 模式下延迟类指标仅作参考，有效判定需 KVM 或裸金属环境

## 5. 测试验证

文档内容基于 TASK-43 收集的实测数据（3 次运行取中位数），包含：
- 完整原始数据表（ON/OFF 各 3 次 run）
- 对比汇总表（中位数 + 变化百分比 + 阈值 + 判定）
- 每 socket 内存理论计算（72 bytes，含 struct 定义推导）
- 5 项指标的逐一分析（开销来源、TCG 放大效应、KVM 预期）
- 局限性与 v6.5.0 后续计划

## 6. 待办/遗留问题

- [ ] KVM 环境补充数据后更新报告
- [ ] 多轮运行后更新阈值建议
- [ ] v6.5.0 CI 接入后补充 CI 运行结果

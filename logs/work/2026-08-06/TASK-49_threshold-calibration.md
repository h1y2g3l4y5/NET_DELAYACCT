# [TASK-49] 基于多轮数据微调阈值

- **日期**: 2026-08-06
- **关联 Review**: v6.5.0 议题1（阈值校准）
- **状态**: [已完成] 无需调整

## 1. 任务描述

基于 TASK-48 收集的多轮性能数据，评估当前阈值是否需要微调。

## 2. 阈值评估

### 2.1 当前阈值（v6.5.0 TASK-54 校准后）

| 编号 | 指标 | 阈值 | 校准依据 |
|------|------|------|----------|
| Perf-1 | TCP 吞吐下降 | < 5% | CI KVM run #137: 3.3% |
| Perf-2 | UDP PPS 下降 | < 15% | CI KVM run #137: -7.5% (INVALID) |
| Perf-3 | TCP 延迟增加 | < 10% (相对) | CI KVM run #137: 3.1% |
| Perf-4 | 每 socket 内存 | ≤ 192 bytes | pahole 72B + slab align 56B + 余量 |
| Perf-5 | CPU 利用率增加 | < 10% (相对) | CI KVM run #137: 7.9% |

### 2.2 多轮数据验证

| 指标 | KVM (run#137) | TCG R1 | TCG R2 | TCG R3 | TCG CV | 阈值合理性 |
|------|---------------|--------|--------|--------|--------|-----------|
| tcp_throughput | 3.3% PASS | 8.9% FAIL | 18.9% FAIL | 5.3% FAIL | 64% | ✅ KVM 稳定 PASS，TCG 不适用 |
| udp_pps | -7.5% INVALID | 18.6% FAIL | 25.7% FAIL | 6.9% PASS | 56% | ✅ KVM INVALID，TCG 不适用 |
| tcp_latency | 3.1% PASS | 11.4% FAIL | -2.1% INVALID | 0.6% PASS | 217% | ✅ KVM 稳定 PASS，TCG 不适用 |
| cpu_util | 7.9% PASS | 1.1% PASS | 0.0% PASS | -1.1% INVALID | — | ✅ 全环境稳定 PASS |
| sock_objsize | +128 PASS | +64 PASS | +64 PASS | +64 PASS | 0% | ✅ 完美稳定 |

### 2.3 决策：无需调整

**理由**：
1. **KVM 环境（CI 目标环境）**：5 项指标全部 PASS 或 INVALID，无 FAIL
2. **TCG 环境**：高 CV（56-217%）确认 TCG 不适合阈值验证，FAIL 是噪声非回归
3. **静态指标**：sock_objsize CV=0%，阈值 192 对 +64(TCG)/+128(KVM) 均有充足余量
4. **cpu_util**：KVM 7.9% 离 10% 阈值有 2.1% 余量，TCG 始终 <2%，阈值合理
5. **FAIL→warn 设计**：即使 KVM 偶尔 FAIL（如 run #139 推测 cpu_util），warn 模式不阻断

**如果需要为 TCG 单独设阈值**（非当前需求，仅记录）：
- tcp_throughput: < 25%（TCG 均值 11%，最大 18.9%）
- udp_pps: < 30%（TCG 均值 17%，最大 25.7%）
- tcp_latency: < 20%（TCG 含 INVALID，不稳定）
- 但 TCG 阈值无实际意义，因 CI 使用 KVM

## 3. pahole 验证补充（TASK-53）

pahole 确认 struct net_delayacct = 72 bytes：
- 72B struct + 56B SLAB_HWCACHE_ALIGN padding = 128B slab delta (KVM)
- 阈值 192 = 128 + 50% 余量，合理
- 原始 struct 72B 仍在理论 80B 阈值内（v6.4.0 原始阈值）

## 4. 结论

当前阈值（v6.5.0 TASK-54 校准后）**无需调整**：
- KVM 环境全指标 PASS/INVALID，阈值有合理余量
- TCG 环境不适用（噪声主导，CV 56-217%）
- FAIL→warn 设计确保偶发 FAIL 不阻断 CI
- 后续如获取 5+ 轮 KVM 数据可进一步确认（当前 1 轮 KVM + 3 轮 TCG）

## 5. 待办/遗留问题

- [x] 阈值评估完成：无需调整
- [x] 多轮数据验证：3 轮 TCG + 1 轮 KVM
- [x] pahole 验证补充：struct 72B 确认
- [ ] CI KVM 多轮数据收集（需 admin 权限，当前仅单轮）

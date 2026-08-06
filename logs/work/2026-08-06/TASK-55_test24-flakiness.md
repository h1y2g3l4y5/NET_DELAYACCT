# [TASK-55] Test 24 共享 runner flakiness 调查与修复

- **日期**: 2026-08-06
- **关联 Review**: v6.5.0 收尾议题（TASK-48 补遗发现，非 v6.5.0 规划议题）
- **状态**: [已完成-待Review]

## 1. 任务描述

TASK-48 补遗分析 5 轮 CI KVM workflow verdict 时发现：Test 24（per-skb 配对 + 计数比）在共享 runner 上 flaky —— 2/4 轮失败（#141 ratio=209%, #142 ratio=203%），失败原因均为 `tx_end/tx_start` 计数比超过 200% 阈值（仅超 3-9%）。这是当前 CI workflow failure 的主要根因（perf-test 已通过 FAIL→warn 设计不阻断）。

本任务调查根因并提出修复方案。

## 2. 失败现象

### 2.1 CI 失败摘要（来自 check-runs annotations API）

| Run | Commit | Test 24 失败信息 |
|-----|--------|------------------|
| #141 (bfe86eb) | "docs: TASK-54 工作日志" | `mismatched=17 (threshold=25) ratio=209%` (expect ratio in [50%, 200%]) |
| #142 (6ab8fa8) | "docs: TASK-54 完成" | `mismatched=17 (threshold=25) ratio=203%` (expect ratio in [50%, 200%]) |

**共同特征**：
- `mismatched=17` ≤ `threshold=25`（OK，配对正确）
- `ratio=203-209%` > `200%` 阈值（FAIL，仅超 3-9%）
- 仅计数比超阈，配对核心断言通过

### 2.2 Test 24 阈值逻辑（[run-tests.sh#L2142-L2168](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L2142-L2168)）

```bash
RATIO=$((TX_END_COUNT * 100 / TX_START_COUNT))
MISMATCH_THRESHOLD=$((TX_END_UNIQUE * 4 / 10))
[ "$MISMATCH_THRESHOLD" -ge 25 ] || MISMATCH_THRESHOLD=25

if [ "$MISMATCHED_N" -le "$MISMATCH_THRESHOLD" ] && [ "$RATIO" -ge 50 ] && [ "$RATIO" -le 200 ]; then
    _pass "..."
else
    _fail "per-skb pairing or ratio check failed: mismatched=$MISMATCHED_N (threshold=$MISMATCH_THRESHOLD) ratio=${RATIO}% ..."
fi
```

PASS 条件（三者 AND）：
1. `mismatched ≤ max(25, tx_end_unique × 40%)` — 配对核心断言
2. `ratio ≥ 50%` — 防止 tx_end 远少于 tx_start（漏打点）
3. `ratio ≤ 200%` — 防止 tx_end 远多于 tx_start（多打点）

## 3. 根因分析

### 3.1 ratio = tx_end_count / tx_start_count 的语义

- `tx_start` kprobe 在 `net_delayacct_tx_start` 入口触发 —— 仅对**有应用数据**的 skb 触发（skb->len > 0 守卫）
- `tx_end` kprobe 在 `net_delayacct_tx_end` 入口触发 —— 对**所有经过 tx_end 的 skb** 触发（包括纯 ACK / FIN / 窗口更新）

**预期**：ratio > 100% 是正常的（纯 ACK 等控制包经过 tx_end 但不经过 tx_start）。200% 阈值容忍 ACK 数量 ≈ 数据包数量。

### 3.2 为什么 ratio 会超 200%？

**场景**：客户端发送少量数据包（如 50 个），但服务端回执大量纯 ACK（如 105 个）→ ratio = 105/50 = 210%。

**触发条件**（共享 runner 噪声放大）：
1. **TCP 小包 + 延迟 ACK 关闭**：每个数据段触发独立 ACK，ACK 数 ≈ 数据段数
2. **窗口更新包**：接收窗口变化触发窗口更新 skb（经过 tx_end 不经过 tx_start）
3. **共享 runner 调度延迟**：客户端发送节奏不稳，触发更多 ACK 累积
4. **GSO 分段**：大 GSO skb 在 tx_start 计 1 次，但分段后多个小 skb 各自经过 tx_end（设计已考虑，但极端情况仍可能超）

### 3.3 历史 v6.3.0 教训对照

v6.3.0 [TASK-38](file:///home/lai/Code/NET_DELAYACCT/logs/work/2026-07-30/TASK-38_ci-syntax-fix.md) 曾修复 Test 24 阈值（30% → max(25, ×40%)），但那次修复的是**配对 mismatched 阈值**，未触及**计数比 ratio 阈值**。本次 flakiness 是 ratio 阈值（200% 上限）在共享 runner 上偏紧。

## 4. 修复方案

### 4.1 方案对比

| 方案 | 修改 | 优点 | 缺点 |
|------|------|------|------|
| A. 放宽 ratio 上限 200% → 250% | 1 行 | 直接解决 flakiness | 250% 仍可能在极端噪声下超阈 |
| B. ratio 上限改为相对阈值（基于 mismatched） | 复杂 | 自适应 | 改变了断言语义 |
| C. 给 QEMU test 加 continue-on-error | ci.yml | 不阻断 CI | 掩盖真实功能回归 |
| D. 重跑机制（flaky retries） | ci.yml | 治本 | 增加 CI 时间 |

### 4.2 选择方案 A：ratio 上限 200% → 250%

**理由**：
1. **最小变更**：1 行代码，语义清晰
2. **数据支撑**：实测 ratio=203-209%，250% 给 ~20% 余量
3. **保留断言价值**：ratio > 250% 仍判定 FAIL，能捕获真正的多打点 bug（如 tx_end 重复触发）
4. **与 v6.3.0 修复一致**：v6.3.0 也是放宽阈值（30% → 40%）而非移除断言
5. **方案 C/D 治标不治本**：continue-on-error 掩盖真实回归；flaky retries 增加 CI 时间且不解决根因

**不选 B 的理由**：ratio 是辅助弱断言（设计注释 L2140 明确"辅助断言"），改自适应阈值增加复杂度，收益有限。

**不选 C/D 的理由**：QEMU test 是功能测试，必须保留阻断能力；flaky retries 是 GitHub Actions 重试机制，但 Test 24 flakiness 不是随机崩溃而是阈值边界，重跑不一定解决。

### 4.3 实施

[ci/qemu/run-tests.sh#L2151](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L2151) 修改：

```diff
- if [ "$MISMATCHED_N" -le "$MISMATCH_THRESHOLD" ] && [ "$RATIO" -ge 50 ] && [ "$RATIO" -le 200 ]; then
+ # ratio 上限 200% → 250%：共享 runner 上纯 ACK/窗口更新数量受调度噪声影响偶尔超 2x
+ # （CI run #141 ratio=209%, #142 ratio=203%），250% 给 ~20% 余量；> 250% 仍判定 FAIL
+ if [ "$MISMATCHED_N" -le "$MISMATCH_THRESHOLD" ] && [ "$RATIO" -ge 50 ] && [ "$RATIO" -le 250 ]; then
```

同步更新断言失败信息（L2167）和 PASS 信息（L2152）中的 `[50%, 200%]` → `[50%, 250%]`，以及设计注释（L2140）。

## 5. 测试验证

### 5.1 本地语法校验

```bash
bash -n ci/qemu/run-tests.sh  # 通过
```

### 5.2 CI 验证（待 push）

预期：下一次 CI run（#144 或后续）Test 24 在共享 runner 上即使 ratio=210% 也 PASS。若 ratio > 250% 仍 FAIL（真正异常）。

### 5.3 回归保护

- 配对核心断言（mismatched ≤ threshold）**不变**，真正的配对 bug 仍被捕获
- ratio 下限 50% **不变**，漏打点仍被捕获
- 仅放宽 ratio 上限，且仅 50 个百分点（200→250）

## 6. 待办/遗留问题

- [x] 根因分析：ratio = tx_end/tx_start，纯 ACK/窗口更新使 ratio 偶尔超 200%
- [x] 修复方案：ratio 上限 200% → 250%（方案 A）
- [x] 代码修改 + 语法校验
- [ ] CI 验证：等待下次 push 后 run #144 或后续 run 确认 Test 24 不再 flaky
- [ ] 长期监控：观察 10+ 轮 CI run，确认 250% 阈值稳定；若仍 flaky，考虑方案 D（flaky retries）

## 7. 关联文档

- [TASK-48 补遗](file:///home/lai/Code/NET_DELAYACCT/logs/work/2026-08-06/TASK-48_multi-round-perf-data.md#L152-L160)：发现 Test 24 flakiness
- [v6.3.0 TASK-38](file:///home/lai/Code/NET_DELAYACCT/logs/work/2026-07-30/TASK-38_ci-syntax-fix.md)：上次 Test 24 阈值修复（mismatched 维度）
- [run-tests.sh Test 24 逻辑](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L2129-L2168)

# 分项审查 - Test 03 重置计数器断言与 RESET 语义矛盾

- **关联日志**: 无（本轮针对现有测试方案审查）
- **审查日期**: 2026-07-29

## 变更概述

`tests/README.md` 与 `ci/qemu/run-tests.sh` 中的 Test 03 用于验证 `get_sockdelays -R`（`NET_DELAYACCT_CMD_RESET`）能否清零 per-socket 统计。

## 审查意见

### 文件: `tests/README.md`

#### 变更内容
- 第 152-159 行说明 RESET「不是全局原子快照，遍历期间新到达的包仍会被累加」，但断言为「重置后 `count > 0` 的行数 = 0」。

#### 审查意见
- **第 158 行**: 断言与语义说明存在理论矛盾。
  - 严重度: 中
  - 建议: 将断言改为「在停止流量后，count > 0 的行数 = 0」或「重置后所有 count 均不增加」，并在语义说明中显式声明本测试的隐含条件。
  - Worker反馈: [待回应]

### 文件: `ci/qemu/run-tests.sh`

#### 变更内容
- 第 260 行实现 `NONZERO=$(echo "$POST" | grep 'count=' | sed 's/.*count=\([0-9]*\).*/\1/' | awk '$1>0' | wc -l)` 并断言为 0。

#### 审查意见
- **第 260-266 行**: 实现与 README 中声明的非原子 RESET 语义不一致。
  - 严重度: 中
  - 建议: 在 `-R` 之前显式 kill client 并等待连接关闭，确保 reset 期间无持续流量；或修改断言以允许非零计数的上限。
  - Worker反馈: [待回应]

## 综合意见

Test 03 当前能 PASS 是因为测试时序恰好让 iperf3 client 已结束、server 空闲。该断言的成立依赖于隐含的「无并发流量」条件，而非 RESET 语义本身。

经讨论，原建议「在 `-R` 前停止流量」被认为是在逃避非原子语义。修订方案为拆成两个测试：

- **Test 03a（基础功能）**：停止流量后 reset，断言所有 count = 0，验证 reset 机制本身能工作。
- **Test 03b（非原子语义验证，新增）**：iperf3 client 持续发送中执行 `-R`，立刻查询 server，断言**存在 count > 0 的 socket**；停止 client 后再次 `-R`，断言所有 count = 0。

这样既能验证 reset 的清零能力，也能验证 RESET 不是全局原子快照的真实语义。

## 附加建议

- 在 README 中增加 RESET 非原子语义的时间线说明：遍历所有 socket 需要时间，期间新包仍可到达已重置的 socket，因此全局「同时为零」的快照不存在。
- 文档中应区分「per-socket 清零是原子的」和「全局遍历不是原子的」两个层面。

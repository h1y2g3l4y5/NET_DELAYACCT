# 分项审查 - Test 13 并发查询压力未覆盖真实并发路径

- **关联日志**: 无（本轮针对现有测试方案审查）
- **审查日期**: 2026-07-29

## 变更概述

Test 13 用于验证内核侧 Netlink dumpit 在多进程并发查询时的安全性，防止死锁、竞态和 Kernel Oops。

## 审查意见

### 文件: `tests/README.md`

#### 变更内容
- 第 279-288 行说明 Test 13 启动 16 个 worker，每个查询 PID 1 共 20 次，总计 320 次查询。

#### 审查意见
- **第 286 行**: 「为什么查 PID 1？」的解释不足。
  - 严重度: 高
  - 建议: 明确说明 PID 1 空查询只能覆盖 Netlink 协议层和空 fdtable 遍历，不能覆盖 per-socket spinlock 路径；并给出增强计划。
  - Worker反馈: [待回应]

### 文件: `ci/qemu/run-tests.sh`

#### 变更内容
- 第 742-756 行 `_worker()` 函数只执行 `"$GET_SOCKDELAYS" -p 1`。

#### 审查意见
- **第 748 行**: 所有 worker 仅查询 PID 1，不访问任何 socket 的统计字段。
  - 严重度: 高
  - 建议: 将部分 worker 改为查询一个持有多个活跃 socket 的 busy PID（如 iperf3 server），或新增独立测试覆盖 busy PID 并发查询。
  - Worker反馈: [待回应]

## 综合意见

Test 13 的设计无法有效暴露 per-socket 并发安全问题：
- PID 1 通常没有 socket，dumpit 只需遍历空 fdtable，不调用 `net_delayacct_fill_sock()`。
- 因此不会获取任何 `sk->sk_lock.slock`，也不会访问 `struct net_delayacct` 统计字段。
- 无法覆盖 dumpit 与 socket 创建/关闭之间的竞争、过滤条件并发安全、cb->ctx 状态等真实风险。

## 附加建议

推荐增强方案（三选一或组合）：
1. **混合查询**：8 个 worker 查 PID 1，8 个 worker 查 busy iperf3 server PID。
2. **新增 Test 17**：8 个 worker 各查询持有 8 条 TCP 流的 server 20 次，验证无 Oops/死锁。
3. **混合操作**：worker 交替执行「无过滤查询 busy PID」和「带 `--proto tcp` 过滤查询 busy PID」。

# 每日工作汇总 - 2026-08-01

## 今日完成任务
| 编号 | 任务 | 状态 | 备注 |
|------|------|------|------|
| TASK-31 | v6.1.0 Review 修复：假阳性消除 + ftrace 全量验证测试 | 完成 | P0 全部完成，P1 全部完成 |
| TASK-32 | 修复 CI 失败：Test 23 SKIP + Test 03 FAIL | 完成 | 23P/0F/1S（S7 环境限制 SKIP） |

## 关键决策
- **Test 03 POST 阈值取 PRE/2**：容忍非原子累加但要求"大幅下降"，与 Test 17 非原子语义一致
- **Test 23 S7 双轨备选**：netem → iptables 降级，均不可用时 SKIP 而非 FAIL，避免环境限制阻塞 CI
- **Test 19/20/21 内嵌 ftrace 归入 P0**：Reviewer 共识——不必等待 Test 23 矩阵完成，可独立实现
- **Test 08/13 顺手归入 P0**：改动小，避免单独占用一轮
- **Test 23 ftrace 函数改用 `__netif_rx`**：loopback 调用 `__netif_rx` 不调用 `netif_receive_skb`（NAPI 驱动入口）
- **Test 23 S6 顺序执行 TCP → UDP**：iperf3 server 一次只处理一个测试，同时连接会导致 UDP 控制连接失败
- **Test 03 停止 client 后再 reset**：与 Test 17 职责分离，Test 03 验证无流量下清零，Test 17 验证活跃流量下非原子

## 踩坑总结
- **坑 1**：Test 03 POST 阈值选择 → 应在 Review 阶段确认，避免实现后返工
- **坑 2**：Test 23 条件场景变量未初始化 → 条件执行的场景变量应赋默认值
- **坑 3**：ftrace filter 函数名匹配需覆盖两种 trace 格式 → 正则应在实际输出上验证
- **坑 4**：`netif_receive_skb` 在 loopback 不可追踪 → loopback 用 `__netif_rx`，NAPI 驱动才用 `netif_receive_skb`；选择 ftrace 函数前必须确认测试流量的实际内核调用链
- **坑 5**：iperf3 server 一次只处理一个测试 → TCP 和 UDP 不能同时连接同一 server（即使不同端口也可能竞争），应顺序执行
- **坑 6**：CI 与本地内核配置差异 → `ci.yml` 未合并 `kernel-qemu.config`（含 ftrace 配置），导致 CI 中 Test 23 始终 SKIP

## 明日计划
- 提交 git commit 并推送
- 等待 CI 完整构建验证（内核配置变更后编译时间增加）
- Reviewer 复审 v6.1.0 修复结果

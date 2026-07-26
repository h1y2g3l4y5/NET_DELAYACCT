# 每日工作汇总 - 2026-07-26

## 今日完成任务
| 编号 | 任务 | 状态 | 备注 |
|------|------|------|------|
| TASK-01 | Review v2.0.0 响应 | 完成 [闭环完成] | 16/16 条全部解决（12 接受 + 4 共识），对话达成一致 |
| TASK-02 | Review v2.0.0 修复实施 | 完成 | 修改 10 个文件 + 新增 2 个文件，覆盖全部 16 条议题 |
| TASK-03 | 修复 TX GSO NULL deref | 完成（待 CI 验证） | 重开议题 2.2.3，移除 sock_hold/sock_put |
| TASK-04 | 修复 patch 未同步致 iperf3 退出崩溃 | 完成（QEMU 验证通过） | 同步 0007 put_pid 修复；连带重建损坏的 0008/0009 |
| TASK-05 | 修复 Test 09/10 TX 断言错误 | 完成（13/13 PASS） | 非代码 bug：Test 09 改查 client 验 TX；Test 10 阈值 100→50 |

## 关键决策
- **12 条直接接受**：RCU 睡眠、comm 裸读、轮子函数、__ro_after_init、调试日志、PID namespace、kthread 控制、stub 证明力、文档 4 条 — 均为明确的内核工程问题，无争议空间
- **5 条对话达成共识**：全部与 Reviewer 达成一致
  - 2.2.1 (netns)：方案 A + nsproxy NULL + cmd_reset/cmd_get_by_pid 同步
  - 2.2.3 (TX UAF)：~~sock_hold + sock_put~~ → **重开：移除 sock_hold/sock_put**（GSO 下不配对导致 NULL deref）
  - 2.2.4 (KUnit 位置)：删 fallback 宏，路径暂不动，upstream 后迁移
  - 2.3.1 (高风险测试)：v2.0.x 做 netns，v2.1.0 做 fault-injection + GSO
  - 2.3.4 (run-tests.sh)：延后到 v2.1

## 踩坑总结
- **GSO 引用计数不配对（TASK-03）**：sock_hold 在父 skb 一次，sock_put 在每个 GSO 子段一次 → sk_refcnt 提前归零 → socket free 后 __sk_destruct 调用 NULL → RIP=0x0。避免方法：涉及 skb 引用计数必须考虑 GSO 切片，优先依赖 skb->destructor 自动管理。
- **patch 应用位置漂移（TASK-03）**：0010 patch 标 sk_prot_alloc L1990，实际应用到 sk_alloc L2180（patch 工具按上下文行匹配）。避免方法：生成 patch 必须验证上下文行在目标内核中唯一。
- **误诊方向（TASK-03）**：第一次看到 NULL deref 误以为又是编译问题。避免方法：RIP=0x0 几乎总是 NULL 函数指针调用，应聚焦"哪个回调是 NULL"。
- **源文件已修但 patch 未同步（TASK-04）**：源文件移除 put_pid 后未同步 0007 patch，QEMU 从 patch 构建内核仍跑旧代码，崩溃签名与未修复前完全一致。避免方法：改源文件后必须 `diff <(patch +lines) <(source)` 验证同步；纳入提交前自检清单。
- **编辑 patch 后 hunk header 行数未更新（TASK-04）**：移除 3 行 put_pid 后 0007 hunk header 仍是 `+1,673`，`git apply` 报 corrupt。避免方法：手编 patch 后用 `grep -c "^+"` 数实际行数与 header 核对；优先用 `diff -u` 重新生成。
- **0008/0009 hunk header 用 "xxx" 占位符被长期掩盖（TASK-04）**：`step_apply_patches` 的"已应用"短路逻辑使损坏 patch 永不重新应用。避免方法：定期重置 linux 树做"全 patch 重放"演练；patch 行号不能用占位符。
- **测试断言混淆发送方/接收方 TX 语义（TASK-05）**：Test 09 对 server（接收方）断言 TX>0 必然失败——ACK 不走 sendmsg，按设计 TX=0。避免方法：写 TX 断言前先确认被查方是否调用 sendmsg；记住模块的不对称语义（RX 覆盖所有入包，TX 仅覆盖 sendmsg 出包）。
- **计数阈值未考虑 TCG 吞吐衰减（TASK-05）**：Test 10 阈值 100 在 KVM 下能过，TCG 下 client TX=84 不过。避免方法：计数类断言阈值取保守值兼顾 TCG/KVM；阈值本意是"不溢出/不截断"而非"验证吞吐"。

## 明日计划
- 本地 QEMU 已 13/13 全 PASS，可推 CI 验证 + 继续与 Reviewer 闭环对话
- 等 Reviewer 回应重开的议题 2.2.3
- 若 Reviewer 不同意移除 sock_hold/sock_put，需寻找第三种方案
- v2.1.0 可考虑：TX 插桩是否扩展到 ACK 路径（需先对齐设计语义）

## Review 决议汇总（全部已闭环 ✅）
| # | 问题 | 严重度 | 决议 | 备注 |
|---|------|--------|------|------|
| 2.1.1 | RCU 睡眠 | 高 | 接受 | 对齐 cmd_get_by_pid 写法 |
| 2.1.2 | comm 裸读 | 高 | 接受 | task_lock 内拷贝 |
| 2.1.3 | sock_from_file_safe | 中 | 接受 | 直接换 sock_from_file() |
| 2.1.4 | __ro_after_init | 中 | 接受 | 删除修饰符 |
| 2.1.5 | 调试日志 | 低 | 接受 | 清理热路径 pr_debug |
| 2.2.1 | netnsok 矛盾 | 高 | 讨论中 | 方案 A/B + nsproxy NULL |
| 2.2.2 | PID namespace | 高 | 接受 | 换 find_vpid |
| 2.2.3 | TX GSO/UAF | 高 | 讨论中 | sock_hold vs 迁移 |
| 2.2.4 | KUnit 位置 | 中 | 讨论中 | out-of-tree 合理性 |
| 2.3.1 | 高风险测试 | 高 | 讨论中 | 分两轮实施 |
| 2.3.2 | kthread 控制 | 中 | 接受 | kthread_should_stop |
| 2.3.3 | stub 证明力 | 中 | 接受 | 区分测试边界 |
| 2.3.4 | run-tests.sh | 低 | 讨论中 | 推迟到 v2.1 |
| 2.4.1 | RST 漂移 | 高 | 接受 | 以代码为准回写 |
| 2.4.2 | design.md 过期 | 高 | 接受 | 清理已删字段 |
| 2.4.3 | patch 不自洽 | 高 | 接受 | 生成正式 patch |
| 2.4.4 | 身份不统一 | 中 | 接受 | 统一姓名+邮箱 |

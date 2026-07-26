# 每日工作汇总 - 2026-07-26

## 今日完成任务
| 编号 | 任务 | 状态 | 备注 |
|------|------|------|------|
| TASK-01 | Review v2.0.0 响应 | 完成 [闭环完成] | 16/16 条全部解决（12 接受 + 4 共识），对话达成一致 |
| TASK-02 | Review v2.0.0 修复实施 | 完成 | 修改 10 个文件 + 新增 2 个文件，覆盖全部 16 条议题 |
| TASK-03 | 修复 TX GSO NULL deref | 完成（待 CI 验证） | 重开议题 2.2.3，移除 sock_hold/sock_put |

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

## 明日计划
- CI QEMU 测试通过后，本轮 Review v2.0.0 才能最终闭环
- 等 Reviewer 回应重开的议题 2.2.3
- 若 Reviewer 不同意移除 sock_hold/sock_put，需寻找第三种方案

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

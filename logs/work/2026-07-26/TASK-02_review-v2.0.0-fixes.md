# TASK-02 Review v2.0.0 修复实施

- **日期**: 2026-07-26
- **关联 Review**: `logs/review/v2.0.0/REVIEW_REPORT.md`
- **状态**: [已完成]

## 1. 任务描述
根据 Review v2.0.0 的共识决议，逐项执行所有 16 条代码修复。

## 2. 变更内容

### 文件修改清单

| 文件 | 修改内容 | 关联议题 |
|------|----------|----------|
| `kernel-patches/net-core-net-delayacct.c` | RCU/comm/netns/PIDns/UAF/代码清理/身份统一 | 2.1.1/2.1.2/2.1.3/2.1.4/2.1.5/2.2.1/2.2.2/2.2.3/2.4.4 |
| `kernel-patches/include-net-net-delayacct.h` | tx_start 签名加 sk、sock_hold、copyright | 2.2.3/2.4.4 |
| `kernel-patches/tx-instrumentation.patch` | GSO 子段时间戳继承、sk 参数传递 | 2.2.3 |
| `kernel-patches/0010-sock-init-net-delayacct.patch` | **新增**：sock.c 初始化 patch | 2.4.3 |
| `.github/workflows/ci.yml` | 删除 sed 步骤 | 2.4.3 |
| `tests/selftests/net-delayacct/kunit/net-delayacct-test.c` | 删 fallback 宏、kthread_should_stop、tx_start sk 参数、stub 注释 | 2.2.4/2.3.2/2.3.3 |
| `tests/selftests/net-delayacct/netns-isolation.sh` | **新增**：netns 隔离集成测试 | 2.3.1 |
| `docs/design.md` | 清理过期字段、更新函数签名 | 2.4.2 |
| `docs/*.md` (5 个文件) | -r → -R CLI 选项飘移修正 | 2.4.1 |

### 具体改动详情

#### 2.1.1 RCU 临界区睡眠
- `cmd_get_by_inode()` match 分支：先 `get_task_struct(task)` + `sock_hold(sk)` + `get_file(file)` 获取引用，然后在 task_lock 内拷贝 comm，最后 `rcu_read_unlock()` 退出 RCU，再调用 `net_delayacct_one_reply()` (可能睡眠的 GFP_KERNEL 分配)

#### 2.1.2 task->comm 裸读
- 同上：在 match 分支先 `task_lock(task)` 然后 `memcpy(comm, task->comm, TASK_COMM_LEN)`，再 `task_unlock(task)`

#### 2.1.3 sock_from_file_safe
- 替换 60+ 行自写实现为 `return sock_from_file(file)` 一行调用

#### 2.1.4 __ro_after_init
- 删除 `genl_family` 的 `__ro_after_init` 修饰符

#### 2.1.5 调试日志残留
- 删除 `one_reply()` 和 `iter_task_sockets()` 中的 pr_debug 块
- 删除 `cmd_get_by_pid()` 中的 `pr_debug` 行
- 删除 `cmd_get_by_inode()` 中的 pr_debug 输入/输出日志

#### 2.2.1 netnsok 矛盾
- `cmd_get_by_pid()`: 解析 task 后加 `nsproxy` NULL 检查 + `net_ns` 一致性校验
- `cmd_get_by_inode()`: `for_each_process` 循环内第一行加 netns 过滤
- `cmd_reset()`: 同上

#### 2.2.2 PID namespace
- `find_get_pid` → `find_vpid`

#### 2.2.3 TX GSO/UAF
- `net_delayacct_tx_start()`: 签名从 `(struct sk_buff *)` 改为 `(struct sock *sk, struct sk_buff *skb)`，加 `sock_hold(sk)`
- `net_delayacct_tx_end()`: 末尾加 `sock_put(sk)` 及注释（已知 skb drop 泄漏风险）
- `tx-instrumentation.patch`: 在 `dev_hard_start_xmit` 循环中加入 GSO 子段时间戳继承逻辑
- 更新 tcp/udp callsite 传递 `sk` 参数

#### 2.2.4 KUnit fallback 宏
- 删除 `KUNIT_DEFINE_TEST_SUITE` fallback 宏
- 添加 upstream 迁移路径注释

#### 2.3.1 高风险测试覆盖
- 新增 `tests/selftests/net-delayacct/netns-isolation.sh`
  - 测试 1: netns 内创建的 socket 在本 netns 内可见
  - 测试 2: init netns 的 socket 在子 netns 中不可见（无泄漏）

#### 2.3.2 kthread 控制
- 线程函数加 `!kthread_should_stop()` 退出条件
- 删除 `atomic_dec(&ctx->remaining)` + `return 0` 模式
- 用 `kthread_stop()` 等待替代 `while (atomic_read > 0) fsleep` 轮询
- 删除重复的 kthread_stop 调用

#### 2.3.3 stub 证明力
- `stub_sock_create` 注释明确说明局限性：纯逻辑测试 vs 集成测试的分界
- `tx_accumulation` 测试加 `skb->sk = sk` 以模拟真实路径

#### 2.4.1 RST 文档飘移
- 5 个文档文件中 `-r` (reset) → `-R` 统一修正

#### 2.4.2 design.md 过期
- 删除 struct 中不存在的 `rx_start`/`tx_start`/`rx_pending`/`tx_pending` 字段
- 函数名 `net_delayacct_sock_init` → `net_delayacct_init`
- `net_delayacct_sock_reset` → `net_delayacct_reset`
- `net_delayacct_tx_start(struct sk_buff *)` → `net_delayacct_tx_start(struct sock *, struct sk_buff *)`
- 新增 `net_delayacct_get_stats` 声明
- init 实现从手动赋零改为 `memset`

#### 2.4.3 patch 不自洽
- 新增 `kernel-patches/0010-sock-init-net-delayacct.patch`
- 删除 CI 中的 `sed -i 's/sk_tx_queue_clear(sk);/.../'` 步骤

#### 2.4.4 身份不统一
- `h1y2g3l4y5 <h1y2g3l4y5@example.com>` → `laiguo-liang <2909269677@qq.com>`
- 同时更新 .c, .h, 和所有 patch 文件中的 Signoff/From

## 3. 变更原因
所有修改均来自 Review v2.0.0 的共识决议。详情见 `logs/dialogue/DLG-20260727-010000.md`。

## 4. 踩坑记录

### 坑 1: post_comment 字段名错误
- **问题描述**：Reviewer 审查报告中多处使用 `n->post_comment_events` 作为字段名，但在实际代码中该字段名为 `n->pending_comment_s`
- **原因分析**：可能是 Review 过程中记忆错误或复制粘贴
- **解决方案**：在对话中澄清后，Reviewer 已修正
- **如何避免**：审查时应基于实际 diff，而非记忆中的代码片段

## 5. 测试验证
- KUnit 测试需在 QEMU 环境验证（tx_start 签名变更后需重新编译）
- Netns 隔离测试需在内核已部署 netns 过滤的 QEMU 中运行
- 建议在下一轮 QEMU 测试中一并验证

## 6. 待办/遗留问题
- [ ] QEMU 完整测试回归（所有修改需内核编译+启动验证）
- [ ] KUnit 测试在新签名下的通过验证
- [ ] fault-injection 和 GSO 对照测试（v2.1.0 计划）
- [ ] run-tests.sh 拆分重构（v2.1.0 计划）

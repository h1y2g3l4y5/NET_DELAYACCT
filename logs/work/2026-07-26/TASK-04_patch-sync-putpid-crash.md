# TASK-04 修复 patch 未同步导致 iperf3 退出时 NULL deref 持续触发

- **日期**: 2026-07-26
- **关联 Review**: v2.0.0 议题 2.2.2（cmd_get_by_pid put_pid 误用）
- **状态**: 修复完成，QEMU 验证通过（崩溃消失）

## 1. 任务描述

TASK-03 修复 GSO NULL deref 后，再次跑 QEMU 测试，Test 01 (iperf3 客户端查询) 本身 [PASS]，但 iperf3 进程退出时再次触发 `BUG: kernel NULL pointer dereference, RIP: 0x0`，调用路径 `do_notify_parent → __wake_up_common`。需要定位为何此前已修复的 `put_pid` 问题仍然复现。

## 2. 错误现象

```
[   18.955632] BUG: kernel NULL pointer dereference, address: 0000000000000000
[   18.955983] CPU: 0 PID: 114 Comm: iperf3 Tainted: G        W          6.6.145-dirty #1
[   18.955983] RIP: 0010:0x0
[   18.955983] Call Trace:
[   18.955983]  __wake_up_common+0x74/0x140
[   18.955983]  __wake_up_common_lock+0x7e/0xd0
[   18.955983]  do_notify_parent+0x86/0x2a0
[   18.955983]  do_exit+0x9ce/0xae0
[   18.955983]  do_group_exit+0x2c/0x80
[   18.955983]  __x64_sys_exit_group+0x13/0x20
```

- `RIP: 0x0` → 调用 NULL 函数指针
- 路径：iperf3 调用 `exit_group` → `do_exit` → `do_notify_parent` 通知父进程 → `__wake_up_common` 唤醒 `parent->signal->wait_chldrec` 上的 waiter → waiter 的 `func` 为 NULL
- 与 TASK-03 修复前的崩溃签名一致（都是 `do_notify_parent` + `RIP: 0x0`），但此前明明已移除源文件中的 `put_pid`

## 3. 根因分析

### 3.1 表面根因（已在 TASK-03 前移除）

`net_delayacct_cmd_get_by_pid` 之前有 3 处 `put_pid(pidp)`：

```c
pidp = find_vpid(pid);          // find_vpid 不增加 pid->count
...
if (!task) {
    put_pid(pidp);              // ← 误减，第 1 处
    ...
}
if (netns 不匹配) {
    rcu_read_unlock();
    put_pid(pidp);              // ← 误减，第 2 处
    ...
}
...
put_pid(pidp);                  // ← 误减，第 3 处
```

`find_vpid()` 等价于 `find_pid_ns(virtual, current_ns)`，仅查表返回 `struct pid *`，**不调用 `refcount_inc`**。对它的返回值调用 `put_pid` 会错误递减 `pid->count`，多次查询后 `count` 归零，`struct pid` 被释放，但 pidfd 等待队列仍在引用它 → waiter 的 `func` 变成 NULL → `__wake_up_common` 调用 NULL → 崩溃。

源文件 `kernel-patches/net-core-net-delayacct.c` 早已移除这 3 处调用。

### 3.2 真正的根因：patch 没同步

对比 `0007-net-core-add-module.patch` 与源文件：

```bash
$ diff <(patch +lines) <(source)
370c370
<               put_pid(pidp);
---
>               /* find_vpid() does NOT elevate pid->count; do NOT put_pid(). */
381d380
<               put_pid(pidp);
391d389
<       put_pid(pidp);
```

**0007 patch 仍保留旧的 3 处 `put_pid`**。QEMU 测试流程 `local-test.sh` 是从 `.patch` 文件应用补丁后编译内核的——源文件的修复从未进入编译产物，因此崩溃照旧。

这正是 `project_memory.md` 中记录的踩坑："Failing to synchronize .patch files with source code changes results in CI using outdated signatures"。

### 3.3 连带发现：0008/0009 patch 也是坏的

重置 linux 树后重新应用补丁时，发现 0008/0009 一直带病运行：

```
0008: @@ -xxx,6 +xxx,23 @@          ← hunk header 行号是字面量 "xxx"
0009: @@ -xxx,6 +xxx,7 @@           ← 同上
0008 上下文: "faster loadable module support" ← 在 net/Kconfig 中根本不存在
0009 上下文: CONFIG_NETDEV_ADDR_LIST_TEST 紧跟 DST_CACHE ← 与实际 Makefile 顺序不符
```

这两个 patch 之前能"应用"，是因为 `step_apply_patches` 检测到 `delayacct_start` 已在 `skbuff.h` 中就整体跳过，0008/0009 从来没被重新应用过——它们是某个历史版本残留的状态，靠"已应用"短路逻辑掩盖了 patch 本身的损坏。

## 4. 变更内容

### 4.1 修改的文件

| 文件 | 改动 |
|------|------|
| `kernel-patches/0007-net-core-add-module.patch` | 移除 3 处 `put_pid(pidp)`；新增注释；hunk header `@@ -0,0 +1,673 @@` → `@@ -0,0 +1,671 @@`（净减 2 行） |
| `kernel-patches/0008-net-add-Kconfig-entry.patch` | 完整重新生成：修正 hunk header 为 `@@ -327,6 +327,23 @@`，上下文改为实际 `net/Kconfig` 的 `CGROUP_NET_CLASSID` help 文本 |
| `kernel-patches/0009-net-add-module-to-Makefile.patch` | 完整重新生成：修正 hunk header 为 `@@ -36,6 +36,7 @@`，上下文改为实际 `net/core/Makefile` 的 `HWBM/GRO_CELLS/FAILOVER` 序列 |

### 4.2 0007 hunk header 修正

```diff
-@@ -0,0 +1,673 @@
+@@ -0,0 +1,671 @@
```

净变化 = -3（移除 3 个 put_pid）+1（新增 1 行注释）= -2。原 header 673，新 header 671。

### 4.3 0008/0009 重新生成方法

```bash
# 1. 保存原始文件
cp net/Kconfig /tmp/Kconfig.orig
cp net/core/Makefile /tmp/Makefile.orig
# 2. 用 python 在正确位置插入条目（Kconfig: NET_RX_BUSY_POLL 之前；Makefile: failover.o 之后）
# 3. diff -u 生成 patch body，拼接邮件头
# 4. cat -A 验证 tab 缩进正确（Kconfig 的 bool/depends/help 用 \t，help 文本用 \t+2空格）
```

## 5. 踩坑记录

### 5.1 踩坑 1：源文件已修但 patch 未同步，QEMU 跑的是旧代码

**问题描述**: 源文件 `net-core-net-delayacct.c` 早已移除 `put_pid`，但 QEMU 测试仍然崩溃，签名与未修复前完全一致。

**原因分析**:
1. `local-test.sh` 从 `kernel-patches/*.patch` 应用补丁，**不**直接使用 `kernel-patches/net-core-net-delayacct.c`
2. 修复时只改了源文件，忘了同步 0007 patch
3. `step_apply_patches` 检测到补丁已应用就整体跳过，更不会重新应用更新的 0007

**解决方案**: 改源文件后必须同步对应 patch。验证手段：
```bash
awk '/^\+\+\+/{next} /^\+/{sub(/^\+/,""); print}' 0007-*.patch > /tmp/p.c
diff <(sed 's/[[:space:]]*$//' /tmp/p.c) <(sed 's/[[:space:]]*$//' net-core-net-delayacct.c)
# 输出为空 = 完全同步
```

**如何避免**: 任何源文件修改后，立即跑上面的 diff 命令验证 patch 同步；把该 diff 加进提交前自检清单。

### 5.2 踩坑 2：编辑 patch 后忘记更新 hunk header 行数

**问题描述**: 移除 0007 中的 3 行 `put_pid` 后，`git apply` 报 `error: corrupt patch at line 700`。

**原因分析**: unified diff 的 hunk header `@@ -0,0 +1,N @@` 中的 N 是新文件总行数。删除/新增行后必须同步更新 N，否则 patch 工具读到声称的行数超过实际 + 行数就报 corrupt。

**解决方案**: 计算 net 变化（-3+1=-2），更新 673→671。通用规则：编辑 patch 后用 `grep -c "^+"` 数实际 + 行数，与 hunk header 核对。

**如何避免**:
1. 优先用 `diff -u` 从原始/修改后文件重新生成 patch，而非手编 hunk
2. 手编后必跑 `git apply --check` 验证
3. 对于"新增文件"类 patch（`@@ -0,0 +1,N @@`），N = 源文件行数，可直接 `wc -l` 核对

### 5.3 踩坑 3：0008/0009 的 "xxx" hunk header 长期被掩盖

**问题描述**: 0008/0009 patch 的 hunk header 是 `@@ -xxx,6 +xxx,23 @@`（字面量 xxx），且上下文行在目标内核中不存在，但测试一直能跑。

**原因分析**: `step_apply_patches` 用 `grep delayacct_start skbuff.h` 作为"补丁已应用"判据，一旦为真就 `return`，**所有** patch 都不会重新应用。0008/0009 是早期某次手动应用的残留状态，patch 文件本身的损坏被短路逻辑掩盖。

**解决方案**:
1. 0008/0009 用 `diff -u` 从当前 linux-6.6 树重新生成，hunk header 和上下文都对齐
2. 验证：`git checkout -- . && git clean -fd` 重置后，所有 patch 能用 `git apply` 干净应用

**如何避免**:
1. patch 文件不能用占位符（"xxx"）当行号
2. 定期执行"重置 + 重新应用全部 patch"演练，暴露被掩盖的 patch 损坏
3. patch 的上下文行必须在目标内核版本中实际存在且唯一

## 6. 测试验证

### 6.1 静态检查

- `diff` 0007 patch +lines 与源文件：**空输出**（完全同步）✓
- 重置 linux 树后 `git apply` 全部 patch：**10/10 OK**（仅 0010 走 patch fallback，与历史一致）✓
- 应用后 `grep put_pid net/core/net-delayacct.c`：**0 处** ✓
- 应用后 `grep "config NET_DELAYACCT" net/Kconfig`：**1 处** ✓
- 应用后 `grep "net-delayacct.o" net/core/Makefile`：**1 处** ✓
- `make net/core/net-delayacct.o`：编译通过无 warning ✓

### 6.2 QEMU 运行时验证

`./local-test.sh` 完整跑通（TCG 模式，300s 超时）：

| 指标 | 修复前 | 修复后 |
|------|--------|--------|
| Test 01 (iperf3 PID 查询) | [PASS] 但退出时崩溃 | [PASS]，iperf3 正常退出 |
| 内核 BUG/Oops/Call Trace | 有（do_notify_parent NULL deref） | **无** ✓ |
| `do_notify_parent` 崩溃 | 有 | **无** ✓ |
| 测试套件完成度 | 第 1 个测试后崩溃 | 全部 13 个测试跑完 |
| QEMU 退出方式 | "Fixing recursive fault but reboot is needed" | 正常 `Power down` (rc=0) |
| 通过/失败 | N/A（崩溃） | 11 PASS / 2 FAIL（功能性，非崩溃） |

内核 net_delayacct 消息仅：`net_delayacct: framework registered v2 (family=28)`，无任何异常。

## 7. 待办/遗留问题

- [ ] 2 个功能性测试失败需单独排查（与本次崩溃无关）：
  - Test 11: `sockets=10, RX=2068, TX=0`（10 个 socket 的 TX 全为 0）
  - Test 12: `server RX=599, client TX=84 (expect >=100)`（client TX 偏低）
  - 初步判断与 TASK-03 的 GSO 修复（移除 sock_hold/sock_put）可能相关，但 Test 01 的 iperf3 TCP TX 计数正常（count=305），需进一步定位哪些场景 TX 不计入
- [ ] 待 Reviewer 确认本轮修复后，v2.0.0 议题 2.2.2 可闭环

# [TASK-28] v6.0.0 Review 8.3.1/8.3.2 闭环修复

- **日期**: 2026-07-29
- **关联需求/Issue**: v6.0.0 Review 剩余议题 8.3.1（Test 13 wait 返回值）与 8.3.2（Test 20 TCP zerocopy RX 环境支持）

## 1. 任务描述

响应 Reviewer 在 v6.0.0 复审中提出的最后两条议题：

1. **8.3.1**：Test 13 中 `wait $WORKER_PIDS 2>/dev/null || true` 掩盖 worker 真实退出码，要求保留诊断信息。
2. **8.3.2**：Test 20（TCP zerocopy RX）在 QEMU 中持续 SKIP，要求确认是内核配置问题还是环境固有限制，并给出文档或配置修复。

## 2. 变更内容

### 2.1 8.3.1 — wait 返回值诊断

文件：[ci/qemu/run-tests.sh](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L828-L832)

```bash
_WAIT_RC=0
wait $WORKER_PIDS 2>/dev/null || _WAIT_RC=$?
if [ "$_WAIT_RC" -ne 0 ]; then
    echo "    [diag] wait returned $_WAIT_RC (some worker may have failed, check dmesg)"
fi
```

- 捕获 `wait` 退出码并打印诊断，但不改变测试流程（仍依赖 `_CRASH` 计数器做最终断言）。

### 2.2 8.3.2 — Test 20 zerocopy 修复

#### 2.2.1 根因：helper 对 TCP_ZEROCOPY_RECEIVE 用法错误

文件：[tests/helper/delayacct_path_test.c](file:///home/lai/Code/NET_DELAYACCT/tests/helper/delayacct_path_test.c#L183-L298)

原实现存在三处错误：

1. **匿名 mmap**：`zc.address` 必须落在通过 `mmap(cfd)` 获得的 socket VMA 中（`vma->vm_ops == &tcp_vm_ops`）。普通匿名 mmap 的 VMA 不匹配，`find_tcp_vma()` 返回 NULL，`tcp_zerocopy_receive()` 返回 `-EINVAL`（errno=22）。
2. **MAP_PRIVATE**：内核通过 `vm_insert_page()` 向 VMA 插入页面，MAP_PRIVATE 会触发 COW，行为异常。
3. **未处理 `recv_skip_hint`**：非页面对齐的数据无法直接映射，需用普通 `read()` 消费以推进 `copied_seq`；否则 getsockopt 反复返回 length=0。

修复后参照内核 selftest `tools/testing/selftests/net/tcp_mmap.c`：

```c
void *raddr = mmap(NULL, maplen + page_size, PROT_READ, MAP_SHARED, cfd, 0);
void *area = ALIGN_PTR_UP(raddr, page_size);
...
poll(&pfd, 1, 1000);
getsockopt(cfd, IPPROTO_TCP, TCP_ZEROCOPY_RECEIVE, &zc, &optlen);
if (zc.length > 0) { total += zc.length; madvise(area, zc.length, MADV_DONTNEED); }
if (zc.recv_skip_hint > 0) read(cfd, copybuf, zc.recv_skip_hint);
```

同时补充内核机制注释，说明 `tcp_mmap()` 不真正映射页面，而是登记 VMA 供后续 `vm_insert_page()` 使用。

#### 2.2.2 内核配置显式声明 CONFIG_MMU

文件：[ci/kernel.config.fragment](file:///home/lai/Code/NET_DELAYACCT/ci/kernel.config.fragment)

```
CONFIG_NET=y
CONFIG_NET_DELAYACCT=y
CONFIG_MMU=y
```

`tcp_mmap()` 在 linux-6.6 中被 `#ifdef CONFIG_MMU` 包裹；该选项在 x86/x86_64 defconfig 中默认启用，此处显式声明以避免未来在极简配置中遗漏。

#### 2.2.3 测试脚本 SKIP 文案

文件：[ci/qemu/run-tests.sh](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L1280-L1294)

将两处 `_skip` 消息从：

```bash
_skip "kernel does not support TCP_ZEROCOPY_RECEIVE (...)"
```

改为：

```bash
_skip "kernel/config does not support TCP_ZEROCOPY_RECEIVE (... see /tmp/zc.log)"
```

以区分「内核/配置不支持」与「helper 自身参数/用法错误」。

#### 2.2.4 文档同步

文件：[tests/README.md](file:///home/lai/Code/NET_DELAYACCT/tests/README.md#L75-L76)

- 移除「物理 NIC」误导性描述；
- 明确 Test 20 依赖 `CONFIG_MMU` 与 `mmap(cfd)`；
- 在 Test 20 详情表中补充「环境依赖」行。

### 2.3 Review 文件状态更新

- [logs/review/v6.0.0/ITEM-04_wait-return-code.md](file:///home/lai/Code/NET_DELAYACCT/logs/review/v6.0.0/ITEM-04_wait-return-code.md)：Worker反馈 → 接受
- [logs/review/v6.0.0/ITEM-05_zerocopy-environment.md](file:///home/lai/Code/NET_DELAYACCT/logs/review/v6.0.0/ITEM-05_zerocopy-environment.md)：Worker反馈 → 接受
- [logs/review/v6.0.0/REVIEW_REPORT.md](file:///home/lai/Code/NET_DELAYACCT/logs/review/v6.0.0/REVIEW_REPORT.md)：状态统计更新为 13/0/0，结论改为 [待验证]

## 3. 变更原因

- **8.3.1**：`wait` 退出码是诊断 worker 异常退出（段错误/OOM/超时）的重要信息，不应被 `|| true` 完全吞掉；但测试主断言仍应基于 `_CRASH` 计数器，避免 wait 被信号中断时误判 FAIL。
- **8.3.2**：原以为是「内核不支持 / 配置未启用」，静态分析后发现根因是 helper 用法错误。`TCP_ZEROCOPY_RECEIVE` 必须使用 `mmap(cfd, ..., MAP_SHARED)` 创建 socket VMA，并处理 `recv_skip_hint`；匿名 mmap / MAP_PRIVATE 在设计上就不合法。修复用法后，在 `CONFIG_MMU=y` 的 loopback 环境亦可运行。

## 4. 踩坑记录

### 4.1 一度误判为内核配置问题

**问题描述**：最初认为 QEMU SKIP 是因为缺少某个 `CONFIG_TCP_ZEROCOPY_RECEIVE` 选项。

**原因分析**：linux-6.6 中并没有独立的 `CONFIG_TCP_ZEROCOPY_RECEIVE` Kconfig 选项；该特性由 `CONFIG_MMU` 控制，而 x86_64 defconfig 已默认启用。真正的失败点是 `find_tcp_vma()` 检查 `vma->vm_ops == &tcp_vm_ops`。

**解决方案**：
1. 将匿名 mmap 改为 `mmap(cfd, ..., MAP_SHARED)`，让 VMA 的 `vm_ops` 指向 `&tcp_vm_ops`。
2. 用 `poll()` 等待数据，循环 `getsockopt(TCP_ZEROCOPY_RECEIVE)`。
3. 处理 `zc.recv_skip_hint`，用 `read()` 消费非页面对齐数据。
4. 发送端设置 `TCP_MAXSEG = page_size + 12`，使 payload 尽量页面对齐。

**如何避免**：以后遇到「内核 API 返回 EINVAL」时，应先通读该 API 的入口校验逻辑（如 `tcp_zerocopy_receive()` 开头的参数检查），而不是先假设配置缺失；复杂内核 API 优先参考官方 selftest。

### 4.2 run-tests.sh 缩进修复时引入格式回归

**问题描述**：用 Edit 工具修改 SKIP 消息时，连带破坏了 Test 20 代码块的缩进，导致多行被错误地多缩进一级，甚至出现单行拼接。

**原因分析**：Edit 工具要求 old_string 完全匹配，手动构造带制表符的字符串容易出错；且该块在编辑过程中一度被意外合并成单行。

**解决方案**：最后用 Python 脚本整体重写 Test 20 块，并逐行核对 `cat -A` 输出，再用 `bash -n` 做语法检查。

**如何避免**：对多行缩进敏感代码，优先用完整块替换而非多次小范围 Edit；替换后必须 `bash -n` 验证。

## 5. 测试验证

### 5.1 Host 本地验证 helper

在 host 内核（x86_64，CONFIG_MMU=y）上直接运行修复后的 helper：

```bash
$ ./delayacct_path_test zerocopy-server 21435 &
$ ./delayacct_path_test tcp-sender 127.0.0.1 21435 5
```

结果：server 正常退出 rc=0，接收 35 MB 数据，getsockopt 不再返回 EINVAL。

```
zerocopy-server: received 35192832 bytes, exiting
```

### 5.2 QEMU 全量测试

运行命令：

```bash
./local-test.sh --qemu-only
```

环境：TCG 软件模拟（KVM 在当前环境无权限），超时 600s。

结果：

```
Tests run:  22     PASS: 22     FAIL:  0     SKIP:  0
RESULT: ALL PASS
```

关键验证：

- **Test 20** 由之前的 SKIP 转为 PASS：
  ```
  [PASS] zerocopy RX path covered: tcp=1 RX_sum=1662 (>0)
  ```
- **Test 13** 并发查询正常：
  ```
  ok=80 fail=0 crashed=0 workers, busy_ok=40
  ```
  `wait` 未返回非 0，因此未触发 `[diag]` 消息（符合预期，因为 worker 均正常退出）。

完整日志：[tests/reports/local/test-20260729_235911.log](file:///home/lai/Code/NET_DELAYACCT/tests/reports/local/test-20260729_235911.log)

## 6. 待办/遗留问题

- [x] REVIEW_REPORT.md 结论从 [待验证] 更新为 [闭环完成]。
- [x] 生成 `logs/summary/v6.0.0_FINAL_REPORT.md`。
- [x] 更新 `logs/work/2026-07-29/DAILY_SUMMARY.md`。
- 后续如用户要求，可将 `tests/helper/` 下新文件纳入 git 跟踪并提交。

# [TASK-32] 修复 CI 失败：Test 23 SKIP + Test 03 FAIL

- **日期**: 2026-08-01
- **关联需求/Issue**: CI 失败 (21P/1F/1S)

## 1. 任务描述

CI 运行结果显示两个问题：
1. **Test 23 (ftrace 打桩点全量验证) 被 SKIP**：`ftrace not available (CONFIG_FTRACE disabled or tracefs not writable)`
2. **1 个未知 FAIL**：通过本地复现定位为 Test 03 (重置计数器-基础)

最终结果：21 PASS / 1 FAIL / 1 SKIP，exit code 1。

## 2. 变更内容

### 2.1 修复 Test 23 SKIP — CI 内核配置缺失

**文件**: `.github/workflows/ci.yml` (第 141-153 行)

- **问题**: CI workflow 的 "Configure kernel with fragment" 步骤只合并 `ci/kernel.config.fragment`，没有合并 `ci/qemu/kernel-qemu.config`。后者包含 `CONFIG_FUNCTION_TRACER`、`CONFIG_FTRACE`、`CONFIG_NET_SCH_NETEM` 等 Test 23 必需的配置。
- **修复**: 在 `merge_config.sh` 命令中添加第二个 config fragment：
  ```yaml
  scripts/kconfig/merge_config.sh -m .config \
    "$GITHUB_WORKSPACE/ci/kernel.config.fragment" \
    "$GITHUB_WORKSPACE/ci/qemu/kernel-qemu.config"
  ```
- **验证 grep**: 同时更新 grep 检查，包含 `FTRACE|FUNCTION_TRACER|NET_SCH_NETEM` 以确认关键配置生效。

### 2.2 修复 Test 23 SKIP — guest 内 tracefs 未挂载

**文件**: `ci/qemu/guest-init.sh` (第 34-41 行)

- **问题**: `guest-init.sh` 只挂载了 `/proc`、`/sys`、`/dev`，没有挂载 `debugfs` 或 `tracefs`。即使内核启用了 `CONFIG_FTRACE`，guest 内 `/sys/kernel/debug/tracing` 不存在，Test 23 的 tracefs 可用性检查失败 → SKIP。
- **修复**: 在挂载基础文件系统后，添加 debugfs 和 tracefs 挂载：
  ```sh
  mkdir -p /sys/kernel/debug
  mountpoint -q /sys/kernel/debug 2>/dev/null || mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
  mkdir -p /sys/kernel/tracing
  mountpoint -q /sys/kernel/tracing 2>/dev/null || mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null || true
  ```

### 2.3 修复 tracefs 路径兼容性

**文件**: `ci/qemu/run-tests.sh` (4 处：Test 19/20/21/23)

- **问题**: 所有 ftrace 相关代码硬编码 `TRACEFS=/sys/kernel/debug/tracing`（传统 debugfs 路径）。现代内核推荐使用 `/sys/kernel/tracing`（tracefs 独立挂载点）。
- **修复**: 改为双路径自动探测：
  ```bash
  TRACEFS=/sys/kernel/tracing
  [ -d "$TRACEFS" ] || TRACEFS=/sys/kernel/debug/tracing
  ```
  优先使用现代路径，回退到传统路径。

### 2.4 修复 Test 03 FAIL — reset 阈值在活跃流量下过严

**文件**: `ci/qemu/run-tests.sh` (Test 03，第 259-318 行)

- **问题**: Test 03 在 client 仍后台运行（`-t 12`）时执行 reset，reset 后新包继续累加。断言 `POST_NONZERO < PRE_NONZERO / 2` 在小 PRE 值时频繁误判：本地复现 PRE=4、POST=2，`2 < 4/2 = 2` 为 false → FAIL。
- **根因**: Test 03（基础测试）和 Test 17（非原子语义测试）职责重叠。Test 03 试图在活跃流量下验证 reset，但活跃流量下的非原子行为应由 Test 17 专项覆盖。
- **修复**: PRE 查询后停止 client（中止流量），再执行 reset。POST 在无流量干扰下应为 0：
  1. Client 后台运行 → sleep 3 → 查询 PRE（验证 PRE_NONZERO > 0，消除 0→0 假阳性）
  2. **停止 client** → sleep 1（让在途包排空）
  3. 执行 reset → sleep 1 → 查询 POST
  4. 断言 `POST_NONZERO <= 1`（严格：流量已停应清零；≤1 容忍 FIN/RST 残包）

### 2.5 文档同步

**文件**: `tests/README.md` (Test 03 章节)

更新 Test 03 的实现流程表和核心断言描述，反映"停止 client 后 reset"的新设计，并说明与 Test 17 的职责分离。

## 3. 变更原因

### 3.1 Test 23 SKIP 根因分析

两个独立原因叠加导致 Test 23 在 CI 中始终 SKIP：

1. **CI 内核缺少 ftrace 配置**：`ci.yml` 只合并 `ci/kernel.config.fragment`（仅含 `NET`、`NET_DELAYACCT`、`MMU`），不合并 `ci/qemu/kernel-qemu.config`（含 `FUNCTION_TRACER` 等）。`local-test.sh` 合并了两个 fragment，所以本地测试不受影响——这解释了为什么本地测试通过但 CI 失败。

2. **guest 内未挂载 tracefs**：即使内核启用了 ftrace，`guest-init.sh` 没有挂载 debugfs/tracefs，`/sys/kernel/debug/tracing` 不存在。

### 3.2 Test 03 FAIL 根因分析

v6.1.0 review 修复（commit a9e6645）将 Test 03 从"同步运行 client → 0→0 假阳性"改为"后台运行 client + POST < PRE/2"。但新阈值在活跃流量 + 小 PRE 值场景下过严：

- iperf3 `-P 2 -t 12` 产生 4 个非零计数器（PRE=4）
- Reset 后 1 秒内新包累加，2 个计数器恢复非零（POST=2）
- `POST < PRE/2` → `2 < 2` → false → FAIL

正确做法：Test 03 验证"无流量干扰下 reset 清零"（停止 client → reset → POST=0），Test 17 验证"活跃流量下 reset 非原子"（不停止 client → reset → POST>0）。两者职责分离，阈值各自合理。

## 4. 踩坑记录

### 踩坑 1：CI 与本地测试环境差异

- **问题描述**: 本地测试 22/22 PASS（旧代码）或 21P/1F/1S（新代码），CI 也是 21P/1F/1S，但 Test 23 SKIP 的根因不同。
- **原因分析**: `local-test.sh` 合并两个 config fragment，CI 只合并一个。本地内核已编译好（7月28日），但缺少 `FUNCTION_TRACER`。
- **解决方案**: 统一 CI 和本地的 config fragment 合并逻辑。
- **如何避免**: CI 和本地测试脚本应使用相同的内核配置流程，避免环境差异。

### 踩坑 2：Test 03 阈值边界条件

- **问题描述**: `POST < PRE/2` 在 PRE=4、POST=2 时失败（2 不小于 2）。
- **原因分析**: 整数除法 `PRE/2 = 4/2 = 2`，严格小于 `<` 不包含等于。
- **解决方案**: 重新设计测试流程（停止 client），而非调整阈值。调整阈值（如 `<=`）只是治标，活跃流量下的非确定性累加仍会导致偶发失败。
- **如何避免**: 测试断言应避免依赖活跃流量下的精确计数比较；活跃流量场景使用存在性断言（>=1 或 ==0）而非比例断言（< PRE/2）。

## 5. 测试验证

### 5.1 本地复现

用 TCG 模式运行 `local-test.sh --qemu-only`，完美复现 CI 结果：
```
Test 03: [FAIL] reset ineffective: PRE=4 non-zero → POST=2 non-zero (expect POST < PRE/2 or =0)
Test 23: [SKIP] ftrace not available (CONFIG_FTRACE disabled or tracefs not writable)
Tests run: 23     PASS: 21     FAIL: 1     SKIP: 1
```

### 5.2 修复验证

- 重建内核（添加 `FUNCTION_TRACER=y` + `NET_SCH_NETEM=y`）
- 重新运行完整测试套件

### 5.2.1 第一轮验证 — `netif_receive_skb` 不可追踪

重建内核后运行测试，Test 23 不再 SKIP（ftrace 可用），但 S1-S6 全部 MISS `netif_receive_skb`：

```
S1: netif_receive_skb=0 tcp_recvmsg_locked=2579 dev_hard_start_xmit=4458 ...
[MISS] S1: netif_receive_skb not triggered (expected > 0)
```

**根因**：`netif_receive_skb` 是 NAPI 驱动的接收入口，但测试流量全部走 loopback（`127.0.0.1` / `::1`），loopback 驱动 `loopback_xmit()` 调用的是 `__netif_rx()`（`drivers/net/loopback.c:89`），不是 `netif_receive_skb()`。

调用链对比：
- NAPI 驱动：`nic_poll → napi_gro_receive → netif_receive_skb → __netif_receive_skb → __netif_receive_skb_core`
- loopback：`loopback_xmit → __netif_rx → netif_rx_internal → backlog → process_backlog → __netif_receive_skb → __netif_receive_skb_core`

`rx_start` 打桩在 `__netif_receive_skb_core`（static，不可 ftrace），改用其上游的全局函数验证可达性。

### 5.3 第二轮修复 — 替换为 `__netif_rx`

将 `FTRACE_FUNCS` 和所有场景断言中的 `netif_receive_skb` 替换为 `__netif_rx`：
- `__netif_rx` 是 `EXPORT_SYMBOL` 全局函数（`net/core/dev.c:5100`），无 `notrace`/`inline` 属性
- loopback 每次收包都调用它
- 不存在 grep 误匹配风险：`__netif_receive_skb`（static）不会出现在 ftrace trace 中

验证结果（第二轮）：
```
S1: __netif_rx=3597 tcp_recvmsg_locked=2103 ...  → PASS
S2: __netif_rx=88 udp_recvmsg=1 udpv6_recvmsg=70 udp_sendmsg=71 ... → PASS
S3: __netif_rx=3651 tcp_read_sock=7138 ... → PASS
S4: __netif_rx=3577 tcp_zerocopy_receive=1802 ... → PASS
S5: __netif_rx=1540 udp_push_pending_frames=770 ... → PASS
S6: __netif_rx=6301 ... udpv6_recvmsg=0 udpv6_sendmsg=0 → FAIL (UDP 未触发)
S7: SKIP (tc/iptables 不可用)
```

`__netif_rx` 修复成功！但 S6（IPv6 TCP+UDP）仍有问题：`udpv6_recvmsg=0, udpv6_sendmsg=0`。

### 5.4 第三轮修复 — S6 顺序执行 TCP → UDP

S6 失败根因：iperf3 server 一次只处理一个测试，TCP 和 UDP client 同时连接（即使不同端口）会导致 UDP client 的 TCP 控制连接失败。

修复：改为顺序执行（与 Test 22 验证过的模式一致）：
1. 启动 iperf3 server
2. 先运行 TCP client（`-t 2`），sleep 3，kill
3. 再运行 UDP client（`-u -t 2`），sleep 3
4. ftrace 全程启用，捕获两种协议的函数调用

（第三轮验证结果待补充）

### 5.5 第三轮验证 — 全部通过

最终测试结果（TCG 模式）：
```
Tests run:  24     PASS: 23     FAIL:  0     SKIP:  1
RESULT: ALL PASS
```

Test 23 矩阵（6/6 场景 PASS，S7 环境限制 SKIP）：
```
| 函数                     |   S1 |   S2 |   S3 |   S4 |   S5 |   S6 |   S7 |
| __netif_rx                 | 3658 |   88 | 3367 | 3831 | 1516 | 4642 |    0 |
| tcp_recvmsg_locked         | 2120 |    7 |    0 | 3741 |    0 | 2659 |    0 |
| tcp_read_sock              |    0 |    0 | 6253 |    0 |    0 |    0 |    0 |
| tcp_zerocopy_receive       |    0 |    0 |    0 | 1951 |    0 |    0 |    0 |
| udp_recvmsg                |    0 |    1 |    0 |    0 |    0 |    0 |    0 |
| udpv6_recvmsg              |    0 |   69 |    0 |    0 |    0 |   79 |    0 |
| dev_hard_start_xmit        | 3658 |   88 | 3367 | 3831 | 1516 | 4642 |    0 |
| __tcp_transmit_skb         | 3656 |   16 | 3366 | 3830 |    0 | 4559 |    0 |
| __tcp_retransmit_skb       |    0 |    0 |    0 |    0 |    0 |    2 |    0 |
| udp_sendmsg                |    0 |   71 |    0 |    0 | 6064 |    0 |    0 |
| udp_push_pending_frames    |    0 |    0 |    0 |    0 |  758 |    0 |    0 |
| udpv6_sendmsg              |    0 |    2 |    0 |    0 |    0 |   79 |    0 |
| udp_v6_push_pending_frames |    0 |    0 |    0 |    0 |    0 |    0 |    0 |
```

关键验证点：
- `__netif_rx` 在所有 loopback 场景（S1-S6）非零 → rx_start 打桩点可达 ✓
- S6 `udpv6_recvmsg=79, udpv6_sendmsg=79` → IPv6 UDP 路径验证 ✓
- S3 `tcp_read_sock=6253` → splice 专属路径 ✓
- S4 `tcp_zerocopy_receive=1951` → zerocopy 专属路径 ✓
- S5 `udp_push_pending_frames=758` → UDP corked 专属路径 ✓

## 6. 待办/遗留问题

- [x] 第三轮验证（S6 顺序执行）结果确认 → 全部通过
- [x] 推送修复并观察 CI 结果 → **CI 全部通过 (4/4 jobs success)**
- [x] S7 在 CI 环境中可能可用（KVM 有 tc/iptables）→ CI QEMU test (KVM) success，S7 可能通过或 SKIP
- [ ] `udp_v6_push_pending_frames` 在所有场景为 0 — 需要专门的 IPv6 UDP corked 测试才能触发，当前无此场景，可作为未来增强

## 7. CI 验证结果

**Commit**: `2f0e624` (push to origin/main)
**CI Run ID**: 30704859917
**CI Result**: ✅ **ALL SUCCESS** (4/4 jobs)

| Job | Status | Duration |
|-----|--------|----------|
| checkpatch on kernel patches | ✅ success | ~1 min |
| Build userspace get_sockdelays | ✅ success | ~20 sec |
| Build kernel with CONFIG_NET_DELAYACCT | ✅ success | ~13 min |
| QEMU runtime test (KVM) | ✅ success | ~5 min |

对比修复前（commit `a9e6645`）：CI 结果为 **failure**（Test 23 SKIP + Test 03 FAIL）。

CI 的 KVM 环境比本地 TCG 更快（QEMU 测试仅 5 分钟 vs 本地 6 分钟），且可能有 tc/iptables 使 S7 也能通过。

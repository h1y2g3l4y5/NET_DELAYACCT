# [TASK-33~37] v6.2.0 测试体系增强 — kprobe 配对 / ACK 守卫 / IPv6 corked / S7 重传 / 可观测性

- **日期**: 2026-08-02
- **关联需求/Issue**: v6.1.0 复审闭环遗留的 5 项增强任务

## 1. 任务描述

落实 v6.1.0 闭环时延期至 v6.2.0 的 5 项测试体系增强任务：

| 编号 | 任务 | 优先级 | 关联 v6.1.0 问题 |
|------|------|--------|------------------|
| TASK-33 | kprobe events 验证 tx_start/tx_end 配对 | P0 | 2.3.1 |
| TASK-34 | 在 CI/initramfs 中提供 tc/iptables 触发重传 | P0 | 2.3.2 |
| TASK-35 | IPv6 UDP corked 触发 udp_v6_push_pending_frames | P1 | 遗留增强 |
| TASK-36 | 纯 ACK 不计入 TX 的守卫验证 | P1 | 2.3.3 |
| TASK-37 | S7/S8 场景级状态可观测性 | P1 | 下版本关注点#4 |

## 2. 变更内容

### 2.1 TASK-34: 在 CI/initramfs 中打包 tc + iptables

**文件**:
- [.github/workflows/ci.yml](file:///home/lai/Code/NET_DELAYACCT/.github/workflows/ci.yml)
- [local-test.sh](file:///home/lai/Code/NET_DELAYACCT/local-test.sh)

**改动**:
1. CI 的 `apt-get install` 新增 `iproute2 iptables`
2. initramfs 构建逻辑新增 tc/iptables 二进制 + 依赖库 + tc 的 netem qdisc 共享对象 (`/usr/lib/x86_64-linux-gnu/tc/q_netem.so`)
3. local-test.sh 同步新增 tc/iptables 打包逻辑

### 2.2 TASK-37: 场景级状态可观测性

**文件**: [ci/qemu/run-tests.sh](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh)

**改动**:
1. 新增 `_scenario_status()` 辅助函数，每个场景打印独立状态行 `[S1 PASS]`/`[S7 SKIP]` 等
2. 新增 `SCEN_S1`~`SCEN_S8` 状态变量和 `SKIPPED_SCENARIOS` 计数器
3. 矩阵输出后新增"Test 23 场景状态汇总"框，显示 S1-S8 状态和通过率
4. CI summary 新增 "Test 23 Scenario Status" 区块，直接 grep `S[1-8]=` 和 `场景通过率`
5. CI summary 的 PASS/FAIL/SKIP 统计改为 `^\s*\[PASS\]` 精确匹配，避免场景状态行 `[S1 PASS]` 污染计数

### 2.3 TASK-33: kprobe events 验证 tx_start/tx_end 调用计数比 (Test 24)

**文件**: [ci/qemu/run-tests.sh](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh) (新增 Test 24)

**改动**:
- 新增 Test 24: 用 kprobe events 为 `net_delayacct_tx_start` 和 `net_delayacct_tx_end` 注册探针
- 使用 `%si:u64` 寄存器语法抓取 skb 指针（x86_64 ABI: arg2=RSI），不依赖 BTF
- 统计两函数调用次数，断言计数比 `tx_end/tx_start ∈ [50%, 200%]`
  - 下界 50%: 容忍纯 ACK 守卫跳过（tx_end 被调用但 start=0 提前返回）
  - 上界 200%: 容忍 GSO 分段（一个 tx_start 对应多个 tx_end）
- **注意**: 本测试验证的是"调用计数比"，不是"per-skb 配对"。per-skb 配对需要解析 trace 中的 skb 指针并做集合匹配，留待 v6.3.0 增强。

**技术约束**:
- `rx_start` 是 `static inline`（头文件），不可被 kprobe 捕获 → 只验证 tx 路径
- `rx_end`/`tx_start`/`tx_end` 是 out-of-line 全局函数（net-delayacct.c），可 kprobe
- `$argN` 语法依赖 CONFIG_DEBUG_INFO_BTF（项目未启用），改用 `%si:u64` 寄存器语法（仅需 CONFIG_KPROBE_EVENTS=y）

### 2.4 TASK-36: 纯 ACK 不计入 TX 守卫验证 (Test 25)

**文件**: [ci/qemu/run-tests.sh](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh) (新增 Test 25)

**改动**:
- 新增 Test 25: iperf3 server 作为纯接收方，只发 ACK 不发应用数据
- 断言: server RX > 0 (确认通信) ∧ server TX = 0 (纯 ACK 被守卫跳过)
- 验证 `tx_end` 内部 `if (!start || !sk) return` 守卫语义

### 2.5 TASK-35: IPv6 UDP corked (Test 23 S8 + helper)

**文件**:
- [tests/helper/delayacct_path_test.c](file:///home/lai/Code/NET_DELAYACCT/tests/helper/delayacct_path_test.c)
- [ci/qemu/run-tests.sh](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh) (Test 23 新增 S8)

**改动**:
1. helper 新增 `corked-udp6-client` 模式:
   - `socket(AF_INET6, SOCK_DGRAM, 0)`
   - `setsockopt(IPV6_V6ONLY)` 限制为纯 IPv6
   - `setsockopt(UDP_CORK)` + sendto 循环 + 定期 uncork 触发 flush
2. Test 23 新增 S8 场景:
   - 调用 `corked-udp6-client ::1 <port> 8`
   - 断言 `udp_v6_push_pending_frames > 0`、`udpv6_sendmsg > 0`、`dev_hard_start_xmit > 0`
3. 矩阵输出从 7 列扩展到 8 列（S1-S8）

## 3. 变更原因

### 3.1 为什么用 kprobe 而非 function tracer 验证配对

function tracer 只能记录"函数被调用"，不能抓参数。验证 start/end 配对需要知道两个函数是否作用于同一个 skb，这必须抓取 skb 指针参数。kprobe events 的 `$argN` 参数抓取能力正是为此设计。

### 3.2 为什么只验证 tx 配对，不验证 rx 配对

`net_delayacct_rx_start` 定义在头文件中为 `static inline`，编译后无独立符号，kprobe 无法注册。`rx_end`/`tx_start`/`tx_end` 都是 out-of-line 全局函数（在 net-delayacct.c 中定义），可被 kprobe 捕获。这是 v6.1.0 设计决策的副产物（rx_start 内联是为了避免函数调用开销在 RX 热路径）。

### 3.3 为什么配对比率用 [50%, 200%] 而非严格相等

两个方向的不对称：
- **tx_end < tx_start**: 纯 ACK 包的 `delayacct_start=0`，`tx_end` 被调用但守卫 `if (!start) return` 提前返回。这些调用仍被 kprobe 记录（kprobe 在函数入口），但不计入统计。
- **tx_end > tx_start**: GSO 分段时，一个 parent skb 经 `skb_segment()` 分成 N 段，每段都继承 `delayacct_start` 并各自调用 `tx_end`，但 `tx_start` 只在 parent 上调用一次。

### 3.4 为什么 S7 需要 tc/iptables 打包到 initramfs

v6.1.0 的 S7 代码已实现（netem + iptables 双轨），但 initramfs 中没有 tc/iptables 二进制，导致本地和 CI 都 SKIP。通过打包主机上的 tc/iptables + 依赖库 + netem qdisc 共享对象，使 S7 能在 guest 中真正运行。

## 4. 踩坑记录

### 4.1 busybox tc 不支持 netem

**问题描述**: 尝试用 busybox 自带的 tc applet 替代完整 tc 二进制。
**原因分析**: busybox tc 只支持基础 qdisc（pfifo/bfifo/sfq），不支持 netem。
**解决方案**: 必须打包完整的 iproute2 tc 二进制 + 依赖库 + netem qdisc 共享对象。
**如何避免**: busybox applet 功能有限，网络高级功能（netem/cgroup/clsact 等）必须用完整二进制。

### 4.2 CI summary 的 grep 模式会误计场景状态行

**问题描述**: 场景状态行 `[S1 PASS]` 会被 `grep '\[PASS\]'` 匹配，导致 PASS 计数翻倍。
**原因分析**: `[PASS]` 是 `[S1 PASS]` 的子串。
**解决方案**: CI summary 的 grep 改为 `^\s*\[PASS\]`（行首 + 空格 + `[PASS]`），精确匹配 `_pass()` 的输出格式 `    [PASS] ...`，排除 `    [S1 PASS]`。
**如何避免**: 添加新输出格式时，需检查是否与现有 grep 模式冲突。

### 4.3 run-tests.sh PATH 覆盖导致 tc/iptables 不可达

**问题描述**: S7 场景始终 SKIP，提示 "neither tc netem nor iptables statistic available"。
**原因分析**: `run-tests.sh` 第 24 行 `export PATH=/usr/local/bin:/usr/bin:/bin:/sbin` 覆盖了 `guest-init.sh` 设置的 PATH（含 `/usr/sbin`），而 tc 和 iptables 被打包到 `/usr/sbin/`，导致 `command -v tc` 失败。
**解决方案**: PATH 增加 `/usr/sbin` → `export PATH=/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin`。
**如何避免**: 脚本中重新 export PATH 时，应保留 guest-init.sh 的完整路径，或在 `command -v` 失败时打印诊断信息（已添加 `[diag]` 输出）。

### 4.4 TOTAL_SCENARIOS 计数在 SKIP 时不递增导致 -1 FAIL

**问题描述**: Test 23 汇总行显示 "7/7 PASS, 1 SKIP, -1 FAIL"，`FAIL = TOTAL - PASSED - SKIPPED = 7-7-1 = -1`。
**原因分析**: S3-S8 场景的 `TOTAL_SCENARIOS++` 放在 `if` 条件块内（仅 PASS/FAIL 路径执行），SKIP 走 `else` 分支时不递增。
**解决方案**: 将 `TOTAL_SCENARIOS++` 移到条件判断之前，确保无论 SKIP/PASS/FAIL 都计入总数。
**如何避免**: 计数器递增应在分支判断之前完成，而非在某个分支内部。这是"先计数再判定"的基本原则。

### 4.5 kprobe_events 清空时报 EBUSY

**问题描述**: Test 24 清理 kprobe 时 `echo > kprobe_events` 报 "Device or resource busy"。
**原因分析**: kprobe events 仍处于 enabled 状态时，清空 kprobe_events 会返回 EBUSY。
**解决方案**: 先 `echo 0 > events/kprobes/enable` 禁用 kprobes events，再 `echo > kprobe_events` 清空。
**如何避免**: ftrace/kprobe 资源清理需按"先禁用再清空"顺序，直接清空活跃资源会 EBUSY。

## 5. 测试验证

### 5.1 本地 QEMU 测试结果 (2026-08-02, TCG 模式)

运行 `./local-test.sh --qemu-only`，经过 3 轮迭代修复后最终结果：

```
Tests run:  25     PASS: 25     FAIL:  0     SKIP:  0
RESULT: ALL PASS
```

**全部 25 个测试通过，0 FAIL，0 SKIP。**

### 5.2 关键测试验证详情

| 测试 | 验证点 | 结果 | 关键数据 |
|------|--------|------|----------|
| Test 23 S1-S6 | ftrace 基础场景覆盖 | ✅ PASS | 13 个函数全部非零 |
| Test 23 S7 | tc netem 触发 TCP 重传 | ✅ PASS | `netem=1`, `__tcp_retransmit_skb=46` |
| Test 23 S8 | IPv6 UDP corked | ✅ PASS | `udp_v6_push_pending_frames=1026` |
| Test 23 汇总 | 8/8 场景全部通过 | ✅ PASS | `all 8 ftrace scenarios passed (13 functions verified)` |
| Test 24 | kprobe 计数比验证 | ✅ PASS | `tx_start=4653 tx_end=6025 ratio=129%` (∈ [50%,200%]) |
| Test 25 | 纯 ACK 守卫验证 | ✅ PASS | 数据 socket RX>0 ∧ TX=0 |

### 5.3 S7 重传场景 ftrace 计数

```
S7 TCP 重传 ftrace counts (netem=1 iptables=0)
  __netif_rx=294 tcp_recvmsg_locked=107 __tcp_transmit_skb=324 __tcp_retransmit_skb=46 dev_hard_start_xmit=294
```

- tc netem 10% 丢包成功施加到 loopback 接口
- `__tcp_retransmit_skb` 被调用 46 次，证明重传路径打桩点可达
- `__tcp_transmit_skb` 被调用 324 次（含原始发送 + 重传）

### 5.4 迭代修复过程中的发现

修复 v6.2.0 Review 问题过程中，本地测试额外发现并修复了 3 个问题：

1. **TOTAL_SCENARIOS 计数 bug**: S3-S8 的 `TOTAL_SCENARIOS++` 在条件块内，SKIP 时不递增 → `FAIL = 7-7-1 = -1`。修复：移到条件判断之前。
2. **S7 tc/iptables 不可达**: `run-tests.sh` 的 `export PATH` 覆盖了 guest-init.sh 的 PATH，丢失 `/usr/sbin`（tc/iptables 所在路径）。修复：PATH 增加 `/usr/sbin`。
3. **kprobe 清理 EBUSY**: 清空 kprobe_events 时事件仍活跃。修复：先 `echo 0 > events/kprobes/enable` 再清空。

## 6. 待办/遗留问题

- [x] 本地测试验证 S7 (tc netem) 和 S8 (IPv6 corked) 是否真正触发 — **已验证: S7 `__tcp_retransmit_skb=46`, S8 `udp_v6_push_pending_frames=1026`**
- [x] kprobe events 在 QEMU guest 中是否可注册 — **已验证: `%si:u64` 语法成功注册, tx_start=4653 tx_end=6025**
- [ ] CI 验证（KVM 环境下 tc netem 是否可用）— **待推送后由 CI 验证**
- [ ] Test 24 per-skb 配对验证 — **延期至 v6.3.0（当前为计数比验证）**

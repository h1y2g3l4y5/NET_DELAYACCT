# TASK-31 v6.1.0 Review 修复：假阳性消除 + ftrace 全量验证测试

- **日期**: 2026-08-01
- **关联 Review**: v6.1.0（[REVIEW_REPORT.md](file:///home/lai/Code/NET_DELAYACCT/logs/review/v6.1.0/REVIEW_REPORT.md)）
- **关联对话**: [DLG-20260801-183000.md](file:///home/lai/Code/NET_DELAYACCT/logs/dialogue/DLG-20260801-183000.md)

## 1. 任务描述

根据 v6.1.0 Review 报告中的 12 条问题决议，执行全部 P0 修复任务：
1. 修复 Test 03/04/05/06 假阳性（黑盒结果验证 → 打点工作验证）
2. 修复 Test 08/13（关键字检查 + 数据正确性校验）
3. 内核配置增加 FUNCTION_TRACER + NETEM + XTABLES
4. Test 19/20/21 内嵌 ftrace 专属路径验证
5. 实现 Test 23 ftrace 打桩点全量验证（13 函数 × 7 场景）
6. 可视化矩阵输出
7. tests/README.md 同步更新

## 2. 变更内容

### 2.1 ci/qemu/run-tests.sh（主要变更文件）

#### Test 03（重置计数器-基础）
- **变更**：client 同步运行 → 后台运行（`-P 2 -t 12 &`），sleep 3 让流量积累
- **变更**：PRE 检查从 `proto=` 行数 → `count > 0` 的非零计数行数
- **变更**：POST 断言从 `NONZERO = 0` → `POST_NONZERO < PRE_NONZERO / 2 或 = 0`（容忍非原子累加）
- **变更**：PRE_NONZERO = 0 时从 PASS → FAIL（"reset test inconclusive"）
- **根因**：旧实现 client 同步运行结束后 server 关闭 child socket，只剩 listen socket（count=0），PRE/POST 全为 0，reset trivially 通过（假阳性）

#### Test 04（TCP 路径）
- **变更**：client 同步运行 → 后台运行（`-t 8 &`），sleep 3
- **变更**：删除 `else` 分支的 `_pass "..., RX=0 (timing)"`，改为 `_fail "rx_end instrumentation may be broken"`
- **变更**：HAS_RX 检查从 `head -1` → `grep -c 'count=[1-9]'`（统计所有 RX>0 的 socket）
- **根因**：旧实现 RX=0 时仍 PASS，打点失效无法被发现

#### Test 05（UDP 路径）
- **变更**：增加 `SRV_RX > 0` 和 `CLI_TX > 0` 断言
- **变更**：`-t 5` → `-t 8`，sleep 2 → sleep 3
- **根因**：旧实现只断言 socket 枚举数量，不验证打点工作

#### Test 06（多 Socket 枚举）
- **变更**：增加 `SRV_RX > 0` 断言
- **变更**：`-t 5` → `-t 8`，sleep 2 → sleep 3
- **根因**：同 Test 05

#### Test 08（Debug 模式）
- **变更**：增加 `diag`/`netlink`/`nlmsg` 关键字检查
- **变更**：无关键字但行数 ≥ 3 时给 PASS 但标注

#### Test 13（并发查询压力）
- **变更**：worker 函数增加 `_empty` 计数器（退出码 0 但无 `proto=` 行）
- **变更**：汇总增加 `_BUSY_EMPTY` 统计，`_BUSY_EMPTY > 0` 时 FAIL
- **根因**：旧实现只看退出码，不验证返回数据正确性（dumpit 空数据可能是并发竞态）

#### Test 19/20/21（路径覆盖测试）
- **变更**：内嵌 ftrace 验证，分别 filter `tcp_read_sock`/`tcp_zerocopy_receive`/`udp_push_pending_frames`
- **变更**：ftrace 调用次数 ≤ 0 时 FAIL（"splice may have fallen back to tcp_recvmsg_locked"）
- **变更**：ftrace 不可用时优雅降级（不影响原断言）
- **根因**：旧实现只验证 RX/TX > 0，无法区分专属路径和回退路径

#### Test 23（ftrace 打桩点全量验证）— 新增
- **新增**：13 个 ftrace 函数清单（覆盖全部 12 个打桩点）
- **新增**：7 个测试场景（S1 TCP 单向 / S2 UDP 单向 / S3 splice / S4 zerocopy / S5 corked / S6 IPv6 / S7 重传）
- **新增**：`_ftrace_start` / `_ftrace_stop_and_count` / `_ftrace_assert` / `_ftrace_get_count` 辅助函数
- **新增**：可视化矩阵输出（场景 × 函数调用次数表格）
- **新增**：S7 双轨备选（tc netem → iptables statistic），均不可用时 SKIP
- **根因**：全部 22 个测试都是黑盒结果验证，无白盒路径验证

### 2.2 ci/qemu/kernel-qemu.config

- **新增**：`CONFIG_FUNCTION_TRACER=y`, `CONFIG_FUNCTION_GRAPH_TRACER=y`, `CONFIG_FTRACE=y`, `CONFIG_KPROBES=y`, `CONFIG_KPROBE_EVENTS=y`
- **新增**：`CONFIG_NET_SCHED=y`, `CONFIG_NET_SCH_NETEM=y`
- **新增**：`CONFIG_NETFILTER_XTABLES=y`, `CONFIG_IP_NF_FILTER=y`

### 2.3 tests/README.md

- **更新**：Test 03/04/05/06 的描述与修复后的代码对齐
- **新增**：Test 23 完整文档（13 函数映射表、7 场景矩阵、可视化输出说明）
- **更新**：3.1 覆盖矩阵增加"路径可达性"维度

## 3. 变更原因

### 3.1 假阳性根因分析

| 测试 | 假阳性机制 | 修复方案 |
|------|-----------|---------|
| Test 03 | client 同步运行 → child socket 关闭 → PRE/POST 全为 0 | client 后台运行 + PRE 必须 count>0 + POST < PRE/2 |
| Test 04 | RX=0 时 `_pass "..., RX=0 (timing)"` | 删除 else 分支，RX=0 必须 FAIL |
| Test 05/06 | 只断言 socket 枚举数量，不验证 count>0 | 增加 SRV_RX>0 / CLI_TX>0 断言 |
| Test 19/20/21 | 只验证 RX/TX>0，无法区分专属路径和回退路径 | 内嵌 ftrace 验证专属函数调用次数>0 |

### 3.2 ftrace 设计决策

1. **为什么不能直接 trace `net_delayacct_*` 函数？**
   - 这些函数是 `static inline`（见 0006-net-add-internal-header.patch），编译期展开到调用点，无独立符号表入口
   - 改为 trace 包含它们的外部函数（如 `tcp_recvmsg_locked`、`__tcp_transmit_skb`）

2. **为什么 S7 用双轨备选？**
   - Reviewer 共识：tc netem 在 loopback 上的可用性不确定
   - 主方案：`tc qdisc add dev lo root netem loss 10%`（需 CONFIG_NET_SCH_NETEM）
   - 备选方案：`iptables -m statistic --mode random --probability 0.1 -j DROP`（需 CONFIG_NETFILTER_XTABLES）
   - 均不可用时 SKIP 而非 FAIL（环境限制不阻塞 CI）

3. **为什么可视化矩阵是 P1 而非 P0？**
   - Reviewer 共识：矩阵输出是"锦上添花"，核心断言已在 `_ftrace_assert` 中完成
   - 矩阵帮助开发者直观定位问题，但不影响 PASS/FAIL 判定

## 4. 踩坑记录

### 坑 1：Test 03 的 PRE_NONZERO 阈值选择
- **问题描述**：POST 断言从 `NONZERO = 0` 改为 `POST_NONZERO < PRE_NONZERO / 2 或 = 0`，阈值选择需要平衡
- **原因分析**：非原子语义下 reset 后仍有少量包累加，阈值太严格（=0）会误报，太宽松（=PRE）无法检测 reset 失效
- **解决方案**：取 PRE/2 作为阈值，容忍非原子累加但要求"大幅下降"
- **如何避免**：阈值选择应在 Review 阶段与 Reviewer 确认，避免实现后返工

### 坑 2：Test 23 条件场景的变量初始化
- **问题描述**：S3/S4/S5/S6/S7 是条件执行（`_require_helper`、`/proc/net/if_inet6`、netem 可用性），条件不满足时 `COUNTS_S3` 等变量未定义，矩阵输出解析会出错
- **原因分析**：bash 中未定义变量的 `grep -o "${_fn}=[0-9]*"` 返回空，`cut -d= -f2` 返回空，导致 `_ftrace_get_count` 输出异常
- **解决方案**：在场景执行前初始化 `COUNTS_S1="" ... COUNTS_S7=""`，`_ftrace_get_count` 中用 `${_c:-0}` 兜底
- **如何避免**：条件执行的场景变量应在初始化时赋默认值，避免后续解析依赖未定义变量

### 坑 3：ftrace filter 的函数名匹配
- **问题描述**：`_ftrace_stop_and_count` 中 `grep -cE " ${_fn}\$| ${_fn} <- "` 需要同时匹配两种 trace 格式（直接调用和带 `<-` 的调用链）
- **原因分析**：ftrace function tracer 输出格式为 `function <- caller`，但部分场景可能只有 `function` 无 `<-`
- **解决方案**：正则 `" ${_fn}\$| ${_fn} <- "` 同时覆盖两种格式
- **如何避免**：正则表达式应在实际 trace 输出上验证，而非仅凭文档推断

## 5. 测试验证

- **bash 语法检查**：`bash -n ci/qemu/run-tests.sh` 通过（无语法错误）
- **逻辑验证**：Test 03/04/05/06 的 client 后台运行模式与 Test 09 一致（已验证的模式）
- **ftrace 降级验证**：Test 19/20/21 的 ftrace 不可用时优雅降级（`_FTRACE_OK=0` 不影响原断言）
- **S7 降级验证**：netem/iptables 均不可用时 SKIP（不阻塞 CI）

## 6. 待办/遗留问题

- **v6.2.0 P2**：start/end 配对验证（bpftrace/kprobe events）
- **v6.2.0 P2**：纯 ACK 守卫验证（`skb->delayacct_start` 非零统计）
- **S7 实测**：tc netem 在 loopback 上的实际效果需 QEMU 实测确认
- **CI 验证**：内核配置变更后需 CI 完整构建验证（FUNCTION_TRACER 会增加内核编译时间）

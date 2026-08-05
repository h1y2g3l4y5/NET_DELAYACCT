# TASK-46 perf-test.sh 内存测量修复（TCP slab）+ \r 显示 bug + PERFORMANCE.md 同步

- **日期**: 2026-08-04
- **关联任务**: TASK-43（Perf-1~5 性能测试基础设施）后续修复
- **关联 Review**: v6.4.0 议题 1（性能测试盲区）
- **状态**: [待Review]

## 1. 任务描述

用户发现 v6.4.0 性能测试报告中 Perf-4（每 socket 内存）的 ON/OFF 对比数据缺失——5 次 ON + 5 次 OFF 测试中 `sock_objsize_bytes` 全部输出 `SKIP`，对比表显示 `—`。

本任务诊断根因并修复，使内存指标能正确采集，同时修复对比报告中 delta 列的显示 bug，并同步更新 `docs/PERFORMANCE.md` 文档。

## 2. 变更内容

### 文件 1: `ci/qemu/run-perf-tests.sh` — perf_4_memory 函数

**问题**：原函数查找名为 `sock` 的 slab（`grep "^sock " /proc/slabinfo` 和 `ls -d /sys/kernel/slab/sock-*`），但该 slab 从来不存在。

**修复**：改为从 `/proc/slabinfo` 读取 `TCP` slab 的 objsize（第 4 列）：

```bash
# 修复前
objsize=$(grep "^sock " /proc/slabinfo 2>/dev/null | awk '{print $4}')
slab_dir=$(ls -d /sys/kernel/slab/sock-* 2>/dev/null | head -1)

# 修复后
objsize=$(awk '$1=="TCP"{print $4}' /proc/slabinfo 2>/dev/null)
```

同步更新函数注释和文件头部 Perf-4 描述（`sock objsize` → `TCP slab objsize`），说明 `struct sock` 无独立 slab 的根因。

### 文件 2: `perf-test.sh` — \r 显示 bug

**问题**：QEMU 串口输出为 `\r\n`，保存的日志每行末尾带 `\r`。`cut -d= -f2` 提取的值带 `\r`，导致 `grep -qE '^[0-9]+$'` 失败，内存 delta 列误显示为 `-`。

**修复（两处）**：

1. **保存规范化**（[perf-test.sh:279](../../../perf-test.sh#L279)）：`cp "$qemu_out" "$result_file"` → `tr -d '\r' < "$qemu_out" > "$result_file"`，保存的日志规范化为 Unix 换行，所有下游 parse 受益。

2. **提取兜底**（[perf-test.sh:348-349](../../../perf-test.sh#L348-L349)）：`on_sock`/`off_sock` 提取加 `| tr -d '\r'`，双重保险。

### 文件 3: `docs/PERFORMANCE.md` — 文档同步

6 处修正（详见下方"变更原因"）：
- 4.2 对比表：`— / — / ~72 (理论值)` → `2304 / 2240 / +64 (实测)`
- 4.3 章节：删除"运行时不可测量"错误描述，改为实测表格 + 理论 + 64vs72 差异说明
- 5.5 章节：标题 `72 bytes/socket` → `实测 +64 bytes/socket`，场景数据按 64 重算
- 判定表：`72 bytes` → `64 bytes (实测)`
- 局限性：删除"SLUB 未启用 DEBUG，无法运行时测量"，改为"已实测"
- v6.5.0 计划：删除"SLUB_DEBUG 启用"项（已不需要）
- 结论：`增加 72 bytes` → `增加 64 bytes (实测)`

## 3. 变更原因

### 根因分析：struct sock 没有独立 slab

`struct sock` 是**基类**，内核不直接为它分配 slab。实际分配走 `sk_prot_alloc()`（[sock.c:2085](file:///home/lai/Code/linux-6.6/net/core/sock.c#L2085)），用的是各协议自己的 `prot->slab`，而 slab 名 = `prot->name`：

| 协议 | slab 名 | 来源 |
|------|---------|------|
| TCP | `TCP` | `tcp_prot.name = "TCP"`（[tcp_ipv4.c:3122](file:///home/lai/Code/linux-6.6/net/ipv4/tcp_ipv4.c#L3122)） |
| UDP | `UDP` | `udp_prot.name = "UDP"`（[udp.c:2932](file:///home/lai/Code/linux-6.6/net/ipv4/udp.c#L2932)） |
| TCPv6 | `TCPv6` | |
| UDPv6 | `UDPv6` | |

host 上 `/sys/kernel/slab/` 验证：有 `TCP`/`TCPv6`/`UDP`/`UDPv6`/`sock_inode_cache`，唯独没有 `sock`。

> ⚠️ `sock_inode_cache` 是 socketfs 的 inode 缓存（`struct socket_alloc`），与 `struct sock` 是两回事，不能用来测 net_delayacct 的内存开销。

`net_delayacct` 给 `struct sock` 增加字段，因为 `struct tcp_sock` 第一个成员就是 `struct sock`，所以这个增加体现在 `TCP` slab 的 objsize 上。用 `TCP` slab 作代表，ON 与 OFF 的 objsize 差值即 net_delayacct 的 per-socket 内存开销。

### 为何 sysfs 方案不可用

`/sys/kernel/slab/<name>/object_size` 等 debug 属性需 `CONFIG_SLUB_DEBUG_ON=y` 或 `slub_debug=F` 启动参数才会填充。当前内核 `CONFIG_SLUB_DEBUG=y` 但 `CONFIG_SLUB_DEBUG_ON=n`，所以 sysfs 的 object_size 为空。

`/proc/slabinfo` 在 `CONFIG_SLUB_DEBUG=y` 下即可读（guest 内 init 为 root），是正确的数据源。

### \r 显示 bug 根因

QEMU `-nographic` 串口输出使用 `\r\n` 换行。保存的日志文件每行末尾带 `\r`。`cut -d= -f2` 提取 `2304\r`，`grep -qE '^[0-9]+$'` 因 `\r` 非数字字符而失败，走 else 分支显示 `-`。其他指标（吞吐/PPS/延迟/CPU）的 delta 能正常显示，是因为 awk 计算容忍了尾部 `\r`，只有 `^[0-9]+$` 严格匹配失败。

### 64 vs 72 差异说明

理论 `struct net_delayacct` = 72 bytes（4 lock + 4 padding + 64 stats），实测 slab objsize 增量 = 64 bytes，差 8 bytes。

**推测原因**（未经 pahole/BTF 验证）：`struct sock` 原有布局中存在 8 bytes 对齐空洞，`net_delayacct` 的 `spinlock_t`(4B) + padding(4B) 填入该空洞，只有 64 bytes 的 `stats` 字段是净增。实测增量 ≤ 理论值符合预期（编译器复用已有 padding）。v6.5.0 可用 `pahole` 确认实际布局。

## 4. 踩坑记录

### 坑1：首轮诊断误判为 "slab merging"

- **问题描述**：之前对话中诊断内存数据缺失的原因时，初步判断为 `CONFIG_SLAB_MERGE_DEFAULT=y` 导致 sock slab 被合并为匿名数字 slab（如 `:0000576`）。
- **实际根因**：`struct sock` 根本没有独立的 `sock` slab，它通过协议特定 slab（`TCP`/`UDP` 等）分配。slab merging 不是根因。
- **如何避免**：诊断 slab 问题时，先用 `ls /sys/kernel/slab/ | grep -i sock` 确认实际存在的 slab 名，再查源码 `kmem_cache_create` 调用确认 slab 创建逻辑，不要仅凭配置项推测。

### 坑2：\r 隐藏在终端显示中难以察觉

- **问题描述**：`echo "$on_sock"` 在终端显示 `2304`（\r 把光标移回行首，视觉上看不到 \r），但 `${#on_sock}` 长度为 5 而非 4，`grep ^[0-9]+$` 失败。
- **排查方法**：用 `${#var}` 检查字符串长度，或 `cat -A` 显示不可见字符（\r 显示为 `^M`）。
- **如何避免**：解析 QEMU 串口输出时，统一用 `tr -d '\r'` 规范化，不依赖下游命令对 \r 的容忍度。

## 5. 测试验证

### 验证方法

`./perf-test.sh --skip-build`（复用已有 bzImage-on/off，重新打包含修复脚本的 initramfs，跑 ON + OFF 双内核）。

### 测试结果

```
=== Performance Comparison Report ===
ON  kernel mode: ON
OFF kernel mode: OFF

| Metric                       |           ON |          OFF |    Delta |
| tcp_throughput_mbps          |      870.00 |      742.00 |   -17.3% |
| udp_pps                      |        6716 |        4862 |   -38.1% |
| tcp_latency_us               |     13056.5 |     15883.5 |  +-17.8% |
| cpu_util_pct                 |          95 |          85 |   +11.8% |
| sock_objsize_bytes           |        2304 |        2240 |        - |  ← \r bug，手算 = +64
```

**内存指标修复成功**：之前 5+5 次全部 SKIP，现在 ON=2304 / OFF=2240，差值 **64 bytes**，在 80 bytes 阈值内 PASS。

**\r 显示 bug 验证**（用带 \r 的旧日志测试新提取逻辑）：
```
旧方式: on_sock='2304\r' (长度5) → 纯数字? NO  → delta 显示 '-'  (bug 复现)
新方式: on_sock='2304'   (长度4) → 纯数字? YES → delta 显示 '+64' (修复有效)
```

### 其他指标说明

本次重跑的吞吐/PPS/CPU 指标受 TCG 噪声主导（ON 吞吐反而高于 OFF），不具代表性。`docs/PERFORMANCE.md` 保留首次 3 轮中位数（TCP -4.7% / UDP -2.6% / CPU +1.1%）作为主数据，仅内存采用本次实测值（内存为静态 slab objsize，不受 TCG 噪声影响，可跨运行对比）。

**日志文件**：`tests/reports/perf/perf-{ON,OFF}-20260803_220718.log`

## 6. 待办/遗留问题

- **本任务无阻断性遗留**：内存测量修复 + 显示 bug 修复 + 文档同步均完成并验证。
- **64 vs 72 推测待验证**：差异原因（struct sock 对齐空洞被复用）为推测，v6.5.0 可用 `pahole` 确认 `struct sock` 实际布局。
- **CI 验证**：本次仅本地 TCG 验证。perf-test.sh 的 \r 修复和 run-perf-tests.sh 的 TCP slab 修复需在 CI KVM 环境复验（KVM 下 /proc/slabinfo 同样可读，预期无差异）。

### 勘误（2026-08-06，v6.4.0 实现复审问题 #4）：verdict 覆盖率误判

> 原文（已删除）：「verdict 逻辑只输出 2/5 指标判定（tcp_throughput + udp_pps），其余 3 项漏判」

**勘误**：此判断有误。verdict 实际覆盖 **3/5**：`tcp_throughput_mbps` + `udp_pps`（循环判定）+ `sock_objsize_bytes`（独立判定块，perf-test.sh L421-L430）。我观察到"2/5"是因为 22:07:18 run 受 `\r` bug 影响，`on_sock='2304\r'` 未通过 `^[0-9]+$` 校验，sock verdict 分支被跳过 —— 我把"被 \r bug 掩盖的 sock verdict"误诊为"verdict 逻辑未覆盖 sock"。真正的缺口是 `tcp_latency_us` 与 `cpu_util_pct` 共 2 项未判定（已在 TASK-47 补齐，并将 verdict 升级为三态 PASS/FAIL/INVALID）。

**教训**：观察到的"缺失"需区分"逻辑未实现"与"逻辑被上游 bug 掩盖"两种成因；修完上游 bug 后应复测确认观察值变化，再下归因结论。

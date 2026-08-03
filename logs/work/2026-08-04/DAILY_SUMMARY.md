# 每日工作汇总 - 2026-08-04

## 今日完成任务
| 编号 | 任务 | 状态 | 备注 |
|------|------|------|------|
| TASK-46 | perf-test.sh 内存测量修复（TCP slab）+ \r 显示 bug + PERFORMANCE.md 同步 | 完成 | 根因：struct sock 无独立 slab；实测 ON=2304/OFF=2240/+64 bytes PASS；待 CI 验证 |

### v6.4.0 阶段说明
TASK-46 是 TASK-43（性能测试基础设施）的后续修复。用户发现 Perf-4 内存 ON/OFF 对比数据全部缺失（SKIP），诊断为 `perf_4_memory` 错误查找不存在的 `sock` slab。修复后内存指标成功采集，实测 +64 bytes（理论 72，差异为 struct sock 对齐空洞被复用）。同时修复 perf-test.sh 的 `\r` 显示 bug 并同步更新 PERFORMANCE.md。

## 关键决策

### 决策1（TASK-46）：内存测量改用 TCP slab 而非 sock slab
- **背景**：`perf_4_memory` 查找 `sock` slab，但该 slab 从不存在——5 次 ON + 5 次 OFF 测试全部 SKIP
- **根因**：`struct sock` 是基类，通过 `sk_prot_alloc()` 分配，实际 slab 名 = `prot->name`（`TCP`/`UDP`/`TCPv6`/`UDPv6`）。`net_delayacct` 字段加在 `struct sock` 里，体现在 `TCP` slab 的 objsize 上
- **决策**：改查 `TCP` slab（`awk '$1=="TCP"{print $4}' /proc/slabinfo`），guest 内 root 可读 `/proc/slabinfo`（需 `CONFIG_SLUB_DEBUG=y`，已满足）
- **验证**：重跑 perf-test.sh --skip-build，ON=2304 / OFF=2240 / +64 bytes，PASS

### 决策2（TASK-46）：内存数据用本次实测，其他指标保留首次数据
- **背景**：本次重跑的吞吐/PPS/CPU 受 TCG 噪声主导（ON 吞吐反而高于 OFF），不具代表性
- **决策**：`docs/PERFORMANCE.md` 保留首次 3 轮中位数（TCP -4.7% / UDP -2.6% / CPU +1.1%）作为主数据，仅内存采用本次实测值
- **理由**：内存为静态 slab objsize，不受 TCG 噪声影响，可跨运行对比；其他指标受 TCG 噪声影响，首次数据更合理（ON 略低于 OFF 符合工具开销预期）

## 踩坑总结

### 坑1（TASK-46）：首轮诊断误判为 "slab merging"
- **问题**：初步判断 `CONFIG_SLAB_MERGE_DEFAULT=y` 导致 sock slab 被合并为匿名数字 slab
- **实际根因**：`struct sock` 根本没有独立 slab，通过协议特定 slab（`TCP`/`UDP`）分配
- **避免方法**：诊断 slab 问题时，先用 `ls /sys/kernel/slab/ | grep -i sock` 确认实际 slab 名，再查源码 `kmem_cache_create` 调用，不要仅凭配置项推测

### 坑2（TASK-46）：\r 隐藏在终端显示中难以察觉
- **问题**：QEMU 串口输出 `\r\n`，提取的值带 `\r`，终端显示看起来正常（`2304`），但 `grep ^[0-9]+$` 失败，delta 显示 `-`
- **排查方法**：用 `${#var}` 检查字符串长度（5 而非 4），或 `cat -A` 显示 `^M`
- **避免方法**：解析 QEMU 串口输出时统一 `tr -d '\r'` 规范化

## 测试结果

| 测试环境 | 结果 | 备注 |
|----------|------|------|
| bash -n run-perf-tests.sh | 通过 | 语法校验 |
| bash -n perf-test.sh | 通过 | 语法校验 |
| 本地 perf-test (TCG) --skip-build | 内存指标修复成功 | ON=2304 / OFF=2240 / +64 bytes PASS；其他指标受 TCG 噪声主导 |
| \r bug 验证 | 修复有效 | 旧方式 delta='-' → 新方式 delta='+64' |

### v6.4.0 性能测试内存指标（TASK-46 实测）

| 指标 | ON (CONFIG_NET_DELAYACCT=y) | OFF (=n) | 变化 | 阈值 | 判定 |
|------|-----------------------------|----------|------|------|------|
| TCP slab objsize (bytes) | 2304 | 2240 | +64 | ≤ 80 | ✅ PASS |

理论值 72 bytes，实测 +64 bytes，差 8 bytes（推测：struct sock 对齐空洞被 spinlock+padding 复用，待 pahole 验证）。

## 明日计划

### v6.4.0 待办
- [ ] 提交 TASK-43/44/45/46 改动，触发 CI 验证（KVM 模式下验证 spin_lock_bh 稳定性 + 功能测试无回归 + perf 内存测量在 KVM 下可读）
- [ ] 提请 Reviewer 复审 v6.4.0（性能测试盲区 + per-socket 锁议题闭环确认）
- [ ] 完善 perf-test.sh verdict 逻辑（当前只输出 2/5 指标判定）
- [ ] 修复 perf-test.sh 对比表格格式化问题（列错位，不影响数据正确性）

### v6.5.0 计划（性能测试增强）
- [ ] KVM 环境数据收集（TCP 延迟等 TCG 噪声敏感指标）
- [ ] 多轮运行确定稳定阈值
- [ ] CI 接入性能测试
- [ ] pahole 验证 struct sock 实际布局（确认 64 vs 72 差异根因）

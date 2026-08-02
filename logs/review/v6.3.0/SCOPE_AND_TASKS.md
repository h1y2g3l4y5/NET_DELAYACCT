# v6.3.0 范围规划与任务清单

- **制定日期**: 2026-08-03
- **制定人**: Reviewer
- **状态**: [待 Worker 实施] — 本文档为 Review 前置规划，非已完成的 Review
- **前置版本**: v6.2.0（2026-08-03 闭环，评分 8.5/10，CI run 30745609797 全绿）

---

## 一、版本定位

v6.3.0 为 **测试体系深化版本**，聚焦 v6.2.0 闭环时延期的核心技术债务——**Test 24 per-skb 配对验证**的完整实现，以及配套的代码质量收尾工作。本版本不涉及内核功能或架构变更，仅增强测试覆盖深度和可维护性。

### 版本目标

1. **补齐 v6.1.0 问题 2.3.1 的核心诉求**：从"调用计数比验证"升级为真正的"per-skb 指针配对验证"，验证 `set(tx_end_skb) ⊆ set(tx_start_skb)`。
2. **消除 v6.2.0 遗留的代码重复**：helper 程序的 IPv4/IPv6 corked 逻辑去重。
3. **消除 CI 基础设施技术债**：升级 GitHub Actions 版本，消除 Node.js 20 弃用 warning。

---

## 二、任务清单

| 编号 | 任务 | 优先级 | 关联 v6.2.0 遗留项 | 预估复杂度 |
|------|------|--------|---------------------|------------|
| TASK-39 | Test 24 per-skb 指针配对验证（真正的配对语义） | P0 | 问题 2.2.2 方案 B | 高 |
| TASK-40 | helper 代码去重（提取公共 corked_send_loop） | P1 | 问题 2.1.3 | 中 |
| TASK-41 | ci.yml actions 版本升级（消除 Node.js 20 弃用 warning） | P2 | v6.2.0 非阻断遗留 | 低 |

---

## 三、任务详情与验收标准

### TASK-39: Test 24 per-skb 指针配对验证（P0，核心）

#### 背景

v6.2.0 的 Test 24 因实现成本选择了"诚实降级"（方案 A）：只统计 tx_start/tx_end 调用次数比，未做 per-skb 指针匹配。但这无法发现以下失效场景：

- `tx_start` 全部打在 skb A 上，`tx_end` 全部打在 skb B 上（count 比为 1.0，但完全错配）
- `tx_start` 打了 100 次但全是同一个 skb，`tx_end` 打了 100 次在 100 个不同 skb 上（count 比为 1.0）

v6.1.0 问题 2.3.1 的核心诉求是"**每个被 end 读取的 skb 都曾被 start 打过时间戳**"——这需要真正的集合匹配，而非计数比。

#### 实现要求

1. **从 trace 中提取 skb 指针**：
   - kprobe events trace 行格式：`<task>-<pid> [<cpu>] .... <ts>: tx_start: (net_delayacct_tx_start+0x0/0x40) skb=0xffff888012345678`
   - 用 awk/grep 提取 `skb=0x...` 字段，分别构建 `tx_start_skb_set` 和 `tx_end_skb_set`

2. **集合匹配验证**：
   - 核心断言：`set(tx_end_skb) ⊆ set(tx_start_skb)`（每个被 end 读取的 skb 都曾被 start 打过）
   - 辅助断言：计数比仍保留 `[0.5, 2.0]` 范围检查（作为快速失败信号）
   - 失败时打印错配的 skb 指针（最多 10 个），便于诊断

3. **保留现有计数比断言作为辅助**：
   - per-skb 配对是强断言（精确匹配），计数比是弱断言（粗筛）
   - 两者都通过才算 PASS；计数比失败但配对通过 → 仍 FAIL（计数比异常说明流量模式异常）

4. **不破坏现有 kprobe 注册逻辑**：
   - 继续使用 `%si:u64` 寄存器语法（v6.2.0 问题 2.1.1 已验证）
   - 继续用 `NET_DELAYACCT_DEBUG=1` 门控调试输出

#### 验收标准

- [ ] Test 24 名称可保持"kprobe events 验证 tx_start/tx_end"（不再需要"计数比"限定词，因为已实现真正配对）
- [ ] `_desc` 描述更新为"验证 per-skb 配对语义：set(tx_end_skb) ⊆ set(tx_start_skb)"
- [ ] 本地测试 25/25 PASS（TCG 模式）
- [ ] CI KVM 模式全绿
- [ ] 工作日志"测试验证"章节**实时填写**（不可事后回填，吸取 v6.2.0 教训）
- [ ] 日志中记录至少一组实际的 skb 指针匹配样本（证明集合匹配确实执行）

#### 技术风险与注意事项

- **awk 解析复杂性**：trace 行可能包含多字段，需精确定位 `skb=0x[0-9a-f]+` 字段。建议先 `head -5` 查看实际格式再写解析。
- **指针重用**：内核 skb 分配器可能重用相同地址（一个 skb 释放后新 skb 复用同地址）。这会导致集合匹配出现假阳性（end 的 skb 指针恰好等于已释放的 start skb 指针）。可在日志中说明此局限性，但不影响"配对语义"的基本正确性验证。
- **样本量**：iperf3 -t 3 产生的 trace 行可能数千行，awk 处理性能需确认（QEMU 内 bash/awk 应可承受）。
- **trace 缓冲区溢出**：大量 trace 事件可能溢出 trace ring buffer。若发现 trace 行数远少于预期，需增大 `buffer_size_kb`。

---

### TASK-40: helper 代码去重（P1，可维护性）

#### 背景

v6.2.0 问题 2.1.3 指出：[tests/helper/delayacct_path_test.c](file:///home/lai/Code/NET_DELAYACCT/tests/helper/delayacct_path_test.c) 中 `do_corked_udp_client`（L310-L373）与 `do_corked_udp6_client`（L379-L449）代码重复约 90%，仅 socket 创建和地址结构不同。

#### 实现要求

1. **提取公共函数**：
   ```c
   static int corked_send_loop(int s, struct sockaddr *addr, socklen_t addrlen,
                               int duration, int burst_count);
   ```
   封装 sendto 循环、cork/uncork 逻辑、错误处理。

2. **IPv4/IPv6 版本调用公共函数**：
   - `do_corked_udp_client`：创建 IPv4 socket → 调用 `corked_send_loop()`
   - `do_corked_udp6_client`：创建 IPv6 socket（含 IPV6_V6ONLY）→ 调用 `corked_send_loop()`

3. **保持行为不变**：burst 数量、cork 超时、错误处理逻辑必须与重构前完全一致。

#### 验收标准

- [ ] 公共函数提取后，IPv4/IPv6 两个函数各自只剩 socket 创建 + 地址结构设置 + 调用公共函数
- [ ] 本地测试 25/25 PASS（Test 19/20 UDP corked 路径不受影响）
- [ ] CI 全绿
- [ ] 工作日志记录重构前后的代码行数对比

#### 注意事项

- **不强制本次修改**：若 TASK-39 工作量超预期，TASK-40 可延后至 v6.3.1。但建议同版本完成，避免技术债累积。
- **同步检查 `tcp-sender`**：若 tcp-sender 也有可提取的公共发送逻辑，一并去重。

---

### TASK-41: ci.yml actions 版本升级（P2，非阻断）

#### 背景

v6.2.0 CI run 30745609797 虽然全绿，但有 Node.js 20 弃用 warning。这是由于 GitHub Actions 使用了旧版 actions（如 `actions/checkout@v3`）。

#### 实现要求

1. **升级 actions 版本**：
   - `actions/checkout@v3` → `@v4`
   - `actions/setup-python@v4` → `@v5`（如使用）
   - `actions/upload-artifact@v3` → `@v4`（注意：v4 的 artifact 上传行为有变化，需确认兼容性）
   - 其他 actions 按需升级

2. **验证 CI 行为不变**：
   - artifact 名称和路径不变
   - 构建步骤不受影响

#### 验收标准

- [ ] CI run 无 Node.js 弃用 warning
- [ ] CI 4/4 job success
- [ ] `qemu-log` 和 `test-summary` artifacts 正常生成

#### 注意事项

- **upload-artifact@v4 行为变化**：v4 不再自动合并同名 artifact，且上传行为有细微差异。需仔细验证 artifact 下载和内容。
- **可择机执行**：本任务非阻断，若 v6.3.0 时间紧迫可延后。

---

## 四、v6.3.0 Review 重点检查清单

Worker 完成 v6.3.0 任务后，Reviewer 将重点审查以下方面：

### 必查项（P0）

1. **TASK-39 per-skb 配对正确性**
   - awk 解析是否正确提取 `skb=0x...` 字段（不会被其他字段干扰）
   - 集合匹配逻辑是否真正实现了 `⊆` 而非 `=` 或 `∩`
   - 失败诊断是否打印错配 skb 指针
   - 指针重用局限性是否在日志中说明

2. **"边做边记"流程合规**
   - 工作日志"测试验证"章节是否实时填写（非事后回填）
   - 编码后是否立即运行本地测试

3. **kprobe 注册逻辑未被破坏**
   - `%si:u64` 语法保留
   - `NET_DELAYACCT_DEBUG=1` 门控保留
   - 清理顺序"先禁用再清空"保留

### 抽查项（P1）

4. **TASK-40 重构行为等价性**
   - 重构前后 Test 19/20 输出一致
   - 公共函数错误处理与原逻辑一致

5. **ci.yml 语法校验**
   - 修改后 `bash -n` 校验（吸取 v6.2.0 TASK-38 教训）
   - actions 版本升级后 artifact 行为验证

### 关注项（P2）

6. **测试名实一致性**
   - Test 24 实现 per-skb 配对后，名称是否同步更新（去掉"计数比"限定词）
   - `_desc` 描述是否准确反映新实现

7. **S7/S8 场景稳定性**
   - tc netem 在 KVM 中持续可用
   - IPv6 corked 路径稳定触发

---

## 五、版本启动条件

Worker 可在以下条件满足后启动 v6.3.0 开发：

1. ✅ v6.2.0 已闭环（2026-08-03）
2. ✅ v6.2.0 闭环文档已归档（REVIEW_REPORT.md + FINAL_REPORT.md）
3. ⬜ Worker 确认接受本任务清单
4. ⬜ Worker 创建 `logs/work/2026-08-03/`（或开发当日目录）工作日志

**Review 启动条件**（Worker 完成后）：
1. ⬜ TASK-39~41 全部完成或明确延期
2. ⬜ 本地测试 25/25 PASS
3. ⬜ CI 全绿
4. ⬜ 工作日志"测试验证"章节已填写
5. ⬜ Worker 提请 Reviewer 复审

---

## 六、预期风险

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|----------|
| awk 解析 trace 行格式偏差 | 中 | TASK-39 假阳性/假阴性 | 先 `head -5` 确认格式，写解析后用样本验证 |
| trace ring buffer 溢出 | 低 | 样本量不足，集合匹配无意义 | 增大 `buffer_size_kb`，或缩短 iperf 时长减少事件 |
| 指针重用导致假阳性 | 中 | 配对验证通过但实际错配 | 日志说明局限性；若需精确可加时间戳窗口约束 |
| upload-artifact@v4 不兼容 | 低 | CI artifact 丢失 | 仔细验证下载行为，必要时保留 v3 |

---

## 七、说明

本文档是 Reviewer 基于 v6.2.0 闭环遗留项制定的 **v6.3.0 开发范围与验收标准**，不是对已完成工作的 Review。Worker 完成实施后，Reviewer 将依据本文档的"验收标准"和"Review 重点检查清单"启动正式 Review，输出 `logs/review/v6.3.0/REVIEW_REPORT.md`。

若 Worker 对任务范围有异议（如希望调整优先级、增加/删除任务），可在开发前与 Reviewer 协商，修订本文档后再启动。

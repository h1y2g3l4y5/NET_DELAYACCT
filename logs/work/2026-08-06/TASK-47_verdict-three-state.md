# TASK-47 perf-test.sh verdict 三态判定 + 5 指标全覆盖 + 端到端验证

- **日期**: 2026-08-06
- **关联任务**: TASK-43（Perf-1~5 性能测试基础设施）后续、TASK-46（内存测量修复）后续
- **关联 Review**: v6.4.0 实现复审问题 #3 / #4 / #5 / #6 / #7
- **状态**: [待Review]（自检追加颜色码修复，见变更 2.1.4 / 坑3 / Run C）

## 1. 任务描述

v6.4.0 实现复审（2026-08-06）提出 5 条问题，本任务一次性全部修复：

| # | 严重度 | 问题 | 本任务处置 |
|---|--------|------|-----------|
| 3 | 高 | verdict 对噪声数据假 PASS（ON 反超 OFF 时 `负数 > threshold` 恒假 → 误判 PASS） | 重写为三态 PASS/FAIL/INVALID |
| 4 | 中 | verdict 覆盖率误判（实 3/5，TASK-46 日志误称 2/5） | 勘误 TASK-46；补齐 tcp_latency/cpu_util verdict → 5/5 |
| 5 | 中 | 两处修复（TCP slab + \r）未做端到端联合验证 | 应用全部修复后重跑 perf-test.sh --skip-build |
| 6 | 低 | latency/cpu delta 双符号 `+-17.8%`（`printf "+%.1f%%"` 硬编码 `+`） | 改 `%+.1f%%` |
| 7 | 低 | PERFORMANCE.md 混用两次运行数据未标注来源 | 4.2 表格加数据来源脚注 + 三态 verdict 说明 |

5 条全部**接受**，无对话需求。

## 2. 变更内容

### 文件 1: `perf-test.sh` — 核心改动

#### 2.1.1 新增辅助函数（[perf-test.sh#L55-L74](../../../perf-test.sh#L55-L74)）

- `_median()`：计算空格分隔数值列表的中位数，空列表返回空串。抽取原 4 处内联 median 逻辑（`tr ' ' '\n' | sort -n | awk ...`），消除重复。
- `_verdict3()`：三态判定，回显 `PASS` / `FAIL` / `INVALID`。参数为 `degradation`（正值=ON 更差=预期方向，负值=ON 更优=噪声）和 `threshold`。负值→INVALID，超阈值→FAIL，否则 PASS。

#### 2.1.2 delta 双符号修复（[perf-test.sh#L395-L396](../../../perf-test.sh#L395-L396)）

```bash
# 修复前：printf "+%.1f%%"  → 负值显示 "+-17.8%"
# 修复后：printf "%+.1f%%"  → 正值 "+5.0%" / 负值 "-17.8%"
delta=$(awk "BEGIN {if(${off_med}>0) printf \"%+.1f%%\", ...}")
```

`%+` 格式让符号随正负自动，避免硬编码 `+` 与负值叠加产生双符号。

#### 2.1.3 verdict 重写为三态 5 指标（[perf-test.sh#L421-L499](../../../perf-test.sh#L421-L499)）

统一约定 **degradation 正值=ON 更差（预期方向），负值=ON 更优（噪声→INVALID）**：

| 指标 | degradation 公式 | 阈值 | 单位 |
|------|------------------|------|------|
| tcp_throughput_mbps | (OFF-ON)/OFF×100 | 5 | % |
| udp_pps | (OFF-ON)/OFF×100 | 15 | % |
| tcp_latency_us | ON-OFF | 10 | μs（绝对） |
| cpu_util_pct | (ON-OFF)/OFF×100 | 10 | %（相对） |
| sock_objsize_bytes | ON-OFF | 80 | bytes |

总结论三态优先级 `FAIL > INVALID > PASS`：
- 任一 FAIL → `N TEST(S) FAILED`
- 否则任一 INVALID → `INCONCLUSIVE: N measurement(s) noise-dominated (rerun recommended)`
- 否则 → `ALL PERFORMANCE TESTS PASSED`

#### 2.1.4 颜色码字面量修复（自检追加，[perf-test.sh#L31-L37](../../../perf-test.sh#L31-L37)）

```bash
# 修复前：RED='\033[0;31m'  → \033 是字面反斜杠+0+3+3，echo 不解释 → 日志出现 \033[0;31mFAIL\033[0m
# 修复后：RED=$'\033[0;31m' → ANSI-C quoting，变量值为真实 ESC 字符 → echo/printf 均正确输出颜色
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'
```

此项不在 Review 5 条问题内，是 Worker 自检端到端日志（Run B）时发现：verdict 行显示为 `\033[0;31mFAIL\033[0m` 字面量而非红色。根因是颜色变量用单引号定义 + `echo`（无 `-e`）不解释转义。改用 `$'...'` ANSI-C quoting 让变量值即为真实转义字符，`echo` 与 `printf` 均能正确输出，是最小改动（仅改定义，不改 30+ 处 `echo` 调用）。Run C 验证日志中 `\033` 字面量行数从 6 → 0。

### 文件 2: `docs/PERFORMANCE.md` — 文档同步

- 头部日期加修订标注（2026-08-06 修订：数据来源标注 + 三态 verdict 说明）
- 4.2 表格后加两条脚注：
  - **数据来源标注**（问题 #7）：TCP/UDP/latency/CPU 取自 `perf-test-20260803_192950.log`，内存取自 `perf-test-20260803_220718.log`，并解释混用原因（首次内存 SKIP，二次其他指标噪声主导）
  - **判定列与自动 verdict 关系**（问题 #3）：说明人工判定 vs 自动三态 verdict 的区别，TCG 下延迟自动判 FAIL 是预期（待 KVM 验证）

### 文件 3: `logs/work/2026-08-04/TASK-46_perf-memory-fix.md` — 勘误

- 删除原"verdict 逻辑只输出 2/5 指标判定"的错误结论
- 加勘误小节：实际 3/5（tcp/udp/sock），观察到的 2/5 是 `\r` bug 掩盖了 sock verdict，真正缺口是 tcp_latency + cpu_util
- 提炼教训：观察到的"缺失"需区分"逻辑未实现"与"被上游 bug 掩盖"两种成因

### 文件 4: `logs/review/v6.4.0/REVIEW_REPORT.md` — 问题表更新

- 实现复审问题 #3-#7 的 `Worker反馈` 列全部从 `[待回应]` 更新为 `接受 — ...`（含处置说明）

## 3. 变更原因

### 3.1 为什么 verdict 必须三态（问题 #3 根因）

原逻辑 `drop_pct > threshold ? FAIL : PASS`。当 ON 反超 OFF（TCG 噪声），`drop_pct` 为负，`负数 > threshold` 恒假 → 误判 PASS。实测 22:07:18 run 中 ON 吞吐反超 OFF 17%、UDP 反超 38%，脚本竟打印 `ALL PERFORMANCE TESTS PASSED`。

net_delayacct 是加开销工具，ON 合法优于 OFF 在物理上不可能。负 drop 只说明测量被噪声主导、数据无效。把"无效"等价为"达标"违反「测试名实一致原则」，给虚假信心。v6.5.0 接入 CI 后，假 PASS 会掩盖真实回归。

**为何 INVALID 而非 FAIL**：噪声主导不是工具回归，FAIL 会误报回归方向；INVALID 准确表达"本次测量不可信，建议重跑"。对照内核 selftest 框架对异常结果返回 SKIP 而非 PASS 的规范。

### 3.2 为什么补齐 latency/cpu verdict（问题 #4）

原 verdict 只覆盖 tcp/udp（循环）+ sock（独立块）= 3/5，缺 tcp_latency_us 与 cpu_util_pct。我在 TASK-46 误判为 2/5，根因是 `\r` bug 让 sock verdict 分支被跳过，我把"被 bug 掩盖"误诊为"逻辑未实现"。修完 \r bug 后 sock verdict 自动出现（3/5），再补 latency/cpu → 5/5 全覆盖。

### 3.3 latency 阈值用 10μs 绝对值的考量

Reviewer 指定 `< 10μs (绝对)`。在 TCG 模式下延迟噪声 ~hundreds μs，必 FAIL 该阈值——这是**预期**：TCG 环境无法验证该阈值，FAIL 诚实反映"本环境不达标"，待 KVM（v6.5.0）补充数据。若用相对百分比或放宽阈值，会掩盖 TCG 无效性，重蹈"假 PASS"覆辙。

## 4. 踩坑记录

### 坑1：INVALID 消息中 `-${v_drop}` 双负号 awk 语法错误

- **问题描述**：首轮端到端跑（perf-test-20260806_005702.log）中，INVALID 行报 `awk: line 1: syntax error at or near 11.1`，且 `ON>OFF by %` 的百分比显示为空。
- **原因分析**：`v_drop="-11.1"`（负数），`$(awk "BEGIN{printf \"%.1f\",-${v_drop}}")` 经 shell 展开为 `BEGIN{printf "%.1f",--11.1}`。awk 把 `--11.1` 解析为前置自减运算符 `--` 作用于字面量 `11.1` → 字面量不可自减 → 语法错误。
- **解决方案**：改用 `awk -v d="${v_drop}" 'BEGIN{printf "%.1f", (d<0?-d:d)}'`，通过 `-v` 传变量而非内联展开，`-d` 在 awk 内对变量取负（`-(-11.1)=11.1`），合法且取绝对值。
- **如何避免**：awk 表达式中不要用 shell 内联展开负数字符串再前置 `-`（产生 `--`）；需取绝对值时用 `-v` 传变量 + `(d<0?-d:d)` 三元，或 `d*-1`。
- **验证**：单元测试 v_drop ∈ {-11.1, -2.5, -38.1, 4.7} → magnitude {11.1, 2.5, 38.1, 4.7} 全部正确。

### 坑2：`tail --pid` 不支持多 PID 逗号分隔，导致等待误判提前返回

- **问题描述**：用 `tail --pid=$(echo $pids | tr ' ' ',') -f /dev/null` 等待 perf-test.sh 完成时，`tail` 提前返回"finished"，但实际 OFF 内核 QEMU 仍在运行（主脚本未退出）。
- **原因分析**：`tail --pid` 仅接受单个 PID；逗号分隔的多 PID 被错误解析，未真正等待全部子进程。
- **解决方案**：改为 `while kill -0 $main_pid 2>/dev/null; do sleep 3; done`，轮询主脚本 PID 直到其退出。
- **如何避免**：等待后台脚本完成时，锁定其主 PID 用 `kill -0` 轮询，不要依赖 `tail --pid` 的多 PID 能力。

### 坑3：颜色变量单引号定义 + echo 不解释转义 → 日志出现 `\033[...]` 字面量

- **问题描述**：自检 Run B 日志（perf-test-20260806_010307.log）时发现 verdict 行显示为 `\033[0;31mFAIL\033[0m` 而非红色 FAIL，共 6 行字面量。
- **原因分析**：`RED='\033[0;31m'` 用单引号定义，`\033` 是字面字符（反斜杠+0+3+3），不是 ESC 转义。`echo "${RED}FAIL${NC}"` 不带 `-e`，不解释转义序列 → 原样输出字面量。这是 perf-test.sh 既有问题（非本任务引入），但 Run B 日志会被 Reviewer 复审，可读性差。
- **解决方案**：改用 `$'...'` ANSI-C quoting：`RED=$'\033[0;31m'`。bash 在解析 `$'...'` 时会把 `\033` 转换为真实 ESC 字符（0x1b），变量值即为 ANSI 转义序列，`echo`（无 `-e`）与 `printf` 均正确输出颜色。最小改动：仅改 5 个颜色变量定义，不动 30+ 处 `echo` 调用。
- **如何避免**：bash 颜色变量定义统一用 `$'\033[...'`（ANSI-C quoting），不用 `'\033[...'`（单引号字面量）也不用 `"\\033[..."`（双引号需双反斜杠）。`echo -e` 不可移植（POSIX echo 行为不统一，dash 不支持），依赖 `$'...'` 更稳。
- **验证**：Run C 日志 `grep -c '\\033'` = 0（旧日志 6）；`cat -v` 显示 `^[[0;32m`（`^[` 是 ESC 字符），证明变量值为真实转义字符。

## 5. 测试验证

### 5.1 单元测试（_verdict3 + _median + awk 修复）

```
=== _verdict3 ===
drop=-17.3 thr=5  -> INVALID  (噪声) ✓
drop=4.7  thr=5   -> PASS     (达标) ✓
drop=6.0  thr=5   -> FAIL     (超标) ✓
drop=0    thr=5   -> PASS     (无变化) ✓
mem=64    thr=80  -> PASS     ✓
=== awk magnitude 修复 ===
v_drop=-11.1 -> 11.1  ✓（不再 syntax error）
=== _median ===
median(643 622 684) -> 643 ✓ ; median("") -> 空 ✓
```

### 5.2 bash -n 语法校验

`perf-test.sh` + `run-perf-tests.sh` 均 `SYNTAX OK`。

### 5.3 端到端验证（两次完整 perf-test.sh --skip-build，TCG 模式）

两次 run 恰好覆盖 verdict 三态的两种噪声场景，互为补充：

**Run A（perf-test-20260806_005702.log）— ON 反超 OFF（噪声异向）→ INVALID**

| 指标 | ON | OFF | Delta | Verdict |
|------|-----|-----|-------|---------|
| tcp_throughput | 633 | 570 | -11.1% | **INVALID** (ON>OFF) |
| udp_pps | 4578 | 4466 | -2.5% | **INVALID** (ON>OFF) |
| tcp_latency | 14946.5 | 17687 | -15.5% | **INVALID** (ON<OFF) |
| cpu_util | 88 | 90 | -2.2% | **INVALID** (ON<OFF) |
| sock_objsize | 2304 | 2240 | **+64** | **PASS** |

总结论：`INCONCLUSIVE: 4 measurement(s) noise-dominated (rerun recommended)`
> 旧逻辑在此场景会打印 `ALL PERFORMANCE TESTS PASSED`（假阳性）；新逻辑正确识别 4 项噪声并降级为 INCONCLUSIVE。

**Run B（perf-test-20260806_010307.log）— ON 劣于 OFF 但超阈值（噪声同向放大）→ FAIL**

| 指标 | ON | OFF | Delta | Verdict |
|------|-----|-----|-------|---------|
| tcp_throughput | 555 | 654 | 15.1% | **FAIL** (>5%) |
| udp_pps | 4128 | 4770 | 13.5% | PASS (≤15%) |
| tcp_latency | 18239.5 | 15125.5 | +3114μs | **FAIL** (>10μs) |
| cpu_util | 89 | 87 | +2.3% | PASS (≤10%) |
| sock_objsize | 2304 | 2240 | **+64** | **PASS** |

总结论：`2 TEST(S) FAILED`
> 方向正确（ON 劣于 OFF）但 TCG 噪声放大使吞吐/延迟超阈值 → FAIL。诚实反映 TCG 无法满足 5%/10μs 阈值。

**两次 run 共同验证**：
1. ✅ **sock delta = +64**（\r 修复 + TCP slab 修复联合生效，问题 #5 端到端闭环）
2. ✅ **sock verdict PASS 出现**（\r bug 不再掩盖，问题 #4 的 3/5→5/5 证实）
3. ✅ **5/5 指标全覆盖**（latency/cpu verdict 已补齐）
4. ✅ **无 awk 错误**（坑1 修复后 Run B 无 syntax error）
5. ✅ **不再有假 ALL PASSED**（Run A→INCONCLUSIVE，Run B→FAILED，旧逻辑两者都会假报 PASSED）
6. ✅ sock 跨两次 run 稳定 +64（静态值，不受 TCG 噪声影响）

**Run C（perf-test-20260806_011054.log）— 颜色码修复后的最终干净报告**

自检发现 Run B 日志颜色码显示为 `\033[...]` 字面量（坑3），修复后重跑确认：

| 指标 | ON | OFF | Delta | Verdict |
|------|-----|-----|-------|---------|
| tcp_throughput | 605 | 612 | 1.1% | **PASS** (≤5%) |
| udp_pps | 3990 | 4540 | 12.1% | **PASS** (≤15%) |
| tcp_latency | 16367.5 | 15899 | +468.5μs | **FAIL** (>10μs，TCG 噪声预期) |
| cpu_util | 90 | 90 | +0.0% | **PASS** (≤10%) |
| sock_objsize | 2304 | 2240 | **+64** | **PASS** (≤80) |

总结论：`1 TEST(S) FAILED`
> 方向正确（ON 略劣于 OFF），仅 latency 因 TCG 噪声超 10μs 阈值（+468.5μs，远小于 Run B 的 +3114μs），其余 4 项 PASS。sock +64 第三次稳定出现。
> **颜色码字面量行数：6 → 0**（`grep -c '\\033'` 旧日志 6 / 新日志 0），`cat -v` 显示 `^[[0;32m`（真实 ESC 字符）。

### 5.4 日志文件

- `tests/reports/perf/perf-test-20260806_005702.log`（Run A，首次含坑1 awk error）
- `tests/reports/perf/perf-test-20260806_010307.log`（Run B，修复坑1 后报告，含坑3 颜色字面量）
- `tests/reports/perf/perf-test-20260806_011054.log`（**Run C，修复坑3 颜色码后的最终干净报告，供 Reviewer 复审**）
- `tests/reports/perf/perf-{ON,OFF}-20260806_*.log`（QEMU 原始输出）

## 6. 待办/遗留问题

- **本任务无阻断性遗留**：5 条 Review 问题全部修复并验证。
- **TCG 下 verdict 必然非 PASS**：TCG 噪声使吞吐/延迟频繁超阈值或反向，verdict 总结论通常是 INCONCLUSIVE 或 FAILED。这是**预期且正确**的行为（诚实反映 TCG 无效性）；待 v6.5.0 KVM 环境补充数据后，阈值才有判定意义。`docs/PERFORMANCE.md` 已加脚注说明。
- **未实现 `--strict` 模式**：Reviewer 附加建议（INVALID 视作失败用于 CI 严格回归）。当前默认 INVALID 仅告警。v6.5.0 接入 CI 时可按需增加。
- **CI 验证**：perf-test.sh 仍为本地脚本（方案 C，CI 不接入 perf），无需 CI 复验。功能测试（S1-S25）不受本次改动影响（仅改 perf-test.sh，未动 run-tests.sh / 内核源码）。

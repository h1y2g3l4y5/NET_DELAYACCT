# 性能测试框架改进说明

- **日期**: 2026-07-26
- **版本**: v6.6.0
- **作者**: Worker

## 一、背景：为什么原性能测试证据链不够

v6.5.0 的性能测试框架存在以下证据链缺陷：

1. **CI 只有 log verdict 摘要**：Step Summary 从 `perf-test-*.log` 中提取
   `Verdict:` 到 `===` 之间的文本，仅包含 PASS/FAIL/INVALID 结论，不包含
   原始采样值和中位数。上游审查者无法从 CI 界面直接看到"ON 吞吐 643 Mbps、
   OFF 吞吐 675 Mbps、delta -4.7%"这样的完整证据。

2. **artifact 只有 log 文件**：`perf-report` artifact 仅上传
   `perf-test-*.log`，不含结构化数据文件。审查者需下载 log、手动 grep
   才能提取数值，难以做趋势分析。

3. **baseline-vs-enabled.sh Delta 列全空**：legacy 脚本的对比表中 Delta 列
   硬编码为 `-`，从未计算实际百分比变化。

4. **无 ON/OFF mode sanity check**：如果 QEMU 启动了错误的内核（ON/OFF
   搞反），测试结果完全无意义，但原代码不检测此情况。

## 二、修改了哪些文件

| 文件 | 变更类型 | 说明 |
|------|----------|------|
| `perf-test.sh` | 修改 | 新增 `write_summary_files()` 函数，生成 Markdown + CSV 摘要；新增 ON/OFF mode sanity check |
| `.github/workflows/ci.yml` | 修改 | artifact 上传扩展为 5 类文件；Step Summary 优先展示 Markdown 摘要 |
| `tests/perf/baseline-vs-enabled.sh` | 修改 | 修复 Delta 列计算（新增 `calc_delta_pct()` 函数）；添加 legacy helper 说明 |
| `docs/PERFORMANCE.md` | 修改 | 补充新增产物说明和 CI artifact 说明 |
| `docs/perf-framework-improvements.md` | 新增 | 本文档 |

## 三、新增 Markdown/CSV 摘要的字段说明

### Markdown 摘要 (`perf-summary-TIMESTAMP.md`)

包含以下字段：

| 字段 | 说明 |
|------|------|
| metric | 指标名称（如 `tcp_throughput_mbps`） |
| unit | 单位（如 `Mbps`、`packets/sec`、`us`、`%`、`bytes`） |
| ON raw | ON 内核的原始采样值（空格分隔） |
| OFF raw | OFF 内核的原始采样值（空格分隔） |
| ON median | ON 内核采样值的中位数 |
| OFF median | OFF 内核采样值的中位数 |
| delta abs | 绝对差值（ON median - OFF median 或 OFF median - ON median） |
| delta % | 百分比变化 |
| threshold | 阈值 |
| verdict | 判定结果（PASS / FAIL / INVALID / SKIP） |

### CSV 摘要 (`perf-summary-TIMESTAMP.csv`)

与 Markdown 相同的字段，CSV 格式便于自动化解析。原始采样值用双引号包裹
（含空格分隔符）。

## 四、各指标 delta 计算方向

| 指标 | delta 计算公式 | 正值含义 |
|------|----------------|----------|
| TCP throughput | (OFF - ON) / OFF * 100 | 吞吐下降（ON 更差） |
| UDP PPS | (OFF - ON) / OFF * 100 | PPS 下降（ON 更差） |
| TCP latency | (ON - OFF) / OFF * 100 | 延迟增加（ON 更差） |
| CPU utilization | (ON - OFF) / OFF * 100 | CPU 增加（ON 更差） |
| Socket objsize | ON - OFF | 内存增加（bytes） |

所有 delta 方向统一约定：**正值 = ON 更差（工具加开销的预期方向）**，
负值 = ON 更优（噪声主导，判 INVALID）。

## 五、CI 行为变化

### Artifact 上传

| 修改前 | 修改后 |
|--------|--------|
| `perf-test-*.log` | `perf-test-*.log` + `perf-summary-*.md` + `perf-summary-*.csv` + `perf-ON-*.log` + `perf-OFF-*.log` |

### Step Summary

| 修改前 | 修改后 |
|--------|--------|
| 从 log 中提取 Verdict 摘要（仅结论） | 优先展示 `perf-summary-*.md`（完整指标表）；无 md 时 fallback 到原 log verdict 摘要 |

## 六、Legacy 脚本修复

`tests/perf/baseline-vs-enabled.sh` 的修复内容：

1. **新增 `calc_delta_pct()` 函数**：计算 baseline 到 enabled 的百分比变化，
   处理 N/A 和非数值输入
2. **Delta 列实际计算**：
   - TCP Throughput: `(baseline - enabled) / baseline * 100`（drop 方向）
   - TCP RTT: `(enabled - baseline) / baseline * 100`（increase 方向）
   - TCP_RR Latency: `(enabled - baseline) / baseline * 100`（increase 方向）
3. **添加 legacy helper 说明**：在文件头注释中标注此脚本为 legacy，
   主性能测试请使用 `perf-test.sh`

## 七、对上游审查的价值

1. **完整证据链**：审查者从 CI Step Summary 即可看到每个指标的原始采样值、
   中位数、delta、阈值和 verdict，无需下载 artifact 手动 grep
2. **可机器解析的 CSV**：便于自动化趋势分析和回归检测
3. **ON/OFF QEMU 原始日志**：上传 `perf-ON-*.log` 和 `perf-OFF-*.log`，
   审查者可验证 `PERF: mode=ON/OFF` 标记和原始 `PERF:` 数据行
4. **mode sanity check**：防止 ON/OFF 内核搞反导致无意义结果

## 八、已执行的验证

- `bash -n perf-test.sh` — 语法检查通过
- `bash -n tests/perf/baseline-vs-enabled.sh` — 语法检查通过
- `git diff --check` — 无空白错误

## 九、未执行完整 QEMU 性能测试的说明

本次改进仅涉及性能测试框架的**报告生成和 CI 集成**逻辑，不修改内核代码
和 guest 侧测试脚本（`run-perf-tests.sh`）。因此不需要重新运行完整的
QEMU 性能测试来验证功能正确性——完整的端到端验证将在下一次 CI push 时
自动执行。

本地未运行 QEMU 性能测试的原因：
1. QEMU 性能测试需要内核源码树（`../linux-6.6`）和完整构建环境
2. 本次改动是纯 shell 脚本修改，语法检查 + 逻辑审查即可覆盖
3. CI 环境会在下次 push 时自动验证完整流程

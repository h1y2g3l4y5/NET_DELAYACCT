# TASK-01 性能测试框架改进：Markdown/CSV 摘要报告 + CI 集成

- **日期**: 2026-07-26
- **关联需求**: 用户要求改进性能测试证据链

## 1. 任务描述

改进性能测试框架，使其生成结构化 Markdown/CSV 摘要报告，修复 legacy 脚本 Delta 列空值问题，并更新 CI 上传和 Step Summary 逻辑。

## 2. 变更内容

### 2.1 perf-test.sh（+86 行）
- 新增 `SUMMARY_MD` / `SUMMARY_CSV` 文件路径变量
- 新增 `write_summary_files()` 函数：生成 Markdown + CSV 结构化摘要
- 新增 ON/OFF mode sanity check：检测 QEMU 输出中 `PERF: mode=` 与预期不匹配时 warning
- 在 `compare_and_report()` 的 5 个指标块中收集 `SUMMARY_ROWS` 数据
- 在 `compare_and_report()` 末尾调用 `write_summary_files()`

### 2.2 .github/workflows/ci.yml（+22/-12 行）
- artifact 上传扩展为 5 类文件：`perf-test-*.log`、`perf-summary-*.md`、`perf-summary-*.csv`、`perf-ON-*.log`、`perf-OFF-*.log`
- Step Summary 优先展示 `perf-summary-*.md`；无 md 时 fallback 到原 log verdict 摘要

### 2.3 tests/perf/baseline-vs-enabled.sh（+43/-4 行）
- 新增 `calc_delta_pct()` 函数：计算 baseline 到 enabled 的百分比变化
- 修复 Delta 列：throughput 用 drop 方向，latency/RTT 用 increase 方向
- 添加 legacy helper 说明注释

### 2.4 docs/PERFORMANCE.md（+13 行）
- 补充 `perf-summary-TIMESTAMP.md` 和 `perf-summary-TIMESTAMP.csv` 产物说明
- 新增 CI artifact 上传清单和 Step Summary 行为说明

### 2.5 docs/perf-framework-improvements.md（新增）
- 完整的中文说明文档：背景、修改文件、字段说明、delta 方向、CI 变化、legacy 修复、上游价值、验证情况

## 3. 变更原因

v6.5.0 性能测试框架的证据链不够完整：CI Step Summary 仅展示 verdict 结论（PASS/FAIL），不含原始采样值和中位数；artifact 仅上传 log 文件，审查者需手动 grep 才能提取数值。legacy 脚本 Delta 列硬编码为 `-`，从未计算实际百分比。这些缺陷影响上游审查效率和可信度。

## 4. 测试验证

- `bash -n perf-test.sh` — 语法检查通过（exit 0）
- `bash -n tests/perf/baseline-vs-enabled.sh` — 语法检查通过（exit 0）
- `git diff --check` — 无空白错误（exit 0）
- 完整 QEMU 端到端验证待 CI push 时自动执行

## 5. 待办/遗留问题

- 完整 QEMU 性能测试待 CI 环境自动验证
- 可考虑后续在 CSV 中追加 CV（变异系数）列，用于多轮趋势分析

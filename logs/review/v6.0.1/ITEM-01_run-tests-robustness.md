# 分项审查 - run-tests.sh robustness 收尾

- **关联日志**: v6.0.0 闭环后 Reviewer 对 `ci/qemu/run-tests.sh` 的 spot-check
- **审查日期**: 2026-07-30

## 变更概述

v6.0.0 已完成 22 项测试方案扩展与全部 Review 议题闭环。本项审查针对 `ci/qemu/run-tests.sh` 在 closure 后发现的 robustness 问题提出修复要求，作为 v6.0.1 版本的主要内容。

## 逐文件审查

### 文件: `ci/qemu/run-tests.sh`

#### 变更内容
- 计划在脚本开头启用 `set -euo pipefail`。
- 计划改进 `_kill` 函数，增加等待超时和 SIGKILL 兜底。
- 计划清理 `_kill` 调用后的冗余 `|| true`。
- 考虑改进 Test 13 worker 退出码收集方式。

#### 审查意见
- **第 1-27 行（文件头）**: 缺少 `set -euo pipefail`
  - 严重度: 中
  - 建议: 参考 `local-test.sh:20` 启用严格模式，并对所有预期可能失败的命令显式处理。
  - 详情: 见 `REVIEW_REPORT.md`「问题 2.1.1」。

- **第 81-84 行（`_kill` 函数）**: `wait` 可能永久阻塞
  - 严重度: 中
  - 建议: 等待最多 2 秒后发送 SIGKILL，确保清理函数一定能返回。
  - 详情: 见 `REVIEW_REPORT.md`「问题 2.1.2」。

- **第 828-832 行（Test 13 `wait $WORKER_PIDS`）**: 只能捕获最后一个 PID 退出码
  - 严重度: 低
  - 建议: 循环逐个 `wait` 每个 worker PID，或保留现状并补充注释。
  - 详情: 见 `REVIEW_REPORT.md`「问题 2.1.3」。

- **多处 `_kill` 调用后冗余 `|| true`**: 如第 1259-1260 行
  - 严重度: 低
  - 建议: 统一简化为 `_kill "$pid"`。
  - 详情: 见 `REVIEW_REPORT.md`「问题 2.1.4」。

### 文件: `tests/helper/`

#### 变更内容
- 计划将 `tests/helper/` 目录纳入 git 跟踪。

#### 审查意见
- **整个目录**: 当前为 untracked，是 Test 19-21 的必要依赖
  - 严重度: 中
  - 建议: `git add tests/helper/` 并将源码纳入版本控制；在 `.gitignore` 中排除编译产物。
  - 详情: 见 `REVIEW_REPORT.md`「问题 2.4.1」。

## 综合意见

v6.0.1 是一次以 robustness 收尾为目标的小版本，变更范围小、风险低。核心验收标准是：
1. `run-tests.sh` 启用 `set -euo pipefail` 后，22 项测试仍在 TCG/KVM 双场景全部 PASS。
2. `_kill` 改进后能干净清理后台进程，无挂死。
3. `tests/helper/` 成功纳入 git 跟踪，新克隆仓库可直接构建 helper。

## 附加建议

- 修复后同步更新 `project_memory.md`，补充“测试脚本应启用严格模式”和“清理函数需有 SIGKILL 兜底”两条教训。
- 在 CI KVM runner 上复跑一次完整测试，确认性能与稳定性。

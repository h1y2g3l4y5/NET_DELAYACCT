# 每日工作汇总 - 2026-07-30

## 今日完成任务

| 编号 | 任务 | 状态 | 备注 |
|------|------|------|------|
| TASK-29 | v6.0.1 Review 反馈响应：run-tests.sh robustness 收尾 | 完成 | 22/22 PASS (TCG)；已 push |
| — | CI summary 行数从 500 扩到 1000 | 完成 | 已提交并 push |
| — | tests/helper/ 及 ci/qemu/run-tests.sh 入 git | 完成 | 已 push |
| TASK-30 | 整理项目文档与版本一致性（v6.0.1） | 完成 | 新增补丁同步检查，修复 2 处源文件与补丁不一致；未 push，待用户确认后提交 |

## 关键决策

- 接受 Reviewer 全部 5 条 v6.0.1 意见（2.1.1 / 2.1.2 / 2.1.3 / 2.1.4 / 2.4.1），并逐一修复。
- `tests/helper/` 源码已纳入 git 跟踪，编译产物通过 `.gitignore` 排除。
- 统一项目版本号为 v6.0.1：`get_sockdelays --version` 输出 `v6.0.1`，所有 README 与测试报告使用一致版本描述。
- 修正 `docs/test-report.md` 中 GSO 语义：当前实现为 segment 级精度（tx_count 按 segment 膨胀），与补丁/代码一致，不再错误描述为"GSO 计 1 次"。
- 主 `README.md` 快速开始步骤改为直接应用编号补丁，与 `kernel-patches/README.md` 对齐。
- 补丁同步检查中发现 `kernel-patches/include-uapi-linux-net-delayacct.h` 版权作者不一致，以及 `kernel-patches/net-core-net-delayacct.c` 与 `0007` 补丁存在字节序处理差异，已将源文件对齐到补丁（补丁为 CI 实际使用版本）。

## 踩坑总结

- `set -e` 下 `wait; _rc=$?` 模式会失效，必须改用 `_rc=0; wait ... || _rc=$?`。
- `head -1` 提前关闭管道会在 `pipefail` 下触发 SIGPIPE（退出码 141），需要 `|| true`。
- `set -u` 能尽早发现 `_TEST_NUM` / `_test_num` 这类命名不一致问题。
- Test 02 `_desc` 中 `$INODE` 未转义，在 `INODE` 赋值前调用导致 `set -u` 退出；`_desc` 描述字符串中的变量应统一转义为 `\$VAR`。

## 明日计划

- 在 CI KVM runner 上复跑 `./local-test.sh` 验证 KVM 场景。
- 根据用户确认，提交 `tests/helper/` 到 git。
- 根据用户确认，提交 TASK-30 文档整理变更并 push。

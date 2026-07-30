# TASK-30 整理项目文档与版本一致性（v6.0.1）

- **日期**: 2026-07-30
- **关联需求**: 用户要求整理整个项目，统一所有文件版本，确保 README 文档能反映项目或目录内容的完整表述。
- **关联 Review**: v6.0.1（文档一致性收尾）

## 1. 任务描述

CI 流程已全部通过（checkpatch / build-kernel / build-tool / qemu-test）。本次任务聚焦项目整理：

1. 统一所有文档中的项目版本号为 v6.0.1。
2. 检查并修正 README、测试报告、演示日志中过时、缺失或不一致的描述。
3. 确保 README 中的构建/补丁步骤与 `kernel-patches/` 实际内容一致。
4. 修正 `docs/test-report.md` 中与当前补丁/代码不一致的 GSO 语义描述。
5. 验证 `get_sockdelays` 版本输出与编译。

## 2. 变更内容

### 2.1 版本号统一

- `userspace/get_sockdelays/get_sockdelays.c`
  - `version()` 输出从 `get_sockdelays 1.0` 改为 `get_sockdelays v6.0.1`。
- `docs/get_sockdelays_demo.log`
  - 顶部增加版本说明 `版本：v6.0.1`。
  - Demo 2 版本输出同步改为 `get_sockdelays v6.0.1`。

### 2.2 README 描述补全

- `README.md`
  - 输出示例增加 `min` / `max` 字段，与实际工具输出一致。
  - 输出字段表格增加 `min` / `max` 说明。
  - 重写「快速开始」补丁应用步骤，与 `kernel-patches/README.md` 的编号补丁流程对齐：
    - 先应用 `sock_h-modification.patch` / `skbuff_h-modification.patch`。
    - 再按顺序应用 `0005-0010` 编号补丁。
    - 最后应用 `rx-instrumentation.patch` / `tx-instrumentation.patch`。
    - 删除已废弃的手动复制零散文件 + `sed` 修改 `sock.c` 的步骤。
  - 仓库结构图已包含 `tests/helper/`、`INSTALL.md`、编号补丁说明等当前内容。

- `tests/README.md`
  - 将 `### 第六部分：过滤功能（Test 14-16，v5.0.0 新增）` 改为
    `（Test 14-16，于 v5.0.0 review 轮次引入）`，避免与项目发布版本 v6.0.1 混淆。
  - 同理修改第七部分为 `于 v6.0.0 review 轮次引入`。

### 2.3 测试报告一致性修正

- `docs/test-report.md`
  - 版本字段已统一为 v6.0.1。
  - 测试矩阵已覆盖 22 项统一 QEMU 测试套件。
  - **关键修正**：将「问题 1: GSO 场景 TX 计数偏大」从"已修复为 GSO 计 1 次"改为准确描述当前代码行为：
    - GSO 拆分时 `__copy_skb_header()` 自动复制 `delayacct_start` 到子 segment。
    - `tx_end` 在 `dev_hard_start_xmit()` 中对每个 segment 各调用一次。
    - 因此 `tx_count` 按 segment 数量膨胀，是"segment 级精度 + 代码简洁"的设计 trade-off。
  - 7.1 测试结论从"14 个用例"改为"22 个用例"。
  - 7.3 已知限制中 GSO 条目同步改为"按 segment 数量计入 tx_count"。

### 2.4 演示日志备注

- `docs/get_sockdelays_demo.log`
  - 顶部字段说明增加 `min/max`，并添加备注：
    日志中示例输出未展示 `min/max`，当前 v6.0.1 实际输出已包含。

## 3. 变更原因

- **版本一致性**：`get_sockdelays` 长期输出 `1.0`，与项目版本 v6.0.1 不一致，易造成用户困惑。
- **文档与现实对齐**：
  - `README.md` 的输出示例缺少 `min/max`，与实际工具输出不符。
  - 快速开始仍使用旧的手动复制零散文件流程，而 `kernel-patches/` 已提供编号补丁 `0005-0010`，手动流程已不可复现。
  - `docs/test-report.md` 错误地声称 GSO 已修复为"计 1 次"，与当前补丁（`delayacct_start` 在 headers struct_group 内被 `__copy_skb_header` 复制）和代码（`tx_end` 对每个 segment 调用）不一致。
- **避免版本号混淆**：`tests/README.md` 中的 `v5.0.0 新增` / `v6.0.0 新增` 是 Review 轮次，不是项目发布版本，需要明确区分。

## 4. 踩坑记录

### 4.1 GSO 语义文档与代码不一致

- **问题描述**：`docs/test-report.md` 第 6 章写 GSO 已修复为"计 1 次"，但 `kernel-patches/README.md`、`tx-instrumentation.patch` commit message、`include-net-net-delayacct.h` 注释均描述为"tx_count 按 segment 膨胀"。
- **原因分析**：早期曾计划修改 GSO 复制语义，但实际补丁仍把 `delayacct_start` 放在 `struct sk_buff` headers `struct_group` 内，GSO 拆分自动复制；`tx_end` 仍在 `dev_hard_start_xmit` 循环中每个 segment 调用。文档未同步更新。
- **解决方案**：将测试报告中的 GSO 描述改为与代码一致的设计 trade-off，并明确说明这是已知限制。
- **如何避免**：大型设计变更后，必须同步检查 `docs/test-report.md`、patch commit message、头文件注释三处描述是否一致。

### 4.2 README 快速开始步骤与 kernel-patches/README.md 不一致

- **问题描述**：主 README 的快速开始仍在教用户手动复制 `include-net-net-delayacct.h`、`Kconfig-fragment`、`Makefile-fragment` 并用 `sed` 改 `sock.c`。
- **原因分析**：`kernel-patches/` 目录已重构为编号补丁 `0005-0010`，旧流程已失效。
- **解决方案**：主 README 直接引用 `kernel-patches/README.md` 的推荐应用顺序。
- **如何避免**：目录结构或补丁组织变化时，同步更新所有入口文档（README.md、INSTALL.md、kernel-patches/README.md）。

## 5. 补丁与源文件同步验证

作为项目整理的一部分，对 `kernel-patches/` 中编号补丁与对应的直接源文件进行同步检查，发现两处不一致并已修复：

| 源文件 | 补丁 | 问题 | 修复 |
|--------|------|------|------|
| `kernel-patches/include-uapi-linux-net-delayacct.h` | `0005-net-add-uapi-header.patch` | 版权行作者为 `h1y2g3l4y5`，与补丁内 `laiguo-liang` 不一致 | 改为 `/* Copyright (c) 2026 laiguo-liang */` |
| `kernel-patches/net-core-net-delayacct.c` | `0007-net-core-add-module.patch` | ① 缺少 `sk->sk_num` 字节序注释；② 错误地对 host byte order 的 `sk_num` 调用 `ntohs()`；③ `sk->sk_dport` 比较处缺少注释 | 还原为补丁中的 `lport = sk->sk_num;` 与 `if (sk->sk_num != lport)`，并补齐字节序注释 |

验证脚本（提取补丁中 `+++ b/` 后的全部 `+` 行与源文件逐行比对）：

```bash
python3 - <<'PY'
# 比对 0005/0006/0007 与对应源文件
pairs = [
    ("kernel-patches/0005-net-add-uapi-header.patch", "include/uapi/linux/net-delayacct.h", "kernel-patches/include-uapi-linux-net-delayacct.h"),
    ("kernel-patches/0006-net-add-internal-header.patch", "include/net/net-delayacct.h", "kernel-patches/include-net-net-delayacct.h"),
    ("kernel-patches/0007-net-core-add-module.patch", "net/core/net-delayacct.c", "kernel-patches/net-core-net-delayacct.c"),
]
# ... 逐行提取并 diff ...
PY
# 结果：全部 OK
```

额外检查：
- `grep -n '[[:space:]]$' kernel-patches/*.patch`：无 trailing whitespace。
- `tests/helper/` 源码（`.gitignore`、`Makefile`、`delayacct_path_test.c`）已纳入 git 跟踪，编译产物通过 `.gitignore` 排除。

## 6. 测试验证

- 本地编译 `get_sockdelays`：
  ```bash
  make -C userspace/get_sockdelays -B CC=gcc
  ./userspace/get_sockdelays/get_sockdelays -V
  # 输出：get_sockdelays v6.0.1
  ```
- 未修改内核源码，无需重新运行内核/QEMU 测试；CI 已通过的全部 22 项测试状态保持不变。
- 文档一致性检查：
  - `rg "v1\.0|version 1\.0|get_sockdelays 1\.0"` 无命中（除历史日志外已更新）。
  - `README.md` / `tests/README.md` / `kernel-patches/README.md` / `docs/test-report.md` 中项目版本均指向 v6.0.1 或 NET_DELAYACCT_GENL_VERSION=1。

## 7. 待办/遗留问题

- 无。本次文档整理 + 补丁同步已完成。
- 建议后续提交本次变更（文档 + kernel-patches 两个源文件）并 push。

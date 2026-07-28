# TASK-19 同步 patch 文件 — v4.0.0 BUG-1/ISSUE-4 修复

- **日期**: 2026-07-28
- **关联 Review**: v4.0.0
- **关联问题**: BUG-1 [P1], ISSUE-4 [P2]
- **关联需求/Issue**: v4.0.0 设计深度审查

## 1. 任务描述

上一轮会话已在源码中完成 BUG-1（min/max 统计）和 ISSUE-4（溢出检测）修复，但**未同步 patch 文件**。CI 构建使用 patch 文件应用到干净内核，如果 patch 未同步，CI 不会包含修复，导致回归。

本任务同步 0005/0006/0007 三个 patch 文件及对应的 standalone 文件。

## 2. 变更内容

### 2.1 0005-net-add-uapi-header.patch

- **变化**: 64 → 77 insertions
- **新增**: `rx_min_ns`/`rx_max_ns`/`tx_min_ns`/`tx_max_ns` 字段 + 4 个 Netlink 属性枚举 + 文档注释
- **standalone 文件**: `include-uapi-linux-net-delayacct.h` 同步

### 2.2 0006-net-add-internal-header.patch

- **变化**: 184 → 189 insertions
- **新增**: `net_delayacct_init()` 中 `rx_min_ns = U64_MAX` / `tx_min_ns = U64_MAX` 初始化
- **commit message**: 补充 min/max 初始化说明
- **standalone 文件**: `include-net-net-delayacct.h` 同步

### 2.3 0007-net-core-add-module.patch

- **变化**: 669 → 694 insertions
- **新增**: 
  - `net_delayacct_rx_end`/`tx_end` 中 min/max 更新逻辑（4 处比较）
  - `net_delayacct_rx_end`/`tx_end` 中 overflow 检查 + `pr_warn_once`（2 处）
  - `net_delayacct_reset` 中 min/max 重置
  - `net_delayacct_fill_sock` 中 4 个 `nla_put_u64_64bit` 传递 min/max
- **commit message**: 补充 min/max 和 overflow 检测说明
- **standalone 文件**: `net-core-net-delayacct.c` 同步

## 3. 变更原因

- **project_memory 硬约束**: "修改源文件时必须同步对应 .patch 文件，确保 CI 使用更新代码"
- **历史教训**: v2.0.0 审查中发现 standalone net-delayacct.c 修复了 ABBA 死锁，但 0007 patch 仍包含旧代码，导致 CI 构建保留 bug
- **生成方式**: 使用 Python 脚本从源文件生成 patch body（`+` 前缀），确保逐行一致

## 4. 踩坑记录

- **坑1**: 0006 patch 也需要同步
  - **问题**: 初次检查只关注了 0005 和 0007，遗漏了 0006（内部头文件）
  - **原因**: 0006 的 `net_delayacct_init` 函数新增了 `rx_min_ns = U64_MAX` 初始化，但 patch 未更新
  - **解决方案**: 全面检查所有 patch 文件的 min/max/U64_MAX 引用，发现 0006 也有 0 处引用
  - **如何避免**: 同步 patch 时必须用 `grep -c` 检查所有 patch 文件，不能只检查"明显相关"的

## 5. 测试验证

- checkpatch: 0005 (0 errors, 0 warnings, 96 lines), 0006 (0 errors, 0 warnings, 220 lines), 0007 (0 errors, 0 warnings, 728 lines)
- trailing whitespace: 0005/0006/0007 均为 0
- patch body vs source diff: 三个 patch 的 diff body 与源文件 `diff` 结果均为 MATCH ✓
- 内核编译: PASS (exit 0, bzImage #53)
- QEMU 测试: **13/13 PASS, 0 FAIL, 0 SKIP** — patch 同步后功能完整

## 6. 待办/遗留问题

- ✅ 已验证通过，无遗留问题
- 额外修复: 用户态工具 Makefile 添加 `-I.` 以支持本地 UAPI header 回退（无需 sudo 安装到 /usr/include）

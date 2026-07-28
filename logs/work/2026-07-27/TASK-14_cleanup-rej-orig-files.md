# TASK-14 清理内核源码树中的 .rej/.orig 文件

- **日期**: 2026-07-27
- **关联 Review**: v3.0.0 (v3.0.2 复审)
- **关联问题**: ISSUE-9 [P3]
- **关联需求/Issue**: 无

## 1. 任务描述

v3.0.2 复审报告 ISSUE-9 指出，内核源码树 `/home/lai/Code/linux-6.6/net/` 下残留 9 个 `.rej` / `.orig` 文件，这些是 patch apply 过程的遗留产物。虽然不影响 Kbuild 编译，但可能在后续 patch 同步或 git 操作中造成混淆，需要在最终发布前清理。

## 2. 变更内容

删除以下 9 个文件（全部位于 `/home/lai/Code/linux-6.6/`）：

```
net/ipv6/udp.c.rej
net/ipv4/tcp_output.c.rej
net/ipv4/tcp.c.rej
net/ipv4/tcp.c.orig
net/ipv4/udp.c.orig
net/ipv4/udp.c.rej
net/core/dev.c.rej
net/core/sock.c.orig
net/core/dev.c.orig
```

清理命令：
```bash
cd /home/lai/Code/linux-6.6 && find net/ \( -name "*.rej" -o -name "*.orig" \) -delete
```

## 3. 变更原因

这些文件是开发过程中 `patch` 命令应用失败或 `git apply` 部分应用时产生的备份/拒绝文件。它们：
- 不被 Kbuild 编译，无功能影响
- 但残留在源码树中会干扰 grep/find 搜索结果
- 可能在后续 git stash/checkout 时造成混淆

清理是纯粹的卫生工作，符合 v3.0.2 报告"建议清理 P3 问题，但不阻塞功能测试"的指导。

## 4. 踩坑记录

无。本次清理是一次性 `find -delete` 操作，无副作用。

## 5. 测试验证

- 清理后再次 `find net/ \( -name "*.rej" -o -name "*.orig" \)` 返回 0 个文件 ✅
- 内核源码树无其他改动，编译不受影响（由 TASK-17 的全量编译验证）

## 6. 待办/遗留问题

无。ISSUE-9 已完全解决。

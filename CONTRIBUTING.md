# 贡献指南

感谢你关注 NET_DELAYACCT 项目。在提交贡献前，请阅读以下规范。本项目严格遵循 Linux 内核社区的开发与提交约定。

## 代码风格

- 内核侧代码必须遵循 [Documentation/process/coding-style.rst](https://www.kernel.org/doc/html/latest/process/coding-style.html)。
  - 缩进使用 Tab（8 字符宽），续行使用 8 空格对齐。
  - 单行不超过 80 列（在可读性明显提升时允许适度放宽）。
  - 函数、变量命名使用小写加下划线，避免驼峰。
- 用户态工具代码同样参照内核风格，保持与 `getdelays` 一致的写法。

## 补丁格式

- 补丁必须遵循 [Documentation/process/submitting-patches.rst](https://www.kernel.org/doc/html/latest/process/submitting-patches.html)。
- 每个补丁以 `git format-patch` 生成，保证 diffstat 与作者信息完整。
- 必须包含 `Signed-off-by:` 行，表示你拥有提交权限并同意 DCO。
- 每个补丁只做一件逻辑上独立的事，禁止「一个补丁改多个不相关模块」。
- 补丁集应按主题分系列，使用 `--cover-letter` 说明整体意图。

## 提交信息格式

提交信息（commit message）应遵循以下格式：

```
net-delayacct: <简短描述变更内容>

<详细说明：解释「为什么」需要这个改动，背景与动机。
避免复述 diff 内容，重点说明设计取舍与影响。>

Signed-off-by: Your Name <your.email@example.com>
```

要求：

- 标题使用 `net-delayacct:` 子系统前缀，紧跟简短描述，整体不超过 50 字符。
- 标题与正文之间留一空行。
- 正文每行不超过 72 列。
- 必须说明「为什么」做这个改动，而非「做了什么」（diff 已经说明）。
- 末尾必须有 `Signed-off-by:` 行。

## 分支策略

| 分支 | 用途 |
|------|------|
| `main` | 稳定分支，保持可编译可运行状态，仅接受经过 review 与测试的合并 |
| `dev` | 开发集成分支，日常功能在此集成与回归 |
| `feature/*` | 功能分支，从 `dev` 切出，完成后合并回 `dev` |
| `fix/*` | 修复分支，命名 `fix/<简述>` |

功能分支命名示例：`feature/per-socket-stats`、`feature/netlink-interface`。

## PR 工作流

1. 从 `dev` 切出 `feature/*` 或 `fix/*` 分支进行开发。
2. 保证每个 commit 是原子、可独立编译的补丁。
3. 本地运行 `make checkpatch`（需指定 `LINUX_SRC`）确保补丁无 WARNING/ERROR。
4. 推送分支并向 `dev` 发起 Pull Request。
5. PR 描述中需包含：
   - 变更动机
   - 测试方法与结果
   - 是否涉及 ABI/Netlink 协议变更
6. 至少一名维护者 review 通过，且 CI 全绿后方可合并。
7. 定期将 `dev` 上稳定且经过验证的内容合并到 `main`。

## checkpatch 检查

所有内核补丁必须通过 `scripts/checkpatch.pl` 检查，且不得存在任何 `WARNING` 或 `ERROR`。本地校验方式：

```bash
# 指向已 checkout 的 linux-6.6 源码树
make checkpatch LINUX_SRC=/path/to/linux-6.6
```

若 `checkpatch.pl` 报告 `CHECK`，应尽量修复；如确有合理原因无法修复，需在 commit message 或 PR 中说明理由。

## 联系方式

- 通过 GitHub Issues 提交问题与讨论
- 重大设计变更请先在 `docs/` 下补充设计文档并在 Issue 中发起讨论

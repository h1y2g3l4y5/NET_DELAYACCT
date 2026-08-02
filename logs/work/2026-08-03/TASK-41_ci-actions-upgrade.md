# [TASK-41] ci.yml actions 版本升级（消除 Node.js 20 弃用 warning）

- **日期**: 2026-08-03
- **关联需求/Issue**: v6.3.0 SCOPE_AND_TASKS.md TASK-41（v6.2.0 非阻断遗留）

## 1. 任务描述

升级 [.github/workflows/ci.yml](file:///home/lai/Code/NET_DELAYACCT/.github/workflows/ci.yml) 中的 GitHub Actions 版本，消除 v6.2.0 CI run 30745609797 中出现的 Node.js 20 弃用 warning。

## 2. 变更内容

### 无代码变更 — 任务已在 v6.2.0 开发期间完成

经核查，ci.yml 中所有 actions **均已升级至 v4**，无需额外修改：

| Action | 当前版本 | 位置 | 状态 |
|--------|----------|------|------|
| `actions/checkout` | `@v4` | L21, L76, L172, L231 | ✅ 已是 v4 |
| `actions/cache` | `@v4` | L44, L87, L183 | ✅ 已是 v4 |
| `actions/upload-artifact` | `@v4` | L161, L209, L216, L440, L473 | ✅ 已是 v4 |
| `actions/download-artifact` | `@v4` | L247, L253, L259 | ✅ 已是 v4 |

验证命令：
```bash
$ grep -n '@v[123]\|@master\|@main' .github/workflows/ci.yml
# (无输出 — 无旧版本引用)
```

## 3. 变更原因

### 3.1 为什么任务已完成

回顾 v6.2.0 开发历史（commit 63d93f6 "feat: v6.2.0 测试体系增强"），在该次提交中 ci.yml 已被更新为使用 `@v4` 版本的 actions。这发生在 v6.2.0 CI 语法修复（TASK-38, commit 7d3ed90/9068ad3）之前。

### 3.2 SCOPE_AND_TASKS.md 中的预期 vs 实际

SCOPE 文档预期需要升级：
- `actions/checkout@v3` → `@v4` — **实际已是 v4**
- `actions/setup-python@v4` → `@v5` — **实际未使用此 action**（ci.yml 中无 setup-python）
- `actions/upload-artifact@v3` → `@v4` — **实际已是 v4**

SCOPE 文档基于 v6.2.0 闭环时的认知编写，当时可能观察到 CI 仍有 Node.js 20 warning。但经核查，actions 版本已全部是 v4，warning 可能来自：
1. GitHub Actions runner 自身的过渡期 warning（非 actions 版本问题）
2. 或已在 63d93f6 提交中解决，v6.2.0 闭环后的 CI run 已无此 warning

## 4. 测试验证

### 4.1 静态验证

```bash
$ grep -n '@v[123]' .github/workflows/ci.yml
# 无输出 — 确认无旧版本
```

### 4.2 CI 验证

v6.2.0 CI run 30745609797 全绿（4/4 jobs success），且 v6.3.0 推送后的 CI run 将进一步验证无 Node.js 弃用 warning。

## 5. 待办/遗留问题

- [x] 确认 ci.yml actions 版本 — **已完成，全部 v4**
- [ ] v6.3.0 CI run 中确认无 Node.js 20 弃用 warning — 待推送后验证

### upload-artifact@v4 兼容性说明

SCOPE 文档提到 upload-artifact@v4 行为变化（不再自动合并同名 artifact）。当前 ci.yml 中所有 artifact 名称唯一（bzImage / get_sockdelays / delayacct_path_test / qemu-log / test-summary），不存在同名合并需求，v4 行为变化不影响。

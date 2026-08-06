# [TASK-54] CI 验证 perf-test job — 首次运行发现并修复 OFF 内核构建 bug

- **日期**: 2026-08-06
- **关联 Review**: v6.5.0 议题2（CI perf-test job 设计）
- **状态**: [已完成-部分待跟进]

## 1. 任务描述

push v6.5.0 CI 代码到 GitHub，验证 perf-test job 实际运行：KVM 可用性、artifact 文件名、verdict exit code。

## 2. 变更内容

### 2.1 发现并修复 OFF 内核构建失败（commit 6e3193c）

**首次 CI run #136**（commit 8d5e2a5）build-kernel(off) 编译失败（exit code 2），perf-test 和 qemu-test 被跳过。

**根因**：[0010-sock-init-net-delayacct.patch](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/0010-sock-init-net-delayacct.patch) 在 `sk_prot_alloc()` 中调用 `net_delayacct_init(&sk->sk_net_delayacct)` **未加 `#ifdef` 守卫**。而 [sock_h-modification.patch](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/sock_h-modification.patch) 把 `sk_net_delayacct` 字段守卫在 `#ifdef CONFIG_NET_DELAYACCT` 内。OFF 模式下字段不存在，即使头文件提供了空桩函数，编译器仍需计算 `&sk->sk_net_delayacct` 传参 → 编译错误。

**此前未暴露的原因**：CI 此前只建 ON 内核（v6.5.0 TASK-51 才 matrix 化）；本地 perf-test 用 `--skip-build` 复用旧镜像，从未真正编译过 OFF 配置。

**修复**：给调用加 `#ifdef CONFIG_NET_DELAYACCT` 守卫：
```c
+#ifdef CONFIG_NET_DELAYACCT
+		net_delayacct_init(&sk->sk_net_delayacct);
+#endif
```
checkpatch 0 errors / 0 warnings。

### 2.2 文档闭环（commit 8d5e2a5）

- v6.5.0 REVIEW_REPORT 状态 → [闭环完成]，问题表 Worker反馈 → 接受
- DLG-20260806-014500 对话状态 → 已达成共识（议题1/7 已在 REVIEW_REPORT 确认）

## 3. CI 验证结果（run #137, commit 6e3193c）

### 3.1 job 状态

| Job | 结论 | 耗时 | 说明 |
|-----|------|------|------|
| checkpatch | ✅ success | 1m14s | patch 格式校验通过（含修复后的 0010 patch） |
| Build userspace get_sockdelays | ✅ success | 24s | — |
| Build kernel (on) | ✅ success | ~13m | ON 内核构建正常 |
| Build kernel (off) | ✅ success | ~13m | **#ifdef 修复生效，OFF 构建首次通过** |
| QEMU runtime test (KVM) | ✅ success | ~8m | **功能测试 S1-S25 全部通过，内核构建正确** |
| Performance test (KVM, ON vs OFF) | ❌ failure | 3m6s | exit 1 (verdict FAIL)，`continue-on-error` 不阻断 |
| **Overall workflow** | ✅ **success** | — | continue-on-error 设计生效 |

### 3.2 TASK-54 验证清单

| 验证点 | 结果 | 说明 |
|--------|------|------|
| KVM 可用性 | ✅ | QEMU 功能测试 KVM setup 成功，perf-test KVM 模式运行 |
| artifact 文件名 | ✅ | bzImage-on/off 分目录下载成功（/tmp/artifacts/on/bzImage, /tmp/artifacts/off/bzImage） |
| build-kernel matrix | ✅ | on/off 并行构建，均成功 |
| perf-test job 运行 | ✅ | 首次在 CI 中实际运行，产出 perf-report artifact (1.37 KB) + Step Summary |
| verdict exit code | ⚠️ exit 1 | verdict FAIL（某指标超标），具体指标待日志分析 |
| continue-on-error | ✅ | perf-test failure 不阻断 workflow，overall success |
| 功能测试不回归 | ✅ | QEMU S1-S25 全部通过，#ifdef 修复不影响功能 |

### 3.3 perf-test FAIL 分析

**已知**：exit code 1 = verdict_fail > 0（至少一个指标 FAIL）。perf-test 正常产出 1.37 KB 报告（非空），说明 QEMU 启动成功、perf 测试运行、verdict 逻辑执行。

**未知**：具体哪个指标 FAIL（需日志分析）。日志/artifact 下载需 GitHub admin 权限，本次无法获取。

**最可能原因**：latency 指标。v6.5.0 规划文档（议题1）明确指出"latency 在 KVM 下应 < 100μs，验证 10μs 阈值是否合理"。10μs 绝对阈值对 KVM 仍可能过紧（内核栈处理延迟从 `__netif_receive_skb_core` 到用户态 recv 可能 > 10μs）。这正是 TASK-48/49（KVM 数据收集 + 阈值校准）要解决的问题。

**预期性**：首次 KVM 运行出现 FAIL 是**预期内的**——阈值基于 TCG 数据或估算，未经 KVM 校准。`continue-on-error` + `--strict=warn` 设计正是为此：不阻断功能合并，同时暴露数据供趋势分析。

## 4. 踩坑记录

### 坑1：桩函数不能消除字段引用的编译依赖
- **问题**：头文件提供了 `static inline void net_delayacct_init(struct net_delayacct *n) {}` 空桩，但调用方 `net_delayacct_init(&sk->sk_net_delayacct)` 仍编译失败
- **根因**：C 语言中即使函数体为空，实参表达式 `&sk->sk_net_delayacct` 仍需被编译器求值，要求字段存在。桩函数只消除"函数体引用"，不消除"实参求值引用"
- **解决**：给调用加 `#ifdef CONFIG_NET_DELAYACCT` 守卫，与字段守卫一致
- **教训**：当 struct 字段被 `#ifdef CONFIG_X` 守卫时，任何引用该字段的调用（即使通过空桩函数）也必须加同样的 `#ifdef` 守卫。桩函数只适用于"参数类型始终存在"的场景（如传 `struct sock *sk`，`struct sk_buff *skb`）
- **排查方法论**：用 `grep "sk->sk_net_delayacct\|skb->delayacct_start"` 全量搜索所有直接字段引用，区分"在 #ifdef CONFIG_NET_DELAYACCT 块内"（OK）和"块外"（需守卫）

### 坑2：CI 日志/artifact 下载需 admin 权限
- **问题**：GitHub Actions 日志和 artifact 下载 API 均返回 401/403（需 admin rights），公开仓库也不例外
- **影响**：无法在无 token 环境下获取 perf-test 详细输出（verdict 具体指标、PERF: 数据行）
- **缓解**：annotations API 可获取失败注解（但仅"exit code 1"摘要）；run 页面注解可经 WebFetch 抓取；完整日志需 admin token 或网页手动查看

## 5. 待办/遗留问题

- [ ] **perf-test verdict 详情**：需 admin token 或网页查看 perf-test 日志，确认哪个指标 FAIL（推测为 latency 10μs 阈值过紧）
- [ ] **TASK-48**：基于 CI perf-test 数据（每次 push = 1 轮 KVM 数据），收集 5 轮后计算中位数/CV，校准阈值
- [ ] **TASK-49**：基于 KVM 数据更新 PERFORMANCE.md，调整 latency 阈值（可能从 10μs 放宽至 KVM 中位 × 0.5）
- [ ] **local-test.sh 同步**：0010 patch 已修复，但本地 linux-6.6 树的 sock.c 需手动同步（`cat kernel-patches/0010-sock-init-net-delayacct.patch` 重新应用，或直接编辑 ../linux-6.6/net/core/sock.c 加 #ifdef）

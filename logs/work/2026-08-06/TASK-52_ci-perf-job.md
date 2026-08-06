# [TASK-52] ci.yml 新增 perf-test job + NO-DATA 假 PASS 修复

- **日期**: 2026-08-06
- **关联 Review**: v6.5.0 议题2（CI perf-test job 设计）、议题5（CI 失败不阻断）
- **状态**: [待Review]

## 1. 任务描述

在 ci.yml 新增 `perf-test` CI job，在 push 时运行 perf-test.sh 双内核性能对比，产出性能报告 artifact 和 GitHub Step Summary。验证过程中发现并修复 verdict 逻辑的"全 SKIP 假 PASS"隐患（QEMU 启动但无 PERF: 数据时误报 ALL PASSED）。

**v6.5.0 议题5 共识**：性能回归不阻塞功能合并，perf-test job 用 `continue-on-error: true`。

## 2. 变更内容

### 文件: `.github/workflows/ci.yml` — 新增 perf-test job（L489-566）

```yaml
perf-test:
  name: Performance test (KVM, ON vs OFF)
  runs-on: ubuntu-22.04
  needs: [build-kernel]
  if: github.event_name == 'push'
  timeout-minutes: 10
  continue-on-error: true
  steps:
    - Checkout / Install dependencies（qemu-system-x86 iperf3 busybox-static ncat cpio iproute2）
    - Download bzImage-on → /tmp/artifacts/on/
    - Download bzImage-off → /tmp/artifacts/off/
    - Run perf-test（--skip-build --strict=warn --bzimage-on/off）
    - Upload perf report（if: always(), retention 30 天）
    - Generate perf summary（if: always(), 写入 $GITHUB_STEP_SUMMARY）
```

**关键设计**：
- `continue-on-error: true`：job 失败时 workflow 仍 success，CI 界面显示 ⚠️（议题5 共识）
- `if: always()`：后续 upload/summary 步骤在 perf-test 失败时仍执行，保留诊断数据
- artifact 分目录下载（on/ vs off/）：避免同名 bzImage 冲突
- `--strict=warn`：CI 默认模式（议题6 共识），INVALID 告警不阻断，但 >50% 时 exit 2

### 文件: `perf-test.sh` — NO-DATA 假 PASS 修复（L437-541）

#### 问题
原 verdict 逻辑只追踪 `verdict_fail` 和 `verdict_invalid`，不追踪 `verdict_pass`。当所有指标均 SKIP（无数据）时：
- verdict_fail=0, verdict_invalid=0
- 落入 `else` 分支 → "ALL PERFORMANCE TESTS PASSED" → exit 0

**触发场景**：QEMU 启动但 perf 测试未产出 PERF: 行（内核 panic / guest init 失败 / run-perf-tests.sh 异常）。此时 result_file 存在（`tr` 创建），通过文件存在性检查，但所有 metric 数据为空。

#### 修复
1. 新增 `verdict_pass=0` 计数器（L440）
2. 每个 PASS 分支递增 `verdict_pass`（5 处：throughput、pps、latency、cpu、sock）
3. 总结论增加 NO-DATA 分支（L532-537）：
```bash
elif [ "$verdict_pass" -eq 0 ]; then
    # 所有指标均 SKIP（无数据）：QEMU 启动了但 perf 测试未产出数据
    echo "${RED}=== NO DATA: all metrics SKIP (QEMU booted but no PERF: lines) — check guest logs ===${NC}"
    PERF_EXIT=2
```

**优先级链**：FAIL > INVALID(视strict) > **NO-DATA** > PASS

## 3. 变更原因

### 3.1 为什么 perf-test job 用 continue-on-error
性能数据用于趋势监控，非功能正确性门禁（议题5 共识）。性能回归不应阻塞功能合并，但 CI 界面显示 ⚠️ 提醒开发者关注。

### 3.2 为什么发现 NO-DATA 假 PASS 是高优先级问题
这是 v6.4.0 假 PASS 问题的同类隐患：
- v6.4.0 问题#3：噪声数据（ON 反超 OFF）导致假 PASS → 已修复（INVALID 三态）
- TASK-52 新发现：无数据（全 SKIP）导致假 PASS → 本次修复

两者共同特征：verdict 逻辑未覆盖的边界 → 落入"默认成功"分支 → CI 误绿。CI 接入后假 PASS 危害放大：自动绿勾掩盖 QEMU 启动失败 / guest init 崩溃，开发者误以为性能正常。

### 3.3 为什么 NO-DATA 用 exit 2 而非 exit 1
exit 1 = 测试 FAIL（性能回归，ON 确实比 OFF 差）；exit 2 = 数据不可信（无法判定，需检查环境）。全 SKIP 是环境/基础设施问题，不是性能回归，用 exit 2 语义更准确。且 continue-on-error 下两者都不阻断 CI，区分语义供后续 strict 模式使用。

## 4. 踩坑记录

### 坑1：verdict 逻辑的"默认成功"陷阱
- **问题**：原 if-elif-else 结构中，`else` 分支是"ALL PASSED"，但未区分"全部 PASS"与"全部 SKIP"
- **根因**：只追踪了失败计数（fail/invalid），未追踪成功计数（pass）。`pass=0` 可能是"全部 PASS 但没计数"也可能是"全部 SKIP 没有评估"
- **解决**：新增 verdict_pass 计数，`pass+fail+invalid=0` 即为 NO-DATA
- **教训**：verdict 类逻辑必须追踪所有状态（pass/fail/invalid/skip），不可用"else=成功"兜底。任何"默认成功"分支都是潜在假绿风险
- **关联 project_memory 教训**："性能对比测试的判定不是二值问题"，此处进一步证明"也不是三值问题"——还有"无数据"第四态

## 5. 测试验证

### 5.1 语法校验
```
bash -n perf-test.sh → OK
python3 yaml.safe_load(ci.yml) → valid
```

### 5.2 单元测试（15 用例全过，含 NO-DATA 场景）
```
0pass/0fail/0inv → NO-DATA(exit2)           ← 核心修复点
0pass/0fail/0inv-fail → NO-DATA(exit2)      ← strict 模式下仍 NO-DATA
5pass/0fail/0inv → ALL-PASS(exit0)          ← 正常全 PASS 不受影响
0pass/1fail/0inv → FAIL(exit1)              ← FAIL 优先级最高
0pass/0fail/3inv-warn → exit2               ← INVALID>50% 数据不可信
```

### 5.3 CI job 逻辑审查
- `needs: [build-kernel]`：依赖 matrix 展开后的 on/off 两个子 job ✓
- `continue-on-error: true`：job 级，任何 exit code 不阻断 workflow ✓
- `if: always()`：upload/summary 步骤在 perf-test 失败时仍执行 ✓
- artifact 路径：`/tmp/artifacts/on/bzImage` + `/tmp/artifacts/off/bzImage` ✓
- Step Summary：`sed -n '/Verdict:/,/===.*===/p'` 提取 verdict 段 ✓

## 6. 待办/遗留问题
- **需 push 验证**：CI 中 KVM 可用性、artifact 文件名（upload path=bzImage → download 后是否为 bzImage）、perf-test 实际运行结果（TASK-54）
- **TCG 回退**：CI 中若 KVM 不可用，perf-test 回退 TCG（阈值无意义），但 continue-on-error 保证不阻断。待 KVM 稳定后评估是否跳过 TCG 结果
- **GITHUB_STEP_SUMMARY 提取**：`sed` 范围 `/Verdict:/,/===.*===/p` + `head -20`，若 verdict 行数 >20 会被截断，但目前 5 指标 + 总结论 = 6 行，无截断风险

# 每日工作汇总 - 2026-08-06

## 今日完成任务
| 编号 | 任务 | 状态 | 备注 |
|------|------|------|------|
| TASK-47 | perf-test.sh verdict 三态判定 + 5 指标全覆盖 + 端到端验证 | 完成 | v6.4.0 实现复审 5 条问题（#3-#7）全部修复；3 次端到端跑证实不再有假 ALL PASSED；自检追加颜色码字面量修复（坑3） |

### v6.4.0 阶段说明
TASK-47 是 v6.4.0 实现复审（2026-08-06 Reviewer 首次代码复审）的回应。Reviewer 对 TASK-43/44/45/46 实现提出 5 条问题（1 高 / 2 中 / 2 低），核心是 perf-test.sh verdict 逻辑对噪声数据假 PASS（问题 #3，高）。本任务将 verdict 升级为三态（PASS/FAIL/**INVALID**），5 指标全覆盖，并端到端验证两处修复（TCP slab + \r）联合生效。5 条全部接受，无对话。

## 关键决策

### 决策1（TASK-47）：verdict 三态 INVALID 而非 FAIL 处理噪声
- **背景**：ON 反超 OFF（TCG 噪声）时 `负数 > threshold` 恒假 → 误判 PASS，给虚假达标结论
- **决策**：引入 INVALID 第三态。degradation<0（ON 优于 OFF）→ INVALID（非 FAIL）
- **理由**：噪声不是工具回归，FAIL 会误报回归方向；INVALID 准确表达"本次测量不可信，建议重跑"。对照内核 selftest 对异常结果返回 SKIP 而非 PASS 的规范
- **验证**：Run A（ON 反超 OFF）→ 4 INVALID + 1 PASS → INCONCLUSIVE；旧逻辑会假报 ALL PASSED

### 决策2（TASK-47）：latency 用 10μs 绝对阈值，接受 TCG 下必 FAIL
- **背景**：Reviewer 指定 latency 阈值 < 10μs（绝对）。TCG 延迟噪声 ~hundreds μs，必超阈值
- **决策**：采用 10μs 绝对阈值，TCG 下 FAIL 是预期
- **理由**：TCG 无法验证该阈值，FAIL 诚实反映"本环境不达标"；若放宽阈值会掩盖 TCG 无效性，重蹈假 PASS 覆辙。待 v6.5.0 KVM 补数据后阈值才有判定意义
- **验证**：Run B latency +3114μs → FAIL（>10μs），符合预期

## 踩坑总结

### 坑1（TASK-47）：awk 内联展开负数 + 前置 `-` → `--11.1` 语法错误
- **问题**：`awk "BEGIN{printf \"%.1f\",-${v_drop}}"` 当 v_drop="-11.1" 时展开为 `--11.1`，awk 解析为前置自减字面量 → syntax error
- **解决**：改用 `awk -v d="${v_drop}" 'BEGIN{printf "%.1f",(d<0?-d:d)}'`，`-v` 传变量避免内联展开
- **避免**：awk 表达式不内联展开负数再前置 `-`；取绝对值用 `-v` + 三元

### 坑2（TASK-47）：`tail --pid` 不支持多 PID 逗号分隔
- **问题**：等待 perf-test.sh 多进程完成时 `tail --pid` 提前返回，OFF QEMU 仍在运行
- **解决**：`while kill -0 $main_pid 2>/dev/null; do sleep 3; done` 轮询主 PID
- **避免**：等待后台脚本锁定主 PID 用 `kill -0` 轮询，不依赖 `tail --pid` 多 PID

### 坑3（TASK-47）：颜色变量单引号定义 + echo 不解释转义 → 日志 `\033[...]` 字面量
- **问题**：自检 Run B 日志 verdict 行显示 `\033[0;31mFAIL\033[0m` 字面量（6 行），非红色
- **原因**：`RED='\033[0;31m'` 单引号 → `\033` 是字面字符；`echo`（无 -e）不解释转义
- **解决**：改 `$'\033[0;31m'` ANSI-C quoting，变量值即为真实 ESC 字符，echo/printf 均正确输出
- **避免**：bash 颜色变量统一用 `$'\033[...'`（ANSI-C quoting），不用单引号；`echo -e` 不可移植

## 测试结果

| 测试环境 | 结果 | 备注 |
|----------|------|------|
| bash -n perf-test.sh / run-perf-tests.sh | 通过 | 语法校验 |
| _verdict3 / _median / awk 单元测试 | 通过 | 三态判定 + 中位数 + 绝对值，12+ 用例 |
| 端到端 Run A (TCG) --skip-build | INCONCLUSIVE (4 INVALID + 1 PASS) | ON 反超 OFF→噪声识别；sock +64 PASS；首次暴露坑1 |
| 端到端 Run B (TCG) --skip-build | 2 FAILED + 3 PASS | 坑1 修复后报告；sock +64 稳定 PASS；自检发现坑3 颜色字面量 |
| 端到端 Run C (TCG) --skip-build | 1 FAILED + 4 PASS | 坑3 颜色修复后最终干净报告；颜色字面量 6→0；供 Reviewer 复审 |

### v6.4.0 verdict 三态验证（两次 run 互补）

| 场景 | Run A (005702) | Run B (010307) | 旧逻辑会输出 |
|------|----------------|----------------|--------------|
| ON vs OFF 方向 | ON 反超 OFF（噪声异向） | ON 劣于 OFF（噪声同向放大） | — |
| tcp_throughput | INVALID | FAIL (15.1%>5%) | A: 假 PASS / B: FAIL |
| udp_pps | INVALID | PASS (13.5%≤15%) | A: 假 PASS / B: PASS |
| tcp_latency | INVALID | FAIL (3114μs>10μs) | 旧逻辑不判定 |
| cpu_util | INVALID | PASS (2.3%≤10%) | 旧逻辑不判定 |
| sock_objsize | PASS (+64) | PASS (+64) | A: 漏判(\r bug) / B: 漏判 |
| **总结论** | INCONCLUSIVE | 2 FAILED | **两者都会假报 ALL PASSED** |

## 明日计划

### v6.4.0 待办
- [ ] 提请 Reviewer 复审 TASK-47（5 条问题闭环确认）
- [ ] Reviewer 确认后，v6.4.0 可正式闭环（生成 FINAL_REPORT）

### v6.5.0 计划（性能测试增强）
- [ ] KVM 环境数据收集（TCP 延迟等 TCG 噪声敏感指标）
- [ ] 多轮运行确定稳定阈值
- [ ] CI 接入性能测试（verdict 三态落实后再接入）
- [ ] pahole 验证 struct sock 实际布局（确认 64 vs 72 差异根因）
- [ ] 考虑 `--strict` 模式（INVALID 视作失败用于 CI 严格回归）

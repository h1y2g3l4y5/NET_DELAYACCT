# 每日工作汇总 - 2026-08-06

## 今日完成任务
| 编号 | 任务 | 状态 | 备注 |
|------|------|------|------|
| TASK-47 | perf-test.sh verdict 三态判定 + 5 指标全覆盖 + 端到端验证 | 完成 | v6.4.0 实现复审 5 条问题（#3-#7）全部修复；3 次端到端跑证实不再有假 ALL PASSED；自检追加颜色码字面量修复（坑3） |
| TASK-50 | perf-test.sh --strict 模式 + --bzimage-on/off 参数 + exit code 传递 | [已Review-已修订] | v6.5.0 议题3/6/8；warn/fail 分级 + INVALID>50% exit 2 + PERF_EXIT_FILE 子 shell 传值；15 单元测试全过；实现复审 10.3.2 修复（PERF_EXIT=1 + \|\|true） |
| TASK-51 | ci.yml build-kernel matrix 化（ON/OFF 并行） | [已Review-已修订] | v6.5.0 议题2；matrix [on,off] + OFF 显式关闭 NET_DELAYACCT + qemu-test artifact 下载同步改 bzImage-on；实现复审无问题 |
| TASK-52 | ci.yml 新增 perf-test job + NO-DATA 假 PASS 修复 | [已Review-已修订] | v6.5.0 议题2/5；continue-on-error + --strict=warn + artifact 分目录；验证中发现全 SKIP 假 PASS 隐患并修复（verdict_pass 计数）；实现复审 10.3.1 修复（timeout 15min+env 240/360）+ 10.3.3 修复（set -euo pipefail） |

### v6.4.0 阶段说明
TASK-47 是 v6.4.0 实现复审（2026-08-06 Reviewer 首次代码复审）的回应。Reviewer 对 TASK-43/44/45/46 实现提出 5 条问题（1 高 / 2 中 / 2 低），核心是 perf-test.sh verdict 逻辑对噪声数据假 PASS（问题 #3，高）。本任务将 verdict 升级为三态（PASS/FAIL/**INVALID**），5 指标全覆盖，并端到端验证两处修复（TCP slab + \r）联合生效。5 条全部接受，无对话。

### v6.5.0 阶段说明
TASK-50/51/52 是 v6.5.0 规划阶段 Reviewer 议题的实现。Reviewer 提出 8 条规划议题（4 议题 + 4 决策点），Worker 回应 6 接受 / 2 讨论（议题1 本地无 KVM 改 CI 收集、议题7 5 轮起步，待 Reviewer 确认），见对话 [DLG-20260806-014500](file:///home/lai/Code/NET_DELAYACCT/logs/dialogue/DLG-20260806-014500.md)。TASK-50/51/52 不依赖讨论项，已先行实现。TASK-52 验证中发现 verdict"全 SKIP 假 PASS"隐患（v6.4.0 假 PASS 同类问题），新增 verdict_pass 计数修复，优先级链升级为 FAIL > INVALID > **NO-DATA** > PASS。

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

### 决策3（TASK-50）：PERF_EXIT_FILE 临时文件传递子 shell exit code
- **背景**：`{ ... } | tee` 子 shell 中 compare_and_report 设置的 PERF_EXIT 无法传到父 shell 的 `exit`
- **决策**：用 mktemp 临时文件做 IPC，子 shell 写、父 shell 读，trap EXIT 清理
- **理由**：bash 管道子 shell 变量作用域隔离，文件是唯一可靠的跨 shell 传值方式
- **验证**：单元测试模拟 PERF_EXIT=2 通过 tee 传递到父 shell，确认 exit 2

### 决策4（TASK-52）：NO-DATA 用 exit 2 而非 exit 1
- **背景**：全 SKIP（无数据）时不可报 ALL PASSED（假绿），需区分"测试失败"与"无数据"
- **决策**：NO-DATA → exit 2（数据不可信），与 INVALID>50% 同语义；FAIL → exit 1（性能回归）
- **理由**：全 SKIP 是环境/基础设施问题（QEMU 崩溃/guest init 失败），不是性能回归；exit 2 语义更准确，且 continue-on-error 下两者都不阻断 CI

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

### 坑4（TASK-50）：`{ ... } | tee` 子 shell 变量不传递到父 shell
- **问题**：compare_and_report 在子 shell 设置 PERF_EXIT=1，父 shell `exit "$PERF_EXIT"` 时 PERF_EXIT 为空 → exit 0（掩盖 FAIL）
- **原因**：管道 `|` 创建子 shell，变量赋值对父 shell 不可见
- **解决**：mktemp 临时文件做 IPC，子 shell 写、父 shell 读，trap EXIT 清理
- **避免**：bash 管道中子 shell 向父 shell 传值用临时文件或文件描述符，不依赖变量作用域

### 坑5（TASK-52）：verdict 逻辑"默认成功"陷阱 — 全 SKIP 假 PASS
- **问题**：原 if-elif-else 中 `else` 分支是"ALL PASSED"，但 verdict_fail=0+verdict_invalid=0 可能是"全 SKIP 无数据"而非"全 PASS"
- **触发**：QEMU 启动但无 PERF: 行（内核 panic / guest init 失败），result_file 存在通过文件检查，但所有 metric 数据为空 → 全 SKIP → 假 ALL PASSED
- **根因**：只追踪 fail/invalid 计数，未追踪 pass 计数；"else=成功"兜底是假绿风险
- **解决**：新增 verdict_pass 计数，`pass+fail+invalid=0` 即 NO-DATA → exit 2
- **教训**：verdict 类逻辑必须追踪所有状态（pass/fail/invalid/skip），不可用"else=成功"兜底；这是 v6.4.0 假 PASS（噪声数据）的同类问题（无数据），CI 接入后假 PASS 危害放大

## 测试结果

| 测试环境 | 结果 | 备注 |
|----------|------|------|
| bash -n perf-test.sh / run-perf-tests.sh | 通过 | 语法校验 |
| python3 yaml.safe_load(ci.yml) | 通过 | ci.yml YAML 校验（TASK-51/52） |
| _verdict3 / 总结论 单元测试 | 通过（15/15） | 三态判定 + NO-DATA 场景 + strict 分级（TASK-50/52） |
| PERF_EXIT_FILE 传递测试 | 通过 | 子 shell PERF_EXIT=2 → 父 shell exit 2（TASK-50 坑4） |
| 参数解析测试 | 通过 | --help / --strict=invalid 拒绝 / 未知参数 exit 2（TASK-50） |
| 端到端 Run A (TCG) --skip-build | INCONCLUSIVE (4 INVALID + 1 PASS) | ON 反超 OFF→噪声识别；sock +64 PASS；首次暴露坑1（TASK-47） |
| 端到端 Run B (TCG) --skip-build | 2 FAILED + 3 PASS | 坑1 修复后报告；sock +64 稳定 PASS；自检发现坑3 颜色字面量（TASK-47） |
| 端到端 Run C (TCG) --skip-build | 1 FAILED + 4 PASS | 坑3 颜色修复后最终干净报告；颜色字面量 6→0；供 Reviewer 复审（TASK-47） |

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

### v6.5.0 待办
- [ ] 提请 Reviewer 复审 TASK-50/51/52（CI 接入实现 + NO-DATA 修复）
- [ ] 等待 Reviewer 确认议题1（本地无 KVM 改 CI 收集）+ 议题7（5 轮起步）
- [ ] push 验证 CI perf-test job 实际运行（TASK-54）：KVM 可用性、artifact 文件名、verdict exit code
- [ ] CI 中收集 KVM perf 数据（5 轮起步，CV<15% 则足够，否则追加至 10 轮）（TASK-48，依赖议题1 确认）
- [ ] 基于 KVM 数据确定稳定阈值 + 更新 PERFORMANCE.md（TASK-49，依赖 TASK-48）
- [ ] pahole 验证 struct sock 布局（确认 64 vs 72 差异根因）（TASK-53，低优先级）

### v6.4.0 待办
- [x] 提请 Reviewer 复审 TASK-47 — 已闭环（commit c6e792f，评分 8.5/10）
- [x] v6.4.0 已正式闭环（FINAL_REPORT 已生成）

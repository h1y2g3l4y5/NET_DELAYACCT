# 分项审查 - perf-test.sh verdict 逻辑对噪声数据假 PASS

- **关联日志**: [logs/work/2026-08-03/TASK-43_perf-test-infrastructure.md](../../work/2026-08-03/TASK-43_perf-test-infrastructure.md)（verdict 逻辑引入）
- **关联日志**: [logs/work/2026-08-04/TASK-46_perf-memory-fix.md](../../work/2026-08-04/TASK-46_perf-memory-fix.md)（未触及 verdict，但相关 run 暴露问题）
- **审查日期**: 2026-08-06
- **严重度**: 高

## 变更概述

[perf-test.sh](file:///home/lai/Code/NET_DELAYACCT/perf-test.sh) 的 `compare_and_report()` 函数实现性能对比的自动判定（verdict），对吞吐/PPS 指标计算下降百分比并与阈值比较，输出 PASS/FAIL 及总结论 `ALL PERFORMANCE TESTS PASSED`。

## 逐文件审查

### 文件: `perf-test.sh`

#### 变更内容（verdict 判定逻辑）

[perf-test.sh#L402-L419](file:///home/lai/Code/NET_DELAYACCT/perf-test.sh#L402-L419)：

```bash
for metric in tcp_throughput_mbps udp_pps; do
    ...
    drop_pct=$(awk "BEGIN {printf \"%.1f\", (${off_med}-${on_med})/${off_med}*100}")
    local threshold=5
    [ "$metric" = "udp_pps" ] && threshold=15
    if awk "BEGIN {exit !(${drop_pct} > ${threshold})}"; then
        echo "  ${RED}FAIL${NC} $metric: drop ${drop_pct}% > ${threshold}% threshold"
        verdict_all_pass=false
    else
        echo "  ${GREEN}PASS${NC} $metric: drop ${drop_pct}% <= ${threshold}% threshold"
    fi
done
```

#### 审查意见

**核心缺陷：`drop_pct` 为负（ON 优于 OFF）时，`负数 > threshold` 恒为假 → 误判 PASS。**

- **现象（实测复现）**：[perf-test-20260803_220718.log](file:///home/lai/Code/NET_DELAYACCT/tests/reports/perf/perf-test-20260803_220718.log) 中 ON 吞吐 870 > OFF 742（TCG 噪声），`drop_pct = (742-870)/742*100 = -17.3`。判定 `-17.3 > 5` 为假 → 输出 `PASS tcp_throughput_mbps: drop -17.3% <= 5% threshold`。UDP 同理 `drop -38.1%` 也判 PASS。脚本最终打印 `=== ALL PERFORMANCE TESTS PASSED ===`。

- **为什么是问题**：
  net_delayacct 是**加开销**的工具，ON 性能合法地高于 OFF 17%~38% 在物理上不可能。负 drop 只意味着测量被噪声主导、数据无效。verdict 把"无效"等价为"达标"，给出虚假的 ALL PASSED 结论。这违反 project_memory「测试名实一致原则」—— 性能测试的价值在于提供可信的开销证据，假 PASS 比没有测试更危险，因为它给虚假信心。

- **触发条件**：
  (1) TCG 模式下 ON/OFF 运行间噪声振幅 > 工具实际开销（已实测发生）；
  (2) 任何单次运行 ON 恰好优于 OFF 的随机情形；
  (3) v6.5.0 接入 CI 后，共享 runner 负载波动使 ON/OFF 非同期噪声增大时。

- **后果**：
  对一次 ON 反超 OFF 38% 的噪声运行报 "ALL PASSED"。更危险的复合场景：真实回归使 ON 跌 3%（本应 < 5% 阈值 PASS），但因 OFF 基线被噪声拉低，`drop_pct` 变成负数被判 PASS，回归被噪声掩盖。一旦接入 CI，这种假 PASS 会让回归 silently 通过。

- **修法**：
  verdict 增加异向（ON 优于 OFF）检测，引入三态判定。吞吐/PPS 类：

  ```bash
  if awk "BEGIN {exit !(${drop_pct} < 0)}"; then
      # ON 优于 OFF = 噪声主导，数据无效
      echo "  ${YELLOW}INVALID${NC} $metric: ON>OFF by $(-${drop_pct})% (noise-dominated)"
      verdict_all_pass=false   # 或引入 verdict_inconclusive 第三态
  elif awk "BEGIN {exit !(${drop_pct} > ${threshold})}"; then
      echo "  ${RED}FAIL${NC} $metric: drop ${drop_pct}% > ${threshold}% threshold"
      verdict_all_pass=false
  else
      echo "  ${GREEN}PASS${NC} $metric: drop ${drop_pct}% <= ${threshold}% threshold"
  fi
  ```

  latency/cpu 类（delta = (on-off)/off，正向=ON 更差=预期方向）：当 `delta < 0`（ON 延迟/CPU 反而更低）同样判 INVALID。

- **为什么这么修**：
  性能对比是三值问题（达标/超标/无效），不是二值。把"无效"当"达标"是逻辑漏洞。对照内核 `tools/testing/selftests/` 框架：selftest 对异常/不可信结果返回 SKIP 而非 PASS，正是为不混淆"没测出来"与"通过了"。本工具 perf 测试应同等要求 —— 尤其 v6.5.0 计划接入 CI，自动判定必须能识别无效数据，否则 CI 绿灯毫无意义。

  引入 `INVALID` 第三态（而非直接 FAIL）的理由：噪声主导不是工具的错，FAIL 会误报回归；INVALID 准确表达"本次测量不可信，需重跑"，避免误判方向。

## 综合意见

verdict 逻辑的本意是"自动判定性能是否达标"，但当前实现对噪声毫无防御，在最容易出噪声的 TCG 环境下恰好会给出最乐观的假 PASS。这是 perf-test.sh 接入 CI 前必须修复的阻断项（问题 9.4.1）。

修复优先级：**高**。建议与问题 9.4.2（补齐 latency/cpu verdict）、9.4.3（端到端重跑）一并处理 —— 三者都涉及 verdict 逻辑，一次修改 + 一次重跑即可闭环。

## 附加建议

- verdict 总结论也应区分三态：`ALL PASSED` / `SOME FAILED` / `INCONCLUSIVE (noise-dominated)`，避免对无效运行报 PASSED。
- 可考虑增加 `--strict` 模式：INVALID 也视作失败（适合 CI 严格回归）；默认模式 INVALID 仅告警（适合本地探索）。
- 长期：多轮运行取中位数已能压制部分噪声，但单轮 ON>OFF 的异常仍需 INVALID 兜底 —— 中位数无法消除系统性噪声偏置。

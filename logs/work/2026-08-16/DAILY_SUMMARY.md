# 每日汇总 - 2026-08-16

## 任务清单

| 任务 | 状态 | 产出 |
|------|------|------|
| TASK-01 perf 指标失真修复 + p99 调查结案 | 完成 | 4 commits + ftrace 验证 + 本报告 |

## 当日要点

1. **三处指标失真修复**（延迟预热 / idle 公式与 pp 判定 / 摘要表回填）全部 CI 验证通过
2. **SYN 重传伪影**：从 sysctl 调优 → strace 定位 busybox nc backlog=1 → 数据层剔除（>100ms + retrans 计数），4 轮 CI 验证
3. **p99 噪声结案**：3 空提交轮稳定性验证（方差与差异同量级）+ ftrace function_graph 独立测量（hook 开销 7-14 μs/connect = 0.4-0.8%，与 p50 +1.0% 吻合，p99 差异大 2-3 个数量级）→ QEMU 调度噪声，非回归
4. **环境坑归档**：本地内核 KASLR 死循环、用户终端 QEMU 三坑、initramfs shebang——已同步 project_memory.md

## 明日候选

- actions v4→v5 升级（规划版本 v6.6.0，Node 20 弃用警告）

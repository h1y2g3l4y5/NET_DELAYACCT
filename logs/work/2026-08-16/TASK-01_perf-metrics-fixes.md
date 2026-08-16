# TASK-01: perf 测试指标失真修复 + p99 噪声调查结案

- **日期**: 2026-08-16
- **范围**: perf-test.sh, ci/qemu/run-perf-tests.sh
- **Commits**: b299ec3, b95993f, 9ea9fc2, 81be5f0（+ 3 个空提交 CI 验证轮 1621d1e/1f5519a/a3065bf）

## 背景与问题

用户反馈 perf 对比表三处指标失真：
1. K0 `tcp_latency_p999/max` = 1,019,610 μs（≈1s 离群点）
2. `idle_cpu_pct` 显示 +500%（1%→6% 相对百分比无意义）
3. 摘要表 Thresh/Verdict 列恒为 `-`/`info`

## 变更内容

### Commit b299ec3 — 三处指标失真修复
- **延迟预热**：perf_3 采样前 3 个预热连接（丢弃），消除冷启动 ~1s 离群
- **idle 公式**：guest 端 `100 - idle占比`（实为忙占比）改为真 idle 占比；host 端 delta 改百分点差（`+N.Npp`），verdict 改 `|Δpp| <= 2`
- **摘要表回填**：`SUM_*` 数组暂存 + verdict 段填 `THRESHOLDS/VERDICTS`，md/csv 摘要不再恒 `-`

### Commit b95993f — 控制台表格回填 + SYN 溢出调优
- 控制台对比表打印挪到 verdict 段之后（此前硬编码 `-`/`info`，与 md/csv 不一致）
- guest 内 `tcp_syncookies=1` + `somaxconn=1024`（半连接队列溢出丢 SYN → RTO 1s 重传）

### Commit 9ea9fc2 — 诊断增强（sysctl 读回 + top3）
- `sysctl_check` 输出验证 /proc/sys 可写性
- 每轮输出 top3 最大样本，观测剔除后长尾形态

### Commit 81be5f0 — SYN 重传伪影剔除
- 调优后仍见 1s 离群 → strace 实锤 busybox nc `listen(3, 1)` backlog=1，syncookies/somaxconn 无法干预
- 采样时 `>100ms` 判为重传伪影剔除，输出 `retrans_run` 计数

## 验证

1. **CI 验证轮**（14:34）：三处修复全部生效，p999 回毫秒级，retrans 计数透明
2. **p99 稳定性**（3 个空提交轮）：4 轮 K0→K2 p99 = +144% / -25%(INVALID) / +21% / +44%，K0 自身轮间波动 2.1x，方差与差异同量级 → 无法定论
3. **ftrace function_graph 独立交叉验证**（本地 QEMU）：`net_delayacct_tx_start/end` 单次 p50 = 0.44/1.39 μs，每 connect ~9 次 hook 共 ~7 μs（上界 13.8 μs）= p50 基线的 0.4-0.8%
   - 与 CI p50 +1.0% PASS 完美吻合
   - p99 差异（600-7600 μs）比 hook 开销大 2-3 个数量级 → **判定为 QEMU 调度噪声，非 delayacct 回归，结案**

## 踩坑记录

1. **本地内核树 KASLR 死循环**：8/3 旧 .config 增量构建的内核卡在 `Physical KASLR using RDRAND RDTSC`（CI fresh clone 构建无此问题）→ `nokaslr` 绕过。教训：本地复现 CI 内核须删 .config 重做 defconfig+fragment
2. **用户终端 QEMU 三坑**：`-nographic` stdio 多路复用、`-device e1000`、`smm=off` 在交互终端环境均导致 QEMU 进程级卡死（0 串口输出）；CI runner systemd 服务环境正常。解法：`-display none -serial file:`
3. **initramfs shebang**：guest init 用 `#!/bin/bash` 但 bash 装在 /usr/local/bin → 内核 `Failed to execute /init (error -2)` fallback busybox init 卡死。解法：建 /bin/bash 符号链接（或用 #!/bin/sh）
4. **伪影剔除优先于 sysctl 调优的判断过程**：先上 syncookies/somaxconn（未生效），再 strace 找到 busybox nc listen backlog=1 根因 → 最终用数据层剔除。教训：先确认工具实现（strace）再调系统参数

## 遗留

- p99 维持趋势信号（strict=warn 告警不阻塞），不调阈值、不优化内核（ftrace 已证伪回归）

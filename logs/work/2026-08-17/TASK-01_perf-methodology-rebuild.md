# TASK-01: 性能测试方案重建（iperf3 速率驱动 → 固定工作量微基准）

- **日期**: 2026-08-17
- **范围**: ci/qemu/bench-net.c（新增）, ci/qemu/run-perf-tests.sh, ci/qemu/guest-init-perf.sh, perf-test.sh, .github/workflows/ci.yml
- **Commit**: f2585d0

## 背景与决策

用户否决旧方案数据（"符合物理规律吗"）：多轮修复后 tcp_throughput K0→K3 仍 +11%、p99 ±30-90% 乱跳、cpu/idle 方向不一。
ftrace 绝对测量（v6.5.2）已锚定 hook 真实开销 = 每包 4 次 × 0.44-1.39us ≈ 吞吐的 0.4-0.8%，
而共享 runner 噪声地板 5-50%（p99 达 90%）→ **信噪比倒挂，速率驱动模型在该环境下原理性不可用**。

决策（用户选定"微基准 + ftrace 对账"方向）：放弃 iperf3 全家指标（吞吐/PPS/延迟百分位/CPU），
改测固定工作量下每操作耗时，把 hook 信号放大到噪声之上。

## 新方案四支柱

1. **Perf-A bench-net**（新增 ci/qemu/bench-net.c，verdict 主判定）
   - UDP64 自发自收 + TCP 1KB write-read 两模式，固定循环次数 N
   - 绑 CPU0 + SCHED_FIFO（降级不报错），QEMU `-smp 1` 消除 vCPU 间迁移噪声
   - warmup 自动校准 N（每轮 ~1s，KVM/TCG 自适应，夹在 20k-500k）；首轮 N 经 out_n 复用到后续轮
   - 信号放大：64B 单循环 ~2-5us（KVM），4 次 hook × 50-150ns = 5-20% 占比
2. **Perf-B ftrace 对账**（仅 ON 内核，info）：function tracer 数 hooks/op，
   function_graph 叶子取单次 p50/p99；对账式 `Δns/op ≈ hooks/op × hook_ns_p50`
3. **Perf-C slab objsize**（确定性，保留）
4. **Perf-D dump 计时**（K3）：get_sockdelays × 50 次取均值（含 fork+exec，空表口径）
   - K3 语义变更：不再跑"后台查询干扰 iperf3"（-smp 1 下 SCHED_FIFO 会饿死查询进程，
     且干扰量 ∝ 环境争抢不可迁移）；导出开销由 Perf-D 直接量化

## 主要变更

- run-perf-tests.sh 重写（91%）：iperf3 全套移除，四支柱接入；ftrace 指标加 `_run1` 后缀（host 解析协议要求）
- perf-test.sh：QEMU `-smp 1` + `-display none -serial file:` + `-nic none` + `nokaslr`；
  判定改为 bench_udp64/bench_tcprw（阈值 25% 初始值）+ sock_objsize（192B）；噪声地板节改用 bench 指标；
  移除 `--test-duration/--warmup/--enable-cycles/--fixed-load-rates` 及全部旧指标死代码
  （`TEST_DURATION` 等未定义变量在 `set -u` 下会崩，属重建遗留 bug）
- ci.yml perf-test job：apt 去 iperf3/ncat 加 gcc（runner 上编译 bench-net）；
  timeout 60→30min、QEMU KVM 360→240s / TCG 900→360s（新矩阵 4 boot × 实际 ~60s KVM）

## 本地冒烟验证（沙箱 TCG，8/3 旧 bzImage，perf-test-20260817_110601.log）

- 全链路通：initramfs 打包 → K0/K2/K0B 3×QEMU（~40s/boot）→ 解析 → 报告/噪声地板
- **udp64 K0→K2 = +14.4%**（预测 5-20% 区间内，方案核心假设成立）
- tcprw +1.4%（1KB 路径更长，hook 占比被稀释，符合预期）
- ftrace 对账：hooks/op=4.20 × p50 4794ns（TCG 膨胀）≈ 20135 vs 实测 Δ9209 ns/op，同数量级
- 噪声地板：udp64 15.6% / tcprw 22.0%（TCG+沙箱最差环境，均 < 25%；KVM 下预期显著更低）

## 踩坑记录

1. **旧方案残留未定义变量**：perf-test.sh 重建后残留 `TEST_DURATION/ENABLE_CYCLES` 等引用，
   `set -u` 下必崩——方案重建必须同步清理所有消费端（ci.yml 参数、summary 生成、噪声地板指标列表）
2. **沙箱限制**：TRAE 沙箱禁写内核树（perf-test.sh 完整构建路径须用户终端跑）+ 拦 /dev/kvm
   → 冒烟验证用 `--skip-build` + 现有 bzImage，KVM 由 CI 覆盖
3. **`-serial file:` 后报错分流**：QEMU 进程错误走 stderr（qemu_err 文件），KVM 回退 grep
   必须同时查 err 与串口文件，否则回退逻辑失效

## 验证状态

- 本地冒烟：✅（上节）
- CI（run 31990418460，f2585d0）：
  - checkpatch / build-kernel (on/off) / build-tool / QEMU 功能测试：✅ 全绿
  - perf-test：03:21:31Z 被 runner 领取后 **runner 掉线**（run updated_at 冻结，job 回落 queued），
    等待 runner VM 恢复后自动重跑 → 结果待回填
- CI run #178（91a300a，runner 重启后自动补跑，15:34 成功）：
  - **udp64 K0→K2 = -4.9%、tcprw = -11.2% → 双 INVALID（负 delta）**
  - tcprw 两分布零重叠（K0 五轮 11607-12939 vs K2 五轮 9779-11733）
  - ftrace 对账符号矛盾：预测 +1500 ns/op vs 实测 -255/-1379 ns/op
  - 用户判定结果仍不对 → 根因分析见批次 2

## 批次 2：启动间漂移根因分析与修复（同日）

### 根因（run #178 数据实证）

- **K2 与 K3 是同一个 bzImage-on**（ci.yml 双 artifact，K3 仅多 bench 之后的 dump 步骤），
  guest 流程 bench 前完全一致，但中位数差 **+10.7%（tcprw）/+12.8%（udp64）**
  → 证明存在 ~10% 量级的"每次 QEMU 启动之间"漂移
- K0↔K0B（同 OFF 二进制）却只有 0.8-1.1% → **单对采样测不准地板，1% 纯属运气**
- 噪声来源：QEMU vCPU 线程在宿主（VM）上**无绑核**，每次启动被调度器随机放置
  （不同 VM CPU/物理核/SMT/turbo 状态）；-smp 1 只固定 guest 内 vCPU 数，
  不约束 QEMU 线程的宿主放置
- 结论：信号（hook ~5-10%）< 启动间噪声（~13%）→ 负 delta INVALID 是必然
- 排除项：ftrace/dump 均在 bench 之后执行（run-perf-tests.sh 主流程顺序），无污染

### 修复（3 层防线）

1. **宿主侧绑核**：QEMU 启动包 `taskset -c N`（KVM/TCG 两处）；N = online∩allowed
   交集降序逐个 taskset 试探（本 VM allowed=0-127 但 online 仅 0-3，直接取最大号会
   EINVAL → 必须试探）；避开 CPU0（IRQ 聚集）；不可绑降级告警
2. **交错重复启动**：K0→K2→K0R→K2R→K3→K0B 六次启动；K0/K2 各 2 次，时漂等权；
   K0R/K2R 结果并入 K0/K2 中位数（单启动 5 轮 → 跨启动 10 轮）
3. **多对噪声地板 + verdict 接入**：floor = max(|K0-K0R|, |K2-K2R|, |K2R-K3|, |K0-K0B|)
   （全部同二进制对）；verdict 中 |Δ| < floor → INVALID（差异不可分辨于启动漂移），
   不再只依赖负 delta 判 INVALID；ftrace 对账实测为负时显式提示漂移压过信号

### 变更文件

- perf-test.sh：run_perf_in_qemu 绑核 + PERF_PIN_CPU 自动选择；main 交错启动序列；
  compare_and_report 解析合并 K0R/K2R、_file_med/_pair_floor 辅助、FLOOR 多对估计、
  verdict 地板判定、ftrace 负值提示、噪声地板节重写、md 判定说明同步
- .github/workflows/ci.yml：perf-test timeout 30→40min（6×TCG 360s 上限）；
  诊断表 mode 循环 + artifact 加 K0R/K2R/K0B
- 单元冒烟：伪造 PERF 日志验证 _file_med/_pair_floor/多对 max/合并中位数 ✅；
  绑核选择逻辑在沙箱环境选中 CPU3 ✅（allowed 0-127 ∩ online 0-3）

### 踩坑记录（批次 2）

1. **/proc/self/status Cpus_allowed_list 不可信**：本 VM 报 0-127 但 online 仅 0-3，
   绑 127 直接 EINVAL —— 绑核目标必须 online∩allowed 且实测试探
2. **单对同二进制对比不是噪声地板**：K0↔K0B=1% vs K2↔K3=13%（同轮次、同性质），
   地板估计必须多对取 max（保守上界）

## 批次 3：run #179 复盘 —— 冷启动瞬态 + 串口污染（同日）

### run #179（1a3c182）观测

- 绑核生效（6 次启动全部 pinned CPU3），但地板反而 13-25%：
  按启动顺序 tcprw 中位数 15769 → 15078 → 11654 → 11515 → 11073 → 11697
- **根因 1（冷启动瞬态）**：批次前 1-2 次启动偏慢 +30%（频率/缓存预热），
  污染 K0/K2 首样本与 K0-K0R/K0-K0B 地板对；稳定区（后 4 次启动）离散仅 ~3%
- **根因 2（串口污染）**：启动初期内核 console 日志与 PERF: 行交错拼接
  （`sock_objsize=2240[ 3.87] input: ImExPS/2 Generic Explorer Mouse`、
  `2368[ 4.02] sched: RT throttling activated`）→ sock_objsize K0="Generic"、K3="RT"
- **物理结论**：稳定区 |K0-K2| ≈ 1.2-1.6%，远小于 ftrace 预测 13%（4.2×360ns）
  → function_graph 的 360ns 含 tracer 自身开销，真实 hook 开销 ~1% 级。
  该环境下微基准的角色 = 回归护栏（floor 门控），绝对开销以 ftrace 上界口径汇报

### 修复

1. **WARM 预热启动**：正式序列前一次 1 轮的丢弃启动（OFF 内核，日志落盘不解析），
  吸收冷启动瞬态；run_perf_in_qemu 增加第 4 参 runs
2. **guest 顺序防御**：run-perf-tests.sh 主流程改为 bench→ftrace→slab→dump
  （slab 挪到 console 静默后，此前它排在启动后第一位，正处内核探测日志高峰）
3. **host 解析防御**：values 累积时非纯数值样本丢弃 + 计数告警；
  sock 提取改 `grep -oE '=[0-9]+'` 数值前缀
4. ci.yml：timeout 40→45min（7 次 QEMU）；诊断表/artifact 加 WARM

### 验证状态（批次 3）

- 语法/单元：bash -n + yaml ✅；数值过滤/顺序逻辑静态走查 ✅
- CI：待 push 后回填（预期：地板降至稳定区 ~3% 量级，verdict 可判或诚实 INVALID）

## 批次 4：矩阵简化 K0/K3-only + RT 节流根因修复（同日，用户决策）

### run #179 原始数据复盘（未推送前的进一步分析）

- **轮内离散 10-25%**（如 K0 udp64 五轮 5352~6670）——绑核 + FIFO 后单次启动
  内部仍然发散，说明噪声源在 runner VM 宿主层（外层 hypervisor 抢占），VM 内
  绑核约束不到物理 CPU
- **K0 日志实证 `sched: RT throttling activated`（[4.83s]）**：bench 的 SCHED_FIFO
  在 loopback 上不睡眠（send 路径 softirq 已将数据入队，recv 立即返回），
  950ms/s 配额耗尽后被强制停 50ms/s，每轮 ~1s 的测量被随机截入 5% 停顿
  → 轮内 10-25% 离散中存在自伤成分（可消除），宿主抢占成分（不可消除）
- 稳定区 ON vs OFF 符号仍矛盾（tcprw -3.3% / udp64 +6.2%）→ n=2 无统计意义

### 用户决策与依据

用户拍板"只要 K0 和 K3"。依据：K2 与 K3 本就是同一个 bzImage-on，guest 侧
顺序 bench→ftrace→slab→dump（dump 在 bench 之后），K3 的 bench 阶段与 K2
逐字节一致 → K2 是纯冗余启动，砍掉省 1 次 QEMU（7→6），主判定 K0→K3
（最坏情形口径：插桩 + dump 都在的 ON 内核）。

### 修复（随批次 3 一并推送）

1. **矩阵简化**：WARM→K0→K3→K0R→K3R→K0B；K2/K2R 移除，--with-k3 参数移除
  （K3 必跑，get_sockdelays 缺失时 dump 自动 SKIP）；噪声地板对改
  K0-K0R / K3-K3R / K0-K0B；摘要表/CSV 从 13 列（K0/K2/K3 三列+三 delta）
  收敛为 9 列（K0/K3+K0→K3）
2. **RT 节流禁用**：guest cmdline 追加 `sysctl.kernel.sched_rt_runtime_us=-1`
  （内核 6.6 支持 sysctl.* cmdline 参数；单用途测量 guest，卡死由 QEMU
  timeout 兜底）——消除 bench FIFO 每秒 50ms 的强制停顿
3. ci.yml：去 --with-k3；诊断表/artifact 改 WARM/K0/K3/K0R/K3R/K0B；
  timeout 45→40min（6 次 QEMU）
4. run-perf-tests.sh：QUERY_MODE 默认 K3（K2 语义随矩阵移除），注释同步

### 验证状态（批次 4）

- 语法：bash -n ✅
- CI：待 push 后回填（预期：轮内离散显著收窄、地板回落、K0→K3 符号恢复正向
  或诚实 INVALID）

## 遗留

- 阈值校准：积累 5+ 轮 CI 噪声地板数据后收紧 25% 初始阈值
- KVM 下 ftrace 单次 hook 耗时应回到 0.4-1.4us 量级（对账式更准），CI 首轮确认
- v6.6.0：actions v4→v5 升级等顺延项不变

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

### 批次 4 追加：codeload 429 三连杀与 action 缓存预填（同日晚）

- **#180（ece6171）/ #181（d56e60c 重触发）perf job 均在 job 初始化阶段死**：
  从 codeload 下载 `actions/download-artifact@v4`（SHA d3f86a1）3 次重试全 429，
  连 checkout 都没执行；run 级 conclusion=success 是 continue-on-error 假象，
  必须 jobs API 逐 job 核对
- **第一次预填失败根因**：TRAE 沙箱禁写 `/home/lai/actions-runner/_work/_actions/`
  （mkdir Permission denied → 沙箱拦截），指令静默未落地；且缓存目录名必须用
  **ci.yml 里的 ref 字符串原样**（`v4`，不是 SHA）——runner 按路径存在性跳过下载
- **正确预填法**（用户终端执行）：`git clone --branch v4 git@github.com:actions/download-artifact.git`
  → cp -a 到 `_work/_actions/actions/<name>/v4`，删 .git（runner 走 tarball 口径，
  不需要 git 元数据）；action 从 dist/index.js 运行，无需 node_modules
- 重触发：8824b35（run #182），验证预填缓存能否让 perf job 真正跑起来

### run #182 结果（20260818_011516 报告，首次全链路成功）

- **预填缓存生效**：perf job 4m07s 真实执行（此前 429 死于初始化 1m46s），全 6 boot 落地
- **bench_udp64 K0→K3 = +16.3% PASS**：K0 中位 4438.7 → K3 5161.05 ns/op；
  K0 样本域 4074-4913 vs K3 4745-5247 接近不重叠；落在方案预测 5-20% 区间，
  方向为正（加开销变慢）——**新方案首个物理自洽结果**
- **ftrace 对账**：4.20 hooks/op × 383ns(p50) ≈ 1609ns vs 实测 Δ722ns，
  同数量级（2.2x，ftrace 自身开销抬高 p50 属已知效应）
- **RT 节流修复确认**：6 个 boot log 均无 "RT throttling"
- bench_tcprw -0.3% INVALID：1KB 路径信号被稀释到地板以下，诚实判 INVALID（符合设计）
- 噪声地板：udp64 13.9%（K0-K0R，首次 OFF boot 仍偏快 8-10%）、tcprw 7.7%；
  信号 16.3% > 地板 13.9% → udp64 判定可用（Usable=YES）
- 遗留小项：dump_per_call_us=0.0（疑似测量口径问题，info 级不阻断）；
  K0 首 boot 偏快现象 → 阈值校准阶段评估是否丢弃各二进制首 boot

## 遗留

- 阈值校准：积累 5+ 轮 CI 噪声地板数据后收紧 25% 初始阈值
- KVM 下 ftrace 单次 hook 耗时应回到 0.4-1.4us 量级（对账式更准），CI 首轮确认
- v6.6.0：actions v4→v5 升级等顺延项不变

## 批次 5：指标体系收敛 + 24 格矩阵化（2026-08-19，用户决策）

### 用户决策链

1. 用户质疑"现有性能测试存在很大问题需重新设计"，先厘清测什么：
   CPU 占用率（导出量，不测）/ socket 内存（确定性单点）/ hook 单次+单包延迟
   （本征量）/ 吞吐影响（导出量，不测——包大摊薄包大放大，运维可自算）
2. 拍板：**只展示每包 CPU 成本（Δns/op）作为主指标**，吞吐百分比弃测；
   tcprw 单点砍掉；内存单点不进矩阵
3. 矩阵范围（AskUserQuestion 确认）：核心 4 路径（udp4/tcp4/udp6/tcp6）×
   3 尺寸（64/1400/65000B）× 2 压力（1/16 流交错）= **24 格**；
   冷门路径（splice/zerocopy/corked）不进矩阵（hook 同批函数，功能测试已覆盖）

### 设计要点

- **本征量 vs 导出量**：每包 CPU 成本（~700ns/包）是工具固有属性，一次测准
  处处可用；吞吐 % = 固有成本 ÷ 包大小，是负载函数非工具属性——上游 cover
  letter 惯例也是报绝对开销
- **物理预期写进判定语义**：税按 skb 收不按字节收 → 各尺寸格 Δns 绝对值
  应近似平稳（~500-800ns），Δ% 随 1/尺寸 摊薄（64B ~16% → 65000B <1%
  落入噪声地板下判 INVALID 是预期形态，不是失败）——24 格矩阵就是
  "包大影响小"论断的实证曲线
- 压力维度 = 同核 16 socket 轮转（测统计结构 cache 局部性）；跨核锁争用
  需 -smp>1 会重新引入调度噪声，明确不测（写进 bench-net.c 头注释）

### 实现（commit b2e7312）

- **bench-net.c v2**（61% 重写）：通用引擎 `-m=<path> -s=<size> -f=<flows>`；
  UDP/TCP 均支持 v4/v6 + 16 流交错；TCP 65000B 单 write 走 1 个 GSO 大 skb
  （验证"税按 skb 收"的关键格）；tcprw 模式删除。本机全路径验证：
  udp4_64f1/tcp4_65000f2/udp6_1400f16/tcp6_1400f1 全通
- **run-perf-tests.sh**：24 格独立调用编排；ftrace B1 升级为 path×size
  12 格 hooks/op 计数（f1 口径，hooks/op 与流数无关）；B2 单次耗时按 4 路径
  各测一轮；PERF_RUNS 5→3（24 格×3 轮 ≈ 旧 2 指标×5 轮同时长）
- **perf-test.sh**：host 侧改为**动态发现矩阵格**（从 K0 log 键扫描
  bench_*_ns_per_op，不再硬编码指标名）；逐格三态判定 + 逐格噪声地板；
  对比表新增 **Δns/op 列**（主指标）+ Δ% 列；ftrace 对账逐格化；表名改为
  "Per-Packet CPU Cost Matrix"
- **验证方式**：TRAE 沙箱禁 QEMU/禁写内核树 → 端到端假数据 harness
  （/tmp/t_report.sh：生成 5 份假 K0/K0R/K0B/K3/K3R log 驱动
  compare_and_report 全链路）——24 格全发现、64B/1400B PASS、
  65000B below-floor INVALID、地板表 24 行、PERF_EXIT=0 全部符合预期；
  source <(...) 被沙箱拦（/dev/fd）→ 先落地 /tmp/perf-lib.sh 再 source

### 踩坑

- Edit 工具 old_string 必须与文件逐字节一致（注释里 K0/K2 vs K0/K3 一字之差
  连续失败两次）——先 Read 再改，别凭记忆
- 沙箱内 `source <(sed ...)` 会因 /dev/fd 受限报 "cannot create directory
  /dev/fd/tests"——先写实体文件再 source

### 状态

- 本地：bash -n / gcc -fsyntax-only / 假数据端到端 全过
- CI run 32165279912（b2e7312）验证中，预期形态：64B/1400B 格 PASS、
  65000B 格 INVALID（below-floor）、每 boot ~110s（bench 24×3 ≈ 75s）

## 批次 6：CI 首轮矩阵结果验证（2026-08-19）

### Run 32165279912 结果（report perf-test-20260819_013741）

- perf job **success**（--strict=warn 下 22 INVALID 不阻塞），6 boot 全部完成
  （WARM→K0→K3→K0R→K3R→K0B，每 boot ~110s 符合预算）
- 24 格全发现，判定形态：**2 PASS / 22 INVALID** + sock_objsize PASS
  - PASS：udp4_64f1 +665ns (+15.9%)、udp6_64f1 +784ns (+17.9%)
  - 其余 22 格 |Δ| 均低于各自噪声地板（6-25%）→ INVALID（"测不出"，预期形态）
- **核心信号两轮独立复现**：run #182 单点 udp64 = +16.3%，本轮 udp4_64f1 = +15.9%
  —— 跨 CI run 一致，信号真实

### 与批次 5 预期的偏差

- 预期"64B/1400B PASS"过于乐观：本轮启动间噪声地板 6-25%（udp4_65000f16
  K0-K0B 达 100%），1400B 格预期信号 ~+5-8%（税额 500-800ns 摊到 ~5μs 基线）
  低于地板 → INVALID 是物理必然。run #182 时地板 ~3% 是宿主状态好的特例，
  共享宿主地板在 3-25% 间波动——**只有 64B 格具备常判能力**，矩阵其余格
  是"预期形态记录"而非判定格
- ftrace 对账系统性高估：B2 hook_ns_p50 = 289-318ns 含 function tracer 自身
  开销（每 hook 点插桩 ~150ns），udp4 预测 4.2×298 ≈ 1254ns vs 实测 +665ns
  （52%）；反推真实裸 hook ≈ 665/4.2 ≈ 158ns/次。对账应视为**上界估计**，
  文档需注明口径

### 数据可信度交叉检查（原始 per-boot 中位数）

- K0 合并 4163/4530/4577，K3 合并 4898/4258 —— K3R(4258) < K0R(4530)
  出现"ON 比 OFF 快"，即启动间漂移（14%）可淹没 K0→K3 差值的铁证；
  K3 主值 4898 与 K0 4163 差 +17.6% 仍显著 → 中位数口径下信号占优
- hooks/op 两次 ON boot 完全一致（udp 4.20 / tcp 5.60）——确定性计数，稳定

### 遗留问题（下批次）

1. **QEMU runtime test job 被取消**：runs-on ubuntu-22.04（GitHub-hosted），
   Install dependencies 步骤 cancelled（17:32-17:47），run 整体 cancelled；
   矩阵化未动功能测试代码，需 re-run 确认无回归
2. perf job display name 仍为 "K0 vs K2 vs K3"（K2 已删）→ 改 "K0 vs K3"
3. 文档补充 ftrace hook_ns 口径说明（含 tracer 开销，真实值减半）
4. INVALID>50% 阻塞规则与矩阵口径的适配待评估（当前 warn 模式未阻塞，
   但 22/24 INVALID 若换 strict 模式会 exit 2）

## 批次 7：v3 同 boot A/B —— static key 运行时开关（2026-08-19，用户决策）

### 根因：v2 跨 boot 对比的"ON 比 OFF 快"物理矛盾

批次 6 数据交叉检查发现 K3R(4258) < K0R(4530)：ON 内核比 OFF 内核快
在物理上不可能（多干活不会更快），矛盾指向两重不可归因噪声：

1. **二进制布局差异**：ON 内核 struct sock +128B → 全内核对象布局/
   cache 局部性变化，性能影响可正可负，与 hook 开销（~158ns/次）混叠
2. **启动间漂移**：QEMU vCPU 线程宿主放置随机（实测 10-14%），高于
   多数格信号（1400B/65000B 格 <3%）

对策（用户拍板）：内核补丁加**运行时开关**，同一 ON 内核 boot 内交错
翻转 OFF/ON 测 24 格——二进制逐字节相同 → 布局差异归零；同 boot 差分
→ 启动间漂移被抵消，残余噪声仅轮间抖动 ~1-3%。信噪比恢复后 24 格
全部具备判定能力（v2 只有 64B 格可判的限制解除）。

### 改动清单

**内核补丁（kernel-patches/）**：
- `include-net-net-delayacct.h`：`DEFINE_STATIC_KEY_FALSE(net_delayacct_key)`
  声明 + `net_delayacct_enabled()` 内联判断（static_branch_unlikely）；
  `net_delayacct_rx_start` 加开关检查
- `net-core-net-delayacct.c`：static key 定义 + `enabled` 模块参数
  （module_param_cb 自定义 setter，翻转 static_branch_enable/disable，
  0644 权限）；rx_end/tx_start/tx_end 入口加开关检查；mod_init 按
  cmdline 参数启用；0006/0007 补丁已重新生成
- 开关接口：`/sys/module/net_delayacct/parameters/enabled`（Y/N）

**guest 侧（ci/qemu/）**：
- `run-perf-tests.sh`：boot 模式自检（switch 存在→AB；ON 内核无开关→
  ON_NOSWITCH 防呆；OFF 内核→仅 slab）；开关往返自检（0→1→0→1 翻转
  失败→switch_check=fail + 全 SKIP）；`perf_a_bench_ab` 交错翻转 OFF/ON
  各跑 24 格（起始状态逐对交替），输出 `bench_<cell>_ns_per_op_{off,on}_run<k>`
- `guest-init-perf.sh`：watchdog 660s（AB boot 更长）；cmdline 解析
  perf_runs；移除 QUERY_MODE

**host 侧（perf-test.sh）**：
- boot 编排 6→2 次：K0（OFF 内核仅 slab，兼预热）+ AB（ON 内核全套）
- `parse_ab_results`（off/on 双前缀样本分离）+ `parse_k0_results`
- 逐格三态判定 `_verdict_ab`：Δ%>25 FAIL / [-5,25] PASS / <-5 INVALID
  （同 boot 下 on 显著快于 off = 开关失效/异常，非噪声）
- ftrace 对账用 AB boot 数据；sock_objsize 用 K0 vs AB（编译期确定值）
- 移除噪声地板节（K0R/K3R/K0B 启动对不存在了，残余噪声由 off spread
  随行输出）

**ci.yml**：job 名 → "Performance test (KVM, same-boot A/B)"；
timeout 40→30min；QEMU timeout KVM 240→280 / TCG 360→620（AB boot
~220s KVM / ~500s TCG）；artifact 路径 K0/AB；诊断段 mode 自检
（mode≠AB / switch_check=fail 提示）

**文档**：testing-overview.md §4.4 重写（2 次 boot + 运行时开关原理）、
§4.7 判定规则（INVALID 新语义 + 防呆链路）、§5 历史口径注记、§6.4 环境

### 假数据 harness 验证（/tmp/gen_harness.sh）

物理模型：Δns 恒定 158（税按 skb 收），off 基线按 path/size/flows 缩放，
run 间 ±1% 抖动；ftrace hooks=3.5 × 45ns = 157.5 预测值。结果：

- 24 格全发现；23 PASS + 1 INVALID（注入 udp6_65000f16 on=-12% 模拟
  开关失效格）→ 三态判定正确
- ftrace 对账逐格 matched（measured 158 ≈ predicted 158）
- sock_objsize K0 2240 vs AB 2368 → +128 PASS
- warn 模式 1/24 INVALID → exit 0；ALL-INVALID 变体（24/25）→ exit 2
- 表格对齐、md/csv 摘要生成正常

### 本批次发现并修复的 2 个既有 bug

1. `parse_ab_results` 双前缀：key 去 `_ns_per_op_off_run` 后缀后已含
   `bench_` 前缀，再拼 `bench_` → `bench_bench_*`，且 cell 名与
   `ftrace_hooks_per_op_<cell>` 错位导致对账失配（v2 引入，对账行一直
   没出现过就是这个原因）
2. INVALID>50% 阻断失效：`[ "$verdict_invalid" * 2 -gt "$evaluated" ]`
   非法算术（`*` 被 glob 展开，test 报错返回 2 → if 恒假）→ 该规则
   自 v2 引入以来从未生效；改 `$((verdict_invalid * 2))`

### 批次 6 遗留闭环

- 遗留 #2（job 名）：已改 "same-boot A/B" ✓
- 遗留 #3（ftrace 口径）：testing-overview.md §4.5 已有口径说明
  （预测值是上界，反推裸 hook ≈158ns）✓
- 遗留 #4（INVALID>50% 与矩阵口径适配）：v3 下 INVALID 语义收窄为
  "开关失效/测量异常"，>50% 阻断合理；算术 bug 已修 ✓
- 遗留 #1（功能测试 job 被取消 re-run）：待本次 push 的 CI 验证

### 遗留问题（下批次）

1. CI 首轮 v3 实测验证：观察 mode=AB 自检、开关翻转、24 格判定形态
   （预期全部可判而非 22 INVALID）、AB boot 时长是否在 280s 内
2. static key 开关对 checkpatch 的影响（0006/0007 已过本地检查，CI 复核）
3. 阈值校准：v3 下残余噪声 ~1-3%，25% 阈值和 -5% 容差可在积累 3-5 轮
   数据后收窄

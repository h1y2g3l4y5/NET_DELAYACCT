# 审查报告 - v6.5.0（KVM 数据补齐 + CI 接入规划）

- **规划日期**: 2026-08-06
- **状态**: [规划阶段] — Worker 已回应 8 条议题（6 接受 / 2 讨论），见 [DLG-20260806-014500](file:///home/lai/Code/NET_DELAYACCT/logs/dialogue/DLG-20260806-014500.md)；TASK-50/51 可立即启动（不依赖讨论项）
- **前置版本**: v6.4.0 已闭环（评分 8.5/10，commit c6e792f）
- **审查人**: Reviewer

---

## 一、版本目标

v6.4.0 完成了性能测试基础设施的本地落地（方案 C：本地脚本 + 报告文档，CI 暂不接入）。但留下一组关键缺口：**所有 perf 数据均来自 TCG 软件模拟，TCP 延迟/吞吐阈值在 TCG 噪声下无判定意义**（latency 必 FAIL，throughput 偶发 INVALID）。verdict 三态虽已落实，但阈值未经 KVM 多轮验证，贸然接入 CI 会因阈值不稳导致频繁误报。

**v6.5.0 目标**：
1. **KVM 环境补齐**：在 KVM 硬件加速下收集 perf 多轮数据，确定每个指标的稳定阈值
2. **CI 接入**：verdict 三态 + 稳定阈值落实后，将 perf-test 接入 CI（方案 C 的兑现）
3. **`--strict` 模式**：为 CI 严格回归场景提供 INVALID=FAIL 的判定模式
4. **`pahole` 验证**：确认 struct sock 64 vs 72 字节差异根因（当前为推测）

引用：
- [v6.4.0_FINAL_REPORT.md](file:///home/lai/Code/NET_DELAYACCT/logs/summary/v6.4.0_FINAL_REPORT.md) 八、下版本规划
- [v6.4.0 REVIEW_REPORT.md](file:///home/lai/Code/NET_DELAYACCT/logs/review/v6.4.0/REVIEW_REPORT.md) 9.7 下版本关注点

---

## 二、当前状态基线（v6.4.0 闭环后）

### 2.1 已具备的能力

| 能力 | 状态 | 来源 |
|------|------|------|
| perf-test.sh 双内核 ON/OFF 对比 | ✅ | TASK-43 |
| verdict 三态判定（PASS/FAIL/INVALID） | ✅ | TASK-47 |
| 5/5 指标全覆盖（throughput/pps/latency/cpu/sock） | ✅ | TASK-47 |
| KVM 优先 + TCG 自动回退 | ✅ | perf-test.sh L272-292 |
| TCP slab 内存测量（objsize） | ✅ | TASK-46 |
| docs/PERFORMANCE.md 数据来源脚注 | ✅ | TASK-47 |
| spin_lock_bh 4 处修复（KVM CI 验证） | ✅ | TASK-44, CI run #135 |

### 2.2 关键缺口

| 缺口 | 影响 | v6.5.0 处置 |
|------|------|-------------|
| **无 KVM perf 数据** | latency/throughput 阈值无判定意义，TCG 下 latency 必 FAIL | 议题1：本地 KVM 多轮收集 |
| **阈值未经多轮验证** | 贸然接入 CI 会频繁误报 | 议题1：基于 KVM 数据确定稳定阈值 |
| **CI 只构建 ON 内核** | perf-test 需双内核对比，CI 无法直接运行 | 议题2：build-kernel matrix 化 |
| **无 `--strict` 模式** | CI 中 INVALID 处理策略未定 | 议题3：新增 strict 模式 |
| **struct sock 64 vs 72 差异未验证** | 内存开销文档基于推测 | 议题4：pahole 验证 |

### 2.3 CI 现状（[ci.yml](file:///home/lai/Code/NET_DELAYACCT/.github/workflows/ci.yml)）

当前 4 个 job：

| Job | 作用 | 与 perf 接入的关系 |
|-----|------|---------------------|
| `checkpatch` | patch 格式校验 | 无关 |
| `build-kernel` | 构建 ON 内核（CONFIG_NET_DELAYACCT=y），产出 bzImage | **需扩展为双内核**（matrix: on/off） |
| `build-tool` | 构建 get_sockdelays | 无关 |
| `qemu-test` | KVM 运行 S1-S25 功能测试（`if: github.event_name == 'push'`） | perf-test 作为独立 job，不影响现有功能测试 |

**关键约束**：
- CI runner 为 `ubuntu-22.04` 共享 runner，KVM 可用但不稳定（run #135 成功，但共享 runner 负载波动）
- `qemu-test` timeout 15 分钟；perf-test 双内核 QEMU 约 3-5 分钟（KVM），可接受
- CI 的 QEMU 配置 `-smp 2`，perf-test.sh 当前 `-smp 1`（需统一或论证差异）

---

## 三、议题与规划项

### 议题1：KVM 环境数据补齐（高优先级）

**背景**：v6.4.0 所有 perf 数据来自 TCG，latency 噪声 ~hundreds μs（必超 10μs 阈值），throughput 波动大（Run A ON 反超 OFF 触发 INVALID）。KVM 硬件加速下噪声应显著降低，但无数据证实。

**目标**：在本地 KVM 环境跑 5-10 轮 perf-test.sh，收集每个指标的中位数与波动范围，确定稳定阈值。

**实施方案**：见 4.1。

**验收标准**：
- 至少 5 轮 KVM 数据（每轮含 3 次采样取中位数）
- 每个指标的变异系数（CV = σ/μ）< 15%（阈值稳定判定）
- latency 在 KVM 下应 < 100μs（远低于 TCG 的 hundreds μs），验证 10μs 阈值是否合理

### 议题2：CI 接入实施方案（高优先级）

**背景**：方案 C 承诺"阈值稳定后 v6.5.0 接入 CI"。verdict 三态已落实（TASK-47），接入条件基本成熟，但需解决双内核构建和 verdict CI 处理两个技术问题。

**目标**：新增 `perf-test` CI job，在 push 时运行 perf-test.sh，产出性能对比报告。

**实施方案**：见 4.2-4.4。

**验收标准**：
- CI 中 perf-test job 成功运行（KVM 模式）
- 双内核（ON/OFF）在 CI 中并行构建
- verdict 三态在 CI 中正确处理（见 4.4 策略）
- CI 运行时间增量 < 8 分钟（不影响现有 job）

### 议题3：`--strict` 模式设计（中优先级）

**背景**：CI 共享 runner 噪声大于本地专用机，INVALID（噪声主导）可能频繁触发。若 INVALID=FAIL，CI 会因噪声频繁失败；若 INVALID=PASS，又重蹈 v6.4.0 假达标覆辙。需要分级处理。

**目标**：为 perf-test.sh 新增 `--strict` 参数，控制 INVALID 的 CI 判定行为。

**实施方案**：见 4.5。

### 议题4：`pahole` 验证 struct sock 布局（低优先级）

**背景**：docs/PERFORMANCE.md 记录 sock objsize ON=2304 / OFF=2240，差异 64 字节。但 net_delayacct 在 struct sock 中新增字段的理论大小为 72 字节（含对齐），实测 64 字节的差异根因未验证（推测为对齐填充或字段大小估算错误）。

**目标**：用 `pahole -C sock vmlinux` 对比 ON/OFF 内核的 struct sock 布局，确认差异根因。

**实施方案**：见 4.6。

---

## 四、详细实施方案

### 4.1 KVM 数据收集流程

**前提**：本地环境需有 `/dev/kvm`（非沙箱，参考 project_memory 教训）。

**步骤**：

1. **确认 KVM 可用**：
   ```bash
   ls -la /dev/kvm && grep -Ec 'vmx|svm' /proc/cpuinfo
   ```
   perf-test.sh 已有 KVM 优先 + TCG 回退逻辑，无需改代码。

2. **多轮运行**（建议 10 轮，取中位数）：
   ```bash
   for i in $(seq 1 10); do
     ./perf-test.sh --skip-build 2>&1 | tee tests/reports/perf/kvm-run-${i}.log
   done
   ```
   每轮产出 ON/OFF 各 3 次采样，取中位数后共 10 个中位数数据点。

3. **数据分析**：对每个指标计算：
   - 中位数（P50）
   - P95 置信区间
   - 变异系数 CV = σ/μ
   - INVALID 触发率（KVM 下应 < 10%，TCG 下 ~40%）

4. **阈值确定**：
   - 吞吐/PPS：阈值 = KVM 中位 drop% × 2（安全余量 2x）
   - latency：若 KVM 中位 < 50μs，保持 10μs 阈值；若 > 50μs，放宽至中位 × 0.5
   - CPU/sock：保持现有阈值（这两项 TCG/KVM 差异小）

5. **产出**：更新 [docs/PERFORMANCE.md](file:///home/lai/Code/NET_DELAYACCT/docs/PERFORMANCE.md) 增加 KVM 数据章节，标注阈值确定依据。

**风险**：本地 KVM 若不可用（沙箱限制），需在非沙箱环境运行。project_memory 已记录此约束。

### 4.2 CI 双内核构建方案

**方案**：`build-kernel` job 改用 matrix strategy，并行构建 ON/OFF 内核。

```yaml
build-kernel:
  strategy:
    matrix:
      mode: [on, off]
  name: Build kernel (${{ matrix.mode }})
  steps:
    # ... 现有 checkout/install/cache 步骤不变 ...
    
    - name: Configure kernel
      run: |
        cd "$LINUX_SRC"
        make defconfig
        # ON 模式合并 NET_DELAYACCT fragment；OFF 模式不合并
        if [ "${{ matrix.mode }}" = "on" ]; then
          scripts/kconfig/merge_config.sh -m .config \
            "$GITHUB_WORKSPACE/ci/kernel.config.fragment" \
            "$GITHUB_WORKSPACE/ci/qemu/kernel-qemu.config"
        else
          # OFF 模式仍需 QEMU boot config，但不含 NET_DELAYACCT
          scripts/kconfig/merge_config.sh -m .config \
            "$GITHUB_WORKSPACE/ci/qemu/kernel-qemu.config"
          # 显式关闭 NET_DELAYACCT
          sed -i 's/CONFIG_NET_DELAYACCT=y/# CONFIG_NET_DELAYACCT is not set/' .config
        fi
        make olddefconfig
    
    - name: Build kernel
      run: |
        cd "$LINUX_SRC"
        make -j"$(nproc)" CC="ccache gcc" bzImage
    
    - name: Upload bzImage artifact
      uses: actions/upload-artifact@v4
      with:
        name: bzImage-${{ matrix.mode }}
        path: ${{ env.LINUX_SRC }}/arch/x86/boot/bzImage
        retention-days: 1
```

**关键点**：
- ON/OFF 并行构建（matrix），不增加串行时间
- OFF 内核仍需 `kernel-qemu.config`（QEMU 启动 + ftrace 配置），只是不含 NET_DELAYACCT
- artifact 命名区分 `bzImage-on` / `bzImage-off`
- 现有 `qemu-test` job 的 `needs: [build-kernel]` 需改为 `needs: [build-kernel]`（matrix 会被自动展开为所有子 job 的依赖）

### 4.3 CI perf-test job 设计

新增 `perf-test` job，与 `qemu-test` 并行（不阻塞功能测试）：

```yaml
perf-test:
  name: Performance test (KVM)
  runs-on: ubuntu-22.04
  needs: [build-kernel]  # 依赖 matrix 展开后的 on/off 两个 job
  if: github.event_name == 'push'
  timeout-minutes: 10
  steps:
    - name: Checkout project
      uses: actions/checkout@v4
    
    - name: Install dependencies
      run: |
        sudo apt-get update
        sudo apt-get install -y qemu-system-x86 iperf3 busybox-static ncat cpio iproute2
    
    - name: Download bzImage-on
      uses: actions/download-artifact@v4
      with:
        name: bzImage-on
        path: /tmp/artifacts
    
    - name: Download bzImage-off
      uses: actions/download-artifact@v4
      with:
        name: bzImage-off
        path: /tmp/artifacts
    
    - name: Run perf-test
      run: |
        cd "$GITHUB_WORKSPACE"
        # perf-test.sh 期望 bzImage 在 $LINUX_SRC/arch/x86/boot/bzImage-{on,off}
        # CI 中用环境变量重定向到 artifact 目录
        mkdir -p /tmp/linux-fake/arch/x86/boot
        cp /tmp/artifacts/bzImage /tmp/linux-fake/arch/x86/boot/bzImage-on 2>/dev/null || \
          cp /tmp/artifacts/bzImage-on /tmp/linux-fake/arch/x86/boot/bzImage-on
        # 注意：download-artifact 会把 artifact 内容平铺到 path，
        # 需确认下载后的文件名（bzImage vs bzImage-on）
        LINUX_SRC=/tmp/linux-fake ./perf-test.sh --skip-build --strict=warn
    
    - name: Upload perf report
      if: always()
      uses: actions/upload-artifact@v4
      with:
        name: perf-report
        path: tests/reports/perf/perf-test-*.log
        retention-days: 30
```

**需解决的问题**：
1. **artifact 文件名**：`upload-artifact` 的 `name: bzImage-on` + `path: bzImage`，下载后文件名是 `bzImage` 还是 `bzImage-on`？需实测确认（download-artifact 会保留上传时的目录结构）
2. **perf-test.sh 路径适配**：当前 perf-test.sh 硬编码 `BZIMAGE_ON="$LINUX_SRC/arch/x86/boot/bzImage-on"`。CI 中内核不在 LINUX_SRC 树里，需用环境变量或参数指定路径。建议新增 `--bzimage-on=<path>` `--bzimage-off=<path>` 参数
3. **QEMU 配置统一**：perf-test.sh 用 `-smp 1`，CI 功能测试用 `-smp 2`。perf 测试单 CPU 更稳定（减少调度噪声），建议 perf-test job 保持 `-smp 1`

### 4.4 verdict CI 处理策略

**核心矛盾**：CI 共享 runner 噪声 > 本地专用机，INVALID 可能频繁触发。

**分级策略**（`--strict` 参数）：

| 模式 | INVALID 处理 | FAIL 处理 | 适用场景 |
|------|--------------|-----------|----------|
| 默认（无 --strict） | 告警不阻断（exit 0） | 阻断（exit 1） | 本地开发 |
| `--strict=warn` | 告警不阻断（exit 0），但记录计数 | 阻断（exit 1） | CI 默认 |
| `--strict=fail` | 阻断（exit 1） | 阻断（exit 1） | CI 严格回归 |

**附加规则**：无论何种模式，当 INVALID 比例 > 50%（4/5 以上指标噪声主导）时，视为"数据不可信"，exit 2（区别于测试失败的 exit 1）。

**CI 推荐配置**：`--strict=warn`（默认）。理由：
- 共享 runner 噪声不可控，INVALID=FAIL 会导致 CI 频繁红
- INVALID 告警 + 计数记录，开发者可从 artifact 查看趋势
- 当 INVALID > 50% 时 exit 2，提示环境异常而非工具回归

### 4.5 `--strict` 模式实现

perf-test.sh 新增参数解析：

```bash
STRICT_MODE="warn"  # 默认 warn（CI 友好），本地无参数时也是 warn

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build) SKIP_BUILD=1 ;;
        --strict) STRICT_MODE="fail" ;;           # 无参数 = fail
        --strict=*) STRICT_MODE="${1#--strict=}" ;;  # warn/fail
        *) echo "Unknown option: $1"; exit 2 ;;
    esac
    shift
done
```

verdict 总结论逻辑调整：

```bash
# 总结论三态优先级: FAIL > INVALID(视strict) > PASS
if [ "$verdict_fail" -gt 0 ]; then
    echo "${RED}=== ${verdict_fail} TEST(S) FAILED ===${NC}"
    exit 1
elif [ "$verdict_invalid" -gt 0 ]; then
    case "$STRICT_MODE" in
        fail)
            echo "${RED}=== ${verdict_invalid} measurement(s) INVALID (strict mode) ===${NC}"
            exit 1
            ;;
        warn)
            echo "${YELLOW}=== INCONCLUSIVE: ${verdict_invalid} noise-dominated (rerun recommended) ===${NC}"
            # INVALID > 50% 视为数据不可信
            if [ "$verdict_invalid" -ge 3 ]; then
                echo "${RED}=== INVALID ratio > 50%, data unreliable (exit 2) ===${NC}"
                exit 2
            fi
            exit 0
            ;;
    esac
else
    echo "${GREEN}=== ALL PERFORMANCE TESTS PASSED ===${NC}"
    exit 0
fi
```

### 4.6 `pahole` 验证 struct sock 布局

**步骤**：

1. **在内核构建后运行 pahole**：
   ```bash
   # ON 内核
   pahole -C sock $LINUX_SRC/vmlinux > /tmp/sock-on.txt
   # OFF 内核
   pahole -C sock $LINUX_SRC/vmlinux > /tmp/sock-off.txt
   ```

2. **对比布局**：
   ```bash
   diff /tmp/sock-on.txt /tmp/sock-off.txt
   ```
   预期看到 net_delayacct 相关字段（如 `delayacct_start`, `rx_bytes`, `tx_bytes` 等）的差异。

3. **确认差异根因**：
   - 若新增字段总大小 = 64 字节：理论估算 72 字节有误（某字段小于预期）
   - 若新增字段总大小 = 72 字节但 objsize 差异 = 64：对齐填充吸收了 8 字节
   - 用 `pahole -C sock --sizes` 查看每个字段的偏移和大小

4. **更新文档**：将实测结果写入 [docs/PERFORMANCE.md](file:///home/lai/Code/NET_DELAYACCT/docs/PERFORMANCE.md)，替换当前的推测性描述。

**CI 集成（可选）**：在 build-kernel job 中加一步 `pahole -C sock vmlinux`，对比 ON/OFF 布局差异，作为 artifact 上传。低优先级，可手动验证。

---

## 五、风险与决策点

### 5.1 风险

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|----------|
| CI 共享 runner KVM 不可用 | 中 | perf-test job 回退 TCG，阈值无意义 | 回退 TCG 时跳过 perf-test（exit 0 + 告警），不阻断 CI |
| KVM 阈值仍不稳定 | 低 | CI 频繁 FAIL | 增加采样轮次（10→20），或放宽阈值安全余量 |
| 双内核构建增加 CI 时间 | 中 | 总 CI 时间增加 ~5 分钟 | matrix 并行构建，不增加串行时间 |
| artifact 文件名歧义 | 中 | perf-test job 无法找到 bzImage | 实测 download-artifact 行为，必要时调整上传路径 |
| struct sock 差异非 net_delayacct 导致 | 低 | 文档结论错误 | pahole 对比字段级布局，非仅看总大小 |

### 5.2 决策点（需 Worker 确认）

1. **CI 中 perf-test 失败是否阻断 CI？**
   - 建议：**不阻断**（perf-test job 失败时 `continue-on-error: true`），性能回归不阻塞功能合并
   - 理由：性能数据用于趋势监控，非功能正确性门禁

2. **`--strict=warn` 是否作为 CI 默认？**
   - 建议：**是**。共享 runner 噪声不可控，strict=fail 会导致频繁误报
   - 本地开发可用 `--strict=fail` 做严格回归

3. **KVM 数据收集轮次？**
   - 建议：**10 轮**。v6.3.0 教训"单次数据不可靠"，10 轮可计算 P95 置信区间

4. **`-smp 1` vs `-smp 2`？**
   - 建议：perf-test 保持 `-smp 1`（减少调度噪声），与功能测试 `-smp 2` 解耦

---

## 六、验收标准

### 6.1 KVM 数据补齐

- [ ] 至少 5 轮 KVM perf 数据（每轮 3 采样取中位数）
- [ ] 每个指标 CV < 15%（阈值稳定）
- [ ] latency KVM 中位 < 100μs（验证 10μs 阈值合理性）
- [ ] INVALID 触发率 < 10%（KVM 噪声应远小于 TCG）
- [ ] docs/PERFORMANCE.md 新增 KVM 数据章节

### 6.2 CI 接入

- [ ] build-kernel matrix 化（on/off 并行构建）
- [ ] perf-test CI job 成功运行（KVM 模式）
- [ ] verdict 三态在 CI 中正确处理（`--strict=warn`）
- [ ] CI 运行时间增量 < 8 分钟
- [ ] perf-report artifact 上传成功

### 6.3 `--strict` 模式

- [ ] perf-test.sh 支持 `--strict` / `--strict=warn` / `--strict=fail` 参数
- [ ] INVALID > 50% 时 exit 2（数据不可信）
- [ ] 本地验证三态 + 三种 strict 模式的组合

### 6.4 pahole 验证

- [ ] pahole 对比 ON/OFF struct sock 字段级布局
- [ ] 确认 64 vs 72 差异根因（字段大小 vs 对齐填充）
- [ ] docs/PERFORMANCE.md 更新实测结论

---

## 七、任务分解（预编号）

| 编号 | 任务 | 优先级 | 依赖 | 预估 |
|------|------|--------|------|------|
| TASK-48 | KVM 环境多轮 perf 数据收集（10 轮） | P0 | 本地 KVM 可用 | 2h |
| TASK-49 | 基于KVM 数据确定稳定阈值 + 更新 PERFORMANCE.md | P0 | TASK-48 | 1h |
| TASK-50 | perf-test.sh 新增 `--strict` 模式 + `--bzimage-on/off` 参数 | P1 | 无 | 1.5h |
| TASK-51 | ci.yml build-kernel matrix 化（on/off 并行） | P1 | 无 | 1h |
| TASK-52 | ci.yml 新增 perf-test job | P1 | TASK-50/51 | 2h |
| TASK-53 | pahole 验证 struct sock 布局 + 更新文档 | P2 | 内核构建 | 1h |
| TASK-54 | CI 验证 perf-test job（多次 push 观察稳定性） | P1 | TASK-52 | 2h |

**建议执行顺序**：
1. TASK-48 → TASK-49（KVM 数据 + 阈值，本地进行，不依赖 CI）
2. TASK-50（`--strict` 模式，纯本地开发）
3. TASK-51 → TASK-52（CI 接入，需 push 验证）
4. TASK-53（pahole，可与 1-3 并行）
5. TASK-54（CI 多轮验证，最后进行）

---

## 八、下版本（v6.6.0）关注点

- CI perf 数据趋势监控（基于多次 CI 运行的阈值漂移检测）
- `--strict=fail` 模式在 CI 中的启用条件（当 KVM 稳定性证实后）
- 物理硬件 perf 数据（QEMU 数据仅供参考，生产准入需物理机数据）
- perf-test 覆盖更多场景（双向流量、多 CPU pin、高 PPS 小包）

---

## 九、Review 议题追踪表

| # | 议题 | 严重度 | Worker反馈 |
|---|------|--------|-------------|
| 1 | KVM 环境数据补齐方案（4.1） | 高 | 共识-调整顺序（本地无KVM改CI收集，待Reviewer确认） |
| 2 | CI 接入实施方案（4.2-4.4） | 高 | 接受（补充：qemu-test artifact 下载需同步改 bzImage-on） |
| 3 | `--strict` 模式设计（4.5） | 中 | 接受 |
| 4 | pahole 验证计划（4.6） | 低 | 接受 |
| 5 | 决策点：perf-test CI 失败是否阻断（5.2-1） | 中 | 接受 |
| 6 | 决策点：`--strict=warn` 作为 CI 默认（5.2-2） | 中 | 接受 |
| 7 | 决策点：KVM 数据收集轮次 10 轮（5.2-3） | 低 | 共识-5轮起步CV不达标再追加（待Reviewer确认） |
| 8 | 决策点：`-smp 1` vs `-smp 2`（5.2-4） | 低 | 接受 |

**轮次状态**：6/8 已解决（接受），2 条讨论中（议题1 执行顺序 + 议题7 轮次，待 Reviewer 确认）。TASK-50/51 不依赖讨论项，Worker 已启动开发。

# 审查报告 - v6.5.0（KVM 数据补齐 + CI 接入规划）

- **规划日期**: 2026-08-06
- **状态**: [实现复审中] — 规划阶段 8 条议题全部解决（6 接受 / 2 共识，见下文议题追踪表）；Worker 已实现 TASK-50/51/52（commit 605a047），本文档第十节为实现复审
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

| # | 议题 | 严重度 | Worker反馈 | Reviewer 决议 |
|---|------|--------|-------------|---------------|
| 1 | KVM 环境数据补齐方案（4.1） | 高 | 共识-调整顺序（本地无KVM改CI收集） | **共识-接受调整**。Worker 已实测确认本地无 /dev/kvm + CPU 无 vmx/svm，改 CI 收集是唯一可行路径。执行顺序 50→51→52→48(CI)→49 正确，解决"鸡生蛋"问题。初始用 TCG 阈值，CI 中逐步校准。 |
| 2 | CI 接入实施方案（4.2-4.4） | 高 | 接受（补充：qemu-test artifact 下载需同步改 bzImage-on） | **接受**。Worker 补充的 qemu-test artifact 同步是关键点，已在 TASK-51 中实现。 |
| 3 | `--strict` 模式设计（4.5） | 中 | 接受 | **接受**。 |
| 4 | pahole 验证计划（4.6） | 低 | 接受 | **接受**。低优先级，TASK-53 待执行。 |
| 5 | 决策点：perf-test CI 失败是否阻断（5.2-1） | 中 | 接受 | **接受**。 |
| 6 | 决策点：`--strict=warn` 作为 CI 默认（5.2-2） | 中 | 接受 | **接受**。 |
| 7 | 决策点：KVM 数据收集轮次 10 轮（5.2-3） | 低 | 共识-5轮起步CV不达标再追加 | **共识-接受 5 轮起步**。5 轮可计算中位数 + P90，足够判断阈值方向。补充：若 CV 处于 10-15% 边界，建议直接追加至 10 轮，避免阈值稳定性存疑。 |
| 8 | 决策点：`-smp 1` vs `-smp 2`（5.2-4） | 低 | 接受 | **接受**。 |

**规划阶段轮次状态**：8/8 全部解决（6 接受 + 2 共识），零遗留。Worker 已实现 TASK-50/51/52，进入实现复审（见第十节）。

---

## 十、实现复审 — TASK-50/51/52（commit 605a047）

- **复审日期**: 2026-08-06
- **审查范围**: [TASK-50_strict-mode.md](file:///home/lai/Code/NET_DELAYACCT/logs/work/2026-08-06/TASK-50_strict-mode.md)、[TASK-51_ci-matrix.md](file:///home/lai/Code/NET_DELAYACCT/logs/work/2026-08-06/TASK-51_ci-matrix.md)、[TASK-52_ci-perf-job.md](file:///home/lai/Code/NET_DELAYACCT/logs/work/2026-08-06/TASK-52_ci-perf-job.md)
- **代码变更**: [perf-test.sh](file:///home/lai/Code/NET_DELAYACCT/perf-test.sh) (+108/-7)、[ci.yml](file:///home/lai/Code/NET_DELAYACCT/.github/workflows/ci.yml) (+111/-8)

### 10.1 实现复审评分

| 审查项 | 评分 | 说明 |
|--------|------|------|
| 代码质量 | 8/10 | --strict 参数解析清晰、NO-DATA 修复正确；1 高 1 中 1 低问题 |
| 设计合理性 | 9/10 | verdict 优先级链 FAIL>INVALID>NO-DATA>PASS 设计合理；PERF_EXIT_FILE 子 shell 传值方案正确 |
| 测试覆盖 | 8/10 | 15 单元测试 + exit code 传递 + 参数解析；缺 CI 实际运行验证（待 TASK-54） |
| 文档/日志质量 | 9/10 | 三个 TASK 日志详实，踩坑记录完整，决策理由充分 |
| **综合评分** | **8.5/10** | 主动发现并修复 NO-DATA 假 PASS 是亮点；CI timeout 不匹配是必修项 |

### 10.2 优点

1. **NO-DATA 假 PASS 主动发现与修复（TASK-52）**：Worker 在验证 CI job 逻辑时主动发现 verdict 逻辑的"默认成功"陷阱——QEMU 启动但无 PERF: 数据时全 SKIP 误报 ALL PASSED。这是 v6.4.0 噪声假 PASS 的同类隐患，CI 接入后假绿危害放大。`verdict_pass` 计数器是正确解法，优先级链升级为 FAIL > INVALID > NO-DATA > PASS 设计合理。**这体现了从 v6.4.0 教训中的成长——不等 Reviewer 指出，主动排查同类隐患。**

2. **PERF_EXIT_FILE 子 shell exit code 传递（TASK-50）**：`{ ... } | tee` 子 shell 变量不传递到父 shell 是 bash 经典陷阱。Worker 用 mktemp 临时文件做 IPC + trap EXIT 清理，方案正确，并有单元测试验证 exit 2 能正确传递。

3. **qemu-test artifact 下载同步（TASK-51）**：matrix 化后 artifact 名从 `bzImage` 变为 `bzImage-on/off`，Worker 主动发现 qemu-test job 的下载步骤需同步修改——这不在 Reviewer 原始方案中。对下游影响的主动排查值得肯定。

4. **参数解析的防御性（TASK-50）**：`--strict=invalid` 返回 exit 2 并给出明确错误信息；未知参数 exit 2；`-h/--help` 打印用法。非法输入不会静默通过。

### 10.3 问题

| # | 严重度 | 问题描述 | 建议 | Worker反馈 |
|---|--------|----------|------|-------------|
| 1 | 高 | 见下文「问题 10.3.1 — CI perf-test job timeout 与 QEMU timeout 不匹配」 | 见下文 | [待回应] |
| 2 | 中 | 见下文「问题 10.3.2 — compare_and_report return 1 未设 PERF_EXIT，set -e 绕过 PERF_EXIT_FILE」 | 见下文 | [待回应] |
| 3 | 低 | CI Run perf-test 步骤用 `set -e` 而非 `set -euo pipefail`（[ci.yml#L526](file:///home/lai/Code/NET_DELAYACCT/.github/workflows/ci.yml#L526)） | 统一为 `set -euo pipefail`，与 perf-test.sh 严格模式一致 | [待回应] |

#### 问题 10.3.1 — CI perf-test job timeout 与 QEMU timeout 不匹配

**现象**：CI `perf-test` job 设置 `timeout-minutes: 10`（600s，[ci.yml#L494](file:///home/lai/Code/NET_DELAYACCT/.github/workflows/ci.yml#L494)），但 perf-test.sh 内部两次 QEMU 运行的 timeout 为 `QEMU_TIMEOUT_KVM=300` × 2 = 600s（KVM）或 `QEMU_TIMEOUT_TCG=600` × 2 = 1200s（TCG），见 [perf-test.sh#L27-28](file:///home/lai/Code/NET_DELAYACCT/perf-test.sh#L27-L28)。

**为什么是问题**：job timeout 是硬上限，超过后 GitHub Actions 直接 kill 整个 job（包括正在运行的 QEMU），不产出任何 artifact 或诊断信息。KVM 模式下两次 QEMU 恰好 600s = job timeout，没有任何余量——CI runner 启动慢、apt install 慢、QEMU boot 慢任何一项都会超时。TCG 回退模式下 1200s 远超 600s，**必定 timeout**。

**触发条件**：
- KVM 模式：CI runner 负载高、QEMU boot 慢、apt install 耗时 >0s（这些在共享 runner 上是常态）
- TCG 模式：KVM 不可用时自动回退 TCG，1200s > 600s 必定 timeout

**后果**：job timeout 后无 perf-report artifact、无 GITHUB_STEP_SUMMARY、无诊断信息。开发者看到的是一个干枯的 timeout 错误，无法判断是 QEMU 慢、perf 测试失败、还是基础设施问题。`continue-on-error: true` 让 workflow 仍 success，但 perf-test job 永远是红/黄，失去趋势监控价值。

**修法**：两种方案择一：
- 方案 A（推荐）：CI 步骤中通过环境变量缩短 QEMU timeout：`env: QEMU_TIMEOUT_KVM: 240, QEMU_TIMEOUT_TCG: 480`，总耗时 480s (KVM) / 960s (TCG)，留 2-10 分钟余量给 install/checkout
- 方案 B：增大 `timeout-minutes: 20`，容忍 TCG 的 1200s。但 20 分钟 job 占用共享 runner 过久

**为什么这么修**：方案 A 更优——QEMU 240s (KVM) 对 perf 测试足够（内核 boot ~10s + perf 测试 ~30s + iperf3 ~60s × 3 runs ≈ 200s），缩短 timeout 反而能更快发现 QEMU hang。TCG 480s 仍超 job timeout，但 TCG 回退本身是异常情况（CI 应有 KVM），timeout 可接受。

#### 问题 10.3.2 — compare_and_report return 1 未设 PERF_EXIT，set -e 绕过 PERF_EXIT_FILE

**现象**：[perf-test.sh#L343-L346](file:///home/lai/Code/NET_DELAYACCT/perf-test.sh#L343-L346) 中 `compare_and_report` 在 result 文件缺失时 `return 1`，但未设置 `PERF_EXIT`。主流程 [perf-test.sh#L631-L634](file:///home/lai/Code/NET_DELAYACCT/perf-test.sh#L631-L634) 依赖 `set -e` 触发子 shell 退出来传播这个失败——`return 1` → `set -e` kill 子 shell → `echo "$PERF_EXIT" > $PERF_EXIT_FILE`（L634）未执行 → PERF_EXIT_FILE 为空。

**为什么是问题**：exit code 的传递有两条路径——verdict 走 PERF_EXIT_FILE，硬错误走 set -e。这种"分裂责任"设计是维护陷阱：当前行为恰好正确（set -e 让 pipeline 返回 1，父 shell set -e exit 1），但如果未来有人为了"容错"在 pipeline 后加 `|| true`，或把 `set -e` 改成 `set +e`，missing-files 失败就会被 PERF_EXIT_FILE 的默认值 "0" 掩盖 → exit 0 → 假 PASS。这正是 v6.4.0 和 TASK-52 刚修复的"假绿"问题的同一类根因——verdict 逻辑依赖隐式行为而非显式状态。

**触发条件**：result 文件缺失（`run_perf_in_qemu` 未创建 perf-ON/OFF-*.log）。当前 `run_perf_in_qemu` 总是创建 result_file（`tr` 命令），所以这个分支实际很难触发。但如果未来 `run_perf_in_qemu` 被重构为失败时 return 而非继续，或 `tr` 命令本身失败（磁盘满），就会触发。

**后果**：当前无实际 bug（set -e 恰好传播了失败）。但设计脆弱——exit code 传递依赖 set -e 的隐式行为，而非 PERF_EXIT 的显式赋值。维护者修改 pipeline 结构时极易引入假 PASS。

**修法**：在 `compare_and_report` 的 missing-files 分支显式设置 `PERF_EXIT=1`，并在主流程用 `|| true` 防止 set -e 绕过 PERF_EXIT_FILE 写入：
```bash
# perf-test.sh L343-346
if [ ! -f "$on_file" ] || [ ! -f "$off_file" ]; then
    echo "${RED}Missing result files${NC}"
    PERF_EXIT=1
    return 1
fi

# perf-test.sh L631-634（主流程）
compare_and_report || true   # 不让 set -e 绕过 PERF_EXIT_FILE
echo "${PERF_EXIT:-0}" > "$PERF_EXIT_FILE"
```

**为什么这么修**：让 PERF_EXIT 成为 exit code 的**唯一来源**，set -e 不再承担 exit code 传递职责。`|| true` 确保 compare_and_report 的 return 1 不 kill 子 shell，PERF_EXIT_FILE 总是被写入。这样即使未来修改 pipeline 结构，exit code 仍由 PERF_EXIT 决定，不会引入假 PASS。对照 v6.4.0/TASK-52 的教训：verdict 逻辑不可依赖"默认成功"或"隐式行为"，必须显式追踪所有状态。

### 10.4 实现复审议题追踪

| # | 问题 | 严重度 | Worker反馈 |
|---|------|--------|-------------|
| 10.3.1 | CI perf-test job timeout 与 QEMU timeout 不匹配 | 高 | [待回应] |
| 10.3.2 | compare_and_report return 1 未设 PERF_EXIT | 中 | [待回应] |
| 10.3.3 | CI 步骤缺少 pipefail | 低 | [待回应] |

**实现复审轮次状态**：0/3 已解决，3 条待回应。

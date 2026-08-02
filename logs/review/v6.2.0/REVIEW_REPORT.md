# 审查报告 - v6.2.0

- **审查日期**: 2026-08-02
- **审查范围**: v6.1.0 闭环遗留的 5 项增强任务（TASK-33~37）—— kprobe 配对验证 / ACK 守卫验证 / IPv6 UDP corked / S7 重传可观测性 / 场景级状态输出
- **审查人**: Reviewer
- **总体评分**: 6.5/10
- **状态**: [待复审] — 7 条问题全部接受并修复，本地测试 25/25 PASS，待 Reviewer 复审闭环

---

## 一、审查概览

| 审查项 | 评分 | 说明 |
|--------|------|------|
| 代码质量 | 7/10 | helper 代码干净、断言逻辑正确；但 Test 24 有阻断性缺陷（BTF 依赖），调试输出残留 |
| 设计合理性 | 6/10 | S8/Test 25 设计到位；Test 24 名实不符（声称"配对验证"实则只做计数比）；SKIP→FAIL 语义退化 |
| 测试覆盖 | 6/10 | 覆盖了 v6.1.0 遗留的 4 项空白，但全部代码尚未经本地测试验证，覆盖效果未知 |
| 文档/日志质量 | 6/10 | TASK-33 日志结构完整、踩坑记录有价值；但缺 DAILY_SUMMARY，测试验证章节空白 |
| **综合评分** | **6.5/10** | 方向正确但有 1 条阻断性问题（Test 24 必 SKIP）+ 1 条语义退化问题需修复后才能闭环 |

### 本轮 Review 的触发背景

v6.1.0 闭环时，以下 4 项被延期至 v6.2.0：

1. start/end 配对验证（kprobe events）— 问题 2.3.1
2. 纯 ACK 守卫验证 — 问题 2.3.3
3. IPv6 UDP corked 路径覆盖（`udp_v6_push_pending_frames`）— 唯一全场景为 0 的函数
4. S7 重传场景可观测性 — 避免 CI success 掩盖场景级 SKIP/FAIL

Worker 据此分解为 TASK-33~37 并完成编码，但**尚未执行任何本地测试验证**（工作日志第 5 节"测试验证"为空白）。

---

## 二、各项审查详情

### 2.1 代码质量 (7/10)

#### 优点
- `corked-udp6-client` helper 代码结构清晰，`IPV6_V6ONLY` 设置确保走纯 IPv6 路径，cork/uncork burst 策略与 IPv4 版本一致。
- Test 25 的 awk 解析逻辑正确区分了 iperf3 server 的三类 socket（listen / control / data），避免了 control connection TX>0 导致的假阴性。
- Test 23 S8 场景的 ftrace 断言函数列表（`udp_v6_push_pending_frames udpv6_sendmsg dev_hard_start_xmit`）与打桩点映射表一致。
- ci.yml 的 grep 模式从 `\[PASS\]` 改为 `^\s*\[PASS\]`，正确排除了 `[S1 PASS]` 场景状态行的污染。

#### 问题
| # | 严重度 | 问题描述 | 建议 | Worker反馈 |
|---|--------|----------|------|-------------|
| 1 | 高 | Test 24 kprobe 使用 `$arg2` 语法但内核未启用 BTF，kprobe 注册必然失败 → Test 24 永远 SKIP | 见下文「问题 2.1.1」 | 接受 — 已改为 `%si:u64` |
| 2 | 中 | Test 24 残留调试输出（`[debug]` 行），且 `head -10` dump trace 内容在生产测试中过于冗长 | 见下文「问题 2.1.2」 | 接受 — 已改为 `NET_DELAYACCT_DEBUG=1` 门控 |
| 3 | 低 | `corked-udp-client` 与 `corked-udp6-client` 代码重复约 90%，可提取公共函数 | 见下文「问题 2.1.3」 | 接受 — 后续优化 |

### 2.2 设计合理性 (6/10)

#### 优点
- Test 25 对"纯接收方 TX=0"的验证设计精巧：不是汇总所有 socket 的 TX，而是逐 socket 查找 RX>0 ∧ TX=0 的数据 socket，正确排除了 control connection 的干扰。
- Test 23 场景级状态汇总（S1-S8 矩阵 + 通过率框）让 CI summary 不打开 artifact 就能看到场景状态，可观测性显著提升。
- Test 24 的配对比率断言 `[50%, 200%]` 的上下界推导逻辑（下界容忍 ACK 守卫跳过、上界容忍 GSO 分段）是合理的。

#### 问题
| # | 严重度 | 问题描述 | 建议 | Worker反馈 |
|---|--------|----------|------|-------------|
| 4 | 高 | Test 23 场景 SKIP 导致整个测试 FAIL（而非 SKIP），环境缺失会触发 CI 失败 | 见下文「问题 2.2.1」 | 接受 — 已区分 SKIP/FAIL |
| 5 | 中 | Test 24 声称"start/end 配对验证"但实际只做计数比，skb 指针被捕获后未使用 | 见下文「问题 2.2.2」 | 接受 — 方案A，已降级为"计数比验证" |

### 2.3 测试覆盖 (6/10)

#### 优点
- S8 场景首次覆盖 `udp_v6_push_pending_frames`，补齐了 v6.1.0 中唯一全场景为 0 的函数。
- Test 25 首次正面验证纯 ACK 守卫语义，不再仅依赖 Test 09 的间接推断。
- tc/iptables 打包到 initramfs 使 S7 重传场景从"永远 SKIP"变为"可实际运行"。

#### 问题
| # | 严重度 | 问题描述 | 建议 | Worker反馈 |
|---|--------|----------|------|-------------|
| 6 | 高 | 全部 v6.2.0 代码变更未经任何本地测试验证，工作日志"测试验证"章节为空白 | 见下文「问题 2.3.1」 | 接受 — 本地测试 25/25 PASS，日志已回填 |

### 2.4 文档/日志质量 (6/10)

#### 优点
- TASK-33 日志的"变更原因"章节解释充分：为什么用 kprobe 而非 function tracer、为什么只验证 tx 配对、为什么配对比率用 [50%, 200%]。
- 踩坑记录有价值：busybox tc 不支持 netem、CI summary grep 误计场景状态行——都是真实遇到的问题。

#### 问题
| # | 严重度 | 问题描述 | 建议 | Worker反馈 |
|---|--------|----------|------|-------------|
| 7 | 低 | 缺少 `logs/work/2026-08-02/DAILY_SUMMARY.md`（Worker 规范要求每日汇总） | 见下文「问题 2.4.1」 | 接受 — 已创建 |

---

## 三、分项问题展开

### 问题 2.1.1 — Test 24 kprobe `$arg2` 语法依赖 BTF，内核未启用 → Test 24 必 SKIP

- **现象**：[ci/qemu/run-tests.sh#L1991-L1992](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L1991-L1992) 中 Test 24 注册 kprobe：
  ```bash
  echo 'p:tx_start net_delayacct_tx_start skb=$arg2' > "$TRACEFS/kprobe_events" 2>/dev/null
  echo 'p:tx_end net_delayacct_tx_end skb=$arg2' >> "$TRACEFS/kprobe_events" 2>/dev/null
  ```
  而 [ci/qemu/kernel-qemu.config](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/kernel-qemu.config) 的 tracing 配置段只有：
  ```
  CONFIG_FUNCTION_TRACER=y
  CONFIG_FTRACE=y
  CONFIG_KPROBES=y
  CONFIG_KPROBE_EVENTS=y
  ```
  **缺少 `CONFIG_DEBUG_INFO_BTF=y`**。CI 构建步骤中也未安装 `pahole`（dwarves 包），即使配置了 BTF 也无法生成。

- **为什么是问题**：
  - `$argN` 是 Linux 5.11+ 引入的 BTF-based kprobe 参数语法，内核通过 BTF 信息解析函数参数的寄存器位置。
  - 没有 `CONFIG_DEBUG_INFO_BTF=y` 时，`$arg2` 语法**不可用**，写入 kprobe_events 会返回 `-EINVAL`。
  - 由于 echo 重定向了 stderr（`2>/dev/null`），注册失败被静默吞掉。
  - 随后的检查 `grep -q 'tx_start' "$TRACEFS/kprobe_events"` 会失败（因为注册没成功），Test 24 走 `_skip` 分支。
  - **结论：Test 24 在当前配置下永远 SKIP，等于 v6.1.0 问题 2.3.1 的"配对验证"目标完全没有达成。**

- **触发条件**：每次运行 Test 24（本地和 CI 均如此）。

- **后果**：
  - TASK-33 的核心交付物（kprobe 配对验证）在运行时不可用。
  - Worker 在 TASK-33 日志第 6 节标注的待办"kprobe events 在 QEMU guest 中是否可注册（需确认符号导出）"实际答案是**不能注册**，但根因不是符号导出而是 BTF 缺失。
  - 如果不修复，v6.2.0 的 P0 任务 TASK-33 形同未完成。

- **修法**（二选一）：

  **方案 A（推荐）：改用寄存器语法，不依赖 BTF**
  ```bash
  # x86_64 ABI: arg1=rdi(sk), arg2=rsi(skb)
  echo 'p:tx_start net_delayacct_tx_start skb=%si:u64' > "$TRACEFS/kprobe_events"
  echo 'p:tx_end net_delayacct_tx_end skb=%si:u64' >> "$TRACEFS/kprobe_events"
  ```
  优点：无需修改内核配置和构建依赖，立即可用。
  缺点：架构相关（但本项目 QEMU 仅运行 x86_64，可接受）。

  **方案 B：启用 BTF**
  - kernel-qemu.config 增加 `CONFIG_DEBUG_INFO_BTF=y`
  - CI 和 local-test.sh 的内核构建步骤增加 `sudo apt-get install -y dwarves`
  优点：语法可移植，`$argN` 自动适配架构。
  缺点：增加构建时间（pahole 生成 BTF），增大 vmlinux 体积。

- **为什么这么修**：
  - 方案 A 的 `%si:u64` 语法是 kprobe events 最古老的参数捕获方式，只需要 `CONFIG_KPROBE_EVENTS=y`（已有），不依赖 BTF。
  - 项目目标是 x86_64 QEMU 测试，不需要跨架构可移植性。
  - 如果未来需要跨架构支持，再切换到方案 B。

---

### 问题 2.1.2 — Test 24 残留调试输出，生产测试中过于冗长

- **现象**：[ci/qemu/run-tests.sh#L1996-L2001](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L1996-L2001) 和 [ci/qemu/run-tests.sh#L2015-L2018](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L2015-L2018)：
  ```bash
  echo "    [debug] kprobe_events content:"
  cat "$TRACEFS/kprobe_events" 2>/dev/null | sed 's/^/      | /' || echo "      | (empty or unreadable)"
  echo "    [debug] available_filter_functions has net_delayacct_tx_start: $(grep -c ...)"
  ...
  echo "    [debug] trace lines: $(wc -l < "$TRACEFS/trace" ...)"
  echo "    [debug] trace first 10 lines:"
  head -10 "$TRACEFS/trace" 2>/dev/null | sed 's/^/      | /'
  ```

- **为什么是问题**：
  - `[debug]` 前缀的输出在测试通过时也会打印，增加约 15-20 行噪声。
  - `head -10` dump 的 trace 内容包含内核地址（`0xffff...`），在 CI 公开日志中可能被视为信息泄漏（虽然 QEMU 环境地址无实际价值，但不符合最小信息暴露原则）。
  - 其他测试（Test 01-22）在 PASS 时不打印调试信息，Test 24 的调试输出打破了格式一致性。

- **触发条件**：每次 Test 24 运行（无论 PASS/FAIL/SKIP）。

- **后果**：
  - CI 日志可读性下降。
  - 调试输出在问题修复后失去价值，成为维护负担。

- **修法**：
  - 将 `[debug]` 输出改为仅在 FAIL 时打印（移到 `_fail` 分支前）。
  - 或使用环境变量控制：`[ "${NET_DELAYACCT_DEBUG:-0}" = "1" ] && ...`
  - `head -10` 的 trace dump 改为 `head -5` 并过滤掉地址行，或仅在 FAIL 时打印。

- **为什么这么修**：
  - 调试信息的价值在问题排查时最高，在测试通过时为零。按"失败时诊断、通过时静默"原则设计。

---

### 问题 2.1.3 — corked-udp-client 与 corked-udp6-client 代码重复约 90%

- **现象**：[tests/helper/delayacct_path_test.c#L310-L373](file:///home/lai/Code/NET_DELAYACCT/tests/helper/delayacct_path_test.c#L310-L373)（`do_corked_udp_client`）与 [tests/helper/delayacct_path_test.c#L379-L449](file:///home/lai/Code/NET_DELAYACCT/tests/helper/delayacct_path_test.c#L379-L449)（`do_corked_udp6_client`）的 sendto 循环、cork/uncork 逻辑、错误处理几乎完全相同，仅 socket 创建和地址结构不同。

- **为什么是问题**：如果 cork 逻辑需要修改（如 burst 数量、超时策略），需要同步修改两处，容易遗漏。

- **严重度**：低（测试辅助程序，重复不影响正确性）。

- **修法**：可提取公共的 `corked_send_loop(int s, struct sockaddr *addr, socklen_t addrlen, int duration)` 函数。但考虑到这是测试 helper 且逻辑稳定，**不强制要求本次修改**，仅作为后续优化建议。

---

### 问题 2.2.1 — Test 23 场景 SKIP 导致整个测试 FAIL（语义退化）

- **现象**：[ci/qemu/run-tests.sh#L1956-L1962](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L1956-L1962) 的 Test 23 最终断言：
  ```bash
  if [ "$PASSED_SCENARIOS" -eq "$TOTAL_SCENARIOS" ]; then
      _pass "all $TOTAL_SCENARIOS ftrace scenarios passed"
  else
      _fail "... scenarios failed (PASS=$PASSED_SCENARIOS SKIP=$SKIPPED_SCENARIOS)"
  fi
  ```
  当 S3/S4/S5/S6/S7/S8 因环境缺失（helper 不可用、tc 未安装、IPv6 未启用等）被 SKIP 时，`TOTAL_SCENARIOS` 仍计入该场景，导致 `PASSED_SCENARIOS < TOTAL_SCENARIOS` → `_fail`。

- **为什么是问题**：
  - v6.1.0 中 S7 不可用时走 `_skip`，Test 23 整体标记为 SKIP，不影响 CI 成功。
  - v6.2.0 改为 `_fail` 后，**任何场景的环境缺失都会导致 CI 失败**。
  - 这与 v6.1.0 对话中"S7 两者均不可用时 `_skip` 而非 `_fail`"的共识（见 [DLG-20260801-183000.md](file:///home/lai/Code/NET_DELAYACCT/logs/dialogue/DLG-20260801-183000.md) 议题 1）直接矛盾。
  - CI runner 环境变化（如 apt 源缺少 iproute2、tc 版本不支持 netem）会从"SKIP 不影响 CI"变成"FAIL 阻断 CI"。

- **触发条件**：任何场景因环境原因 SKIP（如 CI 中 tc 不可用、helper 未重新编译、IPv6 模块未加载）。

- **后果**：
  - CI 在环境不完整时返回失败，而非优雅降级。
  - 与 v6.1.0 达成的共识矛盾，属于回归。

- **修法**：区分"场景失败"和"场景跳过"：
  ```bash
  FAILED_SCENARIOS=$((TOTAL_SCENARIOS - PASSED_SCENARIOS - SKIPPED_SCENARIOS))
  if [ "$FAILED_SCENARIOS" -gt 0 ]; then
      _fail "$FAILED_SCENARIOS scenarios failed (PASS=$PASSED_SCENARIOS SKIP=$SKIPPED_SCENARIOS)"
  elif [ "$SKIPPED_SCENARIOS" -gt 0 ]; then
      _skip "$SKIPPED_SCENARIOS/$TOTAL_SCENARIOS scenarios skipped (PASS=$PASSED_SCENARIOS, no failures)"
  else
      _pass "all $TOTAL_SCENARIOS scenarios passed"
  fi
  ```

- **为什么这么修**：
  - "场景跑不了"（SKIP）和"场景跑了但断言失败"（FAIL）是不同严重度的事件。
  - SKIP 表示环境限制，应优雅降级；FAIL 表示功能缺陷，必须阻断。
  - 修改后保持与 v6.1.0 共识一致：环境缺失 → SKIP，不阻断 CI。

---

### 问题 2.2.2 — Test 24 声称"配对验证"但实际只做计数比

- **现象**：[ci/qemu/run-tests.sh#L1974-L1976](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L1974-L1976) Test 24 的描述和断言：
  ```bash
  _desc \
      "通过 kprobe events 抓取 tx_start/tx_end 的 skb 指针，验证 start/end 配对语义" \
      "注册 kprobe → 运行 TCP 流量 → 统计两函数调用次数 → 断言配对比率在合理范围" \
      "tx_end/tx_start 比率 ∈ [0.5, 2.0]（容忍纯 ACK 守卫 + GSO 分段）"
  ```
  但实际实现 [ci/qemu/run-tests.sh#L2011-L2012](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L2011-L2012) 只统计调用次数：
  ```bash
  TX_START_COUNT=$(grep -c 'tx_start:' "$TRACEFS/trace" 2>/dev/null || true)
  TX_END_COUNT=$(grep -c 'tx_end:' "$TRACEFS/trace" 2>/dev/null || true)
  ```
  kprobe 虽然注册了 `skb=$arg2`（或 `%si:u64`），但 trace 中的 skb 指针**从未被解析或匹配**。

- **为什么是问题**：
  - 测试名称"验证 start/end 配对"暗示"每个 tx_end 的 skb 都能在 tx_start 集合中找到对应记录"——这是真正的配对验证。
  - 但实际只检查 `count(tx_end) / count(tx_start) ∈ [0.5, 2.0]`，这是**计数比验证**，不是配对验证。
  - 以下失效场景无法被计数比发现：
    - `tx_start` 全部打在 skb A 上，`tx_end` 全部打在 skb B 上（count 比为 1.0，但完全错配）
    - `tx_start` 打了 100 次但全是同一个 skb（count=100），`tx_end` 打了 100 次在 100 个不同 skb 上（count=100，比为 1.0）
  - TASK-33 日志声称"抓取 skb 指针（`$arg2`），统计两函数调用次数"——但 skb 指针被抓取后从未使用，等于浪费。

- **触发条件**：任何 start/end 错配但计数恰好相等的场景。

- **后果**：
  - 测试通过不代表 start/end 真的配对，给开发者虚假的信心。
  - v6.1.0 问题 2.3.1 的核心诉求"每个被 end 读取的 skb 都曾被 start 打过时间戳"未被真正验证。

- **修法**（二选一）：

  **方案 A（推荐）：诚实降级，修改名称和描述**
  - 测试名称改为"kprobe events 验证 tx_start/tx_end 调用计数比"
  - `_desc` 中明确说明"本测试验证调用次数比，不验证 per-skb 配对；per-skb 配对需要解析 trace 中的 skb 指针，留待后续增强"
  - 在 TASK-33 日志中同步更新描述

  **方案 B：实现真正的 per-skb 配对**
  - 从 trace 中提取每个 tx_start 和 tx_end 的 skb 指针
  - 构建两个集合，验证 `set(tx_end_skb) ⊆ set(tx_start_skb)`
  - 实现复杂度较高（需在 shell 中解析 trace 行、提取指针、去重、集合运算），但可用 awk 完成

- **为什么这么修**：
  - 方案 A 是对当前实现的诚实描述，不改变代码逻辑，只修正命名。
  - 方案 B 是真正的配对验证，但工作量较大，可作为 v6.3.0 增强。
  - **关键原则**：测试的名称和描述必须与实际验证的内容一致，不能"名实不符"。

---

### 问题 2.3.1 — 全部 v6.2.0 代码变更未经任何本地测试验证

- **现象**：[TASK-33_to_37_v6.2.0-enhancements.md](file:///home/lai/Code/NET_DELAYACCT/logs/work/2026-08-02/TASK-33_to_37_v6.2.0-enhancements.md) 第 5 节"测试验证"内容为：
  ```
  （待本地测试完成后填充）
  ```
  第 6 节"待办/遗留问题"列出 3 项均未完成：
  - ⬜ 本地测试验证 S7 (tc netem) 和 S8 (IPv6 corked) 是否真正触发
  - ⬜ CI 验证（KVM 环境下 tc netem 是否可用）
  - ⬜ kprobe events 在 QEMU guest 中是否可注册（需确认符号导出）

- **为什么是问题**：
  - 未经测试的代码变更不能标记为"完成"，也不能提交 Review。
  - Worker 规范要求"边做边记，不要事后补日志"和"测试验证"章节必须填写。
  - 本轮 Review 发现的**问题 2.1.1（BTF 缺失导致 Test 24 必 SKIP）**正是"kprobe 是否可注册"待办项的答案——如果 Worker 在编码后立即运行本地测试，这个问题会在提交 Review 前被发现并修复，而非由 Reviewer 发现。

- **触发条件**：当前状态——代码已写完但未测试。

- **后果**：
  - Reviewer 不得不扮演"第一个测试者"的角色，发现本应由 Worker 自己发现的问题。
  - 测试覆盖评分无法给出——因为覆盖效果未知。
  - 如果 Worker 直接推送 CI，CI 失败后还需要来回修复，浪费 CI 资源。

- **修法**：
  1. **先修复问题 2.1.1（BTF/kprobe 语法）**
  2. **运行 `./local-test.sh --qemu-only` 本地验证**
  3. **确认 Test 24/25 和 S7/S8 的实际运行结果**
  4. **回填 TASK-33 日志第 5 节"测试验证"**
  5. **再提交给 Reviewer 复审**

- **为什么这么修**：
  - "先测试再提交 Review"是 Worker 规范的基本要求。
  - 本地测试能发现大部分阻断性问题（如 BTF 缺失、符号不可见、awk 解析错误），减少 Review 轮次。

---

### 问题 2.4.1 — 缺少 DAILY_SUMMARY.md

- **现象**：`logs/work/2026-08-02/` 目录下只有 `TASK-33_to_37_v6.2.0-enhancements.md`，缺少 `DAILY_SUMMARY.md`。

- **为什么是问题**：Worker 规范要求"每天结束时必须生成每日汇总"。

- **修法**：创建 `logs/work/2026-08-02/DAILY_SUMMARY.md`，汇总今日完成的任务、关键决策、踩坑总结和明日计划。

- **严重度**：低（文档规范问题，不影响代码功能）。

---

## 四、突出问题总结

### 严重问题（必须修复）
1. **问题 2.1.1**：Test 24 kprobe `$arg2` 依赖 BTF 但内核未启用 → Test 24 永远 SKIP，TASK-33 核心目标未达成。
2. **问题 2.2.1**：Test 23 场景 SKIP 导致整个测试 FAIL，与 v6.1.0 共识矛盾，会导致 CI 在环境不完整时失败。
3. **问题 2.3.1**：全部代码变更未经本地测试验证，工作日志测试章节为空白。

### 改进建议（建议采纳）
1. **问题 2.1.2**：Test 24 调试输出改为仅 FAIL 时打印。
2. **问题 2.2.2**：Test 24 名称和描述应诚实反映"计数比验证"而非"配对验证"，或实现真正的 per-skb 配对。

### 优化建议（可选）
1. **问题 2.1.3**：helper 代码去重（后续优化）。
2. **问题 2.4.1**：补充 DAILY_SUMMARY.md。

---

## 五、踩坑点评

### 坑1：busybox tc 不支持 netem

- **Worker 记录**：尝试用 busybox tc applet 替代完整 tc，发现不支持 netem。
- **Reviewer 评价**：处理得当。busybox applet 功能精简是已知限制，Worker 正确地转向了完整 iproute2 tc + netem qdisc 共享对象的方案。
- **深层启示**：QEMU initramfs 中使用 busybox 时，需提前确认所需功能是否被 applet 覆盖，避免在测试运行时才发现功能缺失。

### 坑2：CI summary grep 误计场景状态行

- **Worker 记录**：`[S1 PASS]` 被 `grep '\[PASS\]'` 匹配，导致 PASS 计数翻倍。
- **Reviewer 评价**：根因分析准确，修复方案（`^\s*\[PASS\]` 精确匹配）正确。
- **深层启示**：添加新输出格式时，需检查是否与现有 grep 模式产生子串冲突。这应作为 CI summary 维护的 checklist 条目。

---

## 六、总体评价

### 本轮工作的价值

Worker 在 v6.2.0 中落实了 v6.1.0 闭环时延期的全部 4 项增强任务，方向正确、设计意图清晰：

- **S8 场景**首次覆盖了 `udp_v6_push_pending_frames`，补齐了 v6.1.0 中唯一全场景为 0 的函数。
- **Test 25** 的 ACK 守卫验证逻辑设计精巧，正确区分了 iperf3 server 的三类 socket。
- **TASK-37** 的场景级可观测性增强让 CI summary 不打开 artifact 就能看到 S1-S8 状态。
- **tc/iptables 打包**使 S7 重传场景从"永远 SKIP"变为"可实际运行"。

### 需要改进的方面

1. **先测试再提交 Review**：本轮最大的问题是代码未经任何本地验证就提交了 Review。问题 2.1.1（BTF 缺失）是典型的"运行一次就能发现"的阻断性问题，却由 Reviewer 在静态审查中发现。Worker 应在编码完成后立即运行 `./local-test.sh --qemu-only`，确认所有新增测试实际可运行。
2. **名实一致**：Test 24 声称"配对验证"但只做计数比，skb 指针被捕获后未使用。测试的命名和描述必须与实际验证内容一致。
3. **共识遵守**：问题 2.2.1 的 SKIP→FAIL 语义退化与 v6.1.0 对话中明确达成的共识矛盾。修改已有行为时应检查是否与之前的共识冲突。

### Worker 的成长点

- 踩坑记录质量明显提升：busybox tc 不支持 netem、grep 子串冲突——都是真实问题且根因分析准确。
- TASK-33 日志的"变更原因"章节解释充分，技术决策有据可查。
- 场景级可观测性设计（`_scenario_status` + 汇总框 + CI summary 提取）是工程上的正向改进。

---

## 七、下版本关注点

1. **Test 24 per-skb 配对验证**：如果 v6.2.0 选择方案 A（降级为计数比），v6.3.0 应考虑实现方案 B（真正的 per-skb 配对）。
2. **S7 重传场景在 CI 中的稳定性**：tc netem 在 KVM 环境下的可用性需通过 CI 实际运行验证，关注是否会因 KVM 网络栈差异导致 netem 不生效。
3. **helper 代码去重**：`corked-udp-client` / `corked-udp6-client` / `tcp-sender` 可提取公共的发送循环逻辑。

---

## 八、闭环检查记录

### 第一轮审查（2026-08-02）

**问题状态统计**：
| 状态 | 数量 | 问题编号 |
|------|------|---------|
| 接受 | 7 | 2.1.1, 2.1.2, 2.1.3, 2.2.1, 2.2.2, 2.3.1, 2.4.1 |
| 共识 | 0 | — |
| 撤回 | 0 | — |
| 待回应 | 0 | — |
| **合计** | **7** | **全部达成决议，代码已修复并本地测试验证** |

**P0 修复清单**（Worker 行动依据）：
| 优先级 | 任务 | 关联问题 | 状态 |
|--------|------|---------|------|
| P0 | 修复 Test 24 kprobe 语法（`$arg2` → `%si:u64`） | 2.1.1 | ✅ 已修复 |
| P0 | 修复 Test 23 SKIP 语义（区分 SKIP 和 FAIL） | 2.2.1 | ✅ 已修复 |
| P0 | 运行本地测试验证全部新增测试 | 2.3.1 | ✅ 25/25 PASS |
| P1 | Test 24 调试输出改为仅 FAIL 时打印 | 2.1.2 | ✅ 已修复 (NET_DELAYACCT_DEBUG 门控) |
| P1 | Test 24 名称/描述与实际验证内容一致 | 2.2.2 | ✅ 已修复 (降级为"计数比验证") |
| P2 | 补充 DAILY_SUMMARY.md | 2.4.1 | ✅ 已创建 |
| P2 | helper 代码去重（可选） | 2.1.3 | ⏳ 后续优化 |

### 本地测试验证结果（2026-08-02，TCG 模式）

```
Tests run:  25     PASS: 25     FAIL:  0     SKIP:  0
RESULT: ALL PASS
```

**关键验证点**：
- Test 23 S7 (tc netem 重传): ✅ PASS — `__tcp_retransmit_skb=46`
- Test 23 S8 (IPv6 UDP corked): ✅ PASS — `udp_v6_push_pending_frames=1026`
- Test 24 (kprobe 计数比): ✅ PASS — `tx_start=4653 tx_end=6025 ratio=129%`
- Test 25 (ACK 守卫): ✅ PASS — 数据 socket RX>0 ∧ TX=0
- Test 23 汇总: ✅ `all 8 ftrace scenarios passed (13 functions verified)`

**额外修复**（本地测试过程中发现）：
1. TOTAL_SCENARIOS 计数 bug（S3-S8 SKIP 时不递增 → -1 FAIL）
2. PATH 缺少 `/usr/sbin` 导致 tc/iptables 不可达（S7 永久 SKIP 的根因）
3. kprobe_events 清空 EBUSY（需先禁用 events 再清空）

# 审查报告 - v6.0.0

- **审查日期**: 2026-07-29
- **审查范围**: `tests/README.md`、`ci/qemu/run-tests.sh`（NET_DELAYACCT 整套测试方案）
- **审查人**: Reviewer
- **总体评分**: 6.5/10

---

## 一、审查概览

| 审查项 | 评分 | 说明 |
|--------|------|------|
| 代码质量 | 7/10 | 脚本结构清晰，辅助函数完整，失败诊断机制较好 |
| 设计合理性 | 6/10 | 方向分离验证合理，但并发测试设计较弱，重置测试断言与语义存在矛盾 |
| 测试覆盖 | 6/10 | 覆盖了 sendmsg/recvmsg 主路径，但缺少 splice/zerocopy/corked/IPv6 等已声明支持路径的专项验证 |
| 文档/日志质量 | 7/10 | README 详细且解释了 iperf3 行为，但存在自相矛盾的说法和未显式声明的假设 |
| **综合评分** | **6.5/10** | 测试方案整体可用，但存在 5 个必须修复/澄清的关键问题 |

---

## 二、审查详情

### 2.1 代码质量 (7/10)

#### 优点
- `run-tests.sh` 的 `_test_header` / `_pass` / `_fail` / `_skip` / `_require` 框架简洁，失败诊断信息完整。
- `_show_output()` 在失败时打印协议摘要、RX/TX 总量、进程存活状态，对 QEMU 内调试友好。
- 端口分配表清晰，避免测试间冲突。

#### 问题
| # | 严重度 | 问题描述 | 建议 | Worker反馈 |
|---|--------|----------|------|-------------|
| 1 | 中 | Test 03 重置断言与 RESET 非原子语义矛盾 | 见下文「问题 2.1.1」 | 已修复 |
| 2 | 中 | Test 13 并发查询仅查 PID 1，未覆盖真实 per-socket 并发路径 | 见下文「问题 2.1.2」 | 已修复 |

### 2.2 设计合理性 (6/10)

#### 优点
- 方向分离验证（server 验 RX、client 验 TX）正确规避了纯 ACK 路径不计入 TX 的设计语义。
- 过滤测试使用 UDP server 作为目标，利用其同时持有 TCP 控制 socket 和 UDP 数据 socket 的特点，设计巧妙。

#### 问题
| # | 严重度 | 问题描述 | 建议 | Worker反馈 |
|---|--------|----------|------|-------------|
| 1 | 高 | Test 13 并发压力测试设计无法有效暴露 per-socket spinlock / dumpit 竞态 | 见下文「问题 2.2.1」 | 已修复 |
| 2 | 中 | Test 06 对 server socket 数量的解释忽略了 TIME-WAIT 等真实状态 | 见下文「问题 2.2.2」 | 已修复 |
| 3 | 低 | Test 09 仅验证 RX 的理由应补充为断言层面的反向约束 | 见下文「问题 2.2.3」 | 已修复 |

### 2.3 测试覆盖 (6/10)

#### 优点
- 16 个用例覆盖了 PID/inode/RESET/JSON/debug/过滤/协议隔离/边界条件/并发压力等维度。
- 阈值取值保守（如 Test 10 的 50），兼顾 TCG/KVM 双场景。

#### 问题
| # | 严重度 | 问题描述 | 建议 | Worker反馈 |
|---|--------|----------|------|-------------|
| 1 | 高 | TCP/UDP 测试未覆盖 splice/zerocopy/corked 等已插桩路径 | 见下文「问题 2.3.1」 | 已修复 |
| 2 | 中 | 未声明 IPv6 流量路径的实际覆盖情况 | 见下文「问题 2.3.2」 | 已修复 |
| 3 | 中 | 无 negative test 验证过滤条件的错误使用不会误匹配 | 见下文「问题 2.3.3」 | 已修复 |

### 2.4 文档/日志质量 (7/10)

#### 优点
- `tests/README.md` 对 iperf3 server 单线程、UDP 控制连接、`-P` fork 行为等做了充分说明。
- 端口表、覆盖矩阵、核心测试手段、环境注意事项等章节结构完整。

#### 问题
| # | 严重度 | 问题描述 | 建议 | Worker反馈 |
|---|--------|----------|------|-------------|
| 1 | 中 | README 中 Test 03 的「语义说明」与「断言」存在理论冲突 | 见下文「问题 2.4.1」 | 已修复 |
| 2 | 低 | README 中 3.1 覆盖矩阵对 IPv6 的声明与测试实现不一致 | 见下文「问题 2.4.2」 | 已修复 |

---

## 三、分项问题展开

### 问题 2.1.1 — Test 03 重置断言与 RESET 非原子语义矛盾

**现象**
- `tests/README.md` 第 152-159 行说明：RESET「不是全局原子快照，遍历期间新到达的包仍会被累加」。
- 但同一段的**断言**写为「重置后 `count > 0` 的行数 = 0」，即要求所有 socket 的 RX/TX count 全部归零。
- `ci/qemu/run-tests.sh` 第 260 行实现同样使用 `NONZERO=$(... | awk '$1>0' | wc -l)` 并断言其等于 0。

**为什么是问题**
- 如果 RESET 确实是非原子的，理论上在 reset 遍历期间到达的包会让某些 socket 在遍历完成后仍具有非零 count。
- 文档一方面承认非原子语义，另一方面又用「全部为零」作为硬断言，存在逻辑不自洽。
- 当前测试能 PASS 只是因为 iperf3 client 已结束（`-t 3`），server 处于空闲监听状态，没有持续流量。该断言的成立依赖于「恰好无并发流量」这一隐含条件，而非 RESET 语义本身。

**触发条件**
- 任何在 reset 执行期间仍有活跃流量的场景（例如后台持续发送的 UDP 流、长连接 TCP bulk transfer）都会使该断言失败。
- 如果未来扩展测试为「重置正在传输中的 socket」，此测试会 flaky 失败。

**后果**
- 测试通过会给人造成「RESET 是原子清零」的错误印象。
- 文档与代码实现的不一致会成为后续 review/维护的争议点。

**修法**
1. **修改断言语义**：将「count > 0 的行数 = 0」改为「在确认已停止流量后，count > 0 的行数 = 0」或「重置后相对于重置前，所有 count 均不增加」。
2. **显式停止流量**：在 `-R` 之前 kill 掉 client 并等待连接完全关闭，确保 reset 期间无新数据到达。
3. **文档同步**：在 README 的 Test 03 中增加一句说明：「本测试在 iperf3 client 已结束、server 空闲时执行 reset，因此非原子语义不会导致 count 非零；若 reset 时仍有活跃流量，可能出现少量非零计数。」

**为什么这么修**
- 保留 RESET 非原子的真实语义，同时让测试断言与语义一致。
- 避免测试对「恰好空闲」这一隐含条件的依赖，提高可维护性。

---

### 问题 2.1.2 / 2.2.1 — Test 13 并发查询压力仅查 PID 1，未覆盖真实 per-socket 并发路径

**现象**
- `tests/README.md` 第 279-288 行说明：Test 13 启动 16 个 worker，每个连续查询 PID 1 20 次，共 320 次查询。
- `ci/qemu/run-tests.sh` 第 742-756 行的 `_worker()` 函数同样只执行 `"$GET_SOCKDELAYS" -p 1`。

**为什么是问题**
- PID 1 在 QEMU guest 内通常没有任何 socket，因此内核侧的 dumpit 路径只是快速遍历一个空的 `files_struct`。
- 该路径**不会**调用 `net_delayacct_fill_sock()`，**不会**获取任何 per-socket 的 `sk->sk_lock.slock`，**不会**访问 `struct net_delayacct` 统计字段。
- 因此 Test 13 无法暴露以下真实并发风险：
  - dumpit 遍历 fdtable 时与 socket 关闭/创建之间的竞争；
  - 多个 dumpit 同时读取同一 socket 的 `n->lock` spinlock 是否会导致死锁或 long latency；
  - `cb->ctx` 在 dumpit start/dumpit/done 之间的状态是否正确；
  - 过滤条件（`--proto`/`--lport`）在高并发下是否可能触发 use-after-free 或错误的 match 结果。

**触发条件**
- 当内核存在 per-socket spinlock 使用不当（例如在 `lock_sock()` 时错误地持有了其他锁）、或 dumpit 回调在 rcu 临界区内做了不该做的事时，Test 13 不会触发故障。
- 真正的问题通常只在「查询一个持有大量 socket 的 busy PID」时暴露。

**后果**
- 测试名称叫「并发查询压力」，但实际压力等级不足，可能遗漏关键并发缺陷。
- 如果未来引入更复杂的过滤或排序逻辑，该测试无法提供有效回归保护。

**修法**
1. **增强 Test 13**：在启动 16 个 worker 查询 PID 1 的同时，启动一个 iperf3 server 作为「busy PID」，让部分 worker（例如 8 个）查询该 busy PID，另一部分（8 个）查询 PID 1。
2. **或新增 Test 17**：专门做「并发查询 busy PID」，例如 8 个 worker 各查询持有 8 条 TCP 流的 iperf3 server 20 次，验证无 Oops、无死锁、无结果不一致。
3. **或混合操作**：让 worker 交替执行「查询 busy PID」和「带过滤条件查询 busy PID」，覆盖过滤路径的并发安全。
4. **文档同步**：在 README 中明确说明当前 Test 13 的覆盖范围（仅验证空 fdtable 遍历 + Netlink 消息收发路径），以及增强方案的目标。

**为什么这么修**
- 并发压力测试的价值在于覆盖真实热点路径。PID 1 空查询虽然能暴露部分 Netlink 协议层问题，但离「per-socket 并发安全」的设计目标相差较远。
- 增强后既能保留「空查询高频率」的 fast-path 测试，又能覆盖「多 socket + 过滤」的慢路径并发。

---

### 问题 2.2.2 — Test 06 多 Socket 枚举对 server socket 数量的解释过于理想化

**现象**
- `tests/README.md` 第 185-193 行说明：server 端断言为「1 listen + 1 control + 4 data = ≥6 个 TCP socket」。
- `ci/qemu/run-tests.sh` 第 380 行使用 `SRV_LINES=$(echo "$SRV_OUT" | grep -c 'proto=tcp' || true)` 并断言 `>= 6`。

**为什么是问题**
- 该解释假设 socket 生命周期完全理想化：listen、control、4 个 data socket 同时存在，且没有其他状态。
- 实际上，当 data socket 关闭后，server 端可能保留 TIME-WAIT 状态的 socket；iperf3 server 内部也可能创建额外的管理/统计 socket。
- 使用 `>= 6` 可以容忍「更多 socket」，但 README 中的文字「1 listen + 1 control + 4 data = 6」会误导读者认为数量应恰好为 6，而实际可能为 7 或更多。

**触发条件**
- 在 client 完成传输、kill server 之前的短暂窗口内，部分 data socket 进入 TIME-WAIT。
- iperf3 版本或参数不同导致额外 socket 创建。

**后果**
- 如果测试偶尔看到 7 个 socket，初学者会困惑「为什么多了一个」。
- 如果后续将断言收紧为 `== 6`，测试会变得 flaky。

**修法**
1. **文档同步**：将 README 中的「1 listen + 1 control + 4 data = 6」改为「**至少** 1 listen + 1 control + 4 data，即 ≥6；实际数量可能因 TIME-WAIT 等状态而更高」。
2. **保留脚本断言**：`run-tests.sh` 中 `>= 6` 的断言是合理的，无需修改。
3. **可选增强**：在 Test 06 的 `_pass` 消息中打印实际数量，便于观察真实值。

**为什么这么修**
- 断言本身正确，但文档解释需要反映真实内核 socket 生命周期，避免读者产生错误预期。

---

### 问题 2.2.3 — Test 09 高并发测试仅验证 RX 的理由应补充为断言层面的反向约束

**现象**
- `tests/README.md` 第 230-238 行说明：Test 09 只验证 server RX 总量 > 0 和 client TX 总量 > 0，不验证 server TX。
- `ci/qemu/run-tests.sh` 第 501-532 行实现也仅检查 server `SOCK_COUNT`、`RX_SUM` 和 client `CLI_TX_SUM`。

**为什么是问题**
- 该设计理由是正确的：server 是接收方，其 TX 主要由纯 ACK 组成，不计入 TX；client 是发送方，TX 来自 `sendmsg`。
- 但当前测试**没有验证 server TX 是否确实接近 0**（或仅由 ACK 导致的极小值）。如果代码实现存在 bug，导致 server 端错误地将某些非 sendmsg 路径计入了 TX，Test 09 无法发现。
- 同理，client RX 也应接近 0（只有 ACK），但测试未做约束。

**触发条件**
- 如果 TX 打点被错误地加到了 `tcp_send_ack()` 或其他 ACK 路径，server TX 会异常偏高。
- 如果 RX 打点被错误地加到了纯 ACK 发送路径（理论上不可能，但可作为回归保护），client RX 会异常偏高。

**后果**
- 测试无法防止「TX/RX 计数方向错误」这一类回归问题。

**修法**
1. **增加反向约束**：在 Test 09 中增加检查 `server TX total <= ACK 上限`（例如 <= 10）和 `client RX total <= ACK 上限`（例如 <= 10）。
2. **或单独新增回归测试**：Test 09 保持现状，新增一个专门验证「纯接收方 TX ≈ 0」的测试。
3. **文档同步**：在 README 中说明「server TX 和 client RX 理论上应接近 0，当前 Test 09 未显式断言，建议未来补充」。

**为什么这么修**
- 方向分离验证的核心价值不仅是「正向验证有数据」，还包括「反向验证无数据」。
- 增加反向约束后，可以更有效地守护「TX 只统计 sendmsg 路径」这一设计语义。

---

### 问题 2.3.1 — TCP/UDP 测试未覆盖 splice/zerocopy/corked 等已插桩路径

**现象**
- 内核补丁中已声明插桩了多条 RX/TX 路径：
  - RX: `tcp_read_sock()`（splice 路径）、`tcp_zerocopy_receive()`、`tcp_recvmsg_locked()`；`udp_recvmsg()`、`udpv6_recvmsg()`。
  - TX: `__tcp_transmit_skb()` clone 块、`__tcp_retransmit_skb()` pskb_copy 路径、`udp_sendmsg()`/`udpv6_sendmsg()`、`udp_push_pending_frames()`/`udp_v6_push_pending_frames()`（corked 路径）。
- 但所有测试均使用 iperf3，iperf3 只走普通的 `sendmsg`/`recvmsg` 路径，**不会触发 splice、zerocopy、UDP corked 路径**。

**为什么是问题**
- 项目文档（`kernel-patches/README.md`）已详细说明支持这些路径，但测试方案没有为它们提供回归保护。
- 如果未来这些路径的插桩被意外删除或破坏（例如 `tcp_read_sock()` 中的 `net_delayacct_rx_end()` 被移除），现有测试不会失败。

**触发条件**
- 用户或开发者使用 `splice()`、`TCP_ZEROCOPY_RECEIVE`、`MSG_MORE` / `UDP_CORK` 时，统计结果将不可信。
- 回归测试在重构 RX/TX 插桩时无法发现路径遗漏。

**后果**
- 测试通过不等于「所有声明路径都正常工作」。
- 项目文档与测试覆盖之间存在 gap，降低工程可信度。

**修法**
1. **新增专项测试**：
   - **Test A（splice RX）**：使用 `splice()` 将 TCP socket 数据直接转储到 `/dev/null`，验证 server RX count > 0。
   - **Test B（UDP corked TX）**：使用 `setsockopt(UDP_CORK)` 或 `sendmsg(MSG_MORE)` 发送 UDP 数据，验证 client TX count > 0。
   - **Test C（TCP zerocopy RX）**：使用 `setsockopt(TCP_ZEROCOPY_RECEIVE)` 接收数据，验证 RX count > 0（如工具链支持）。
2. **文档标注**：如果短期内无法增加测试，应在 `tests/README.md` 的「覆盖矩阵」中明确列出「未覆盖路径：splice/zerocopy/UDP corked」，并说明原因（工具链限制或待集成）。
3. **至少验证 corked 路径**：UDP corked 可通过简单的 `nc` + `sendmsg(MSG_MORE)` 或编写一个小的 C 程序在 initramfs 中运行。

**为什么这么修**
- 这些路径是内核实现的重要组成部分，已投入插桩工作，就应提供相应回归测试。
- 即使部分路径因工具限制难以测试，也应在文档中显式声明，避免「测试通过 = 全部覆盖」的误解。

---

### 问题 2.3.2 — 未声明 IPv6 流量路径的实际覆盖情况

**现象**
- `tests/README.md` 第 336-339 行覆盖矩阵声明：「IPv4（loopback 127.0.0.1，所有测试）；IPv6（`[::]` loopback，工具端格式兼容）」。
- 但所有测试实现（`run-tests.sh`）均使用 `127.0.0.1`，没有任何测试实际使用 `::1` 或 `[::]` 产生 IPv6 流量。

**为什么是问题**
- 工具输出格式兼容 IPv6（`local=[::]:port`）不等于 IPv6 数据路径被测试覆盖。
- IPv4 与 IPv6 在 kernel 中的插桩路径不同：UDPv6 使用 `udpv6_recvmsg()` / `udpv6_sendmsg()`，UDPv4 使用 `udp_recvmsg()` / `udp_sendmsg()`。只测 IPv4 无法保证 IPv6 路径没有 bug。
- 项目此前确实修复过 IPv6 相关的 BUG（如 BUG-1 IPv6 UDP RX/TX instrumentation），说明这是一条真实风险。

**触发条件**
- 用户使用 IPv6 地址时，RX/TX 统计可能为 0 或行为异常。
- `udpv6_sendmsg()` 或 `udpv6_recvmsg()` 中的插桩被意外删除时，测试不会失败。

**后果**
- 覆盖矩阵中的「IPv6」声明会误导用户和 reviewer 认为 IPv6 已被测试。

**修法**
1. **新增 IPv6 专项测试**：至少增加一个 Test 使用 `iperf3 -c ::1 -p PORT` 验证 IPv6 TCP 和 UDP 路径均有 RX/TX 统计。
2. **或修正覆盖矩阵**：将「IPv6（`[::]` loopback，工具端格式兼容）」改为「IPv6 工具输出格式兼容；IPv6 流量路径**待专项测试**」。

**为什么这么修**
- 工具格式兼容与数据路径覆盖是两个不同层面的问题，不应混为一谈。
- 明确区分已测试和未测试范围，是对用户和 reviewer 的诚实声明。

---

### 问题 2.3.3 — 无 negative test 验证过滤条件不会误匹配

**现象**
- Test 14-16 验证了 `--proto` / `--lport` / 组合过滤能正确返回匹配项。
- 但没有测试验证：当过滤条件完全不匹配时，输出确实为空；或者当过滤条件部分匹配时，不会错误包含其他 socket。

**为什么是问题**
- 过滤实现中的常见 bug 是「忽略未识别的过滤属性」或「默认返回所有 socket」。
- 当前 Test 15 包含了 `--lport 99999` 的 negative case，这是好的，但 Test 14 和 Test 16 缺少对应的 negative 验证。

**触发条件**
- 如果 `net_delayacct_match_filter()` 在处理 `--proto udp` 时由于常量错误而实际返回所有 socket，Test 14 仍可能通过（因为 baseline 本身包含 TCP 和 UDP）。

**后果**
- 过滤逻辑的 negative path 缺乏回归保护。

**修法**
1. **增强 Test 14**：增加 `--proto tcp` 查询一个只有 UDP 数据 socket 的进程，断言输出中 `proto=tcp = 0`。
2. **增强 Test 16**：增加 `--proto udp --lport $COMB_PORT` 组合，断言输出为空（因为 port 匹配的是 TCP control socket，但 proto 过滤掉了它）。
3. **文档同步**：在 README 中说明 negative test 的覆盖。

**为什么这么修**
- negative test 是过滤功能正确性的重要组成部分，能有效防止「默认返回全部」这类实现缺陷。

---

### 问题 2.4.1 — README 中 Test 03 的语义说明与断言冲突（同 2.1.1）

**现象** 与 **修法** 见上文「问题 2.1.1」。

此处补充：建议在 README 中把「语义说明」提前到「断言」之前，并使用「在停止流量后」作为断言前缀，使阅读顺序更符合逻辑。

---

### 问题 2.4.2 — README 中 3.1 覆盖矩阵对 IPv6 的声明与测试实现不一致（同 2.3.2）

**现象** 与 **修法** 见上文「问题 2.3.2」。

---

## 四、踩坑点评

- 本次审查没有发现新的「踩坑记录」，但需要指出：当前测试方案在 v5.0.0 快速迭代中完成了「数量扩张」（13 → 16 项），但部分用例的设计深度不足。建议在下一轮中从「数量覆盖」转向「路径覆盖」和「并发深度覆盖」。

---

## 五、总体评价

本轮测试方案在功能覆盖、失败诊断、文档说明等方面已达到可用水平，16 个用例能够守护项目的主要功能。但存在以下结构性问题：

1. **Reset 测试的断言与语义矛盾**：需要同步文档和实现，避免误导。
2. **并发测试压力不足**：Test 13 需要增强以覆盖真实 per-socket 并发路径。
3. **已插桩路径未全部回归测试**：splice/zerocopy/corked/IPv6 等路径缺少专项验证。
4. **文档与实现存在不一致**：IPv6 覆盖声明、多 socket 数量解释需要修正。

建议在 v6.0.0 修复周期内优先处理 1、2、3 项，4、5 项可作为文档澄清同步完成。

---

## 六、下版本关注点

- Test 13 是否增强为「空查询 + busy PID 查询」混合模式。
- 是否新增 splice/zerocopy/UDP corked/IPv6 专项测试，或在文档中明确标注未覆盖。
- Test 03 断言是否与 RESET 非原子语义达成一致的表述。
- 过滤测试是否补充 negative case。

---

## 七、对话后修订（2026-07-29）

在与项目维护者讨论后，对以下问题进行了修正和细化：

### 7.1 Test 03 Reset 测试：不应逃避非原子语义

原审查建议「在 `-R` 前停止流量」被指出是在逃避问题。修订后的方案：

- **Test 03a（基础功能）**：停止流量后执行 `-R`，断言所有 count = 0，验证 reset 机制本身。
- **Test 03b（非原子语义验证，新增）**：在 iperf3 client 持续发送中执行 `-R`，立刻查询 server，断言**存在 count > 0 的 socket**；停止 client 后再次 `-R`，断言所有 count = 0。

这样既能验证 reset 能清零，也能验证 RESET 不是全局原子快照的真实语义。

### 7.2 Test 13 并发查询：必须覆盖 busy PID

原审查指出的「仅查 PID 1」问题在讨论中得到进一步澄清：

- PID 1 没有 socket，当前 Test 13 只测试了 Netlink 控制路径和空 fdtable 遍历。
- 真正需要覆盖的场景是：**多个进程同时查询一个持有多个活跃 socket 的 busy PID**，验证 dumpit 在遍历 fdtable、读取 per-socket 统计、执行过滤时的并发安全。
- 推荐实现：部分 worker 查 PID 1，部分 worker 查 iperf3 server PID；可进一步让 worker 交替执行无过滤查询和带过滤查询。

### 7.3 路径覆盖：必须新增专项测试，不能只标注

原审查中提出的「未覆盖路径」不能只靠 README 标注逃避，必须新增测试：

| 新增测试 | 覆盖路径 | 实现思路 |
|----------|----------|----------|
| TCP splice RX | `tcp_read_sock()` | `splice()` 导 TCP socket 数据到 `/dev/null` |
| TCP zerocopy RX | `tcp_zerocopy_receive()` | `setsockopt(TCP_ZEROCOPY_RECEIVE)` 后 recv |
| UDP corked TX | `udp_push_pending_frames()` | `setsockopt(UDP_CORK)` 或 `sendmsg(MSG_MORE)` |
| IPv6 TCP/UDP | `udpv6_recvmsg/sendmsg` | `iperf3 -c ::1 -p PORT` 跑 TCP/UDP |

### 7.4 Test 09/10 方向分离：原表述不严谨

原审查中「server TX 只有 ACK」的说法不严谨。准确表述：

- 在 iperf3 单向测试中，server TX **以 ACK 为主**，但也可能包含重传、窗口探测等。
- 方向分离设计仍合理（在预期有数据的方向检查），但应增加反向约束：server TX 应接近 0 或远小于 client TX；client RX 应接近 0。
- 建议**新增双向流量测试**（iperf3 `-R` 反向模式），验证同一 socket 上 RX 和 TX 同时有数据。

### 7.5 遍历 socket 的非原子性解释

通过时间线示例澄清了 RESET/dump 遍历 socket 的非原子性：

- 单个 socket 的清零/读取在 `n->lock` 保护下是原子的，不会发生数据损坏。
- 但遍历所有 socket 需要时间，在这期间新包仍可到达已重置/已读取的 socket。
- 因此「所有 socket 同时为零」的全局快照不存在，这是内核批量统计接口的通用设计。

### 7.6 修订后的修复优先级清单

#### 高优先级（必须修复）
1. Test 03 拆分为「基础功能」+「非原子语义验证」两个测试。
2. Test 13 增强为「空 PID 查询 + busy PID 查询」混合并发压力测试。
3. 新增 splice/zerocopy/corked/IPv6 专项测试。

#### 中优先级（建议修复）
4. Test 06 README 修正 server socket 数量解释。
5. Test 09/10 增加反向约束，并新增双向流量测试。
6. Test 14/16 补充 negative case。

#### 低优先级（文档澄清）
7. README 覆盖矩阵区分「已测试」和「待测试」路径。
8. README 增加 RESET 非原子语义的时间线说明。

---

## 八、复审报告（2026-07-29 晚间）

### 8.1 状态

- **复审范围**: Worker 2026-07-29 工作日志（TASK-26 / TASK-27）及对应代码变更
- **复审人**: Reviewer
- **状态**: [审查中] → 修复已验证，剩余 2 个低/中问题待 Worker 回应
- **验证结果**: QEMU 22 项测试全部运行，21 PASS / 0 FAIL / 1 SKIP（Test 20 因内核不支持 TCP_ZEROCOPY_RECEIVE 优雅 SKIP）

### 8.2 原审查问题闭环状态

| 问题编号 | 严重度 | 结论 | Worker反馈 |
|----------|--------|------|-------------|
| 2.1.1 Test 03 重置断言矛盾 | 中 | 已按「Test 03 基础 + Test 17 非原子」方案修复 | 已修复 |
| 2.1.2 Test 13 仅查 PID 1 | 中 | 已改为 4 空 PID + 4 busy PID 混合，80 查询 | 已修复 |
| 2.2.1 Test 13 并发压力不足 | 高 | busy PID 路径已覆盖，并发深度受 TCG 性能限制，当前参数可接受 | 已修复 |
| 2.2.2 Test 06 socket 数量解释 | 中 | README 已修正为「≥6，可能因 TIME-WAIT 更高」 | 已修复 |
| 2.2.3 Test 09 反向约束 | 低 | 已增加 server TX ≤ client TX/10 | 已修复 |
| 2.3.1 已插桩路径未回归测试 | 高 | 新增 Test 19-22 + delayacct_path_test 辅助程序 | 已修复 |
| 2.3.2 IPv6 覆盖声明不一致 | 中 | 新增 Test 22 IPv6 专项测试，README 已同步 | 已修复 |
| 2.3.3 过滤无 negative case | 中 | Test 14/16 已补充 negative case | 已修复 |
| 2.4.1 Test 03 README 冲突 | 中 | README 已重写 Test 03 语义说明 | 已修复 |
| 2.4.2 IPv6 覆盖矩阵 | 低 | README 覆盖矩阵已更新 | 已修复 |

### 8.3 复审中发现的新问题

| # | 严重度 | 问题描述 | 建议 | Worker反馈 |
|---|--------|----------|------|-------------|
| 1 | 低 | `wait $WORKER_PIDS 2>/dev/null \|\| true` 掩盖了 worker 真实退出码，调试时无法区分「worker 自身失败」和「wait 语法问题」 | 改为 `wait $WORKER_PIDS` 或单独检查 `$?`，至少保留 stderr 用于诊断 | 接受 — 已改为显式捕获 `$?` 并打印诊断信息，同时保留 `_CRASH` 计数器 |
| 2 | 中 | delayacct_path_test zerocopy 路径经修复后仍 SKIP，但日志显示 QEMU 内核不支持 TCP_ZEROCOPY_RECEIVE；若该特性在 CI 物理机上也不支持，则 Test 20 将长期 SKIP，失去回归保护意义 | 在支持 zerocopy 的环境手动验证 Test 20 确实能 PASS；如长期 SKIP，考虑在内核 config 中显式启用相关依赖，或把该测试标记为「环境依赖」而非「核心回归」 | 接受 — 根因是 helper 误用匿名 mmap，已改为 `mmap(cfd)`；`CONFIG_MMU=y` 已在 kernel.config.fragment 显式声明；README 已更新；待 QEMU 验证 |
| 3 | 低 | Test 13 源码注释从 `_wid < 8` 改为 `_label` 后仍有残留旧注释（已发现 Worker 已修复） | 保持注释与代码一致 | 已修复 |

#### 问题 8.3.1 — `wait $WORKER_PIDS 2>/dev/null || true` 掩盖 worker 失败

**现象**
[run-tests.sh#L825](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L824-L825) 中修复后的 wait 语句为：
```bash
wait $WORKER_PIDS 2>/dev/null || true
```

**为什么是问题**
- `wait` 在 bash 中如果接收到信号或任一被等待进程以非零退出，会返回非 0 退出码。
- 用 `|| true` 把整个 wait 结果吞掉后，即使某个 worker 进程因为 `get_sockdelays` 崩溃、段错误或被 OOM kill，测试框架也感知不到。
- 当前 Test 13 的崩溃检测依赖「worker 输出文件不存在」(`_CRASH` 计数器)，但 worker 崩溃后可能留下不完整的输出文件，也可能在 `wait` 失败之前就由 shell 重定向写入了空文件。这两种路径都可能让 `_CRASH` 统计不准确。

**触发条件**
- 某个 worker 子进程异常退出（例如 `get_sockdelays` 触发断言、被信号终止、网络栈异常）。
- 测试失败排查时，无法从 `wait` 的返回码判断是 worker 失败还是 wait 自身被信号中断。

**后果**
- 潜在的并发回归（如 per-socket spinlock 导致 `get_sockdelays` 死锁后超时退出）可能被掩盖。
- 调试信息减少：只知道 "80 queries ok"，但不知道是否有 worker 异常退出。

**修法**
1. **推荐方案**：移除 `|| true`，改为 `wait $WORKER_PIDS`，让 wait 的真实退出码保留。
2. 如果确实需要忽略某些信号，可以单独检查 `$?` 并打印诊断：
   ```bash
   wait $WORKER_PIDS
   _wait_rc=$?
   if [ "$_wait_rc" -ne 0 ]; then
       echo "    [diag] wait returned $_wait_rc (some worker may have failed)"
   fi
   ```
3. 同时保留 `_CRASH` 计数器作为补充检测。

**为什么这么修**
- wait 的退出码能反映被等待进程的状态；吞掉它会降低测试框架的可观测性。
- Test 13 的断言已经是「无 worker 崩溃 + busy_ok > 0」，不需要靠 `|| true` 来避免整体失败。

#### 问题 8.3.2 — Test 20 TCP zerocopy RX 长期 SKIP 的风险

**现象**
[tests/helper/delayacct_path_test.c#L204-L220](file:///home/lai/Code/NET_DELAYACCT/tests/helper/delayacct_path_test.c#L204-L220) 中 zerocopy server 使用 `getsockopt(TCP_ZEROCOPY_RECEIVE)`，当内核不支持时返回 exit 3，[run-tests.sh#L1287](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L1286-L1287) 据此 SKIP。
当前 QEMU 测试结果：Test 20 SKIP（`kernel does not support TCP_ZEROCOPY_RECEIVE (getsockopt failed)`）。

**为什么是问题**
- Test 20 的设计目标是回归保护 `tcp_zerocopy_receive()` 的 RX 打点。
- 如果 CI 环境（GitHub Actions 的 Ubuntu runner + KVM）也不支持 `TCP_ZEROCOPY_RECEIVE`，则 Test 20 每次都会 SKIP，无法发现该路径插桩被意外删除或破坏。
- 这会使得「新增专项测试」的目标部分落空：测试存在但无法实际执行。

**触发条件**
- 内核没有启用 `CONFIG_TCP_ZEROCOPY_RECEIVE`（linux-6.6 中该选项可能默认关闭，或需要特定网卡/配置）。
- QEMU loopback / e1000 环境可能不支持 zerocopy 接收路径。

**后果**
- 如果未来 `tcp_zerocopy_receive()` 中的 `net_delayacct_rx_end()` 被移除，Test 20 不会失败，失去回归保护。
- 测试计数 22 项中实际有效回归只有 21 项。

**修法**
1. **立即验证**：在支持 zerocopy 的物理机/VM 上运行 Test 20，确认 helper 和 run-tests.sh 的交互能正确 PASS。
2. **内核配置检查**：检查 linux-6.6 的 `CONFIG_TCP_ZEROCOPY_RECEIVE` 默认值；如默认关闭，在 `ci/kernel.config.fragment` 或 `ci/qemu/kernel-qemu.config` 中显式启用。
3. **文档透明化**：在 README / 测试输出中说明 Test 20 的 SKIP 是「环境不支持」而非「测试未实现」，并给出判断内核是否支持的方法。
4. **备选方案**：如果确实无法在所有 CI 环境启用，可考虑在 CI 中跳过该测试，但需在 README 的覆盖矩阵中明确标注「tcp_zerocopy_receive 仅在支持 TCP_ZEROCOPY_RECEIVE 的环境回归」。

**为什么这么修**
- 专项测试的价值在于实际执行；长期 SKIP 等同于未覆盖。
- 先确认是配置问题还是环境固有限制，再决定是否调整 CI 或文档。

### 8.4 验证结果

修复后 QEMU TCG 测试结果：

```
Tests run:  22     PASS: 22     FAIL:  0     SKIP:  0
RESULT: ALL PASS

Test 13: 80 queries (ok=80 fail=0 busy_ok=40), no oops
Test 20: PASS — zerocopy RX path covered: tcp=1 RX_sum=1662 (>0)
```

### 8.5 评分更新

| 审查项 | 初评分 | 复审评分 | 说明 |
|--------|--------|----------|------|
| 代码质量 | 7/10 | 8/10 | 修复了 wait 死锁、API 误用、过滤假设错误；helper 程序结构清晰 |
| 设计合理性 | 6/10 | 8/10 | 22 项测试设计合理，混合并发覆盖真实 per-socket 路径 |
| 测试覆盖 | 6/10 | 9/10 | 已插桩路径基本覆盖，仅剩 Test 20 环境支持问题 |
| 文档/日志质量 | 7/10 | 8/10 | 文档与实现基本一致，工作日志详细记录了踩坑过程 |
| **综合评分** | **6.5/10** | **8.25/10** | 显著提升，建议修复 8.3.1 和 8.3.2 后闭环 |

### 8.6 下版本 / 闭环前关注点

- 处理 8.3.1：`wait $WORKER_PIDS` 返回值处理。
- 处理 8.3.2：验证 Test 20 在支持 zerocopy 环境是否 PASS，或调整 CI 配置/文档。
- 更新 project_memory.md 中已记录的教训（Worker 已更新，建议确认条目准确性）。

---

## 九、闭环检查（2026-07-29 23:05）

### 检查方法

遍历 `REVIEW_REPORT.md` 全文中所有问题的 `Worker反馈` 列，统计最终状态。

### 状态统计

| 状态 | 数量 | 问题编号 |
|------|------|----------|
| 已修复/已接受 | 13 | 2.1.1, 2.1.2, 2.2.1, 2.2.2, 2.2.3, 2.3.1, 2.3.2, 2.3.3, 2.4.1, 2.4.2, 8.3.1, 8.3.2, 8.3.3 |
| [待回应] | 0 | — |
| [讨论中] | 0 | — |

### 结论

**本轮 Review 所有议题均已获得 Worker 反馈（接受/已修复），零遗留。**

- 8.3.1：已接受，代码已改为显式捕获 `wait` 退出码并打印诊断。
- 8.3.2：已接受，根因为 helper 匿名 mmap 误用，已改为 `mmap(cfd)`；`CONFIG_MMU=y` 已在 `ci/kernel.config.fragment` 显式声明；README 已更新。

**当前状态：[闭环完成]** — `local-test.sh --qemu-only` 已验证：22 项测试全部 PASS（含 Test 20，RX_sum=1662），0 FAIL / 0 SKIP。

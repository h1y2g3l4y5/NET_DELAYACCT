# NET_DELAYACCT 测试体系说明

> 本文档描述项目的完整测试体系，可作为 PR / patch series 提交时的测试说明材料。
> 对应实现：`ci/qemu/run-tests.sh`（功能测试）、`perf-test.sh` + `ci/qemu/run-perf-tests.sh`（性能测试）、
> `.github/workflows/ci.yml`（CI 编排）。

## 1. 测试金字塔总览

```
Layer 3  性能测试 (perf-test job)   K0 vs K3 开销对比：微基准 + ftrace 对账，
                                    三态判定 + 噪声地板校验
Layer 2  动态验证 (Test 23-25)      ftrace 打桩点全量验证、kprobe per-skb 配对、
                                    纯 ACK 守卫
Layer 1  功能测试 (Test 01-22)      查询/路径/过滤/压力/边界/语义，25 个场景
Layer 0  静态检查 (checkpatch)      内核补丁规范检查
```

设计原则：**正确性靠功能测试，开销靠性能测试，两者解耦**——功能测试只跑 ON 内核
（验证行为正确），性能测试跑 ON/OFF 内核对比（量化开销），各自独立 job、独立超时兜底。

## 2. CI 流程

```
push ─→ checkpatch（补丁规范）
     ─→ Build kernel (on)   CONFIG_NET_DELAYACCT=y（带插桩）
     ─→ Build kernel (off)  原生基线
     ─→ Build get_sockdelays（用户态查询工具）
     ─→ QEMU 功能测试（KVM，Test 01-25）
     ─→ QEMU 性能测试（本地 self-hosted runner，KVM，6 次 boot）
```

## 3. 功能测试：25 个场景（ci/qemu/run-tests.sh）

所有场景在 QEMU 内以 initramfs 启动 ON 内核执行，流量走 loopback。
工具缺失时优雅降级（SKIP 而非 FAIL）。

### 第一部分：基础功能（Test 01-06）

> **验证目的**：单连接、小流量下的功能存在性与逻辑正确性（happy path）。
> 断言形态为"存在性"：查询能返回、计数 >0、inode 精确匹配。

| # | 场景 | 方法 | 判定要点 |
|---|------|------|---------|
| 01 | PID 查询 | iperf3 客户端传输中按 PID 查询 | proto=tcp 行存在且 RX/TX 计数正确 |
| 02 | Inode 查询 | nc 监听端，从 `/proc/<PID>/fd` 提取 socket:[inode] 后按 inode 查询 | 输出 inode 精确匹配 |
| 03 | 重置计数器 | 流量积累 count>0 后执行 `-R`，再查询 | PRE 必须 count>0（消除 0→0 假阳性），POST 清零（≤1 容忍 FIN 残包） |
| 04 | TCP 路径 | iperf3 TCP 传输中查询 server | proto=tcp ≥1 且 RX>0（硬断言，打点必须工作） |
| 05 | UDP 路径 | iperf3 UDP 传输中查询两端 | server RX>0 且 client TX>0（验证打点而非仅枚举） |
| 06 | 多 Socket 枚举 | iperf3 -P 4 四条并行流 | server ≥6 socket（枚举完整）+ RX>0 |

### 第二部分：工具展示（Test 07-08）

| # | 场景 | 方法 | 判定要点 |
|---|------|------|---------|
| 07 | JSON 输出 | `-j` 查询 | 输出含 "proto"/"rx" 字段，可程序解析 |
| 08 | Debug 模式 | `-d` 合并捕获 stderr | 含 netlink/nlmsg 诊断关键字 |

### 第三部分：压力测试（Test 09-11）

> **验证目的**：与第一部分的区别——第一部分用单连接验证功能"有没有、对不对"；
> 本部分验证**规模与负载下的正确性**：多连接下枚举是否完整、大流量下计数是否
> 溢出/截断、混合协议下统计是否隔离。断言形态从"存在性"（RX>0）升级为
> "完整性/隔离性"（socket≥21、TCP server 的 udp=0）。
> 注：-P 20 验证的是"几十个 socket 级别的枚举完整性"，并非万级连接规模测试。

| # | 场景 | 方法 | 判定要点 |
|---|------|------|---------|
| 09 | 高并发多连接 | iperf3 -P 20 | server socket≥21（1 监听 + 20 数据）且 RX>0；client TX>0；反向 server TX ≤ client TX/10（纯 ACK 不走 sendmsg） |
| 10 | 大流量高计数 | iperf3 -P 4 不限速 | 计数不溢出不截断（server RX≥50 且 client TX≥50，TCG 保守阈值） |
| 11 | 混合协议隔离 | TCP+UDP 同时传输 | 统计按协议隔离无交叉污染 |

### 第四部分：边界条件（Test 12）

| # | 场景 | 方法 | 判定要点 |
|---|------|------|---------|
| 12 | 极端输入 | PID 1 / 不存在 PID / -h / -V | 不崩溃、合理报错，4 项子检查全过 |

### 第五部分：稳定性（Test 13）

| # | 场景 | 方法 | 判定要点 |
|---|------|------|---------|
| 13 | 并发查询压力 | 4 worker 查空 PID + 4 worker 查 busy PID × 10 次 | 无死锁/竞态/Oops，dmesg 干净，busy 查询成功 >0 |

### 第六部分：过滤功能（Test 14-16）

| # | 场景 | 方法 | 判定要点 |
|---|------|------|---------|
| 14 | 协议过滤 | `--proto tcp` / `--proto udp` | 内核侧筛选，只返回指定协议 |
| 15 | 端口过滤 | `--lport <port>` | 只返回匹配本地端口的 socket |
| 16 | 组合过滤 | `--proto tcp --lport` | AND 语义，两条件同时生效 |

### 第七部分：语义验证 + 路径覆盖（Test 17-22）

> **验证目的**：黑盒**行为语义**与冷门**路径覆盖**。T17/T18 纯查询断言语义
> （不用 ftrace）；T19-21 覆盖 splice/zerocopy/corked 等冷门内核路径——
> 其中的 ftrace 只是**辅助手段**：证明测试流量真的走了专属函数（如
> tcp_read_sock），否则 RX>0 可能来自其他路径，路径覆盖就名存实亡。

| # | 场景 | 方法 | 判定要点 |
|---|------|------|---------|
| 17 | Reset 非原子语义 | 流量持续发送中执行 -R 后立即查询 | 仍存在 count>0 的 socket（reset 不冻结后续流量） |
| 18 | 双向流量 | iperf3 -R 反向 | 同一 socket RX>0 且 TX>0（双向都被统计） |
| 19 | splice RX 路径 | splice→/dev/null | tcp_read_sock 被调用（ftrace 验证）+ RX>0 |
| 20 | zerocopy RX 路径 | TCP_ZEROCOPY_RECEIVE | tcp_zerocopy_receive 被调用 + RX>0（内核不支持时 SKIP） |
| 21 | UDP corked TX 路径 | UDP_CORK flush | udp_push_pending_frames 被调用 + TX>0 |
| 22 | IPv6 路径 | iperf3 -c ::1 | udpv6/tcpv6 sendmsg/recvmsg 打点工作 |

### 第八部分：ftrace 打桩点全量验证（Test 23）

> **验证目的**：与第七部分的区别——T19-21 是"每场景定点验证 1 个函数"
> （证明流量路径真实性），本测试是**系统性覆盖广度矩阵**：16 个函数 × 8 个
> 场景（S1-S8，含 T19-21 没有的 TCP 重传 netem、IPv6 UDP corked 场景）
> 逐一断言，且包含 3 个 start/end 函数的直接追踪（验证插桩内部逻辑被精确执行，
> 而不只是父函数被调用）。

对 **16 个函数 × 8 个场景**做 ftrace function tracer 全量验证：
13 个父函数（覆盖全部打桩点的调用上下文）+ 3 个 start/end 直接追踪函数
（`net_delayacct_{rx_end,tx_start,tx_end}`，验证内部逻辑被精确执行）。
每场景启用 ftrace filter → 运行流量 → 断言预期函数调用次数 >0。
环境不具备（CONFIG_FTRACE 关闭 / tracefs 不可写）时返回 SKIP。

### 第九部分：kprobe 动态验证（Test 24-25）

> **验证目的**：与第八部分的区别——ftrace function tracer 只能记录"函数被
> 调用"，抓不了参数。本部分用 kprobe events 抓 skb 指针，验证**参数级配对
> 语义**（per-skb 集合包含关系）。T25 是全测试集唯一的**负向断言**
> （验证"不该计的没计"），与其余正向断言（"该计的计了"）互补。

| # | 场景 | 方法 | 判定要点 |
|---|------|------|---------|
| 24 | per-skb 配对 | kprobe events 抓 skb 指针（`%si:u64` 寄存器语法，不依赖 BTF） | 强断言：set(tx_end_skb) ⊆ set(tx_start_skb)；弱断言：计数比 ∈ [0.5, 2.0] |
| 25 | 纯 ACK 守卫 | iperf3 server 纯接收方 | TX=0（纯 ACK 被 `if (!start || !sk) return` 守卫跳过）且 RX>0（排除假阳性） |

## 4. 性能测试（perf-test.sh）

### 4.1 要回答的问题（大白话）

**给内核装上 net_delayacct 这套"打卡机"之后，网络到底慢了多少？**

### 4.2 为什么不用 iperf3 测（旧方案失败的原因）

相当于**在高速公路上测一个收费站对车速的影响**：

- 收费站耗时（hook 开销）固定就那么点，在 21.5Gbps 的大流量里被摊薄到 ~1%
- 而测试环境本身在晃（共享服务器上的 QEMU，调度漂移 5-50%）——
  **"地基本身的晃动"比"要测的差异"还大**，测出来的数字没有意义
- 这就是"信噪比倒挂"：信号（要测的开销）< 噪声（环境的晃动）

### 4.3 新方法：不测高速公路，测"小区绕圈"（微基准）

用固定工作量微基准 bench-net 替代 iperf3：

- 同一个 64 字节小包，自发自收**固定圈数**，掐秒表比总耗时（ns/op）
- 小包每圈只要 2-5us，打卡机每圈响 4 次、每次 ~100ns，
  **占比 5-20%——一眼能看出来**，不再被稀释
- 工作量固定（跑固定圈数，不跑固定时长），环境的瞬时抖动无法"改变工作量"，
  只能影响总耗时，噪声天然变小

### 4.4 为什么同一套东西要开 6 次虚拟机

```
WARM (OFF, 预热丢弃) → K0 (OFF 基线) → K3 (ON 带插桩) → K0R → K3R → K0B
```

- OFF 内核（没装打卡机）开 3 次有效启动，ON 内核（装了）开 2 次
- **同一内核两次启动之间也有差异**（虚拟机每次开机被宿主机随机放到不同 CPU 上）
  ——这个差异就是"噪声地板"，用 OFF↔OFF、ON↔ON 的启动对来量化
- 判定铁律：**OFF↔ON 的差异必须大于噪声地板**，否则分不清是"装了打卡机
  变慢"还是"环境自己晃的"→ 老实报 INVALID，不硬给结论
- WARM 是预热开机：第一次开机 CPU 频率/缓存都是冷的，数据偏慢，丢弃

### 4.5 两条独立证据互相印证（ftrace 对账）

秒表量出"ON 比 OFF 每圈慢 722ns"，这个数可信吗？用另一种方法独立验证：

1. 用 ftrace 数：**每圈打卡机响几次**（4.2 次）
2. 用 ftrace 量：**打一次卡多久**（p50 = 383ns）
3. 相乘 = 预测开销 ≈ 1609ns，与秒表量出的 722ns 同数量级 ✓

两种完全独立的方法对上了，才能说"这个开销确实来自打卡机，不是环境噪声"。

### 4.6 四支柱一览

| 支柱 | 大白话 | 角色 |
|------|--------|------|
| Perf-A bench-net | 小区绕圈掐秒表（UDP64 / TCP 1KB 两圈型） | **主判定**（阈值 25%） |
| Perf-B ftrace 对账 | 数打卡次数 × 单次耗时，与秒表互证 | 交叉验证 |
| Perf-C slab objsize | 每个 socket 多占多少字节（2240→2368B） | 确定性内存开销，零噪声 |
| Perf-D dump 计时 | 查询工具单次导出耗时 | info 参考 |

### 4.7 判定规则

- **PASS**：ON 确实变慢了（方向正确），且幅度在阈值内（<25%）
- **INVALID**（老实作废，两种情况）：
  - ON 反而更快了——装了东西不可能更快，说明是噪声在主导
  - 差异比噪声地板还小——分不清是真差异还是开机晃动
- **NO-DATA**：全部场景没跑成（全 SKIP）→ CI 阻断；FAIL/INVALID 只告警
  不阻断——性能是趋势信号，不是硬门槛

## 5. 典型结果解读（run #182，报告 20260818_011516）

| 指标 | K0 (OFF) | K3 (ON) | Δ | 判定 | 大白话 |
|------|-----|-----|-----|------|--------|
| bench_udp64_ns_per_op | 4438.7 | 5161.1 | **+16.3%** | PASS | 64B 小包每圈慢 16.3%，在阈值内 |
| bench_tcprw_ns_per_op | 10802.1 | 10769.8 | -0.3% | INVALID | 1KB 大包里打卡占比被稀释，测不出 |
| sock_objsize_bytes | 2240 | 2368 | +128B | PASS | 每个 socket 多占 128 字节（确定性） |
| ftrace 对账 | — | 4.2 次 × 383ns | 预测 1609ns vs 实测 722ns | ✓ | 两种方法对上了 |
| 噪声地板 | udp64 13.9% | — | 信号 16.3% > 地板 13.9% | 可用 | 差异比开机晃动大，分得清 |

结论三依据：幅度落在理论预测区间（5-20%）；方向正确（变慢而非变快）；
两条独立证据互相印证。

## 6. 环境要求

- 功能测试：QEMU（KVM 优先，TCG 兜底），ON 内核 bzImage + initramfs
- Test 23/24 需 CONFIG_FTRACE + 可写 tracefs（缺失时 SKIP）
- 性能测试：KVM 强制（TCG 下 hook 耗时膨胀 10x，仅作冒烟）；self-hosted runner
- 内核：基于 Linux 6.6，CONFIG_NET_DELAYACCT=y（on）/n（off）双构建

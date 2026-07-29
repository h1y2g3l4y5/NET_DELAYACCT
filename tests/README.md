# NET_DELAYACCT 测试套件

## 一、测试基础设施

### 1.1 整体架构

```
GitHub Actions CI
├── checkpatch    → 内核 patch 代码风格检查（checkpatch.pl --strict）
├── build-kernel  → 打 patch → 编译 bzImage（ccache 加速）
├── build-tool    → 编译用户态 get_sockdelays（libmnl 依赖）
└── qemu-test     → 打包 initramfs → QEMU 启动 → guest-init → run-tests.sh → poweroff
```

本地测试入口：[local-test.sh](file:///home/lai/Code/NET_DELAYACCT/local-test.sh)，支持三种模式：

```bash
./local-test.sh                # 完整流程：编译内核 + 工具 + QEMU 测试
./local-test.sh --kernel-only  # 仅编译内核
./local-test.sh --qemu-only    # 仅 QEMU 测试（假设内核已编译）
```

测试日志自动保存到 `tests/reports/local/test-YYYYMMDD_HHMMSS.log`。

### 1.2 QEMU 虚拟机环境

| 组件 | 说明 |
|------|------|
| 内核 | 打上所有 `kernel-patches/*.patch` 的 linux-6.6，`CONFIG_NET_DELAYACCT=y` |
| 文件系统 | 内存 initramfs（busybox + bash + iperf3 + nc(ncat) + get_sockdelays） |
| 网络 | `-netdev user` user-mode 网络，e1000 网卡，`lo` 回环（`ip link set lo up`） |
| 加速 | KVM 优先（90s 超时），不可用则降级 TCG（240s 超时，阈值取保守值） |
| init | [ci/qemu/guest-init.sh](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/guest-init.sh)：挂载 /proc/sys/dev → 诊断（genl family 验证 + dmesg）→ 调 `run-tests.sh` → 写结果到 /root/test-output.txt → poweroff |
| watchdog | `sleep 360; poweroff -f` 防测试挂死（QEMU 内部）；CI 层另有 QEMU_TIMEOUT_KVM=90s / QEMU_TIMEOUT_TCG=240s 硬超时 |

### 1.3 流量生成工具

| 工具 | 用途 | 关键参数说明 |
|------|------|-------------|
| `iperf3 -P N -t T` | TCP 多流数据传输 | `-P N` 产生 N 条并行数据流；server 侧不 fork，所有数据 socket 可见；client fork 子进程 |
| `iperf3 -u -b BW -t T` | UDP 数据流传输 | `-u` UDP 模式，`-b 10M` 限速 10Mbps；UDP 模式仍会创建 TCP 控制连接 |
| `nc -l -p PORT` | 创建单个 TCP 监听 socket | 用于 inode 查询等轻量级场景；ncat 兼容 |

### 1.4 判定框架（[ci/qemu/run-tests.sh](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh)）

```bash
_PASSED=0   _FAILED=0   _SKIPPED=0   _TEST_NUM=0

_pass()   { echo "    [PASS] $*"; _PASSED=$((_PASSED + 1)); }
_fail()   { echo "    [FAIL] $*"; _FAILED=$((_FAILED + 1)); }
_skip()   { echo "    [SKIP] $*"; _SKIPPED=$((_SKIPPED + 1)); }
_require  # 命令不存在 → SKIP + return 1（不崩溃，依赖缺失时优雅降级）

_show_output()   # 失败时打印 get_sockdelays 原始输出 + 协议/计数摘要 + 进程存活状态
_output()        # 成功时也打印工具输出（宽度自适应盒式框）
_desc()          # 打印测试原理/实现/断言三行说明
```

末尾框式汇总：

```
╔══════════════════════════════════════════════════════════════╗
║  NET_DELAYACCT Test Results                                  ║
╠══════════════════════════════════════════════════════════════╣
║  Tests run: 16     PASS: 16     FAIL:  0     SKIP:  0       ║
╠══════════════════════════════════════════════════════════════╣
║  RESULT: ALL PASS                                            ║
╚══════════════════════════════════════════════════════════════╝
```

退出码：有 FAIL 则返回 1，全部 PASS 返回 0（CI 据此判断 job 成功/失败）。

### 1.5 失败诊断机制

当测试失败时，`_show_output()` 自动打印：

- 触发失败的具体条件（预期值 vs 实际值）
- `get_sockdelays` 的原始输出（stdout + stderr 合并，缩进展示）
- 协议摘要：`proto=tcp` 行数、`proto=udp` 行数、总行数、RX 总量、TX 总量
- 进程存活状态（`kill -0 $PID` 检测是否仍在运行）
- Test 13 额外检查 `dmesg` 中是否有 `Kernel panic` / `Oops:` / `BUG:`

示例输出：

```
    [FAIL] data_lines=0, proto=tcp=0
    +-- get_sockdelays -p 12345 ---
    | (empty output)
    | summary: lines=0   (tcp=0   udp=0  ) rx_sum=0      tx_sum=0
    | PID 12345: not running (exited)
    +---------------
```

### 1.6 端口分配

测试使用端口范围 **21401-21417**，每个测试分配独立端口，避免并行冲突：

| Test | 端口 |
|------|------|
| Test 01 | 21401 |
| Test 02 | 21402 |
| Test 03 | 21403 |
| Test 04 | 21404 |
| Test 05 | 21405 |
| Test 06 | 21406 |
| Test 07 | 21407 |
| Test 08 | 21408 |
| Test 09 | 21409 |
| Test 10 | 21410 |
| Test 11 | 21411/21412 |
| Test 14 | 21414/21415 |
| Test 15 | 21416 |
| Test 16 | 21417 |

---

## 二、测试用例详解（共 16 项）

测试按功能分为六个部分。

---

### 第一部分：基础功能（Test 01-06）

验证 `get_sockdelays` 的核心查询能力——能否正确查到 socket 统计。

---

#### Test 01: PID 查询

| 项目 | 内容 |
|------|------|
| **原理** | `get_sockdelays -p <PID>` 通过 Generic Netlink 内核接口（标准 dumpit 协议）查询指定进程持有的所有 socket 统计 |
| **实现** | 启动 iperf3 TCP server（端口 21401）→ iperf3 client `&` 后台运行 → `sleep 2` 在传输进行中查询 client PID |
| **断言** | 输出中 `proto=` 开头的数据行 ≥ 1，且至少包含 1 个 `proto=tcp` |
| **时序关键** | client 必须 `&` 后台运行，否则 5s 传输结束后进程退出，查询时 socket 已被内核清理 |
| **清理** | `kill` 掉 server 和 client，`wait` 回收 |

---

#### Test 02: Inode 查询

| 项目 | 内容 |
|------|------|
| **原理** | 每个 socket 在内核 sockfs 中有唯一 inode 号。`/proc/<PID>/fd/<N>` 的符号链接格式为 `socket:[inode]`，可提取 inode 后通过 `get_sockdelays -i <inode>` 查询单个 socket |
| **实现** | `nc -l -p 21402 &` 创建 TCP 监听 socket → 遍历 `/proc/$PID/fd/*`，`readlink` 提取 `socket:\[数字\]` 中的 inode → `get_sockdelays -i $INODE` |
| **断言** | 输出中包含 `inode=$INODE` |
| **依赖** | `/proc` 文件系统已挂载（guest-init 中 `mount -t proc`） |

---

#### Test 03: 重置计数器

| 项目 | 内容 |
|------|------|
| **原理** | `get_sockdelays -R` 向内核发送 `NET_DELAYACCT_CMD_RESET` 命令，遍历所有 socket 调用 `net_delayacct_reset()` 清零 per-sock 统计 |
| **实现** | iperf3 TCP 传输 3s → 查询 server PID 确认有数据（`PRE_DATA` 行 ≥ 1）→ 执行 `-R` → `sleep 1` 后再次查询 → 检查所有 `count=` 字段是否全为 0 |
| **断言** | 重置后 `count > 0` 的行数 = 0 |
| **语义说明** | RESET 不是全局原子快照，遍历期间新到达的包仍会被累加（与 `/proc/net/snmp` 等批量统计框架一致） |

---

#### Test 04: TCP 路径

| 项目 | 内容 |
|------|------|
| **原理** | 验证内核 per-socket 延迟统计对 TCP socket 的追踪能力——RX 打点（`tcp_recvmsg_locked`/`tcp_read_sock`/`tcp_zerocopy_receive`）是否正常工作 |
| **实现** | iperf3 TCP（端口 21404）传输 5s → 传输完成后查询 server PID |
| **断言** | `proto=tcp` 行 ≥ 1；若有 `RX count≥1` 则标 PASS，否则因 timing 边缘情况也给 PASS 但标注 "(timing)" |
| **容错** | 传输结束到查询之间可能有延迟，导致 skb 已被清空；只要能枚举到 TCP socket 即可通过 |

---

#### Test 05: UDP 路径

| 项目 | 内容 |
|------|------|
| **原理** | 验证内核 per-socket 延迟统计对 UDP socket 的追踪能力。UDP 无连接，end 点在 `skb_copy_and_csum_datagram_msg()` 成功之后，统计行为与 TCP 不同 |
| **实现** | iperf3 UDP（端口 21405，`-u -b 10M -t 5`）→ client `&` 后台运行 → `sleep 2` 同时查询 client 和 server 两端 |
| **断言** | 两端 `proto=udp` 总数 ≥ 1（UDP socket 可能只在一侧可见） |
| **关键设计** | client 必须 `&`，否则同步阻塞 5s 后 UDP 数据 socket 已被关闭；两端同时查避免单端 socket 已清理导致误判 |

---

#### Test 06: 多 Socket 枚举

| 项目 | 内容 |
|------|------|
| **原理** | 验证一个进程持有多个 socket 时，`get_sockdelays` dumpit 遍历 `files_struct` 能否全量枚举，不遗漏 |
| **实现** | iperf3（端口 21406）`-P 4` 产生 4 条并行 TCP 流 → `sleep 2` 后分别查询 client（父进程）和 server |
| **断言** | client 父进程 ≥ 1 个 TCP socket（control 连接），server ≥ 6 个 TCP socket（1 listen + 1 control + 4 data） |
| **关键设计** | iperf3 `-P N` 会 fork 子进程处理数据连接，client 父进程 fd 表中只有 control socket；server 不 fork，所有数据 socket 在主进程可见 |

---

### 第二部分：工具展示（Test 07-08）

验证 `get_sockdelays` 的辅助输出功能。

---

#### Test 07: JSON 格式输出

| 项目 | 内容 |
|------|------|
| **原理** | `get_sockdelays -j` 将 socket 统计以 JSON 格式输出（包含 `proto`、`local`/`remote` 五元组、`rx`/`tx` 统计对象），便于程序解析 |
| **实现** | iperf3 TCP（端口 21407）传输中查询 `-j -p $SERVER_PID` |
| **断言** | 输出中 `"proto"` 字段出现 ≥ 1 次且 `"rx"` 字段出现 ≥ 1 次 |

---

#### Test 08: Debug 诊断模式

| 项目 | 内容 |
|------|------|
| **原理** | `get_sockdelays -d` 在 stderr 输出 netlink 收发诊断信息（family 解析、send/recv 字节数、属性遍历），用于排查内核通信问题 |
| **实现** | `nc -l -p 21408` 创建监听 socket → `get_sockdelays -d -p $PID 2>&1` 合并捕获 stderr+stdout |
| **断言** | 输出非空（至少包含 diag 行或 socket 数据行） |

---

### 第三部分：压力测试（Test 09-11）

在高负载条件下验证工具的**健壮性**和**正确性**。

核心指标：①不崩溃 ②不遗漏 socket ③计数无溢出 ④协议隔离正确。

---

#### Test 09: 高并发多连接

| 项目 | 内容 |
|------|------|
| **原理** | 大量并行连接测试 socket 枚举能力（fdtable 遍历正确性）和计数正确性，同时验证 dumpit 协议在多 socket 场景下不漏消息 |
| **实现** | iperf3（端口 21409）`-P 8`（8 条并行流）→ `sleep 2` 后分别查询 server 和 client |
| **三重断言** | ① server TCP socket 数 ≥ 9（1 listen + 8 data）；② server RX 总量 > 0；③ client TX 总量 > 0 |
| **方向分离** | server 是接收方，TX 仅有纯 ACK（不走 `sendmsg`，按设计不计入 TX），故只验证 server RX；client 是发送方，验证 TX |

---

#### Test 10: 大流量高计数

| 项目 | 内容 |
|------|------|
| **原理** | 不限速大流量传输，验证 64 位计数器不会溢出或截断，同时验证 `pr_warn_once` 溢出告警不触发 |
| **实现** | iperf3（端口 21410）`-P 4 -t 5` 不限速 → 分别查询 server（取最大 RX count）和 client（取最大 TX count） |
| **断言** | server 最大 RX count ≥ 50 **且** client 最大 TX count ≥ 50 |
| **阈值选择** | 阈值 50 是保守值，兼顾 TCG 软件模拟（速度慢）和 KVM 硬件加速（实际远超）；本意是验证不截断/不溢出，非验证吞吐 |
| **关键修复** | 旧代码只查 server，server TX 只有 ACK≈2 永远不满足 ≥100；修复后按方向分端查询 |

---

#### Test 11: 混合协议隔离

| 项目 | 内容 |
|------|------|
| **原理** | TCP 和 UDP 同时传输，验证内核 per-socket 统计按 socket 隔离，不会出现跨协议污染（TCP socket 不统计 UDP 数据，反之亦然） |
| **实现** | 两个 iperf3 server：TCP（端口 21411）+ UDP（端口 21412）→ TCP client `-P 4 -t 5` + UDP client `-u -t 5 -b 20M` 同时运行 → `sleep 2` 后分别查询两个 server PID |
| **断言** | TCP server：`proto=tcp` ≥ 5（1 listen + 4 data）、`proto=udp` = 0；UDP server：`proto=tcp` ≥ 1（控制连接）、`proto=udp` ≥ 1（数据 socket） |
| **关键设计** | iperf3 UDP 模式也用 TCP 做控制连接，所以 UDP server 必然有 1 个 tcp socket，这是正确行为而非 bug |

---

### 第四部分：边界条件（Test 12）

验证工具在极端输入下不崩溃、不泄漏、合理报错。4 个子检查使用本地计数器合并为 1 个测试编号，避免测试计数膨胀。

| 子检查 | 原理 | 断言 |
|--------|------|------|
| **(a) PID 1（init）** | 系统进程通常没有网络 socket，工具应正常退出不崩溃 | 正常退出（exit 0）或输出 "no matching" |
| **(b) PID 99999** | 不存在的 PID，工具应明确报错 | 非零退出码 |
| **(c) `-h` 帮助** | 用户友好使用说明 | 输出包含 "usage" 或 "用法"（大小写不敏感） |
| **(d) `-V` 版本** | 版本号输出 | 正常退出（exit 0） |

---

### 第五部分：稳定性（Test 13）

#### Test 13: 并发查询压力

| 项目 | 内容 |
|------|------|
| **原理** | 多个进程同时对内核发起 Netlink dump 查询，验证**内核并发安全**——per-sock spinlock 无死锁、`cb->ctx` 遍历无竞态、无 Kernel Oops/BUG/panic |
| **实现** | 启动 16 个后台 worker 进程（`&`），每个连续查询 PID 1 **20 次**，共 16 × 20 = **320 次查询**；用 `mktemp -d` 创建临时目录收集各 worker 的 ok/fail 计数；wait 所有 worker 完成后检查 dmesg 尾部 100 行 |
| **断言** | 无 worker 崩溃（所有 worker 输出文件存在）+ dmesg 无 `Kernel panic`/`Oops:`/`BUG:` 关键字 |
| **为什么查 PID 1？** | PID 1 通常没有 socket，查询会快速返回空结果，可以最大化查询频率来暴露竞态 |
| **检测崩溃** | 输出文件不存在视为 worker 崩溃（`_CRASH` 计数器） |

---

### 第六部分：过滤功能（Test 14-16，v5.0.0 新增）

验证内核侧 `net_delayacct_match_filter()` 6 维过滤功能（`--proto`/`--family`/`--lport`/`--rport`/`--laddr`/`--raddr`），确保过滤条件正确传递到内核、在内核 dumpit 回调中正确筛选 socket。

---

#### Test 14: 协议过滤（--proto）

| 项目 | 内容 |
|------|------|
| **原理** | `--proto tcp`/`--proto udp` 通过 `NET_DELAYACCT_A_TYPE` 属性传递到内核，dumpit 回调中比较 `sk->sk_protocol` 决定是否返回该 socket |
| **实现** | TCP server（21414）+ UDP server（21415）→ TCP client `-P 2 -t 8` + UDP client `-u -t 8 -b 10M` → `sleep 2` 后对 **UDP server PID**（同时持有 TCP 控制 socket 和 UDP 数据 socket）做三次查询：无过滤、`--proto tcp`、`--proto udp` |
| **断言** | 无过滤：tcp ≥ 1 **且** udp ≥ 1；`--proto tcp`：tcp ≥ 1 **且** udp = 0；`--proto udp`：tcp = 0 **且** udp ≥ 1 |
| **client -t 8** | 确保三次查询期间 UDP 数据 socket 存活（iperf3 server 在 client 断开后关闭关联 UDP socket） |

---

#### Test 15: 端口过滤（--lport）

| 项目 | 内容 |
|------|------|
| **原理** | `--lport <port>` 通过 `NET_DELAYACCT_A_LPORT` 属性传递，内核比较 `sk->sk_num`（host byte order，**不是 ntohs**）匹配本地端口 |
| **实现** | iperf3 server（端口 21416）→ client `-P 2 -t 3` → `sleep 2` 后三次查询：无过滤、`--lport 21416`、`--lport 99999`（不存在的端口） |
| **断言** | 无过滤：socket ≥ 1；`--lport 21416`：匹配行 ≥ 1 **且** 非匹配行 = 0；`--lport 99999`：socket = 0 |
| **端口匹配正则** | `local=[^ ]*:$PORT( |$)`：`[^ ]*` 在遇到空格（即 `remote=` 之前）停止，兼容 IPv4（`127.0.0.1:port`）和 IPv6（`[::]:port`）格式，不会误匹配 remote 端口 |

---

#### Test 16: 组合过滤（--proto + --lport）

| 项目 | 内容 |
|------|------|
| **原理** | 多个过滤条件同时传入时为 **AND 语义**——socket 必须满足所有条件才被返回 |
| **实现** | 单个 iperf3 server（端口 21417，默认同时监听 TCP/UDP）→ **只启动 UDP client** `-u -t 8 -b 10M`（UDP client 自动建立 TCP 控制连接 + UDP 数据 socket，baseline 同时含 TCP 和 UDP）→ `sleep 3` 后查询：无过滤、`--proto tcp --lport 21417` |
| **断言** | 无过滤：tcp ≥ 1 **且** udp ≥ 1；组合过滤：tcp ≥ 1、udp = 0（被 proto 排除）、端口不匹配 = 0（被 lport 排除） |
| **为什么只启动 UDP client？** | 并行 TCP client（`-P 2`）会因 iperf3 server 单线程处理导致 UDP client 无法建立 TCP 控制连接，server 侧无 UDP 数据 socket。只启动 UDP client 自带 TCP 控制连接，避免干扰 |
| **sleep 3** | 给 UDP client 足够时间完成 TCP 控制连接建立和 UDP 关联 |

---

## 三、测试方法总结

### 3.1 覆盖矩阵

| 维度 | 覆盖情况 |
|------|----------|
| **查询维度** | PID 查询（dumpit）、inode 查询（doit）、RESET、JSON 输出、Debug 模式、协议过滤、端口过滤、组合过滤 |
| **协议覆盖** | TCP（Test 01/04/06/07/09/10/11/14/15/16）、UDP（Test 05/11/14/16） |
| **IPv4/IPv6** | IPv4（loopback 127.0.0.1，所有测试）；IPv6（`[::]` loopback，工具端格式兼容） |
| **负载等级** | 单连接 → 4 并行 → 8 并行 → 16 worker × 20 queries 并发 |
| **数据验证** | socket 数量（不漏）、协议类型（不错）、RX/TX count（不溢出/不截断）、计数器重置（真清零）、过滤精确性（不错误包含/排除） |
| **边界条件** | 正常 PID、PID 1（无 socket）、不存在 PID（99999）、help、version |
| **稳定性** | 320 次并发查询 + dmesg Kernel Oops 检测 |
| **offload 交互** | GRO/GSO 在 loopback + e1000 虚拟网卡上自然触发，通过 count 阈值验证计数逻辑正确 |

### 3.2 核心测试手段

1. **已知特征流量**：用 iperf3 创建已知数量、已知协议、已知方向的 socket 和数据流
2. **时序控制**：`&` 后台 + `sleep N` 确保查询时 socket 存活、数据已传输；client `-t 8` 保证多轮查询期间 socket 不被关闭
3. **方向分离验证**：server 侧验证 RX（接收数据），client 侧验证 TX（发送数据），避免纯 ACK 干扰
4. **文本解析断言**：用 `grep -c 'proto=tcp'`、`awk '/RX  count=/'` 等解析 `get_sockdelays` 文本输出与预期值比较
5. **失败诊断**：失败时自动打印工具原始输出 + 协议摘要 + 进程状态，便于 QEMU 环境下复现调试

### 3.3 测试环境关键注意事项

| 注意点 | 说明 |
|--------|------|
| **iperf3 server 单线程** | 同一端口的 iperf3 server 单线程处理多个 client；TCP client `-P N` 会占用 server，导致 UDP client 无法建立 TCP 控制连接 |
| **iperf3 UDP 模式** | UDP client 会先建立 TCP 控制连接（lport 相同），再发送 UDP 数据；server 侧会同时有 TCP(control) + UDP(data) socket |
| **iperf3 -P fork** | client 侧 `-P N` fork 子进程处理数据连接，父进程 fd 表只有 control socket；server 侧不 fork，所有 socket 可见 |
| **端口正则兼容** | 端口匹配必须用 `local=[^ ]*:$PORT( \|$)` 兼容 IPv4/IPv6，不能依赖 `[]` 括号 |
| **TCG 阈值保守** | 阈值取 50 而非 100，因为 TCG 软件模拟速度慢，count 值低；本意是验证不截断，非验证吞吐 |
| **loopback 流量** | loopback 上的 RX/TX 路径与物理网卡略有不同（可能 shortcut 某些层），但所有打点位于通用路径上，仍然有效 |

---

## 四、目录结构

```
tests/
  README.md                                    本文档
  reports/                                     测试报告输出目录（自动生成）
    local/                                     本地测试日志（test-YYYYMMDD_HHMMSS.log）

ci/
  qemu/
    run-tests.sh                              **统一测试套件入口**（当前活跃，16 项测试）
    guest-init.sh                             QEMU 内部 init 脚本（挂载文件系统 + 诊断 + run-tests.sh）
    build-initramfs.sh                        initramfs 打包脚本
    run-qemu.sh                               QEMU 启动脚本（KVM/TCG 自动选择）

kernel-patches/                               内核补丁（测试目标）
userspace/get_sockdelays/                     用户态工具（测试目标）
local-test.sh                                 本地快速测试入口
.github/workflows/ci.yml                      CI 自动化配置
```

历史遗留目录（已废弃，功能合并入 [run-tests.sh](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh)）：

```
tests/
  selftests/
    net-delayacct/
      test_netdelayacct.sh                    已废弃
      test_helper.sh                         辅助函数（未使用）
      kunit/
        net-delayacct-test.c                 KUnit 单元测试模块（待集成）
  func/
    test_*.sh                                已废弃，功能合并入 run-tests.sh Test 01-06
  perf/
    baseline-vs-enabled.sh                   基线对比性能测试（待集成 CI）
    long-run.sh                              24h 稳定性测试（手动执行）
    concurrent-query.sh                      并发查询压力测试（已合并为 Test 13）
```

---

## 五、如何运行

### 5.1 本地快速测试

```bash
# 完整流程：编译内核 + 工具 + QEMU 测试（推荐）
./local-test.sh

# 仅编译内核和工具（快速验证编译通过）
./local-test.sh --kernel-only

# 仅 QEMU 测试（假设内核已编译过）
./local-test.sh --qemu-only
```

日志自动保存到 `tests/reports/local/test-YYYYMMDD_HHMMSS.log`。

### 5.2 CI 自动化

Git push 到 `main` 或 `dev` 分支自动触发 `.github/workflows/ci.yml`：

| Job | 运行环境 | 预期耗时 |
|-----|----------|----------|
| checkpatch | ubuntu-22.04 | ~1 min |
| build-kernel | ubuntu-22.04（ccache 加速） | ~2 min（热缓存）/ ~10 min（冷缓存） |
| build-tool | ubuntu-22.04 | ~30 sec |
| qemu-test | ubuntu-22.04（KVM） | ~2 min |

### 5.3 QEMU 超时参数

| 场景 | 超时 | 说明 |
|------|------|------|
| CI KVM 硬超时 | 90s | `QEMU_TIMEOUT_KVM=90` |
| CI TCG 硬超时 | 240s | `QEMU_TIMEOUT_TCG=240`（软件模拟慢） |
| Guest 内部 watchdog | 360s | guest-init.sh 中的 `sleep 360; poweroff -f` |
| run-tests.sh 整体超时 | 由 guest-init 的 `timeout 240` 包裹整个脚本 | 单测无独立超时 |

### 5.4 单元测试（KUnit，待集成）

KUnit 测试需要内核启用 `CONFIG_KUNIT=y`：

```bash
# 通过 kunit_tool 运行
./tools/testing/kunit/kunit.py run --kunitconfig=tests/selftests/net-delayacct/kunit

# 模块加载方式（内核已启动后）
modprobe net-delayacct-test
cat /sys/kernel/debug/kunit/results
```

### 5.5 性能测试（手动执行）

```bash
# 基线对比（需要两个内核镜像：CONFIG_NET_DELAYACCT=n vs =y）
cd tests/perf
./baseline-vs-enabled.sh /path/to/baseline-bzImage /path/to/enabled-bzImage

# 长时间稳定性（默认 24h）
./long-run.sh 24

# 并发查询压力（已合并为 Test 13，独立脚本保留供手动调节参数）
./concurrent-query.sh 32
```

---

## 六、测试环境要求

### 内核

- Linux 6.6（或兼容的 6.6.x point release）
- `CONFIG_NET_DELAYACCT=y`
- `CONFIG_KUNIT=y`（单元测试，可选）
- `CONFIG_DEBUG_KMEMLEAK=y`（长时间稳定性测试，可选）

### 用户态工具

- `get_sockdelays`（`PATH` 中或 `GET_SOCKDELAYS` 环境变量指定路径）
- `iperf3`（功能测试与压力测试，版本 ≥ 3.x）
- `nc` / `ncat`（socket 创建与 inode 测试）
- `busybox`（QEMU initramfs 基础命令：sh、mount、ip、sleep、kill 等）
- `bash`（run-tests.sh 使用 bash 语法；guest-init 有 sh 回退）
- `qemu-system-x86_64`（CI QEMU 测试）

### 系统权限

- root 或具备 `CAP_NET_ADMIN`（QEMU guest 内默认 root）
- 可读取 `/proc/<pid>/fd/*`（inode 提取，QEMU 内 `/proc` 已挂载）
- 可运行 `dmesg`（Test 13 稳定性检查内核日志）
- KVM 访问（`/dev/kvm`，可选；无则自动降级 TCG）

---

## 七、注意事项

1. **权限**：大部分测试需要 root 权限或在 QEMU guest 内运行（默认 root）。本地直接运行可能因权限不足失败。

2. **端口占用**：run-tests.sh 使用端口范围 21401-21417，确保不与宿主机其它服务冲突；QEMU user-mode 网络与宿主机隔离，无此问题。

3. **get_sockdelays 路径查找优先级**：
   - 环境变量 `GET_SOCKDELAYS`
   - `/usr/local/bin/get_sockdelays`（QEMU guest 内默认安装路径）

4. **ccache 缓存**：CI 内核编译使用稳定 ccache key，热缓存下编译仅 ~30 秒-2 分钟。修改 patch 后首次运行需全量编译约 10 分钟建立缓存。

5. **KVM 降级**：`/dev/kvm` 不可用时自动降级为 TCG 软件模拟，但耗时增加 10-20 倍；测试阈值已取保守值适配 TCG。

6. **patch 上下文差异**：`sock_h-modification.patch`、`skbuff_h-modification.patch`、`rx-instrumentation.patch`、`tx-instrumentation.patch` 的上下文行在不同 6.6.x point release 之间可能略有差异。`git apply` 失败时改用 `patch -p1 --fuzz=3 < xxx.patch`。

7. **用户态工具编译**：`make -B tool` 强制无条件重建 get_sockdelays，避免使用 stale 二进制。Makefile 已添加 `-I.` 支持本地 UAPI header 回退，无 sudo 权限时不安装到 `/usr/include` 也能编译。

8. **RX/TX 计数语义不对称**：RX 在 `__netif_receive_skb_core` 入口计入（覆盖所有入包，含纯 ACK）；TX 仅在 `tcp_sendmsg`/`udp_sendmsg` 等路径计入（只覆盖应用层 sendmsg 出包，ACK/重传 clone 路径有特殊处理）。测试中断言 TX>0 必须查发送方（client），纯接收方（如 iperf3 server）TX=0 是正确行为。

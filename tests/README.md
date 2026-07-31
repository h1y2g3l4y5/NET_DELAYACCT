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
| 加速 | KVM 优先（300s 超时），不可用则降级 TCG（600s 超时，阈值取保守值） |
| init | [ci/qemu/guest-init.sh](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/guest-init.sh)：挂载 /proc/sys/dev → 诊断（genl family 验证 + dmesg）→ 调 `run-tests.sh` → 写结果到 /root/test-output.txt → poweroff |
| watchdog | `sleep 540; poweroff -f` 防测试挂死（QEMU 内部）；CI 层另有 QEMU_TIMEOUT_KVM=300s / QEMU_TIMEOUT_TCG=600s 硬超时 |

### 1.3 流量生成工具

| 工具 | 用途 | 关键参数说明 |
|------|------|-------------|
| `iperf3 -P N -t T` | TCP 多流数据传输 | `-P N` 产生 N 条并行数据流；server 侧不 fork，所有数据 socket 可见；client fork 子进程 |
| `iperf3 -u -b BW -t T` | UDP 数据流传输 | `-u` UDP 模式，`-b 10M` 限速 10Mbps；UDP 模式仍会创建 TCP 控制连接 |
| `iperf3 -R` | 反向数据传输 | server 向 client 发送数据，用于双向流量测试（同一 socket 同时有 RX+TX） |
| `nc -l -p PORT` | 创建单个 TCP/UDP 监听 socket | 用于 inode 查询、negative case 等轻量级场景；ncat 兼容 |
| `delayacct_path_test` | 路径覆盖辅助程序 | 覆盖 iperf3 无法触发的 splice/zerocopy/corked 路径（Test 19-21）；见 [tests/helper/](file:///home/lai/Code/NET_DELAYACCT/tests/helper/) |

### 1.4 判定框架（[ci/qemu/run-tests.sh](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh)）

```bash
_PASSED=0   _FAILED=0   _SKIPPED=0   _test_num=0

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
║  Tests run: 22     PASS: 22     FAIL:  0     SKIP:  0       ║
╠══════════════════════════════════════════════════════════════╣
║  RESULT: ALL PASS                                            ║
╚══════════════════════════════════════════════════════════════╝
```

退出码：有 FAIL 则返回 1，全部 PASS 或 SKIP 返回 0（CI 据此判断 job 成功/失败）。

> **注**：Test 20（TCP zerocopy RX）依赖内核启用 `CONFIG_MMU`（`tcp_mmap` 编译开关）且 helper 使用 `mmap(cfd)` 而非匿名 mmap。
> 在 `CONFIG_MMU=y` 的内核上 loopback 亦可运行；若 helper 返回退出码 3，测试会 SKIP（graceful degradation），不影响整体结果。

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

测试使用端口范围 **21401-21435**，每个测试分配独立端口，避免并行冲突：

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
| Test 13 | 21413 |
| Test 14 | 21414/21415/21418 |
| Test 15 | 21416 |
| Test 16 | 21417 |
| Test 17 | 21430 |
| Test 18 | 21431 |
| Test 19 | 21432 |
| Test 20 | 21433 |
| Test 21 | 21434 |
| Test 22 | 21435 |

---

## 二、测试用例详解（共 22 项）

测试按功能分为七个部分。

---

### 第一部分：基础功能（Test 01-06）

验证 `get_sockdelays` 的核心查询能力——能否正确查到 socket 统计。

---

#### Test 01: PID 查询

##### 一、测试目标

验证 `get_sockdelays -p <PID>` 通过 Generic Netlink 内核接口（标准 dumpit 协议）查询指定进程持有的所有 socket 统计的能力。这是最核心的功能，所有其他功能都建立在此基础之上。

##### 二、实现流程

代码见 [run-tests.sh:183-217](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L183-L217)，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 启动 iperf3 TCP server 监听端口 21401 | 后台运行，拿到 server PID `_SRV` |
| 2 | `sleep 1` 等待 server 启动 | 避免 client 连接失败 |
| 3 | 启动 iperf3 client 连接 server，持续 5 秒 | **必须 `&` 后台运行**，拿到 client PID `_CLI` |
| 4 | `sleep 2` 等待传输稳定 | 确保连接建立、数据正在传输 |
| 5 | 执行 `get_sockdelays -p $_CLI` 查询 client PID | 捕获输出到 `OUT` |
| 6 | 文本解析：统计 `proto=` 行数和 `proto=tcp` 行数 | 用 grep 做计数 |
| 7 | 断言检查，清理进程 | kill server/client，wait 回收 |

##### 三、核心断言与原理

唯一核心断言：
- **`proto=tcp` 数据行 ≥ 1**：证明 dumpit 遍历能够正确枚举到 client 进程持有的至少一个 TCP socket。

**时序关键**：client 必须后台运行，否则 5s 传输结束后进程退出，查询时 socket 已被内核关闭清理，会误判为失败。

---

#### Test 02: Inode 查询

##### 一、测试目标

验证 `get_sockdelays -i <inode>` 按 socket inode 号精确查询单个 socket 的能力。每个 socket 在内核 sockfs 中有唯一 inode 号，这是除 PID 查询外的第二种定位方式。

##### 二、实现流程

代码见 [run-tests.sh:219-257](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L219-L257)，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | `nc -l -p 21402` 创建 TCP 监听 socket | nc 轻量，不会产生额外连接 |
| 2 | `sleep 1` 等待 nc 监听就绪 | |
| 3 | 遍历 `/proc/$NC_PID/fd/*`，用 `readlink` 提取 inode | 符号链接格式为 `socket:[数字]`，用 sed 提取数字部分 |
| 4 | 执行 `get_sockdelays -i $INODE` 查询 | 捕获输出 |
| 5 | 断言：输出中包含 `inode=$INODE` | grep 匹配 |
| 6 | 清理 nc 进程 | |

##### 三、核心断言与原理

唯一核心断言：
- **输出中包含 `inode=$INODE`**：证明内核通过 inode 查找到了正确的 socket，没有用错 inode 映射。

**依赖**：需要 `/proc` 文件系统已挂载（guest-init 中 `mount -t proc`），否则无法从 fd 符号链接提取 inode。

---

#### Test 03: 重置计数器（基础功能）

##### 一、测试目标

验证 `get_sockdelays -R` 的基础清零能力：**重置前必须有非零计数**，重置后非零计数应大幅下降。这是 RESET 功能最基本的正确性验证，避免"0→0"的假阳性。

##### 二、实现流程

代码见 [run-tests.sh:259-313](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L259-L313)，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 启动 iperf3 server 端口 21403，sleep 1 等待就绪 | |
| 2 | **后台运行** iperf3 client（`-P 2 -t 12`），`sleep 3` 让流量积累 | **关键**：后台运行确保 PRE 查询时流量活跃、count 必然 > 0。若同步运行，client 结束后 server 关闭 child socket，只剩 listen socket（count=0），PRE/POST 全为 0，reset 测试 trivially 通过（假阳性） |
| 3 | 执行 `get_sockdelays -p $_SRV`（重置前查询 PRE） | **必须验证 PRE 有非零计数**（`PRE_NONZERO ≥ 1`），否则 reset 无意义 |
| 4 | 执行 `get_sockdelays -R` 重置 | 向内核发送 RESET 命令 |
| 5 | `sleep 1` 等待 reset 完成并让后续包累加 | |
| 6 | 再次查询 `get_sockdelays -p $_SRV`（重置后查询 POST） | 统计所有 `count=` 字段大于 0 的行数 |
| 7 | 断言：POST 非零计数 < PRE/2 或 = 0 | 容忍非原子语义下的少量累加 |
| 8 | 清理进程 | |

##### 三、核心断言与原理

三个断言（层层递进）：
1. **PRE 必须有非零计数**（`PRE_NONZERO ≥ 1`）：若 PRE 全为 0，reset 是"0→0"的空操作，测试无意义，必须 FAIL。
2. **POST 非零计数远小于 PRE**（`POST_NONZERO < PRE_NONZERO / 2` 或 `= 0`）：证明 reset 确实清空了统计。容忍非原子语义下的少量累加（见 Test 17）。
3. **client 后台运行保证流量活跃**：这是与旧实现（同步运行）的根本区别，旧实现因 client 结束后 socket 被关闭导致 PRE/POST 全为 0，产生"重置前后数据都是 0"的假阳性。

**语义说明**：RESET 不是全局原子快照，遍历期间或遍历之后新到达的包仍会被累加。本测试在流量活跃时执行 reset，POST 可能因后续包到达有小幅累加，因此阈值取 PRE/2 而非严格 = 0；**活跃流量下的非原子行为由 Test 17 专项验证**，两者互补。

---

#### Test 04: TCP 路径

##### 一、测试目标

验证内核 per-socket 延迟统计对 TCP socket 的追踪能力：RX 打点（`tcp_recvmsg_locked`/`tcp_read_sock`/`tcp_zerocopy_receive`）能够正常工作。RX count > 0 是硬断言，无 timing 放宽。

##### 二、实现流程

代码见 [run-tests.sh:315-359](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L315-L359)，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 启动 iperf3 server 端口 21404 | |
| 2 | **后台运行** iperf3 client（`-t 8`），`sleep 3` 让流量积累 | 关键：后台运行确保查询时流量活跃、count 必然 > 0。若同步运行，client 结束后 server 关闭 child socket，只剩 listen socket（count=0），产生假阳性 |
| 3 | 查询 server PID：`get_sockdelays -p $_SRV` | |
| 4 | 统计 `proto=tcp` 行数，检查 RX count > 0 的 socket 数 | |
| 5 | 断言，清理 | |

##### 三、核心断言与原理

三个断言（硬断言，无 timing 放宽）：
- **`proto=tcp` 行 ≥ 1**（必须满足）：证明 TCP socket 被枚举到。
- **RX count > 0 的 socket 数 ≥ 1**（必须满足）：证明 RX 打点工作正常。若 RX=0，说明 `net_delayacct_rx_end()` 可能失效，必须 FAIL。
- **QEMU loopback 下不存在真实 timing 问题**：iperf3 `-t 8` 后台运行 + sleep 3 足够产生 RX count > 0，旧实现的"timing 放宽"是假阳性来源。

---

#### Test 05: UDP 路径

##### 一、测试目标

验证内核 per-socket 延迟统计对 UDP socket 的追踪能力（RX/TX 打点必须工作）。UDP 是无连接协议，end 打点位于 `skb_copy_and_csum_datagram_msg()` 成功之后（checksum 验证通过后才计入），行为与 TCP 不同，需要单独验证。

##### 二、实现流程

代码见 [run-tests.sh:361-417](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L361-L417)，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 启动 iperf3 server 端口 21405 | |
| 2 | 启动 iperf3 UDP client（`-u -b 10M -t 8`），**后台运行 `&`**，sleep 3 | 关键：UDP 无连接，同步阻塞结束后 UDP 数据 socket 会被立即关闭，查询时可能已消失 |
| 3 | **同时查询 client 和 server 两端**：`get_sockdelays -p $_SRV` 和 `get_sockdelays -p $_CLI` | UDP socket 可能只在一侧可见 |
| 4 | 分别统计两端 `proto=udp` 行数，求和；计算 server RX 总和、client TX 总和 | |
| 5 | 断言，清理 | |

##### 三、核心断言与原理

三个断言：
1. **两端 proto=udp 总数 ≥ 1**：UDP 无连接，server 侧或 client 侧可能在查询时 socket 已被关闭（UDP socket 生命周期比 TCP 短），两端同时查避免单端误判。
2. **server RX > 0**：server 作为接收方，应收到 UDP 数据包（`net_delayacct_rx_end` 打点工作）。
3. **client TX > 0**：client 作为发送方，应发送了 UDP 数据包（`net_delayacct_tx_start` 打点工作）。

**关键设计**：client 必须后台运行，否则同步阻塞结束后 socket 立即被内核清理，查询不到任何 UDP socket。

---

#### Test 06: 多 Socket 枚举

##### 一、测试目标

验证一个进程持有多个 socket 时，`get_sockdelays` dumpit 遍历 `files_struct` 能否全量枚举出所有 socket，不遗漏任何一个 fd；同时验证 server 侧 RX 打点工作正常。

##### 二、实现流程

代码见 [run-tests.sh:419-481](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L419-L481)，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 启动 iperf3 server 端口 21406 | |
| 2 | 启动 iperf3 client `-P 4`（4 条并行 TCP 流），**后台运行**，sleep 3 | iperf3 `-P N` 会 fork 子进程处理每条数据连接 |
| 3 | 查询 client 父进程 PID：`get_sockdelays -p $_CLI` | 父进程只持有 control socket |
| 4 | 查询 server PID：`get_sockdelays -p $_SRV` | server 不 fork，所有 socket 在主进程可见 |
| 5 | 分别统计两端 `proto=tcp` 行数；计算 server RX 总和 | |
| 6 | 断言，清理 | |

##### 三、核心断言与原理

三个断言：
1. **client 父进程 ≥ 1 个 TCP socket**：父进程持有 control 连接 socket。
2. **server ≥ 6 个 TCP socket**：至少 1 个 listen socket + 1 个 control 连接 + 4 条数据连接 = 6 个。实际数量可能因 TIME-WAIT 残留 socket 等状态更高，断言用 `>=6` 容忍上浮。
3. **server RX > 0**：server 作为接收方，4 条数据流应产生 RX 计数（`net_delayacct_rx_end` 打点工作）。

**关键设计**：iperf3 `-P N` 会 fork 子进程处理数据连接，子进程的数据 socket 出现在子进程 fd 表中，父进程 fd 表只有 control socket；server 侧不 fork，所有数据 socket 在同一个进程中可见，因此 server 侧断言数量更高。

---

### 第二部分：工具展示（Test 07-08）

验证 `get_sockdelays` 的辅助输出功能。

---

#### Test 07: JSON 格式输出

##### 一、测试目标

验证 `get_sockdelays -j` 能够将 socket 统计以机器可读的 JSON 格式输出，便于脚本和自动化工具解析。JSON 输出是集成到监控系统的关键接口。

##### 二、实现流程

代码见 [run-tests.sh:439-472](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L439-L472)，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 启动 iperf3 server 端口 21407 | |
| 2 | 启动 iperf3 client 传输 3 秒，后台运行 | 保证查询时有活跃 socket |
| 3 | `sleep 1` | |
| 4 | 执行 `get_sockdelays -j -p $_SRV` 查询 | `-j` 启用 JSON 输出 |
| 5 | 统计 `"proto"` 和 `"rx"` 字段出现次数 | grep 计数 |
| 6 | 断言，清理 | |

##### 三、核心断言与原理

两个断言：
- **`"proto"` 字段出现 ≥ 1 次**：JSON 中包含 socket 协议类型字段，证明不是空输出。
- **`"rx"` 字段出现 ≥ 1 次**：JSON 中包含 RX 统计对象，证明数据结构正确序列化。

本测试仅验证 JSON 输出"看起来像 JSON"，不做严格 JSON 语法校验（jq 等 JSON 工具不在 initramfs 中）；格式正确性通过日常使用和代码 review 保证。

---

#### Test 08: Debug 诊断模式

##### 一、测试目标

验证 `get_sockdelays -d` 能够在 stderr 输出 netlink 收发诊断信息（family 解析、send/recv 字节数、属性遍历详情），用于排查内核通信问题。这是调试 netlink 交互问题的重要工具。

##### 二、实现流程

代码见 [run-tests.sh:474-500](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L474-L500)，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | `nc -l -p 21408` 创建 TCP 监听 socket | 轻量场景，避免 iperf3 产生过多输出干扰诊断信息 |
| 2 | `sleep 1` 等待 nc 就绪 | |
| 3 | 执行 `get_sockdelays -d -p $_NC 2>&1` | `-d` 输出到 stderr，用 `2>&1` 合并 stderr 和 stdout 统一捕获 |
| 4 | 检查输出是否非空 | |
| 5 | 断言，清理 | |

##### 三、核心断言与原理

唯一核心断言：
- **输出非空**：debug 模式应该产生诊断输出或正常 socket 数据，不应该静默失败。

---

### 第三部分：压力测试（Test 09-11）

在高负载条件下验证工具的**健壮性**和**正确性**。

核心指标：①不崩溃 ②不遗漏 socket ③计数无溢出 ④协议隔离正确。

---

#### Test 09: 高并发多连接

##### 一、测试目标

验证在高并发多连接场景下，框架的三个核心能力：

1. **Socket 枚举能力**：一个进程持有大量 socket 时，`get_sockdelays` 能否通过 `files_struct` 遍历把所有 socket 都枚举出来，不遗漏
2. **计数正确性**：RX/TX 计数不会因为并发而错乱、丢失、重复统计
3. **方向分离语义验证**：验证TX/RX计数不对称的设计——纯接收方（server）的TX计数应该远小于发送方（client）（因为纯ACK不会被计入TX统计）

##### 二、实现流程

代码见 [run-tests.sh:511-584](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L511-L584)，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 启动 iperf3 server 监听端口 21409 | 后台运行，拿到 server PID `_SRV` |
| 2 | 启动 iperf3 client，`-P 8` 参数 | **并行 8 条 TCP 流**同时向 server 发送数据，持续 5 秒，后台运行，拿到 client PID `_CLI` |
| 3 | `sleep 2` | 等待连接全部建立、数据稳定传输 |
| 4 | 查询 server PID：`get_sockdelays -p $_SRV` | 拿到 server 侧所有 socket 统计 |
| 5 | 查询 client PID：`get_sockdelays -p $_CLI` | 拿到 client 侧所有 socket 统计 |
| 6 | 从输出中解析：<br>- server 侧 proto=tcp 行数（socket数量）<br>- server 侧 RX 总计数<br>- server 侧 TX 总计数<br>- client 侧 TX 总计数<br>- client 侧 RX 总计数 | 用 grep/awk 做文本解析 |
| 7 | 执行断言检查，清理进程 | 通过则 PASS，失败则打印诊断输出 |

##### 三、核心断言与原理

一共四个断言，层层递进验证：

1. **`server socket_count >= 9`**
   - iperf3 server 侧预期至少有 **9个TCP socket**：
     - 1 个 listen socket（监听端口）
     - 1 个 control 连接（iperf3 控制通道，传测试参数/结果）
     - 8 个 data socket（`-P 8` 的8条并行数据连接）
   - 这个断言验证**枚举完整性**：如果我们的 dumpit 遍历逻辑有bug（比如fd遍历遗漏、sock_from_file判断错误），socket数量会少于9，直接失败。
   - 为什么是 `>=9` 而不是 `==9`？因为可能有 TIME-WAIT 残留 socket、临时管理 socket 等，断言用下限容忍上浮，不期望精确等于9。

2. **`server RX_SUM > 0`**
   - server 是接收方，8条流同时发数据，RX 总计数必须大于0。
   - 验证 RX 打点工作正常：高并发下 `net_delayacct_rx_end()` 的 spinlock 累加没有丢计数。

3. **`client TX_SUM > 0`**
   - client 是发送方，8条流的发送数据必须走 `__tcp_transmit_skb` clone路径，TX 总计数必须大于0。
   - 验证 TX 打点在多连接并发下工作正常，`net_delayacct_tx_end()` 累加正确。

4. **`server TX_SUM <= client TX_SUM / 10`**（最关键的语义验证）
   - **这是验证TX/RX计数不对称设计的核心断言**：
     - 单向传输场景下，server 只收数据，发送的只有**纯ACK包**
     - 纯ACK包走 `alloc_skb` 分配，`delayacct_start` 被零初始化为0
     - `net_delayacct_tx_end()` 有 `if (!skb->delayacct_start) return;` 守卫，纯ACK完全不计入TX统计
     - 只有少量重传包、 window probe 包等会走 sendmsg/clone 路径被计入TX
   - 因此 server TX 应该远小于 client TX（我们取1/10阈值，TCG场景下也足够宽松）
   - 这个断言同时验证了两个设计点：① 纯ACK确实不计入TX；② 高并发下方向统计不会串扰。

> 注意：client RX > 0 是正常的，不做约束——因为client会收到server发的ACK，RX打点在`__netif_receive_skb_core`入口，**所有入包包括ACK都会计入RX**，这是设计上的不对称。

---

#### Test 10: 大流量高计数

##### 一、测试目标

验证不限速大流量传输场景下，64 位 RX/TX 计数器不会溢出、不会被截断，也不会触发 `pr_warn_once` 溢出告警。这是计数器正确性的压力测试。

##### 二、实现流程

代码见 [run-tests.sh:586-627](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L586-L627)，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 启动 iperf3 server 端口 21410 | |
| 2 | 启动 iperf3 client `-P 4 -t 5`（不限速），后台运行 | 4条流打满 loopback 带宽 |
| 3 | `sleep 2` 等待流量稳定 | |
| 4 | 查询 server PID：`get_sockdelays -p $_SRV` | 取所有 RX count 中的最大值 |
| 5 | 查询 client PID：`get_sockdelays -p $_CLI` | 取所有 TX count 中的最大值 |
| 6 | 比较两个最大值是否都 ≥ 50 | |
| 7 | 断言，清理 | |

##### 三、核心断言与原理

两个断言：
- **server 最大 RX count ≥ 50**：接收方 RX 计数有足够数据量。
- **client 最大 TX count ≥ 50**：发送方 TX 计数有足够数据量。

**阈值选择**：阈值 50 是保守值，兼顾 TCG 软件模拟（速度慢，计数低）和 KVM 硬件加速（实际计数远超 50）；本意是验证计数器不截断/不溢出，不是验证吞吐性能。

**关键修复**：旧版本测试只查 server 侧 TX，server 仅发 ACK（TX≈0）永远无法满足阈值；修复后按方向分端查询，server 验 RX、client 验 TX，符合 TX/RX 计数不对称设计。

---

#### Test 11: 混合协议隔离

##### 一、测试目标

验证 TCP 和 UDP 同时传输时，内核 per-socket 统计按 socket 正确隔离，不会出现跨协议污染（TCP socket 不会统计到 UDP 数据，UDP socket 也不会统计到 TCP 数据）。这是 per-sock 统计正确性的基础。

##### 二、实现流程

代码见 [run-tests.sh:629-692](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L629-L692)，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 启动两个独立的 iperf3 server：TCP 端口 21411，UDP 端口 21412 | 使用不同端口，进程隔离 |
| 2 | `sleep 1` 等待两个 server 就绪 | |
| 3 | 同时启动两个 client：TCP client `-P 4 -t 5`、UDP client `-u -t 5 -b 20M`，均后台运行 | 同时产生 TCP 和 UDP 流量 |
| 4 | `sleep 2` 等待流量稳定 | |
| 5 | 查询 TCP server PID：统计 proto=tcp 和 proto=udp 行数 | 应该只有 TCP，没有 UDP |
| 6 | 查询 UDP server PID：统计 proto=tcp 和 proto=udp 行数 | 应该有 TCP(control) + UDP(data) |
| 7 | 断言，清理 | kill 两个 client 和两个 server |

##### 三、核心断言与原理

两个方向的协议隔离断言：
1. **TCP server**：`proto=tcp ≥ 5`（1 listen + 4 data），`proto=udp = 0`（TCP server 进程不应有 UDP socket）。
2. **UDP server**：`proto=tcp ≥ 1`（iperf3 UDP 模式用 TCP 做控制连接，必然有一个 TCP socket），`proto=udp ≥ 1`（数据 socket）。

**关键设计**：iperf3 UDP 模式也会建立一个 TCP 控制连接传输测试参数和结果，所以 UDP server 进程必然持有至少 1 个 TCP socket，这是正确行为不是 bug——我们断言的是"不应该有 UDP socket 出现在 TCP server 进程中"，而不是"UDP server 不能有 TCP socket"。

---

### 第四部分：边界条件（Test 12）

验证工具在极端输入下不崩溃、不泄漏、合理报错。4 个子检查使用本地计数器合并为 1 个测试编号，避免测试计数膨胀。

---

#### Test 12: 边界条件（PID 1 / 不存在PID / -h / -V）

##### 一、测试目标

验证 `get_sockdelays` 在各种边界输入下行为正确：
- 查询没有网络 socket 的系统进程（PID 1 init）不应崩溃
- 查询不存在的 PID 应明确报错
- `-h` 帮助和 `-V` 版本选项正常工作

##### 二、实现流程

代码见 [run-tests.sh:702-755](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L702-L755)，4 个子检查顺序执行：

| 子检查 | 操作 |
|--------|------|
| (a) PID 1 (init) | 执行 `get_sockdelays -p 1`，检查是否正常退出或输出 "no matching" |
| (b) PID 99999 (不存在) | 执行 `get_sockdelays -p 99999`，检查是否返回非零退出码 |
| (c) `-h` 帮助 | 执行 `get_sockdelays -h`，检查输出是否包含 "usage" 或 "用法" |
| (d) `-V` 版本 | 执行 `get_sockdelays -V`，检查是否正常退出（exit 0） |

使用本地计数器 `BOUNDARY_OK`/`BOUNDARY_NG` 汇总 4 个子检查结果，通过则统一 PASS。

##### 三、核心断言与原理

所有 4 项子检查全部通过才算 PASS：
- **(a) PID 1**：init 进程通常没有网络 socket，工具应正常退出（exit 0）或输出 "no matching sockets"，绝不能崩溃或 Oops。
- **(b) PID 99999**：不存在的 PID，工具应返回非零退出码表示错误，不能静默返回空结果假装成功。
- **(c) `-h`**：帮助信息应输出包含 "usage" 或 "用法"（大小写不敏感）。
- **(d) `-V`**：版本信息应正常输出，退出码为 0。

---

### 第五部分：稳定性（Test 13）

---

#### Test 13: 并发查询压力（空 PID + busy PID 混合）

##### 一、测试目标

验证多个进程同时对内核发起 Netlink dump 查询时，**内核并发安全**——per-sock spinlock 无死锁、`cb->ctx` 遍历无竞态、不会触发 Kernel Oops/BUG/panic。这是内核代码并发安全性的压力测试。

##### 二、实现流程

代码见 [run-tests.sh:765-901](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L765-L901)，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 启动 iperf3 busy server（端口 21413） | 持有活跃 socket，用于测试 per-socket 慢路径 |
| 2 | 启动 iperf3 client `-P 4 -t 30`（持续 30 秒） | 让 server 持有多条活跃 socket，持续有流量 |
| 3 | 启动 **4 个 worker 进程查 PID 1**（空 fdtable 快速返回路径） | 覆盖空 fdtable 快路径 |
| 4 | 启动 **4 个 worker 进程查 busy server PID**（per-sock 遍历慢路径） | 真正触发 `net_delayacct_fill_sock()`、获取 per-sock spinlock |
| 5 | 每个 worker 执行 **10 次查询**，记录成功/失败次数 | 总共 8 × 10 = 80 次查询 |
| 6 | `wait` 所有 worker 进程，逐个收集退出码 | 检测 worker 崩溃 |
| 7 | 汇总 worker 输出文件：统计 ok/fail/crashed 数量 | 输出文件不存在视为 worker 崩溃 |
| 8 | 检查 `dmesg` 尾部 100 行：搜索 `Kernel panic`/`Oops:`/`BUG:` | 检测内核 Oops |
| 9 | 清理 iperf3 server/client | |

##### 三、核心断言与原理

三个断言必须全部满足：
1. **无 worker 崩溃**（`_CRASH == 0`）：所有 worker 都正常退出，没有 segfault 等异常。
2. **dmesg 无内核错误**（`OOPS == 0`）：内核没有产生 panic、Oops 或 BUG 警告——这是并发安全的最终判据。
3. **busy worker 成功查询次数 > 0**（`_BUSY_OK > 0`）：证明 per-socket 慢路径确实被走到，不是所有查询都走了空 PID 快路径，测试覆盖了真正的并发竞争点。

**为什么混合空 PID + busy PID？**
- 仅查 PID 1（无 socket）只能覆盖 Netlink 控制路径和空 fdtable 遍历，不会调用到 `net_delayacct_fill_sock()`，也不会获取 per-sock spinlock，无法暴露并发问题。
- 加入 busy PID 才会真正触发 dumpit 遍历 fdtable、读取 per-sock 统计、执行过滤等逻辑，才能真正暴露 spinlock 并发、`cb->ctx` 遍历竞态等问题。
- 混合两种场景可以同时覆盖快路径和慢路径。

**参数选择**：4+4 workers × 10 queries = 80 次查询，兼顾 KVM（快速）和 TCG（软件模拟较慢）：TCG 下约 60-80 秒完成，留足时间给后续测试；KVM 下可轻松扩展。

---

### 第六部分：过滤功能（Test 14-16，于 v5.0.0 review 轮次引入）

验证内核侧 `net_delayacct_match_filter()` 6 维过滤功能（`--proto`/`--family`/`--lport`/`--rport`/`--laddr`/`--raddr`），确保过滤条件正确传递到内核、在内核 dumpit 回调中正确筛选 socket。

---

#### Test 14: 协议过滤（--proto）

##### 一、测试目标

验证 `--proto tcp` / `--proto udp` 协议过滤功能：过滤条件通过 netlink 属性正确传递到内核，dumpit 回调中比较 `sk->sk_protocol` 决定是否返回该 socket，不会错误返回其他协议的 socket。

##### 二、实现流程

代码见 [run-tests.sh:911-998](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L911-L998)，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 启动两个 iperf3 server：TCP 端口 21414，UDP 端口 21415 | |
| 2 | 启动两个 client：TCP client `-P 2 -t 8`、UDP client `-u -t 8 -b 10M`，均后台运行 | `-t 8` 保证三次查询期间 socket 存活 |
| 3 | `sleep 2` 等待连接建立 | |
| 4 | 三次查询 **UDP server PID**（它同时持有 TCP control socket 和 UDP data socket，天然具备两种协议）：<br>① 无过滤<br>② `--proto tcp`<br>③ `--proto udp` | UDP server 是最佳测试对象：同一个进程同时有 TCP 和 UDP socket，可以验证过滤是否生效 |
| 5 | negative case：`nc -u -l` 创建纯 UDP 进程 → `--proto tcp` 查询 | 验证"过滤失败时不返回任何结果"，而不是默认返回全部 |
| 6 | 统计每次查询的 tcp/udp 行数 | |
| 7 | 断言，清理 | |

##### 三、核心断言与原理

四个断言层层验证：
1. **无过滤基线**：tcp ≥ 1 且 udp ≥ 1，证明 UDP server 确实同时持有两种协议的 socket，测试前提成立。
2. **`--proto tcp`**：tcp ≥ 1 且 udp = 0，证明只返回 TCP，UDP 被过滤掉。
3. **`--proto udp`**：udp ≥ 1 且 tcp = 0，证明只返回 UDP，TCP 被过滤掉。
4. **negative case**：纯 UDP 进程用 `--proto tcp` 查询应返回 0 行，防止"过滤条件无效时默认返回全部 socket"这类实现缺陷。

**client -t 8**：iperf3 server 在 client 断开后会关闭与该 client 关联的 UDP 数据 socket，用较长的 `-t 8` 确保三次查询期间 UDP socket 存活。

---

#### Test 15: 端口过滤（--lport）

##### 一、测试目标

验证 `--lport <port>` 本地端口过滤功能：内核比较 `sk->sk_num`（host byte order，不是网络字节序，**不能用 ntohs**）匹配本地端口，只返回匹配指定本地端口的 socket。

##### 二、实现流程

代码见 [run-tests.sh:1000-1057](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L1000-L1057)，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 启动 iperf3 server 端口 21416 | |
| 2 | 启动 iperf3 client `-P 2 -t 3`，后台运行 | 产生多条连接，有多 socket |
| 3 | `sleep 2` 等待连接建立 | |
| 4 | 三次查询：<br>① 无过滤<br>② `--lport 21416`（匹配 server 监听端口）<br>③ `--lport 99999`（不存在的端口） | |
| 5 | 统计每次查询的 socket 总数、匹配端口数、非匹配端口数 | |
| 6 | 断言，清理 | |

##### 三、核心断言与原理

三个断言：
1. **无过滤**：socket 总数 ≥ 1，测试前提成立。
2. **`--lport 21416`**：匹配行 ≥ 1 且非匹配行 = 0，证明端口过滤生效，只返回本地端口为 21416 的 socket（listen socket + 对应端口的 established socket）。
3. **`--lport 99999`**：返回 0 行，不存在的端口不应返回任何 socket。

**端口匹配正则**：使用 `local=[^ ]*:$PORT( |$)` 匹配：
- `[^ ]*` 在遇到第一个空格（即 `remote=` 字段之前）停止，确保只匹配 `local=` 字段的端口，不会误匹配 `remote=` 字段的远端端口
- 兼容 IPv4（`127.0.0.1:21416`）和 IPv6（`[::1]:21416`）两种地址格式

---

#### Test 16: 组合过滤（--proto + --lport）

##### 一、测试目标

验证多个过滤条件同时传入时为 **AND 语义**——socket 必须同时满足所有过滤条件才会被返回，而不是满足任一条件就返回（OR 语义）。这是过滤功能正确性的关键。

##### 二、实现流程

代码见 [run-tests.sh:1059-1140](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L1059-L1140)，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 启动单个 iperf3 server 端口 21417（默认同时监听 TCP 和 UDP） | 单 server 简化进程管理 |
| 2 | **只启动 UDP client** `-u -t 8 -b 10M`，后台运行 | UDP client 会自动建立 TCP 控制连接，这样 server 同时持有 TCP(control) 和 UDP(data) socket，构成测试基线。不启动 TCP client 避免 iperf3 单线程处理导致 UDP client 无法建立连接 |
| 3 | `sleep 3` 等待 TCP 控制连接建立和 UDP 关联 | 比平时多睡 1 秒，给 UDP 连接留足时间 |
| 4 | 三次查询：<br>① 无过滤（baseline）<br>② `--proto tcp --lport 21417`（组合过滤）<br>③ `--proto udp --lport 99999`（negative 组合） | |
| 5 | 统计每次查询的 tcp/udp 行数、端口匹配数 | |
| 6 | 断言，清理 | |

##### 三、核心断言与原理

五个断言验证 AND 语义：
1. **无过滤基线**：tcp ≥ 1 且 udp ≥ 1，server 同时有 TCP 和 UDP socket，测试前提成立。
2. **组合过滤 tcp ≥ 1**：满足 proto=tcp 的 socket 存在。
3. **组合过滤 udp = 0**：UDP socket 被 `--proto tcp` 过滤掉，证明 proto 条件生效。
4. **组合过滤端口不匹配 = 0**：本地端口不是 21417 的 socket 被 `--lport` 过滤掉，证明 lport 条件生效。
5. **negative 组合 `--proto udp --lport 99999` 返回 0 行**：虽然 server 有 UDP socket（proto 条件满足），但没有 UDP socket 使用端口 99999（lport 条件不满足），AND 语义下结果应为空。这验证了"不是只要一个条件满足就返回结果"。

**为什么只启动 UDP client？**
- iperf3 server 是单线程处理的，如果并行启动 TCP client `-P 2` 会占用 server，导致 UDP client 无法建立 TCP 控制连接，server 侧不会出现 UDP 数据 socket，测试基线不成立。
- 只启动 UDP client，它会自带一个 TCP 控制连接，天然构造出"同一进程同时有 TCP 和 UDP socket"的测试场景。

---

### 第七部分：语义验证 / 双向流量 / 路径覆盖（Test 17-22，于 v6.0.0 review 轮次引入）

针对 v6.0.0 review 反馈新增：①RESET 非原子语义专项验证；②双向流量同 socket RX+TX；③iperf3 无法触发的 splice/zerocopy/corked/IPv6 路径专项覆盖。

---

#### Test 17: Reset 非原子语义（流量中 reset 后仍存在 count>0）

##### 一、测试目标

验证 RESET 不是全局原子快照：在活跃流量中执行 reset 后，新到达的包仍会继续累加计数，reset 不会阻塞或冻结后续包处理。reset 是"清零当前值"而非"停止统计"，这是与 Test 03（停止流量后 reset 验证清零能力本身）互补的语义验证。

##### 二、实现流程

代码见 [run-tests.sh:1150-1197](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L1150-L1197)，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 启动 iperf3 server 端口 21430 | |
| 2 | 启动 iperf3 client `-P 2 -t 12`（持续 12 秒，长流），后台运行 | 保证 reset 执行期间流量持续活跃，不会中途停止 |
| 3 | `sleep 3` 等待流量稳定并积累一定数据 | |
| 4 | **在流量持续传输中**执行 `get_sockdelays -R` 重置 | 关键：不停止流量直接 reset |
| 5 | `sleep 1` 等待 reset 完成，并让 reset 后新到达的包有时间累加 | |
| 6 | 查询 server PID：统计所有 `count>0` 的 socket 数量 | |
| 7 | 若首次查询为 0（极端 timing：reset 后恰好没有新包到达），`sleep 2` 后重试一次 | 容错 |
| 8 | 断言，清理 | |

##### 三、核心断言与原理

唯一核心断言：
- **reset 后存在 ≥ 1 个 count>0 的 socket**：证明 reset 只是清零了当时的统计值，但没有冻结后续统计，reset 之后到达的新包仍然会被正常计数——即 RESET 语义是非原子的、不阻塞的。

**与 Test 03 的关系**：
- Test 03：停止流量后 reset → 验证"清零能力本身"（reset 确实把已有计数清零了）
- Test 17：活跃流量中 reset → 验证"非原子语义"（reset 不会阻止新包继续累加）
- 两者共同构成对 RESET 语义的完整描述。

---

#### Test 18: 双向流量（iperf3 -R 反向，同 socket RX+TX>0）

##### 一、测试目标

验证同一个 socket 上 RX 和 TX 统计可以同时非零——即 socket 既接收数据又发送数据时，两个方向的统计都能正确工作，不会互相覆盖或干扰。iperf3 `-R` 反向模式让 server 发送数据，此时 server 侧同一个 socket 既有 TX（发送数据）又有 RX（收到 client 的 ACK）。

##### 二、实现流程

代码见 [run-tests.sh:1199-1240](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L1199-L1240)，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 启动 iperf3 server 端口 21431 | |
| 2 | 启动 iperf3 client `-R -t 6`（反向模式，server 发数据），后台运行 | `-R` 反向：client 接收，server 发送 |
| 3 | `sleep 3` 等待反向流量稳定 | |
| 4 | 查询 server PID：`get_sockdelays -p $_SRV` | server 在发数据（TX）同时收 ACK（RX） |
| 5 | awk 脚本逐行解析：遇到 `proto=` 行重置 rx/tx 标志；遇到 RX 行记录 rx count；遇到 TX 行记录 tx count；若同时 rx>0 && tx>0 则双向 socket 计数加 1 | 每个 socket 输出三行：proto/RX/TX |
| 6 | 断言双向 socket 数 ≥ 1，清理 | |

##### 三、核心断言与原理

唯一核心断言：
- **存在 ≥ 1 个 socket 同时 RX>0 且 TX>0**：证明同一 socket 上双向统计可以同时工作，互不干扰。

**awk 配对逻辑**：每个 socket 的输出是连续三行（proto 行 → RX 行 → TX 行），awk 按 proto 行重置状态，在 TX 行检查 RX 是否已经有值，从而统计出"同一 socket 双向都有计数"的数量。

**与 Test 09 的关系**：Test 09 是单向流量验证（server RX、client TX 分开验证方向分离）；Test 18 是双向流量验证（同一 socket 两个方向同时有计数），两者互补。

---

#### Test 19: TCP splice RX 路径（tcp_read_sock）

##### 一、测试目标

验证 `tcp_read_sock()` RX 路径打点正确：`splice()` 系统调用接收数据时走 `tcp_read_sock` 而非 `tcp_recvmsg_locked`，iperf3 使用常规 recvmsg 无法触发该路径，需要专用辅助程序覆盖。这是 v6.0.0 修复 BUG-5 后新增的路径覆盖测试。

##### 二、实现流程

代码见 [run-tests.sh:1242-1276](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L1242-L1276)，依赖辅助程序 `delayacct_path_test`，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 检查辅助程序 `delayacct_path_test` 是否存在 | 不存在则 SKIP（graceful degradation） |
| 2 | 启动 helper `splice-server` 监听端口 21432 | splice-server accept 连接后，用 `splice(sock_fd, ..., pipe_fd, ...)` + `splice(pipe_fd, ..., /dev/null, ...)` 将数据直接导到 `/dev/null`，不走 recvmsg/copy_to_user |
| 3 | `sleep 1` 等待 server 就绪 | |
| 4 | 启动 helper `tcp-sender` 连接 127.0.0.1:21432，发送 8 个数据包 | tcp-sender 是简单的 TCP 发送端 |
| 5 | `sleep 3` 等待数据传输和 splice 处理完成 | |
| 6 | 查询 splice-server PID：统计 TCP socket 数和 RX 总计数 | |
| 7 | 断言，清理 sender 和 server | |

##### 三、核心断言与原理

两个断言：
- **`proto=tcp` 行 ≥ 1**：splice-server 持有的 TCP socket 被枚举到。
- **RX 总计数 > 0**：证明 splice 路径（`tcp_read_sock`）的 RX end 打点被触发，数据被正确统计——这是本测试的核心目标，验证 BUG-5 修复后 splice 接收路径不再漏统计。

**辅助程序**：[tests/helper/delayacct_path_test.c](file:///home/lai/Code/NET_DELAYACCT/tests/helper/delayacct_path_test.c) 中的 `splice-server` 和 `tcp-sender` 子命令，专门用于触发 iperf3 无法覆盖的特殊路径。辅助程序未编译安装时测试优雅 SKIP，不会导致失败。

---

#### Test 20: TCP zerocopy RX 路径（tcp_zerocopy_receive）

##### 一、测试目标

验证 `tcp_zerocopy_receive()` RX 路径打点正确：`TCP_ZEROCOPY_RECEIVE` getsockopt（TCP 接收零拷贝）触发 `tcp_zerocopy_receive()` 内核函数接收数据，该路径绕过 `tcp_recvmsg_locked`，iperf3 不使用该机制，需要专用辅助程序覆盖。这是 v6.0.0 修复 BUG-6 后新增的路径覆盖测试。

##### 二、实现流程

代码见 [run-tests.sh:1278-1327](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L1278-L1327)，依赖辅助程序，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 检查辅助程序存在 | 不存在则 SKIP |
| 2 | 启动 helper `zerocopy-server` 监听端口 21433，日志输出到 `/tmp/zc.log` | zerocopy-server 关键实现：<br>① accept 后用 `mmap(cfd, ..., MAP_SHARED)` 创建 socket VMA（必须是 MAP_SHARED，不能是匿名 mmap）<br>② 设置 `TCP_MAXSEG = page_size + 12`（12 是 TCP timestamp 选项长度）提高页面对齐概率<br>③ 循环调用 `getsockopt(TCP_ZEROCOPY_RECEIVE)` 接收数据，处理 `recv_skip_hint` 消费非页面对齐数据 |
| 3 | `sleep 1`，检查 server 是否立即退出 | 若启动即退出（exit code 3），说明内核不支持 TCP_ZEROCOPY_RECEIVE（或 CONFIG_MMU=n），SKIP 测试 |
| 4 | 启动 helper `tcp-sender` 发送数据 | |
| 5 | `sleep 3` 等待传输完成 | |
| 6 | 再次检查 server 是否存活：若连接后退出（exit code 3）说明 getsockopt 失败，SKIP | |
| 7 | 查询 zerocopy-server PID：统计 TCP socket 数和 RX 总计数 | |
| 8 | 断言，清理 | |

##### 三、核心断言与原理

两个断言（内核支持 zerocopy 时）：
- **`proto=tcp` 行 ≥ 1**：TCP socket 被枚举到。
- **RX 总计数 > 0**：证明 `tcp_zerocopy_receive()` 路径的 RX end 打点被触发，零拷贝接收路径数据被正确统计——验证 BUG-6 修复。

**SKIP 降级机制**：
- helper 返回 exit code 3 表示内核不支持 `TCP_ZEROCOPY_RECEIVE`（可能是内核版本 < 5.18，或 `CONFIG_MMU=n`）
- 此时测试 SKIP 而非 FAIL，因为这是环境不支持而非代码 bug
- x86/x86_64 defconfig 默认启用 `CONFIG_MMU`，已在 `ci/kernel.config.fragment` 中显式声明

**struct 兼容注意**：helper 必须使用内核 UAPI 头 `<linux/tcp.h>` 中的 `struct tcp_zerocopy_receive` 定义（64 字节），不能使用用户态 `<netinet/tcp.h>` 中的定义（大小可能不匹配导致 `ENOPROTOOPT`）。

---

#### Test 21: UDP corked TX 路径（udp_push_pending_frames）

##### 一、测试目标

验证 `udp_push_pending_frames()` TX 路径打点正确：使用 `UDP_CORK` 选项时，多个 `sendmsg` 调用的数据被攒到一个大 skb 中，最后通过 `udp_push_pending_frames()` flush 发送。普通 UDP 发送（非 corked）走 `udp_sendmsg` 中 `ip_make_skb` 之后打点，corked 路径完全绕过该打点位置，需要在 `udp_push_pending_frames` 单独打 TX start。这是 v6.0.0 修复 BUG-2 后新增的路径覆盖测试。

##### 二、实现流程

代码见 [run-tests.sh:1330-1358](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L1330-L1358)，依赖辅助程序，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 检查辅助程序存在 | 不存在则 SKIP |
| 2 | 启动 helper `corked-udp-client` 向 127.0.0.1:21434 发送数据：<br>`setsockopt(UDP_CORK, 1)` → 发 8 个包 → `setsockopt(UDP_CORK, 0)` flush → 重复 | 每 8 个包 uncork 一次触发 `udp_push_pending_frames`，避免 cork 缓冲区超过 64K 导致 `EMSGSIZE`。**无需启动 server**，发往无监听端口仅产生 ICMP unreachable，不影响 TX 统计（因为 TX 打点在发送路径，与对端是否存在无关） |
| 3 | `sleep 1` 等待发送和 flush 完成 | |
| 4 | 查询 corked-udp-client PID：统计 UDP socket 数和 TX 总计数 | |
| 5 | 断言，清理 client | |

##### 三、核心断言与原理

两个断言：
- **`proto=udp` 行 ≥ 1**：UDP socket 被枚举到。
- **TX 总计数 > 0**：证明 corked 路径（`udp_push_pending_frames`）的 TX start 打点被触发，corked 发送数据被正确统计——验证 BUG-2 修复。

**无需接收端**：TX 打点位于 `udp_push_pending_frames`（发送路径，skb 构造完成即将发送时），与对端是否存在、是否回复 ICMP 无关，所以不需要启动 UDP server 来接收数据。

---

#### Test 22: IPv6 TCP+UDP 路径（iperf3 -c ::1）

##### 一、测试目标

验证 IPv6 loopback（`::1`）的 TCP/UDP 路径打点正确。IPv4 和 IPv6 在内核中是独立的协议栈实现：
- TCPv6：`tcp_v6_recvmsg`/`tcp_v6_sendmsg`（虽然最终会调用 IPv4 通用逻辑，但入口函数不同）
- UDPv6：`udpv6_recvmsg`/`udpv6_sendmsg`（独立于 UDPv4，v6.0.0 修复 BUG-1 后补上 UDPv6 打点）

只测 IPv4（127.0.0.1）无法保证 IPv6 路径无 bug，需要专项验证。

##### 二、实现流程

代码见 [run-tests.sh:1360-1420](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L1360-L1420)，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 检查 `/proc/net/if_inet6` 是否存在 | 不存在说明内核未启用 IPv6，SKIP 测试 |
| 2 | 启动 iperf3 server 端口 21435 | iperf3 默认双栈监听（同时支持 IPv4 和 IPv6） |
| 3 | 启动 IPv6 TCP client：`iperf3 -c ::1 -t 4`，后台运行 | 通过 IPv6 loopback 连接 |
| 4 | `sleep 3` 等待 TCP 传输完成，kill TCP client | |
| 5 | 启动 IPv6 UDP client：`iperf3 -u -c ::1 -t 6 -b 10M`，后台运行 | `-t 6` 保证查询时 UDP socket 存活 |
| 6 | `sleep 2` 等待 UDP 流量稳定 | |
| 7 | 查询 server PID：统计 IPv6 socket 数（`local=[`）和 RX 总计数 | |
| 8 | 查询 UDP client PID：统计 IPv6 socket 数和 TX 总计数 | |
| 9 | 断言，清理 | |

##### 三、核心断言与原理

三个断言：
1. **IPv6 socket 总数 ≥ 1**（server 和 client 侧加起来）：证明至少有一个 IPv6 socket 被枚举到，通过 `local=\[` 正则匹配（IPv6 地址在输出中用方括号包裹，如 `local=[::1]:21435`）。
2. **server RX > 0**：IPv6 TCP 接收路径打点工作正常。
3. **UDP client TX > 0**：IPv6 UDP 发送路径打点工作正常（验证 BUG-1 修复，UDPv6 打点）。

**IPv6 检测方式**：工具输出目前没有显式 `family=` 字段，IPv6 通过地址格式隐式检测——IPv6 地址在输出中会被方括号包裹（`[::1]`、`[fe80::...]`），用 `local=\[` 正则即可匹配。

---

### 第八部分：ftrace 打桩点全量验证（Test 23，于 v6.1.0 review 轮次引入）

验证内核打桩点的真实可达性：每个测试场景是否真的触发了预期的内核打桩函数？这是从"黑盒结果验证"升级到"灰盒路径验证"的关键步骤。

#### Test 23: ftrace 打桩点全量验证（13 函数 × 7 场景）

##### 一、测试目标

通过 ftrace function tracer 验证 13 个内核打桩函数在每个测试场景下被真实触发，解决"打桩点是否真的被走到"的根本性质疑。

##### 二、实现流程

代码见 [run-tests.sh:1597-1846](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L1597-L1846)，步骤如下：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 检查 `/sys/kernel/debug/tracing` 是否存在且可写 | 不存在说明 `CONFIG_FTRACE` 未启用，SKIP |
| 2 | 定义 13 个 ftrace 函数清单 | 覆盖全部 12 个打桩点（rx_start×1, rx_end×5, tx_end×1, tx_start×5） |
| 3 | 对每个场景：启用 ftrace filter → 运行流量 → 停止 ftrace → 统计函数调用次数 | 13 函数 × 7 场景 |
| 4 | 断言每个场景的预期函数调用次数 > 0 | 缺失则标记 `[MISS]` |
| 5 | 生成"场景 × 函数"覆盖矩阵 | 可视化展示各函数在各场景的调用次数 |

##### 三、核心断言与原理

13 个 ftrace 函数映射到 12 个打桩点：

| 打桩点 | ftrace 函数 | 方向 |
|--------|------------|------|
| `rx_start` | `__netif_receive_skb_core` | RX 入口 |
| `rx_end` (标准 TCP) | `tcp_recvmsg_locked` | RX 出口 |
| `rx_end` (splice) | `tcp_read_sock` | RX 出口 |
| `rx_end` (zerocopy) | `tcp_zerocopy_receive` | RX 出口 |
| `rx_end` (IPv4 UDP) | `udp_recvmsg` | RX 出口 |
| `rx_end` (IPv6 UDP) | `udpv6_recvmsg` | RX 出口 |
| `tx_end` | `dev_hard_start_xmit` | TX 出口 |
| `tx_start` (TCP clone) | `__tcp_transmit_skb` | TX 入口 |
| `tx_start` (TCP 重传) | `__tcp_retransmit_skb` | TX 入口 |
| `tx_start` (IPv4 UDP fast) | `udp_sendmsg` | TX 入口 |
| `tx_start` (IPv4 UDP cork) | `udp_push_pending_frames` | TX 入口 |
| `tx_start` (IPv6 UDP fast) | `udpv6_sendmsg` | TX 入口 |
| `tx_start` (IPv6 UDP cork) | `udp_v6_push_pending_frames` | TX 入口 |

7 个场景的预期函数：

| 场景 | 预期触发的 ftrace 函数 |
|------|----------------------|
| S1 TCP 单向 | `__netif_receive_skb_core`, `tcp_recvmsg_locked`, `__tcp_transmit_skb`, `dev_hard_start_xmit` |
| S2 UDP 单向 | `__netif_receive_skb_core`, `udp_recvmsg`, `udp_sendmsg`, `dev_hard_start_xmit` |
| S3 TCP splice | `__netif_receive_skb_core`, **`tcp_read_sock`**, `__tcp_transmit_skb`, `dev_hard_start_xmit` |
| S4 TCP zerocopy | `__netif_receive_skb_core`, **`tcp_zerocopy_receive`**, `__tcp_transmit_skb`, `dev_hard_start_xmit` |
| S5 UDP corked | **`udp_push_pending_frames`**, `dev_hard_start_xmit` |
| S6 IPv6 TCP+UDP | `__netif_receive_skb_core`, `tcp_recvmsg_locked`, **`udpv6_recvmsg`**, **`udpv6_sendmsg`**, `__tcp_transmit_skb`, `dev_hard_start_xmit` |
| S7 TCP 重传 (tc netem 丢包) | `__netif_receive_skb_core`, `tcp_recvmsg_locked`, `__tcp_transmit_skb`, **`__tcp_retransmit_skb`**, `dev_hard_start_xmit` |

**加粗**的函数是该场景的"专属验证目标"——如果这些函数调用次数为 0，说明声称的路径覆盖是假的（例如 splice 回退到了标准路径）。

**S7 双轨备选**：先尝试 `tc netem loss 10%`（需 `CONFIG_NET_SCH_NETEM`），失败则降级到 `iptables -m statistic --mode random --probability 0.1 -j DROP`（需 `CONFIG_NETFILTER_XTABLES`）。两者均不可用时 S7 SKIP 而非 FAIL。

##### 四、可视化矩阵输出

测试结束时生成覆盖矩阵，直观展示每个场景下各函数的调用次数：

```
+----------------------------------------------------------+
|  ftrace 覆盖矩阵 (场景 × 函数调用次数)                   |
+----------------------------------------------------------+
| 函数                       | S1  | S2  | S3  | S4  | S5  | S6  | S7  |
|----------------------------|-----|-----|-----|-----|-----|-----|-----|
| __netif_receive_skb_core   | 542 | 318 | 210 | 187 |  45 | 612 | 891 |
| tcp_recvmsg_locked         | 128 |   0 |   0 |   0 |   0 |  56 | 145 |
| tcp_read_sock              |   0 |   0 |  42 |   0 |   0 |   0 |   0 |
| ...                        | ... | ... | ... | ... | ... | ... | ... |
+----------------------------------------------------------+
```

**矩阵解读规则**：
- 每一列（场景）的"预期函数"应全部非零 → 该场景 PASS
- 每一行（函数）至少在一个场景下非零 → 该打桩点可达
- `tcp_read_sock` 只在 S3 非零 → 证明 splice 路径专属
- `__tcp_retransmit_skb` 只在 S7 非零 → 证明重传路径专属

---

## 三、测试方法总结

### 3.1 覆盖矩阵

| 维度 | 覆盖情况 |
|------|----------|
| **查询维度** | PID 查询（dumpit）、inode 查询（doit）、RESET、JSON 输出、Debug 模式、协议过滤、端口过滤、组合过滤 |
| **协议覆盖** | TCP（Test 01/04/06/07/09/10/11/14/15/16/18/19/20/22）、UDP（Test 05/11/14/16/21/22） |
| **IPv4/IPv6** | IPv4（loopback 127.0.0.1，所有测试）；IPv6（`::1` loopback，**Test 22 专项验证** tcpv6/udpv6 sendmsg/recvmsg 路径） |
| **RX 路径覆盖** | `tcp_recvmsg_locked`（iperf3 recvmsg）、`tcp_read_sock`（Test 19 splice）、`tcp_zerocopy_receive`（Test 20）、`udp_recvmsg`/`udpv6_recvmsg`（Test 05/22） |
| **TX 路径覆盖** | `tcp_sendmsg` clone 路径（iperf3 sendmsg）、`udp_sendmsg`/`udpv6_sendmsg`（Test 05/22）、`udp_push_pending_frames` corked 路径（Test 21） |
| **负载等级** | 单连接 → 4 并行 → 8 并行 → 8 worker × 10 queries 并发（空 PID + busy PID 混合） |
| **数据验证** | socket 数量（不漏）、协议类型（不错）、RX/TX count（不溢出/不截断）、计数器重置（真清零 + 非原子语义）、过滤精确性（含 negative case）、双向流量（同 socket RX+TX） |
| **边界条件** | 正常 PID、PID 1（无 socket）、不存在 PID（99999）、help、version |
| **稳定性** | 80 次并发查询（空+busy 混合）+ dmesg Kernel Oops 检测 |
| **offload 交互** | GRO/GSO 在 loopback + e1000 虚拟网卡上自然触发，通过 count 阈值验证计数逻辑正确 |
| **路径可达性** | **Test 23 ftrace 验证**：13 个打桩函数在 7 个场景下的真实调用次数，确保打点代码被真实执行 |

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
  helper/                                      路径覆盖辅助程序（Test 19-21）
    delayacct_path_test.c                      splice/zerocopy/corked 路径覆盖源码
    Makefile                                   静态编译（方便打包进 initramfs）

ci/
  qemu/
    run-tests.sh                              **统一测试套件入口**（当前活跃，22 项测试）
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
| CI KVM 硬超时 | 300s | `QEMU_TIMEOUT_KVM=300` |
| CI TCG 硬超时 | 600s | `QEMU_TIMEOUT_TCG=600`（软件模拟慢） |
| Guest 内部 watchdog | 540s | guest-init.sh 中的 `sleep 540; poweroff -f` |
| run-tests.sh 整体超时 | 由 guest-init 的 `timeout 480` 包裹整个脚本 | 单测无独立超时 |

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

2. **端口占用**：run-tests.sh 使用端口范围 21401-21435，确保不与宿主机其它服务冲突；QEMU user-mode 网络与宿主机隔离，无此问题。

3. **get_sockdelays 路径查找优先级**：
   - 环境变量 `GET_SOCKDELAYS`
   - `/usr/local/bin/get_sockdelays`（QEMU guest 内默认安装路径）

4. **ccache 缓存**：CI 内核编译使用稳定 ccache key，热缓存下编译仅 ~30 秒-2 分钟。修改 patch 后首次运行需全量编译约 10 分钟建立缓存。

5. **KVM 降级**：`/dev/kvm` 不可用时自动降级为 TCG 软件模拟，但耗时增加 10-20 倍；测试阈值已取保守值适配 TCG。

6. **patch 上下文差异**：`sock_h-modification.patch`、`skbuff_h-modification.patch`、`rx-instrumentation.patch`、`tx-instrumentation.patch` 的上下文行在不同 6.6.x point release 之间可能略有差异。`git apply` 失败时改用 `patch -p1 --fuzz=3 < xxx.patch`。

7. **用户态工具编译**：`make -B tool` 强制无条件重建 get_sockdelays，避免使用 stale 二进制。Makefile 已添加 `-I.` 支持本地 UAPI header 回退，无 sudo 权限时不安装到 `/usr/include` 也能编译。

8. **RX/TX 计数语义不对称**：RX 在 `__netif_receive_skb_core` 入口计入（覆盖所有入包，含纯 ACK）；TX 仅在 `tcp_sendmsg`/`udp_sendmsg` 等路径计入（只覆盖应用层 sendmsg 出包，ACK/重传 clone 路径有特殊处理）。测试中断言 TX>0 必须查发送方（client），纯接收方（如 iperf3 server）TX=0 是正确行为。

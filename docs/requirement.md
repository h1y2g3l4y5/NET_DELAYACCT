# NET_DELAYACCT 需求分析

> 配套文档：`docs/background.md`（项目背景）、`docs/design.md`（技术设计）、`.trae/specs/implement-net-delayacct-framework/spec.md`（原始 spec）。
> 本文以 spec.md 中 ADDED Requirements 与 Scenario 为验收标准来源，按软件工程需求文档规范展开。

---

## 1. 项目概述

NET_DELAYACCT 在 Linux 6.6 内核中参考 `CONFIG_DELAYACCT` 的设计思想，新增 `CONFIG_NET_DELAYACCT` 框架与用户态工具 `get_sockdelays`，按进程 PID 或 socket inode 输出每个 socket 的平均收发时延，填补网络时延观测能力的空白。

详细背景与价值见 `docs/background.md`。

---

## 2. 用户故事

### US-1：运维工程师按 PID 查询 socket 时延

> **作为运维工程师**，我希望按 PID 查看该进程下每个 socket 的平均收发时延，以便在业务慢请求告警时快速定位"是网络栈慢还是应用处理慢"。

**接受场景**：

- 启动一个 nginx 进程，PID=1234。
- 执行 `./get_sockdelays -p 1234`。
- 工具输出多行，每行对应 nginx 持有的一个 socket，字段含类型、五元组、comm、pid、平均 RX 时延、平均 TX 时延。
- 若 nginx 同时持有 listen socket 与多个 established socket，每条都单独输出。

### US-2：运维工程师按 inode 查询单个 socket

> **作为运维工程师**，我希望按 inode 查看 /proc/<pid>/fd 中某个 socket 的时延，以便精确定位"是哪个具体的连接出了问题"。

**接受场景**：

- `readlink /proc/1234/fd/7` 返回 `socket:[12345]`。
- 执行 `./get_sockdelays -i 12345`。
- 工具输出单行，对应 inode=12345 的 socket 的完整时延信息。

### US-3：SRE 重置统计

> **作为 SRE**，我希望清零所有 socket 的时延统计，以便在内核升级或配置变更后从干净基线开始观测。

**接受场景**：

- 执行 `./get_sockdelays -r`。
- 工具输出 `Statistics reset for all sockets`。
- 后续查询的时延从 0 开始累加。

### US-4：内核开发者评估性能影响

> **作为内核开发者**，我希望关闭 `CONFIG_NET_DELAYACCT` 后内核行为与原生 6.6 完全一致，以便发行版内核可以放心不开此选项。

**接受场景**：

- `make defconfig && scripts/config --disable CONFIG_NET_DELAYACCT && make -j$(nproc)`。
- 编译出的 `vmlinux` 与 `net/core/dev.o` 大小与原生 6.6 几乎相同（仅相差正常编译抖动）。
- iperf3 吞吐与原生 6.6 误差 < 0.5%。
- `struct sock` / `struct sk_buff` 大小不变。

### US-5：监控 agent 持续采集

> **作为监控 agent 开发者**，我希望以固定间隔循环采集所有业务进程的 socket 时延，以便接入 Grafana 面板。

**接受场景**：

- 工具支持 `./get_sockdelays -p <pid> -d -i <interval>` 类似的 dump 模式（与 getdelays 风格一致）。
- 输出格式稳定可解析（机器友好模式可选）。

---

## 3. 功能需求

### FR-1：CONFIG_NET_DELAYACCT Kconfig 选项

**需求**：系统 SHALL 在 `net/Kconfig` 中提供 `config NET_DELAYACCT` 选项，依赖 `NET`，默认 `n`，含 `help` 文本说明用途与开销。

**验收**：

- `make menuconfig` 中可见该选项，位于 "Networking support" → "Networking options" 下。
- 选项默认未勾选。
- help 文本含项目名、用途、性能开销提示。

### FR-2：per-sock 时延统计结构

**需求**：系统 SHALL 在 `struct sock` 中嵌入 `struct net_delayacct`（受 `#ifdef CONFIG_NET_DELAYACCT` 保护），维护以下累计字段：

- `rx_total_ns`：接收方向累计时延（纳秒）
- `rx_count`：接收方向累计报文数
- `tx_total_ns`：发送方向累计时延（纳秒）
- `tx_count`：发送方向累计报文数

并通过 per-socket `spinlock_t` 保护累加操作。

**验收**：

- 开启选项时 `sizeof(struct sock)` 增加 `sizeof(struct net_delayacct)`（约 56-64 字节）。
- 关闭选项时 `sizeof(struct sock)` 不变。
- `sock_init_data` 中初始化 `sk->sk_net_delayacct`。

### FR-3：skb 时间戳字段

**需求**：系统 SHALL 在 `struct sk_buff` 中新增 `ktime_t delayacct_start` 字段（受 `#ifdef CONFIG_NET_DELAYACCT` 保护），用于携带报文进入协议栈的起始时间戳。

**验收**：

- 开启选项时 `sizeof(struct sk_buff)` 增加 8 字节。
- 关闭选项时 `sizeof(struct sk_buff)` 不变。
- skb 分配时该字段默认为 0（zero-initialized）。

### FR-4：RX 路径插桩

**需求**：系统 SHALL 在以下位置插桩，统计 RX 时延：

- **start**：`net/core/dev.c` 的 `__netif_receive_skb_core` 函数入口，调用 `net_delayacct_rx_start(skb)` 写入 `skb->delayacct_start`。
- **end (TCP)**：`net/ipv4/tcp.c` 的 `tcp_recvmsg` 中拷贝到用户态前，调用 `net_delayacct_rx_end(sk, skb)` 累加到 sock。
- **end (UDP)**：`net/ipv4/udp.c` 的 `__skb_recv_udp` 中返回 skb 前，调用 `net_delayacct_rx_end(sk, skb)` 累加到 sock。

**验收**：

- 向目标 socket 发送 N 个报文，进程读取 N 次后，`rx_count == N`。
- `rx_total_ns > 0`。
- 关闭选项时所有插桩编译为空操作。

### FR-5：TX 路径插桩

**需求**：系统 SHALL 在以下位置插桩，统计 TX 时延：

- **start (TCP)**：`net/ipv4/tcp.c` 的 `tcp_sendmsg` 中对每个新生成的 skb 调用 `net_delayacct_tx_start(skb)`。
- **start (UDP)**：`net/ipv4/udp.c` 的 `udp_sendmsg` 中对生成的 skb 调用 `net_delayacct_tx_start(skb)`。
- **end**：`net/core/dev.c` 的 `dev_hard_start_xmit` 中调用 `ops->ndo_start_xmit` 前，调用 `net_delayacct_tx_end(skb->sk, skb)` 累加到 sock。

**验收**：

- 进程通过目标 socket 发送 N 个报文后，`tx_count == N`。
- `tx_total_ns > 0`。
- GSO 场景下，一次 `send()` 拆成多个 MTU 报文，按 1 次计数（计 GSO skb 一次）。
- 关闭选项时所有插桩编译为空操作。

### FR-6：Generic Netlink 接口

**需求**：系统 SHALL 注册 generic netlink family `net_delayacct`（version=1），支持以下命令：

- `NET_DELAYACCT_CMD_GET_BY_PID`：请求携带 `NET_DELAYACCT_A_PID`（u32）；响应为多条消息（`NLM_F_MULTI` + `NLMSG_DONE`），每条消息携带目标 PID 下一个 socket 的完整属性集合。
- `NET_DELAYACCT_CMD_GET_BY_INODE`：请求携带 `NET_DELAYACCT_A_INODE`（u64）；响应为单条消息（或多条中匹配的那条）。
- `NET_DELAYACCT_CMD_RESET`：清零所有 socket 的时延统计。

每条响应消息的属性包含：`TYPE`（u8）、`LADDR`（4B 或 16B）、`LPORT`（u16）、`RADDR`、`RPORT`、`COMM`（string）、`PID`（u32）、`RX_TOTAL_NS`（u64）、`RX_COUNT`（u64）、`TX_TOTAL_NS`（u64）、`TX_COUNT`（u64）、`INODE`（u64）。

**验收**：

- `cat /proc/net/genetlink` 中可见 `net_delayacct` family。
- 用户态工具能通过 `genl_ctrl_search_by_name("net_delayacct")` 获取 family ID。
- 三条命令均能正确响应。
- 多 socket 场景下响应多条消息并以 `NLMSG_DONE` 结束。

### FR-7：get_sockdelays 用户态工具

**需求**：系统 SHALL 提供 `tools/net/get_sockdelays` 工具，支持以下命令行选项：

| 选项 | 含义 |
|------|------|
| `-p <pid>` | 查询指定 PID 的所有 socket 时延 |
| `-i <inode>` | 查询指定 inode 的 socket 时延 |
| `-r` | 重置所有 socket 时延统计 |
| `-n` | 输出时延单位为 ns（默认 μs） |
| `-d` | dump 模式，循环输出 |
| `-t <interval>` | dump 间隔（秒，默认 1） |
| `-h` | 显示帮助 |

**验收**：

- `make -C tools/net get_sockdelays` 构建成功。
- `./get_sockdelays -p <pid>` 输出多行，每行一个 socket。
- `./get_sockdelays -i <inode>` 输出单行。
- `./get_sockdelays -r` 输出确认信息。
- 平均时延 = 累计时延 / 计数；计数为 0 时显示 `N/A`。
- 输出表头与字段对齐，IPv4/IPv6 地址正确格式化。

### FR-8：文档与测试

**需求**：系统 SHALL 提供：

- `Documentation/networking/net-delayacct.rst`：用户文档，覆盖启用方式、原理、使用示例、输出字段说明、性能开销。
- `tools/testing/selftests/net/net-delayacct/`：自测试套件，含功能与回归用例。
- `docs/` 目录下的设计文档与背景文档。

**验收**：

- `make -C tools/testing/selftests TARGETS=net` 包含 `net-delayacct` 子目录。
- 所有测试用例通过。
- 用户文档含可执行示例。

---

## 4. 非功能需求

### NFR-1：性能

- **NFR-1.1**：单次插桩（start 或 end）开销不超过 100 ns（x86_64，TSC ~3GHz）。
- **NFR-1.2**：在 10Gbps 小包场景（14.88 Mpps）下，开启 `CONFIG_NET_DELAYACCT` 后吞吐下降不超过 5%。
- **NFR-1.3**：关闭 `CONFIG_NET_DELAYACCT` 时，所有插桩编译为空操作，二进制大小与原生 6.6 内核一致（误差 < 0.1%）。
- **NFR-1.4**：内存开销：每个 `struct sock` 增加不超过 80 字节，每个 `struct sk_buff` 增加不超过 8 字节。

### NFR-2：可移植性

- **NFR-2.1**：支持 x86_64 与 ARM64 架构。
- **NFR-2.2**：支持 SMP，per-sock spinlock 保证累加 SMP-safe。
- **NFR-2.3**：兼容 Linux 6.6 mainline（不依赖特定 vendor patch）。
- **NFR-2.4**：用户态工具支持 glibc 2.17+ 与 musl libc。

### NFR-3：可维护性

- **NFR-3.1**：内核代码严格遵循 `Documentation/process/coding-style.rst`，`scripts/checkpatch.pl` 无 WARNING/ERROR。
- **NFR-3.2**：所有插桩点与数据结构有 Doxygen 风格注释说明用途。
- **NFR-3.3**：patch 系列按"独立功能"拆分，每个 patch 单独可编译、单独有意义。
- **NFR-3.4**：UAPI 头文件版本化（`NET_DELAYACCT_GENL_VERSION=1`），后续扩展保持向后兼容。

### NFR-4：安全

- **NFR-4.1**：查询其他 PID 的 socket 时延需要 `CAP_NET_ADMIN` 或同等权限（具体策略与 sock_diag 一致）。
- **NFR-4.2**：RESET 命令需要 `CAP_NET_ADMIN`。
- **NFR-4.3**：不暴露敏感信息（如应用层数据、密钥），仅暴露五元组与时延统计。
- **NFR-4.4**：genl family 注册使用 `resv_start_op`，未定义命令被拒绝，防止 fuzz 攻击。

### NFR-5：文档

- **NFR-5.1**：提供完整的用户文档 `Documentation/networking/net-delayacct.rst`。
- **NFR-5.2**：提供开发文档 `docs/design.md`、`docs/background.md`、`docs/requirement.md`、`docs/research-delayacct.md`、`docs/protocol-stack.md`。
- **NFR-5.3**：所有文档使用简体中文（项目内部文档）或英文（投稿上游的内核文档），无 emoji。
- **NFR-5.4**：文档中使用 ASCII 图，不使用 mermaid 等需要外部渲染的格式。

---

## 5. 验收标准

### 5.1 与 spec.md 一致性

本需求的验收标准与 `.trae/specs/implement-net-delayacct-framework/spec.md` 中的 ADDED Requirements 一一对应：

| 本需求 ID | spec.md Scenario |
|-----------|------------------|
| FR-2 | "Requirement: 内核时延统计框架" → "Scenario: 接收时延统计" / "Scenario: 发送时延统计" |
| FR-2 + FR-3 | "Requirement: 内核时延统计框架" → "Scenario: 关闭选项时零开销" |
| FR-6 | "Requirement: Generic Netlink 查询接口" → "Scenario: 按 PID 查询" / "Scenario: 按 inode 查询" / "Scenario: 重置统计" |
| FR-7 | "Requirement: get_sockdelays 用户态工具" → "Scenario: 按 PID 查询" / "Scenario: 按 inode 查询" / "Scenario: 平均时延计算" |
| FR-8 | "Requirement: 文档与测试" → "Scenario: 用户文档" / "Scenario: 自测试套件" |

### 5.2 详细验收清单

#### 内核侧

- [ ] `net/Kconfig` 含 `config NET_DELAYACCT`，依赖 `NET`，默认 `n`，含 help 文本
- [ ] `net/core/Makefile` 含 `obj-$(CONFIG_NET_DELAYACCT) += net-delayacct.o`
- [ ] `make menuconfig` 可见该选项
- [ ] `include/uapi/linux/net-delayacct.h` 定义 `struct net_delayacct_stats`、命令枚举、属性枚举
- [ ] `include/net/net-delayacct.h` 定义 `struct net_delayacct` 与受 `#ifdef` 保护的内联接口
- [ ] `include/net/sock.h` 的 `struct sock` 嵌入 `struct net_delayacct`（受 `#ifdef` 保护）
- [ ] `include/linux/skbuff.h` 的 `struct sk_buff` 含 `ktime_t delayacct_start`
- [ ] `net/core/net-delayacct.c` 实现初始化、累加、查询、重置，使用 spinlock 保证 SMP 安全
- [ ] RX 路径在 `__netif_receive_skb_core` 起始记录 `skb->delayacct_start`
- [ ] RX 路径在 `tcp_recvmsg`/`__skb_recv_udp` 拷贝前调用 `net_delayacct_rx_end` 累加
- [ ] TX 路径在 `tcp_sendmsg`/`udp_sendmsg` 入口记录起始时间
- [ ] TX 路径在 `dev_hard_start_xmit` 调用 `net_delayacct_tx_end` 累加
- [ ] GSO/分片场景已处理并记录于 `docs/design.md`
- [ ] generic netlink family `net_delayacct` 已注册，`/proc/net/genetlink` 可见
- [ ] `NET_DELAYACCT_CMD_GET_BY_PID` 正确遍历目标 PID 所有 socket，返回每个 socket 的完整属性
- [ ] `NET_DELAYACCT_CMD_GET_BY_INODE` 仅返回指定 inode 的统计
- [ ] `NET_DELAYACCT_CMD_RESET` 清零所有 sock 统计
- [ ] 多 socket 回复使用 `NLM_F_MULTI` + `NLMSG_DONE`
- [ ] 关闭 `CONFIG_NET_DELAYACCT` 时所有插桩编译为空操作，`struct sock`/`struct sk_buff` 无新增字段
- [ ] 开启选项的内核可正常启动，无 oops、无 hung task
- [ ] 内核代码遵循 `Documentation/process/coding-style.rst`，`scripts/checkpatch.pl` 无 WARNING

#### 用户态工具侧

- [ ] `tools/net/get_sockdelays.c` 存在，结构参考 `getdelays.c`
- [ ] `tools/net/Makefile` 可通过 `make -C tools/net get_sockdelays` 构建出可执行文件
- [ ] 命令行支持 `-p <pid>`、`-i <inode>`、`-r`、`-h`、`-n`、`-d`、`-t <interval>`
- [ ] 通过 `genl_ctrl_search_by_name` 正确解析 family
- [ ] `GET_BY_PID` 可发送并接收多消息回复
- [ ] `GET_BY_INODE` 可发送并接收单条回复
- [ ] 属性解析覆盖：type、laddr、lport、raddr、rport、comm、pid、rx_total_ns、rx_count、tx_total_ns、tx_count、inode
- [ ] 平均时延 = 累计时延 / 计数，计数为 0 时显示 `N/A`
- [ ] 输出表头与字段对齐：`TYPE  LADDR  LPORT  RADDR  RPORT  COMM  PID  AVG_RX(μs)  AVG_TX(μs)`
- [ ] IPv4/IPv6 地址可正确格式化
- [ ] `-n` 选项可切换为 ns 单位输出
- [ ] 单进程多 socket 场景下输出多行，每行对应一个 socket

#### 测试侧

- [ ] `tools/testing/selftests/net/net-delayacct/` 目录与 Makefile 存在
- [ ] KUnit 单元测试覆盖累加、重置、并发安全，全部通过
- [ ] `tests/func/test_pid_query.sh` 验证 `-p` 多 socket 输出，通过
- [ ] `tests/func/test_inode_query.sh` 验证 `-i` 输出，通过
- [ ] `tests/func/test_reset.sh` 验证 `-r` 后统计归零，通过
- [ ] `tests/func/test_multi_socket.sh` 验证单进程多 socket 分别显示，通过
- [ ] `tests/func/test_tcp_udp.sh` 分别验证 TCP、UDP 路径，通过
- [ ] `tests/perf/baseline-vs-enabled.sh` 输出开启前后吞吐/RTT 对比数据
- [ ] `tests/perf/long-run.sh` 24h 运行无 `kmemleak` 报告、无死锁
- [ ] `tests/perf/concurrent-query.sh` 高并发查询无 race
- [ ] 回归测试：关闭 `CONFIG_NET_DELAYACCT` 内核行为与原生 6.6 一致
- [ ] `docs/test-report.md` 完整，含覆盖矩阵、通过率、性能数据、问题清单

#### 文档侧

- [ ] `Documentation/networking/net-delayacct.rst` 已编写，含选项说明、原理图、示例、字段表、开销
- [ ] `Documentation/networking/index.rst` 已添加索引条目
- [ ] `docs/background.md` 涵盖项目背景与意义
- [ ] `docs/requirement.md` 完整描述按 PID / 按 inode 需求与字段定义
- [ ] `docs/design.md` 含架构图、数据结构、插桩点、netlink 协议、锁设计、性能评估
- [ ] `docs/research-delayacct.md` 含 DELAYACCT 框架研究
- [ ] `docs/protocol-stack.md` 含协议栈 RX/TX 路径研究
- [ ] `docs/implementation-notes.md` 含关键代码解析与踩坑记录
- [ ] `docs/upstream-plan.md` 含 patch 系列拆分、收件人列表、邮件列表投稿计划
- [ ] 内核 patch 含 `Signed-off-by`，commit message 符合 `submitting-patches.rst`

### 5.3 总体质量门禁

- [ ] `scripts/checkpatch.pl` 对所有内核 patch 无 WARNING/ERROR
- [ ] `make -C tools/testing/selftests TARGETS=net` 全部通过
- [ ] 项目可在 4 周内交付：内核 patch 系列、用户态工具、文档、测试报告、答辩材料

---

## 6. 约束

### 6.1 技术约束

- **C-1**：基于 Linux 6.6 内核 mainline（git tag `v6.6`）。
- **C-2**：所有内核代码遵循 `Documentation/process/coding-style.rst`。
- **C-3**：所有 patch 遵循 `Documentation/process/submitting-patches.rst`，含 `Signed-off-by`、合理的 commit message、patch 分系列。
- **C-4**：用户态代码风格与 `tools/account/getdelays.c` 保持一致。
- **C-5**：使用 generic netlink 框架（不用 netlink raw）。
- **C-6**：UAPI 头文件使用 `__u8/__u16/__u32/__u64` 等定长类型，跨架构稳定。
- **C-7**：不修改 `kernel/delayacct.c`、`kernel/taskstats.c`、`tools/account/getdelays.c` 等既有 delayacct 文件。
- **C-8**：不修改 `.trae/specs/` 下的 spec 文件。

### 6.2 许可证约束

- **C-9**：所有内核代码使用 `GPL-2.0-only` 许可证（与内核兼容）。
- **C-10**：UAPI 头文件使用 `GPL-2.0-only WITH Linux-syscall-note`（允许用户态应用包含）。
- **C-11**：用户态工具使用 `GPL-2.0-only`（与 `getdelays.c` 一致）。

### 6.3 文档约束

- **C-12**：所有项目内部文档使用简体中文。
- **C-13**：文档中不使用 emoji。
- **C-14**：文档中使用 ASCII 图，不使用 mermaid 等需要外部渲染的格式。
- **C-15**：投稿上游的内核文档（`Documentation/networking/net-delayacct.rst` 等）使用英文。
- **C-16**：技术内容必须精确，引用具体内核函数名、文件路径、版本号。

### 6.4 项目流程约束

- **C-17**：项目工期 4 周（28 个工作日），按 `.trae/specs/implement-net-delayacct-framework/tasks.md` 阶段计划执行。
- **C-18**：仓库分支策略：`main`（稳定）、`dev`（开发）、`feature/*`（功能分支）。
- **C-19**：CI 配置（GitHub Actions）须包含内核编译、工具编译、selftests 三个阶段。
- **C-20**：所有内核 patch 须通过 `scripts/checkpatch.pl` 检查。

---

## 7. 假设与依赖

### 7.1 假设

- A-1：目标系统为 x86_64 或 ARM64 Linux，运行 Linux 6.6 内核。
- A-2：用户态工具运行在支持 `AF_GENERIC_NETLINK` 的 Linux 系统（Linux 2.6.15+）。
- A-3：观测目标为 IPv4/IPv6 TCP/UDP 流量。
- A-4：网卡驱动遵循标准 `ndo_start_xmit` 接口。
- A-5：未开启 `CONFIG_NET_NS` 时所有 sock 在 init_net 命名空间。

### 7.2 外部依赖

- D-1：Linux 6.6 内核源码树（git tag `v6.6`）。
- D-2：内核构建工具链：`gcc-12`、`make`、`flex`、`bison`、`libelf-dev`、`libssl-dev`。
- D-3：用户态工具构建：`gcc`、`make`、`libmnl-dev`（可选，可直接用原生 netlink）。
- D-4：测试环境：QEMU + initramfs，或物理机 + 串口控制。
- D-5：性能测试：`iperf3`、`netperf`。

---

## 8. 需求追踪矩阵

| 需求 ID | 用户故事 | spec.md Scenario | design.md 章节 | 测试用例 |
|---------|----------|-------------------|----------------|----------|
| FR-1 | - | "Requirement: 内核时延统计框架" | 3.1, 9 (Patch 1) | `make menuconfig` 可见 |
| FR-2 | US-1, US-5 | "Scenario: 接收时延统计" / "发送时延统计" / "关闭选项时零开销" | 3.2, 3.3, 9 (Patch 2) | KUnit 累加测试 |
| FR-3 | - | 同上 | 3.4, 9 (Patch 2) | KUnit skb 字段测试 |
| FR-4 | US-1, US-5 | "Scenario: 接收时延统计" | 4, 9 (Patch 3) | `tests/func/test_tcp_udp.sh` RX 部分 |
| FR-5 | US-1, US-5 | "Scenario: 发送时延统计" | 4, 9 (Patch 4) | `tests/func/test_tcp_udp.sh` TX 部分 |
| FR-6 | US-1, US-2, US-3 | "Scenario: 按 PID 查询" / "按 inode 查询" / "重置统计" | 5, 9 (Patch 5) | `tests/func/test_pid_query.sh` 等 |
| FR-7 | US-1, US-2, US-3, US-5 | "Scenario: 按 PID 查询" / "按 inode 查询" / "平均时延计算" | 9 (Patch 6) | 全部功能测试 |
| FR-8 | - | "Scenario: 用户文档" / "自测试套件" | 11 | selftests 与文档检查 |
| NFR-1 | US-4 | "Scenario: 关闭选项时零开销" | 7 | `tests/perf/baseline-vs-enabled.sh` |
| NFR-2 | - | - | 6 | 多架构编译验证 |
| NFR-3 | - | "Requirement: 代码规范" | 9 | `checkpatch.pl` 检查 |
| NFR-4 | - | - | 5, 6 | 权限测试 |
| NFR-5 | - | "Requirement: 文档撰写阶段" | - | 文档评审 |

---

## 9. 术语表

| 术语 | 含义 |
|------|------|
| delayacct | Linux 内核既有的任务级延迟统计框架（`CONFIG_DELAYACCT`） |
| net_delayacct | 本项目新增的 socket 级延迟统计框架（`CONFIG_NET_DELAYACCT`） |
| taskstats | delayacct 的 genl 接口与统计结构体 |
| getdelays | delayacct 的用户态工具 |
| get_sockdelays | net_delayacct 的用户态工具 |
| genl | Generic Netlink，Linux 内核与用户态的通用通信机制 |
| skb | `struct sk_buff`，Linux 网络协议栈的核心数据结构 |
| sock | `struct sock`，Linux socket 层的核心数据结构 |
| RX | 接收方向（Receive） |
| TX | 发送方向（Transmit） |
| GRO | Generic Receive Offload，接收方向聚合卸载 |
| GSO | Generic Segmentation Offload，发送方向分段卸载 |
| TSO | TCP Segmentation Offload，TCP 分段卸载 |
| NAPI | New API，Linux 网卡中断/轮询混合接收机制 |
| qdisc | Traffic Control queueing discipline，流量控制队列规则 |
| sockfs | socket 伪文件系统，每个 socket 对应一个 inode |
| inode | 文件系统索引节点，socket 的 inode 即 `/proc/<pid>/fd` 中看到的编号 |
| UAPI | User API，内核暴露给用户态的二进制接口 |
| KUnit | Linux 内核单元测试框架 |
| selftests | Linux 内核自测试套件（`tools/testing/selftests/`） |
| netdev | Linux 网络子系统邮件列表（`netdev@vger.kernel.org`） |
| patch 系列 | 一组相关 patch 按顺序投稿，cover letter + N 个 patch |

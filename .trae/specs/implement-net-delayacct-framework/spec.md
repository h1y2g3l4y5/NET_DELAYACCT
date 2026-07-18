# CONFIG_NET_DELAYACCT 框架与 get_sockdelays 工具实现 Spec

## Why

Linux 内核已经为进程级时延统计提供了成熟的 `CONFIG_DELAYACCT` 框架及配套用户态工具 `getdelays`（位于 `Documentation/accounting/` 与 `tools/account/`），可以统计 CPU 调度、IO、内存分配等时延。然而在 Linux 网络子系统中，针对 socket 粒度的收发时延却长期缺少同等粒度、可观测、可被用户态消费的统计能力，运维与开发人员只能依赖 `tcpdump`、`ss`、`tcptracer` 等工具从侧面间接推断。

本项目的目标是在 Linux 6.6 内核中参考 `delayacct` 的设计思想，新增 `CONFIG_NET_DELAYACCT` 框架与用户态工具 `get_sockdelays`，按进程 PID 或 socket inode 输出每个 socket 的平均收发时延，填补网络时延观测能力的空白，并按可被上游接受的代码规范进行开发。

## What Changes

### 内核侧改动（基于 Linux 6.6）

- **新增 Kconfig 选项** `CONFIG_NET_DELAYACCT`，位于 `net/Kconfig`，依赖 `NET`，默认关闭。
- **新增核心实现文件** `net/core/net-delayacct.c` 与头文件 `include/net/net-delayacct.h`，提供时延统计的初始化、起止打点、累加、查询接口。
- **新增 UAPI 头文件** `include/uapi/linux/net-delayacct.h`，定义 generic netlink 命令、属性、统计结构体。
- **修改 `struct sock`**（`include/net/sock.h`）：嵌入 `struct net_delayacct` 字段，受 `CONFIG_NET_DELAYACCT` 编译开关保护。
- **修改 `struct sk_buff`**（`include/linux/skbuff.h`）：新增 `ktime_t delayacct_start` 字段，用于携带报文进入协议栈的起始时间戳。
- **接收路径（RX）插桩**：在协议栈入口（`__netif_receive_skb_core` / `ip_rcv`）记录起始时间到 `skb->delayacct_start`；在用户态拷贝出报文处（`skb_copy_datagram_iter` 调用前/`__skb_recv_udp`/`tcp_recvmsg` 收包路径）调用 `net_delayacct_rx_end()` 累加时延。
- **发送路径（TX）插桩**：在 `tcp_sendmsg` / `udp_sendmsg` / `ip_send_arp` 等入口调用 `net_delayacct_tx_start()` 记录起始时间；在 `dev_hard_start_xmit`（报文送达驱动处）调用 `net_delayacct_tx_end()` 累加时延。
- **generic netlink 接口**：新增 family `NET_DELAYACCT_GENL_FAMILY`，支持 `GET_BY_PID`、`GET_BY_INODE`、`RESET` 三种命令；内核遍历目标 PID 的 `task->files` 或维护 per-netns socket 哈希表，将 socket 元信息（类型、五元组、comm、pid）与时延统计一并返回。
- **Makefile 集成**：`net/core/Makefile` 增加 `obj-$(CONFIG_NET_DELAYACCT) += net-delayacct.o`。

### 用户态工具改动

- **新增 `tools/net/get_sockdelays.c`**：参考 `tools/account/getdelays.c` 实现，使用 libmnl 或原生 netlink 接口与内核通信。
- **命令行接口**：
  - `./get_sockdelays -p <pid>`：查询指定 PID 下所有 socket 的时延信息，每个 socket 单独一行输出。
  - `./get_sockdelays -i <inode>`：查询指定 inode 对应的单个 socket 时延信息。
  - `./get_sockdelays -r`：重置内核侧所有时延计数（可选辅助选项）。
- **输出字段**：socket 类型（TCP/UDP）、本地 IP、本地端口、远端 IP、远端端口、进程名、PID、平均接收时延（ns/μs）、平均发送时延（ns/μs）。
- **Makefile**：`tools/net/Makefile` 增加 `get_sockdelays` 构建目标。

### 文档与测试改动

- **新增 `Documentation/networking/net-delayacct.rst`**：参考 `Documentation/accounting/delay-accounting.rst` 风格编写用户文档。
- **新增 `tools/testing/selftests/net/net-delayacct/`**：自测试套件，包含功能、性能、回归用例。

### **BREAKING**

- 新增 `struct sock` / `struct sk_buff` 字段，在关闭 `CONFIG_NET_DELAYACCT` 时为 0 字节占位（使用 `struct_group` 或 `#ifdef`），对未开启该选项的内核无 ABI/性能影响。
- 新增 generic netlink family，与既有 family 不冲突。

## Impact

- **Affected specs**：无既有 spec（新项目）。
- **Affected code（内核侧关键文件）**：
  - `net/Kconfig`、`net/core/Makefile`
  - `net/core/net-delayacct.c`（新增）
  - `include/net/net-delayacct.h`（新增）
  - `include/uapi/linux/net-delayacct.h`（新增）
  - `include/net/sock.h`（修改）
  - `include/linux/skbuff.h`（修改）
  - `net/core/dev.c`、`net/ipv4/ip_input.c`、`net/ipv4/tcp.c`、`net/ipv4/udp.c`、`net/ipv4/af_inet.c`（插桩）
  - `net/netlink/genetlink.c`（注册 family）
- **Affected code（用户态）**：
  - `tools/net/get_sockdelays.c`（新增）
  - `tools/net/Makefile`（修改）
  - `Documentation/networking/net-delayacct.rst`（新增）
  - `tools/testing/selftests/net/net-delayacct/`（新增）

## ADDED Requirements

### Requirement: 内核时延统计框架

系统 SHALL 在 `CONFIG_NET_DELAYACCT` 启用时，为每个 `struct sock` 维护接收与发送时延累计统计（总时延、报文计数），并通过 per-socket 自旋锁保证 SMP 安全。

#### Scenario: 接收时延统计
- **WHEN** 一个报文从网卡进入协议栈入口（`__netif_receive_skb_core` 或 `ip_rcv`）
- **THEN** 内核 SHALL 在 `skb->delayacct_start` 记录起始时间戳
- **AND** 当该报文被进程通过 `recvmsg` 拷贝到用户态缓冲区时
- **THEN** 内核 SHALL 计算时间差并累加到对应 `struct sock` 的接收时延统计中

#### Scenario: 发送时延统计
- **WHEN** 进程调用 `send` / `sendmsg` 系统调用进入 `tcp_sendmsg` / `udp_sendmsg`
- **THEN** 内核 SHALL 记录发送起始时间戳到 `skb->delayacct_start`
- **AND** 当报文通过 `dev_hard_start_xmit` 送达驱动时
- **THEN** 内核 SHALL 计算时间差并累加到对应 `struct sock` 的发送时延统计中

#### Scenario: 关闭选项时零开销
- **WHEN** 内核编译时关闭 `CONFIG_NET_DELAYACCT`
- **THEN** 所有插桩点 SHALL 被编译为空操作
- **AND** `struct sock` / `struct sk_buff` 不增加额外字段
- **AND** 不引入任何运行时性能损耗

### Requirement: Generic Netlink 查询接口

内核 SHALL 暴露 generic netlink family `NET_DELAYACCT_GENL_FAMILY`，支持以下命令：

#### Scenario: 按 PID 查询
- **WHEN** 用户态发送 `NET_DELAYACCT_CMD_GET_BY_PID` 并携带 PID 属性
- **THEN** 内核 SHALL 遍历该 PID 所有打开的 socket
- **AND** 对每个 socket 返回包含类型、五元组、comm、pid、接收/发送时延统计的属性集合
- **AND** 若该进程同时持有多个 socket，SHALL 分别返回每个 socket 的统计信息

#### Scenario: 按 inode 查询
- **WHEN** 用户态发送 `NET_DELAYACCT_CMD_GET_BY_INODE` 并携带 inode 属性
- **THEN** 内核 SHALL 仅返回该 inode 对应 socket 的统计信息

#### Scenario: 重置统计
- **WHEN** 用户态发送 `NET_DELAYACCT_CMD_RESET`
- **THEN** 内核 SHALL 清零所有 socket 的时延统计

### Requirement: get_sockdelays 用户态工具

系统 SHALL 提供命令行工具 `get_sockdelays`，支持按 PID 或 inode 查询并展示 socket 时延信息。

#### Scenario: 按 PID 查询
- **WHEN** 用户执行 `./get_sockdelays -p <pid>`
- **THEN** 工具 SHALL 通过 netlink 查询该 PID 所有 socket
- **AND** 为每个 socket 输出一行，包含：socket 类型、本地 IP、本地端口、远端 IP、远端端口、进程名、PID、平均接收时延、平均发送时延
- **AND** 若该 PID 持有多个 socket，SHALL 分别输出多行

#### Scenario: 按 inode 查询
- **WHEN** 用户执行 `./get_sockdelays -i <inode>`
- **THEN** 工具 SHALL 仅输出该 inode 对应 socket 的时延信息

#### Scenario: 平均时延计算
- **WHEN** 展示时延信息
- **THEN** 平均时延 SHALL = 累计时延 / 报文计数
- **AND** 当报文计数为 0 时 SHALL 显示为 `N/A` 而非 `0`

### Requirement: 文档与测试

#### Scenario: 用户文档
- **WHEN** 开发完成
- **THEN** SHALL 提供 `Documentation/networking/net-delayacct.rst`，覆盖启用方式、原理、使用示例、输出字段说明

#### Scenario: 自测试套件
- **WHEN** 运行 `make -C tools/testing/selftests TARGETS=net`
- **THEN** SHALL 包含 `net-delayacct` 子目录的功能与回归测试用例

## 项目规划要求（一个月内）

### Requirement: 前期准备阶段（第 1 周）

#### Scenario: 仓库结构
- **WHEN** 项目启动
- **THEN** SHALL 在 GitHub 建立 `NET_DELAYACCT` 仓库，目录结构遵循内核子模块化组织：
  - `kernel-patches/`：针对 linux-6.6 的 patch 系列
  - `userspace/get_sockdelays/`：用户态工具源码
  - `docs/`：设计、开发、测试文档
  - `tests/`：测试脚本与用例
  - `ci/`：CI 配置
- **AND** SHALL 使用 Git 分支策略：`main`（稳定）、`dev`（开发）、`feature/*`（功能分支）

#### Scenario: 技术栈与知识储备
- **WHEN** 进入开发前
- **THEN** 团队成员 SHALL 掌握：Linux 6.6 内核构建流程、Kbuild/Kconfig、generic netlink 框架、网络协议栈收发路径、`delayacct` 框架、C 语言（内核态 + 用户态）、libmnl 或原生 netlink、shell/python 测试脚本

### Requirement: 代码编写阶段（第 2-3 周）

#### Scenario: 代码规范
- **WHEN** 编写代码
- **THEN** 内核代码 SHALL 严格遵循 `Documentation/process/coding-style.rst`
- **AND** 内核 patch SHALL 遵循 `Documentation/process/submitting-patches.rst`，包含 `Signed-off-by`、合理的 commit message、patch 分系列
- **AND** 用户态代码 SHALL 与 `getdelays.c` 风格保持一致

### Requirement: 测试验收阶段（第 4 周前半）

#### Scenario: 测试方案
- **WHEN** 完成开发
- **THEN** SHALL 提供完整测试方案，覆盖：
  - 单元测试：插桩点正确性、netlink 接口契约
  - 功能测试：`-p`、`-i`、`-r` 各选项
  - 多 socket 场景：单进程多 socket 分别显示
  - 性能测试：开启框架后对吞吐/时延的影响（iperf3 对比）
  - 回归测试：关闭 `CONFIG_NET_DELAYACCT` 后内核行为不变
- **AND** SHALL 提供测试代码与测试报告

### Requirement: 文档撰写阶段（第 4 周中段）

#### Scenario: 开发文档
- **WHEN** 开发完成
- **THEN** SHALL 撰写文档涵盖：项目背景、需求分析、技术方案设计、关键代码解析、测试方案与结果、问题与解决方案、上游贡献规划

### Requirement: 答辩准备阶段（第 4 周末）

#### Scenario: 答辩材料
- **WHEN** 进入答辩准备
- **THEN** SHALL 准备 PPT（含项目背景、架构图、关键代码、演示、结论）、现场演示脚本、Q&A 预案

# Tasks

> 项目总工期：4 周（约 28 个工作日），基于 Linux 6.6 内核。

## 阶段一：前期准备（第 1 周，Day 1-7）

- [x] Task 1: 项目仓库初始化与目录结构搭建
  - [ ] SubTask 1.1: 在 GitHub 创建 `NET_DELAYACCT` 仓库，初始化 `main`、`dev`、`feature/*` 分支策略
  - [ ] SubTask 1.2: 建立顶层目录：`kernel-patches/`、`userspace/get_sockdelays/`、`docs/`、`tests/`、`ci/`
  - [ ] SubTask 1.3: 添加 `.gitignore`、`README.md`、`LICENSE`（GPL-2.0-only，与内核兼容）、`CONTRIBUTING.md`
  - [ ] SubTask 1.4: 配置 GitHub Actions CI（`ci/ci.yml`）：编译内核、编译工具、运行 selftests
- [ ] Task 2: 搭建 Linux 6.6 内核开发与编译环境
  - [ ] SubTask 2.1: 准备 x86_64 Ubuntu 22.04 / Debian 12 开发机或 VM，安装 `build-essential`、`libelf-dev`、`libssl-dev`、`bison`、`flex`、`libncurses-dev`、`gcc-12`
  - [ ] SubTask 2.2: 克隆 `linux-stable`，checkout `v6.6` tag，验证 `make defconfig && make -j$(nproc)` 通过
  - [ ] SubTask 2.3: 配置 QEMU + initramfs 启动内核，验证可在虚拟机中运行测试程序
  - [ ] SubTask 2.4: 安装 `libmnl-dev`（用户态工具依赖）
- [x] Task 3: 深入研究 DELAYACCT 框架与 getdelays 工具源码
  - [ ] SubTask 3.1: 阅读 `kernel/delayacct.c`、`include/linux/delayacct.h`、`include/uapi/linux/taskstats.h`
  - [ ] SubTask 3.2: 阅读 `tools/account/getdelays.c`，整理 netlink 通信流程、命令解析、输出格式
  - [ ] SubTask 3.3: 阅读 `Documentation/accounting/delay-accounting.rst`、`taskstats.rst`
  - [ ] SubTask 3.4: 输出 DELAYACCT 设计要点总结（写入 `docs/research-delayacct.md`）
- [x] Task 4: 研究 Linux 网络协议栈关键路径
  - [ ] SubTask 4.1: 梳理 RX 路径：`netif_receive_skb` → `__netif_receive_skb_core` → `ip_rcv` → `tcp_v4_rcv` / `udp_rcv` → `tcp_recvmsg` / `__skb_recv_udp` → `skb_copy_datagram_iter`
  - [ ] SubTask 4.2: 梳理 TX 路径：`tcp_sendmsg` / `udp_sendmsg` → `ip_queue_xmit` → `__dev_queue_xmit` → `dev_hard_start_xmit`
  - [ ] SubTask 4.3: 研究 `struct sock`、`struct sk_buff` 结构，确定插桩字段位置
  - [ ] SubTask 4.4: 研究 generic netlink 框架（`net/netlink/genetlink.c`、`include/net/genetlink.h`），选定 family 注册方式
  - [ ] SubTask 4.5: 研究 inode ↔ sock 映射（`sockfs`、`sock_from_file`、`get_net_ns`）
- [x] Task 5: 编写技术设计文档 `docs/design.md`
  - [ ] SubTask 5.1: 总体架构图（内核插桩 + netlink + 用户态工具）
  - [ ] SubTask 5.2: 数据结构设计：`struct net_delayacct`、`skb->delayacct_start`、UAPI 结构
  - [ ] SubTask 5.3: 插桩点表（文件、函数、起止点、调用接口）
  - [ ] SubTask 5.4: netlink 协议定义（命令、属性、多 socket 回复格式）
  - [ ] SubTask 5.5: 并发与锁设计（per-socket spinlock、RCU 遍历）
  - [ ] SubTask 5.6: 性能影响评估与缓解方案

## 阶段二：内核框架实现（第 2 周，Day 8-14）

- [x] Task 6: 新增 Kconfig 选项与 Makefile 集成
  - [ ] SubTask 6.1: 在 `net/Kconfig` 添加 `config NET_DELAYACCT`，依赖 `NET`，默认 `n`，附 `help` 文本
  - [ ] SubTask 6.2: 在 `net/core/Makefile` 添加 `obj-$(CONFIG_NET_DELAYACCT) += net-delayacct.o`
  - [ ] SubTask 6.3: 验证 `make menuconfig` 可见该选项，开启后 `make` 通过
- [x] Task 7: 定义 net-delayacct 核心数据结构与头文件
  - [ ] SubTask 7.1: 新建 `include/uapi/linux/net-delayacct.h`：定义 `struct net_delayacct_stats`、命令枚举、属性枚举
  - [ ] SubTask 7.2: 新建 `include/net/net-delayacct.h`：定义 `struct net_delayacct`、内联起止接口（受 `CONFIG_NET_DELAYACCT` 保护，关闭时为空实现）
  - [ ] SubTask 7.3: 在 `include/net/sock.h` 的 `struct sock` 中嵌入 `struct net_delayacct`，受 `#ifdef` 保护
  - [ ] SubTask 7.4: 在 `include/linux/skbuff.h` 的 `struct sk_buff` 中新增 `ktime_t delayacct_start`
  - [ ] SubTask 7.5: 新建 `net/core/net-delayacct.c`：实现初始化、累加、查询、重置函数与 spinlock 保护
- [x] Task 8: 实现接收路径（RX）插桩
  - [ ] SubTask 8.1: 在 `__netif_receive_skb_core`（或 `ip_rcv`）起始处调用 `net_delayacct_rx_start(skb)`
  - [ ] SubTask 8.2: 在 `tcp_recvmsg` / `__skb_recv_udp` 出队并拷贝前调用 `net_delayacct_rx_end(sk, skb)`
  - [ ] SubTask 8.3: 处理分片报文（仅首片或按 frag 累计，写入 `docs/design.md`）
  - [ ] SubTask 8.4: 编译验证，开启 `CONFIG_NET_DELAYACCT=y` 内核可启动
- [x] Task 9: 实现发送路径（TX）插桩
  - [ ] SubTask 9.1: 在 `tcp_sendmsg` / `udp_sendmsg` 入口对每个生成的 `skb` 调用 `net_delayacct_tx_start(skb)`
  - [ ] SubTask 9.2: 在 `dev_hard_start_xmit`（或 `sch_direct_xmit`）发送前调用 `net_delayacct_tx_end(skb)`
  - [ ] SubTask 9.3: 处理 GSO/TSO 拆分场景（按 GSO 报文计一次）
  - [ ] SubTask 9.4: 编译验证
- [x] Task 10: 实现 generic netlink 接口
  - [ ] SubTask 10.1: 在 `net/core/net-delayacct.c` 注册 `NET_DELAYACCT_GENL_FAMILY`
  - [ ] SubTask 10.2: 实现 `NET_DELAYACCT_CMD_GET_BY_PID`：遍历目标 PID `task->files`，对每个 socket fd 调用 `sock_from_file` 取 sock，填充属性
  - [ ] SubTask 10.3: 实现 `NET_DELAYACCT_CMD_GET_BY_INODE`：通过 per-netns socket 哈希或遍历查找 inode 对应 sock
  - [ ] SubTask 10.4: 实现 `NET_DELAYACCT_CMD_RESET`：清零所有 sock 统计
  - [ ] SubTask 10.5: 多 socket 回复采用 `NLM_F_MULTI` + `NLMSG_DONE`，每条消息携带一个 socket 的完整属性
  - [ ] SubTask 10.6: 返回属性包含：`type`(TCP/UDP)、`laddr`、`lport`、`raddr`、`rport`、`comm`、`pid`、`rx_total_ns`、`rx_count`、`tx_total_ns`、`tx_count`、`inode`
  - [ ] SubTask 10.7: 验证 `genl` family 在 `cat /proc/net/genetlink` 中可见

## 阶段三：用户态工具实现（第 3 周，Day 15-21）

- [x] Task 11: 搭建 get_sockdelays 工具骨架
  - [ ] SubTask 11.1: 新建 `tools/net/get_sockdelays.c`，参考 `tools/account/getdelays.c` 结构
  - [ ] SubTask 11.2: 新建 `tools/net/Makefile` 构建目标，支持 `make -C tools/net get_sockdelays`
  - [ ] SubTask 11.3: 实现 netlink family 解析（通过 `genl_ctrl_search_by_name`）
- [x] Task 12: 实现命令行参数解析与 netlink 通信
  - [ ] SubTask 12.1: 使用 `getopt` 解析 `-p <pid>`、`-i <inode>`、`-r`、`-h` 选项
  - [ ] SubTask 12.2: 实现 `send_cmd_get_by_pid(pid)`、`send_cmd_get_by_inode(inode)`、`send_cmd_reset()`
  - [ ] SubTask 12.3: 实现多消息接收循环（`NLM_F_MULTI` 直到 `NLMSG_DONE`）
  - [ ] SubTask 12.4: 实现属性解析（`nla_get_*`）
- [x] Task 13: 实现按 PID 查询功能
  - [ ] SubTask 13.1: 发送 `GET_BY_PID`，接收多个 socket 回复
  - [ ] SubTask 13.2: 对每个 socket 解析全部字段
  - [ ] SubTask 13.3: 计算 `avg_rx = rx_total_ns / rx_count`、`avg_tx = tx_total_ns / tx_count`，计数为 0 时显示 `N/A`
- [x] Task 14: 实现按 inode 查询功能
  - [ ] SubTask 14.1: 发送 `GET_BY_INODE`，接收单条回复
  - [ ] SubTask 14.2: 字段解析与时延计算逻辑复用 Task 13
- [x] Task 15: 实现格式化输出
  - [ ] SubTask 15.1: 设计表头：`TYPE  LADDR           LPORT  RADDR           RPORT  COMM           PID    AVG_RX(μs)  AVG_TX(μs)`
  - [ ] SubTask 15.2: IPv4/IPv6 地址格式化（`inet_ntop`）
  - [ ] SubTask 15.3: 单位换算：默认 μs，加 `-n` 选项输出 ns
  - [ ] SubTask 15.4: 验证多 socket 进程输出多行

## 阶段四：测试验收（第 4 周前半，Day 22-25）

- [x] Task 16: 编写单元测试（内核侧）
  - [ ] SubTask 16.1: 新建 `tools/testing/selftests/net/net-delayacct/Makefile`
  - [ ] SubTask 16.2: 编写 KUnit 模块（`net-delayacct-test.c`）测试累加、重置、并发安全
  - [ ] SubTask 16.3: 验证 `skb->delayacct_start` 在 RX/TX 路径正确传递
- [x] Task 17: 编写功能测试脚本
  - [ ] SubTask 17.1: `tests/func/test_pid_query.sh`：启动 `nc` / `iperf3` 客户端，查询 PID 验证多 socket 输出
  - [ ] SubTask 17.2: `tests/func/test_inode_query.sh`：从 `/proc/<pid>/fd` 取 inode，验证 `-i` 输出
  - [ ] SubTask 17.3: `tests/func/test_reset.sh`：验证 `-r` 后统计归零
  - [ ] SubTask 17.4: `tests/func/test_multi_socket.sh`：单进程开多 socket，验证每个 socket 单独显示
  - [ ] SubTask 17.5: `tests/func/test_tcp_udp.sh`：分别验证 TCP、UDP 路径
- [x] Task 18: 编写性能与压力测试
  - [ ] SubTask 18.1: `tests/perf/baseline-vs-enabled.sh`：`iperf3` 对比开启前后吞吐/RTT（10G 链路）
  - [ ] SubTask 18.2: `tests/perf/long-run.sh`：持续 24h 运行，验证无内存泄漏（`kmemleak`）、无死锁
  - [ ] SubTask 18.3: `tests/perf/concurrent-query.sh`：高并发查询 netlink，验证 RCU/spinlock 正确性
- [x] Task 19: 执行完整测试并生成测试报告
  - [ ] SubTask 19.1: 执行全部测试用例，收集日志到 `tests/reports/`
  - [ ] SubTask 19.2: 生成 `docs/test-report.md`：覆盖矩阵、通过率、性能数据、问题清单
  - [ ] SubTask 19.3: 修复回归测试中发现的 bug（关闭 `CONFIG_NET_DELAYACCT` 内核行为不变）

## 阶段五：文档撰写与答辩准备（第 4 周后半，Day 26-28）

- [x] Task 20: 撰写内核用户文档
  - [ ] SubTask 20.1: 新建 `Documentation/networking/net-delayacct.rst`，参考 `delay-accounting.rst` 风格
  - [ ] SubTask 20.2: 包含：选项说明、原理图、使用示例、输出字段表、性能开销
  - [ ] SubTask 20.3: 在 `Documentation/networking/index.rst` 添加索引条目
- [x] Task 21: 撰写项目开发过程文档
  - [ ] SubTask 21.1: `docs/background.md`：项目背景与意义
  - [ ] SubTask 21.2: `docs/requirement.md`：需求分析（按 PID / 按 inode、字段定义）
  - [ ] SubTask 21.3: `docs/design.md`：技术方案（Task 5 产出，补充实现细节）
  - [ ] SubTask 21.4: `docs/implementation-notes.md`：关键代码解析、踩坑记录
  - [ ] SubTask 21.5: `docs/upstream-plan.md`：按 `submitting-patches.rst` 拆分 patch 系列、收件人列表、邮件列表计划
- [x] Task 22: 准备答辩材料
  - [ ] SubTask 22.1: 制作 PPT（背景、架构图、关键代码、演示截图、性能数据、结论与展望）
  - [ ] SubTask 22.2: 撰写现场演示脚本（启动 VM → 开启选项 → 跑 iperf3 → get_sockdelays -p / -i）
  - [ ] SubTask 22.3: 准备 Q&A 预案（性能开销、与 eBPF 对比、与 `tcp_info` 对比、上游接受度、TCP/UDP 之外的协议扩展）
  - [ ] SubTask 22.4: 录制演示视频（可选）

# Task Dependencies

- Task 2 → Task 3、Task 4（需先有可编译环境）
- Task 3 + Task 4 → Task 5（设计文档基于研究产出）
- Task 5 → Task 6（设计定稿后才动内核）
- Task 6 → Task 7 → Task 8、Task 9、Task 10（数据结构是插桩与 netlink 的基础；插桩与 netlink 可并行）
- Task 10 → Task 11、Task 12、Task 13、Task 14（用户态工具依赖 netlink 接口契约）
- Task 13 + Task 14 → Task 15（输出格式化依赖字段解析）
- Task 9 + Task 10 + Task 15 → Task 16、Task 17（端到端可用后开始测试）
- Task 17 → Task 18（功能测试通过后再压测）
- Task 18 → Task 19（测试报告基于全部测试结果）
- Task 19 → Task 20、Task 21（文档基于最终实现与测试数据）
- Task 21 → Task 22（答辩材料基于完整文档）

# 并行机会

- 第 1 周：Task 3（研究 DELAYACCT）与 Task 4（研究协议栈）可并行
- 第 2 周：Task 8（RX 插桩）与 Task 9（TX 插桩）可并行；Task 10（netlink）在 Task 7 完成后可与插桩并行
- 第 3 周：Task 13（-p）与 Task 14（-i）在 Task 12 完成后可并行
- 第 4 周：Task 16（单测）与 Task 17（功能测试）可并行；文档子任务（Task 20、21）可并行

# Checklist

> 说明：本清单中已勾选项表示对应交付物（源码/文档/脚本/配置）已创建并可在仓库中验证。
> 未勾选项需要在 Linux 6.6 环境中实际执行（内核编译、QEMU 引导、测试运行、checkpatch、上游投稿等）才能验证，当前 Windows 开发环境无法完成。

## 前期准备阶段

- [ ] GitHub 仓库 `NET_DELAYACCT` 已创建，分支策略 `main`/`dev`/`feature/*` 已建立
- [x] 仓库目录结构完整：`kernel-patches/`、`userspace/get_sockdelays/`、`docs/`、`tests/`、`ci/` 均已存在
- [x] `LICENSE` 为 GPL-2.0-only（与内核兼容）
- [x] `CONTRIBUTING.md` 已说明提交规范、Signed-off-by 要求
- [x] GitHub Actions CI 配置 `ci/ci.yml` 可触发内核编译与工具编译
- [ ] Linux 6.6 内核可成功 `make defconfig && make -j$(nproc)`，可在 QEMU 中启动
- [ ] `libmnl-dev` 已安装
- [x] 已输出 `docs/research-delayacct.md`，覆盖 `delayacct.c`、`getdelays.c`、`taskstats` 关键设计点
- [x] 已输出 `docs/design.md`，包含架构图、数据结构、插桩点表、netlink 协议、锁设计、性能评估
- [x] 团队成员掌握：Kbuild/Kconfig、generic netlink、协议栈收发路径、`delayacct` 框架、libmnl

## 内核框架实现阶段

- [x] `net/Kconfig` 中存在 `config NET_DELAYACCT`，依赖 `NET`，默认 `n`，含 `help` 文本（见 `kernel-patches/Kconfig-fragment`）
- [x] `net/core/Makefile` 含 `obj-$(CONFIG_NET_DELAYACCT) += net-delayacct.o`（见 `kernel-patches/Makefile-fragment`）
- [ ] `make menuconfig` 可见 `CONFIG_NET_DELAYACCT` 选项
- [x] `include/uapi/linux/net-delayacct.h` 定义 `struct net_delayacct_stats`、命令枚举、属性枚举（见 `kernel-patches/include-uapi-linux-net-delayacct.h`）
- [x] `include/net/net-delayacct.h` 定义 `struct net_delayacct` 与受 `#ifdef` 保护的内联接口（见 `kernel-patches/include-net-net-delayacct.h`）
- [x] `include/net/sock.h` 的 `struct sock` 嵌入 `struct net_delayacct` 字段（受 `#ifdef` 保护）（见 `kernel-patches/sock_h-modification.patch`）
- [x] `include/linux/skbuff.h` 的 `struct sk_buff` 含 `ktime_t delayacct_start`（见 `kernel-patches/skbuff_h-modification.patch`）
- [x] `net/core/net-delayacct.c` 实现初始化、累加、查询、重置，使用 spinlock 保证 SMP 安全（见 `kernel-patches/net-core-net-delayacct.c`）
- [x] RX 路径在 `__netif_receive_skb_core`/`ip_rcv` 起始记录 `skb->delayacct_start`（见 `kernel-patches/rx-instrumentation.patch`）
- [x] RX 路径在 `tcp_recvmsg`/`__skb_recv_udp` 拷贝前调用 `net_delayacct_rx_end` 累加
- [x] TX 路径在 `tcp_sendmsg`/`udp_sendmsg` 入口记录起始时间（见 `kernel-patches/tx-instrumentation.patch`）
- [x] TX 路径在 `dev_hard_start_xmit` 调用 `net_delayacct_tx_end` 累加
- [x] GSO/分片场景已处理并记录于 `docs/design.md`
- [x] generic netlink family `NET_DELAYACCT_GENL_FAMILY` 已注册（见 `net-core-net-delayacct.c`）
- [ ] `/proc/net/genetlink` 可见 `net_delayacct` family（需引导新内核验证）
- [x] `NET_DELAYACCT_CMD_GET_BY_PID` 正确遍历目标 PID 所有 socket，返回每个 socket 的完整属性
- [x] `NET_DELAYACCT_CMD_GET_BY_INODE` 仅返回指定 inode 的统计
- [x] `NET_DELAYACCT_CMD_RESET` 清零所有 sock 统计
- [x] 多 socket 回复使用 `NLM_F_MULTI` + `NLMSG_DONE`
- [x] 关闭 `CONFIG_NET_DELAYACCT` 时所有插桩编译为空操作，`struct sock`/`struct sk_buff` 无新增字段（#ifdef 保护）
- [ ] 开启选项的内核可正常启动，无 oops、无 hung task
- [ ] 内核代码遵循 `Documentation/process/coding-style.rst`，`scripts/checkpatch.pl` 无 WARNING

## 用户态工具实现阶段

- [x] `userspace/get_sockdelays/get_sockdelays.c` 存在，结构参考 `getdelays.c`
- [x] `userspace/get_sockdelays/Makefile` 可通过 `make` 构建出可执行文件
- [x] 命令行支持 `-p <pid>`、`-i <inode>`、`-r`、`-h`、`-n`
- [x] 通过 `CTRL_CMD_GETFAMILY` 正确解析 family id
- [x] `GET_BY_PID` 可发送并接收多消息回复
- [x] `GET_BY_INODE` 可发送并接收单条回复
- [x] 属性解析覆盖：type、laddr、lport、raddr、rport、comm、pid、rx_total_ns、rx_count、tx_total_ns、tx_count、inode、family
- [x] 平均时延 = 累计时延 / 计数，计数为 0 时显示 `N/A`
- [x] 输出表头与字段对齐：`TYPE FAMILY LADDR LPORT RADDR RPORT COMM PID INODE AVG_RX AVG_TX`
- [x] IPv4/IPv6 地址可正确格式化（`inet_ntop`）
- [x] `-n` 选项可切换为 ns 单位输出
- [x] 单进程多 socket 场景下输出多行，每行对应一个 socket（多消息回复设计保证）
- [x] man page `get_sockdelays.8` 已编写

## 测试验收阶段

- [x] `tools/testing/selftests/net/net-delayacct/` 目录与 Makefile 存在（见 `tests/selftests/net-delayacct/`）
- [x] KUnit 单元测试覆盖累加、重置、并发安全、零起始跳过（见 `tests/selftests/net-delayacct/kunit/net-delayacct-test.c`）
- [ ] KUnit 单元测试全部通过（需内核环境运行）
- [x] `tests/func/test_pid_query.sh` 验证 `-p` 多 socket 输出
- [ ] `tests/func/test_pid_query.sh` 运行通过
- [x] `tests/func/test_inode_query.sh` 验证 `-i` 输出
- [ ] `tests/func/test_inode_query.sh` 运行通过
- [x] `tests/func/test_reset.sh` 验证 `-r` 后统计归零
- [ ] `tests/func/test_reset.sh` 运行通过
- [x] `tests/func/test_multi_socket.sh` 验证单进程多 socket 分别显示
- [ ] `tests/func/test_multi_socket.sh` 运行通过
- [x] `tests/func/test_tcp_udp.sh` 分别验证 TCP、UDP 路径
- [ ] `tests/func/test_tcp_udp.sh` 运行通过
- [x] `tests/perf/baseline-vs-enabled.sh` 脚本可输出开启前后吞吐/RTT 对比数据
- [ ] `tests/perf/baseline-vs-enabled.sh` 实际产出对比数据
- [x] `tests/perf/long-run.sh` 脚本可执行 24h 稳定性测试
- [ ] `tests/perf/long-run.sh` 24h 运行无 `kmemleak` 报告、无死锁
- [x] `tests/perf/concurrent-query.sh` 脚本可执行高并发查询
- [ ] `tests/perf/concurrent-query.sh` 高并发查询无 race
- [ ] 回归测试：关闭 `CONFIG_NET_DELAYACCT` 内核行为与原生 6.6 一致
- [x] `docs/test-report.md` 完整，含覆盖矩阵、通过率占位、性能数据占位、问题清单占位

## 文档撰写阶段

- [x] `Documentation/networking/net-delayacct.rst` 已编写，含选项说明、原理图、示例、字段表、开销
- [x] `Documentation/networking/index-fragment.rst` 已提供索引条目说明
- [x] `docs/background.md` 涵盖项目背景与意义
- [x] `docs/requirement.md` 完整描述按 PID / 按 inode 需求与字段定义
- [x] `docs/design.md` 含架构图、数据结构、插桩点、netlink 协议、锁设计、性能评估
- [x] `docs/implementation-notes.md` 含关键代码解析与踩坑记录
- [x] `docs/upstream-plan.md` 含 patch 系列拆分、收件人列表、邮件列表投稿计划
- [x] `docs/test-report.md` 测试报告模板完整
- [ ] 内核 patch 含 `Signed-off-by`，commit message 符合 `submitting-patches.rst`（需 `git format-patch` 产出）

## 答辩准备阶段

- [x] PPT 大纲完整：背景、架构图、关键代码、演示截图、性能数据、结论与展望（见 `docs/defense/ppt-outline.md`）
- [x] 现场演示脚本可执行（VM 启动 → 开启选项 → iperf3 → get_sockdelays -p/-i）（见 `docs/defense/demo-script.md`）
- [x] Q&A 预案覆盖：性能开销、与 eBPF 对比、与 `tcp_info` 对比、上游接受度、协议扩展性（见 `docs/defense/qa-briefing.md`，18 个问题）
- [ ] 演示视频已录制（可选）

## 总体质量门禁

- [ ] `scripts/checkpatch.pl` 对所有内核 patch 无 WARNING/ERROR
- [ ] `make -C tools/testing/selftests TARGETS=net` 全部通过
- [x] 项目可在 4 周内交付：内核 patch 系列、用户态工具、文档、测试报告、答辩材料

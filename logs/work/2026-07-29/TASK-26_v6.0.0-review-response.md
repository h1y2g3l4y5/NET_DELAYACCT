# TASK-26 v6.0.0 Review 反馈响应：测试方案增强

- **日期**: 2026-07-29
- **关联 Review**: v6.0.0 (logs/review/v6.0.0/REVIEW_REPORT.md)
- **状态**: [待Review]

## 1. 任务描述

根据 Reviewer v6.0.0 审查报告及后续对话（第七节「对话后修订」），对测试方案进行系统性增强。

审查报告提出 5 个关键问题：
1. Test 03 重置断言与 RESET 非原子语义矛盾
2. Test 13 并发查询仅查 PID 1，未覆盖真实 per-socket 并发路径
3. TCP/UDP 测试未覆盖 splice/zerocopy/corked/IPv6 等已插桩路径
4. 过滤测试缺少 negative case
5. Test 09/10 方向分离缺少反向约束

## 2. 变更内容

### 2.1 ci/qemu/run-tests.sh — 测试用例从 16 项扩展到 22 项

| 新增/修改 | 测试 | 覆盖内容 |
|-----------|------|----------|
| 拆分 | Test 03 | 基础重置（停止流量后全 0），断言语义修正 |
| 修改 | Test 09 | 增加 server TX ≤ client TX/10 反向约束 |
| 修改 | Test 13 | 改为 8 空 PID + 8 busy PID 混合并发（320 次查询） |
| 修改 | Test 14 | 增加 negative case（纯 UDP 进程查 --proto tcp 返回空） |
| 修改 | Test 16 | 增加 negative case（--proto udp --lport 组合返回空） |
| 新增 | Test 17 | Reset 非原子语义（流量中 -R 后存在 count>0） |
| 新增 | Test 18 | 双向流量（iperf3 -R，同 socket RX+TX>0） |
| 新增 | Test 19 | TCP splice RX 路径（splice→/dev/null） |
| 新增 | Test 20 | TCP zerocopy RX 路径（TCP_ZEROCOPY_RECEIVE） |
| 新增 | Test 21 | UDP corked TX 路径（UDP_CORK） |
| 新增 | Test 22 | IPv6 路径（iperf3 -c ::1，TCP+UDP） |

### 2.2 tests/helper/delayacct_path_test.c — 新增路径覆盖辅助程序

单一 C 程序，通过子命令覆盖 iperf3 无法触发的内核路径：
- `splice-server <port>` — TCP splice RX 路径（tcp_read_sock）
- `zerocopy-server <port>` — TCP zerocopy RX 路径（tcp_zerocopy_receive）
- `cork-client <port>` — UDP corked TX 路径（udp_push_pending_frames）

静态链接，打包进 initramfs 无需依赖库。

### 2.3 tests/helper/Makefile — 辅助程序构建

静态链接优先（initramfs 兼容），动态链接回退。

### 2.4 local-test.sh — 构建流程集成

新增 `step_build_helper()` 函数，在内核/工具编译后构建辅助程序；
`step_create_initramfs()` 中将辅助程序打包进 initramfs。

### 2.5 tests/README.md — 文档同步

- 测试计数从 16 更新为 22
- 新增第七部分「语义验证 / 双向流量 / 路径覆盖」章节
- 更新覆盖矩阵，区分 RX/TX 路径覆盖
- Test 03 断言修正为「停止流量后执行 reset」
- 端口分配表扩展至 21430-21435
- 补充 negative case 说明

## 3. 变更原因

### 3.1 Test 03 断言矛盾修复

**问题**：原 Test 03 在 iperf3 client `-t 3` 同步运行后执行 `-R`，断言所有 count=0。
但 RESET 非原子语义意味着遍历期间新到达的包仍会被累加。
当前测试能 PASS 只是因为 client 已结束、server 空闲——依赖隐含条件而非 RESET 语义本身。

**方案**：不逃避问题，拆分为两个测试：
- Test 03（基础功能）：停止流量后 reset，验证清零能力本身
- Test 17（非原子语义）：活跃流量中 reset，验证 reset 后仍有 count>0 的 socket

### 3.2 Test 13 并发压力增强

**问题**：PID 1 无 socket，dumpit 路径只快速遍历空 files_struct，不会调用
`net_delayacct_fill_sock()`、不获取 per-socket spinlock、不访问统计字段。
无法暴露 per-socket 并发风险。

**方案**：混合空 PID + busy PID：
- 8 workers 查 PID 1（空 fdtable 快速路径）
- 8 workers 查 iperf3 busy server（真正进入 fill_sock、获取 spinlock、遍历 cb->ctx）
- 共 320 次查询，验证无 Oops/BUG/panic + busy worker 成功次数 > 0

### 3.3 路径覆盖专项测试

**问题**：iperf3 只走 sendmsg/recvmsg 主路径，不触发 splice/zerocopy/corked。
项目已对这些路径投入插桩工作，但无回归测试保护。

**方案**：编写 delayacct_path_test 辅助程序，在 initramfs 中运行专项测试。
不在文档中标注「未覆盖」逃避，而是实际新增测试覆盖。

### 3.4 过滤测试 negative case

**问题**：Test 14/16 只验证正向匹配，不验证「过滤失败应返回空」。
无法防止「默认返回全部」一类实现缺陷。

**方案**：
- Test 14：纯 UDP 进程（nc -u -l）查 --proto tcp，断言返回 0 行
- Test 16：--proto udp --lport $COMB_PORT 组合，断言返回空

### 3.5 Test 09 反向约束

**问题**：只验证 server RX > 0 和 client TX > 0，不验证 server TX ≈ 0。
无法防止「TX 计数方向错误」回归。

**方案**：增加 server TX ≤ client TX/10 反向约束。
纯 ACK 用 alloc_skb 零初始化 delayacct_start，tx_end 守卫跳过不计入 TX，
故 server TX 应接近 0。

## 4. 踩坑记录

### 4.1 TCP_ZEROCOPY_RECEIVE 结构体大小不匹配

- **问题描述**：setsockopt 返回 ENOPROTOOPT
- **原因分析**：`<netinet/tcp.h>` 的 `tcp_zerocopy_receive` 结构体（32 字节）
  与内核 UAPI 定义（64 字节）大小不匹配
- **解决方案**：改用 `<linux/tcp.h>` 获取内核 UAPI 定义
- **如何避免**：涉及 setsockopt 的程序优先使用 `<linux/*.h>` UAPI 头文件

### 4.2 UDP cork 缓冲区溢出

- **问题描述**：sendto 返回 "Message too long"
- **原因分析**：UDP_CORK 持续累积数据超过内核 UDP 缓冲区限制
- **解决方案**：每 8 个包 uncork/recork 一次（CORK_BURST=8），中间 usleep(500)
- **如何避免**：UDP cork 测试需限制单次累积数据量

### 4.3 iperf3 server 单线程处理限制

- **问题描述**：Test 16 并行启动 TCP client + UDP client 时，UDP client 无法建立 TCP 控制连接
- **原因分析**：iperf3 server 单线程处理同一端口，TCP client(-P 2) 占用 server 导致 UDP client 阻塞
- **解决方案**：Test 16 只启动 UDP client（自带 TCP 控制连接 + UDP 数据 socket）
- **如何避免**：iperf3 测试设计需考虑 server 单线程限制，避免同端口多协议并行

## 5. 测试验证

- 辅助程序编译通过（静态链接）
- QEMU 测试进行中（验证 22 项测试全部通过）

## 6. 待办/遗留问题

- QEMU TCG 模式下 22 项测试的完整验证（进行中）
- 如 TCG 超时，需调整 timeout 参数

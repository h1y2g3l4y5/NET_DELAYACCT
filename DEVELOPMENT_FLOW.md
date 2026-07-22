# 开发流程记录

本文按时间顺序整理本项目当前这一轮开发与调试过程，重点记录：初始状态、遇到的问题、定位思路、修复方案和结果。

---

## 1. 初始版本与目标

### 1.1 项目初始目标

本项目要实现一个基于 **Generic Netlink** 的 per-socket 网络时延统计框架，核心能力包括：

- 按 **PID** 查询某个进程持有的 TCP/UDP socket 统计
- 按 **inode** 查询某个 socket 的统计
- 对所有 socket 的统计执行 **reset**
- 提供用户态工具 `get_sockdelays` 访问内核数据
- 通过 QEMU/CI 跑自动化测试验证整个链路

### 1.2 当时的整体状态

一开始仓库中已经有：

- 内核侧框架代码雏形
- 用户态工具 `userspace/get_sockdelays/get_sockdelays.c`
- CI QEMU 测试脚本
- 多个功能测试脚本

但整体处于“**框架基本有了、链路没有完全打通、测试环境也不稳定**”的状态。

---

## 2. 第一阶段：基础环境与仓库同步

### 2.1 静态 IP 配置

#### 遇到的问题
SSH 所在机器需要改为静态 IP，避免网络环境变化影响调试和远程操作。

#### 解决方式
通过 netplan / NetworkManager 配置为静态地址，完成固定 IP 配置。

#### 结果
网络环境稳定，后续仓库同步和远程调试不再受 DHCP 变化影响。

### 2.2 Git 远程同步与推送

#### 遇到的问题
最初 `git push` 走 HTTPS 时出现超时、SSL/GnuTLS 错误，远程同步不稳定。

#### 解决方式
将远程仓库地址从 HTTPS 切换为 SSH：

```bash
git remote set-url origin git@github.com:h1y2g3l4y5/NET_DELAYACCT.git
```

#### 结果
后续 pull / push 恢复正常，可以稳定触发 CI。

---

## 3. 第二阶段：内核 Generic Netlink 注册问题

### 3.1 问题现象
内核加载时 family 注册失败：

```text
net_delayacct: failed to register genl family: -22 (EINVAL)
```

### 3.2 根因
Generic Netlink family / ops 注册参数与当前内核版本要求不完全匹配，导致注册时 `EINVAL`。

### 3.3 修复方式
主要修复包括：

1. 在 family 中增加：

```c
.resv_start_op = __NET_DELAYACCT_CMD_MAX
```

2. 去掉不兼容的 per-op `.policy` / `.maxattr` 组合
3. 保留：

```c
.validate = GENL_DONT_VALIDATE_STRICT
```

### 3.4 结果
family 成功注册，doit 回调终于有机会被分发执行。

---

## 4. 第三阶段：netlink 通信黑盒问题

### 4.1 问题现象
虽然 family 注册成功，但用户态查询时仍经常得到：

```text
(no matching sockets)
```

或者直接超时、无输出。此时无法判断：

- 请求是否真的发出
- 内核 doit 回调是否被执行
- 回包是否构造成功
- 用户态是否正确解析回包

### 4.2 处理方法
为了打破黑盒状态，在两端增加调试信息：

- **内核侧**：增加 `pr_emerg` / `pr_info` 调试日志
- **用户态**：增加 `[diag] send_and_recv / recvfrom / mnl_cb_run` 日志

### 4.3 结果
后续每一步都能看到：

- 请求有没有发出
- 回调有没有进入
- 回包字节数是多少
- 收到的 netlink 消息类型是什么

调试从黑盒变成可观察链路。

---

## 5. 第四阶段：inode 查询失败

### 5.1 问题现象
按 PID 查询时有时能找到 socket，但按 inode 查询返回空，表现为：

```text
(no matching sockets)
```

而测试里实际已经从 `/proc/<pid>/fd/N` 解析出了 `socket:[inode]`。

### 5.2 根因
原实现依赖：

```c
sock_inode_for(sk)
```

而它本质上又依赖 `sk->sk_socket->file`。在某些内核版本或某些 socket 场景下，这个 `file` 可能为 `NULL`，导致 inode 取不到。

### 5.3 修复方式
在 `cmd_get_by_inode()` 中改为直接从文件对象取 inode：

```c
ino = file_inode(file)->i_ino;
```

而不是依赖 `sk->sk_socket->file`。

### 5.4 结果
inode 查询逻辑恢复正确，内核调试日志能明确看到：

```text
cmd_get_by_inode: ENTER ...
cmd_get_by_inode: pid=... fd=... ino=...
cmd_get_by_inode: MATCH ret=0
```

说明内核已经能正确定位到目标 socket。

---

## 6. 第五阶段：CI / QEMU 挂死问题

### 6.1 问题现象
CI 中 QEMU 启动后停在内核启动日志处，没有后续输出，`TEST RESULTS` 不出现，整个 job 卡死。

### 6.2 根因
当时 `get_sockdelays` 的 netlink 通信还没完全打通，用户态内部的：

```c
mnl_socket_recvfrom()
```

可能无限期阻塞；guest-init 卡住后，QEMU 无法继续执行到 `poweroff`，CI 就一直挂起。

### 6.3 修复方式
增加多层超时保护：

- 单次 `get_sockdelays` 调用加 `timeout`
- 测试脚本执行加 `timeout`
- `guest-init.sh` 增加 120 秒 watchdog
- `ci-test.sh` 外层保留 300 秒 QEMU 超时

### 6.4 结果
即使 netlink 出问题，QEMU 也能退出，不会再把整个 CI 卡死。

---

## 7. 第六阶段：本地测试脚本 local-test.sh 建立

### 7.1 动机
频繁依赖 CI 迭代太慢，因此需要一个本地快速测试方案，能够：

- 同步源码到内核树
- 增量编译内核
- 编译用户态工具
- 构造轻量 initramfs
- 本地 QEMU 启动并保存日志

### 7.2 实现方式
新增：

- `local-test.sh`

它支持三种模式：

```bash
./local-test.sh
./local-test.sh --kernel-only
./local-test.sh --qemu-only
```

### 7.3 结果
本地可以快速复现问题，不必每次都 push 跑 CI。

---

## 8. 第七阶段：local-test.sh “无输出 / 卡死”问题

### 8.1 问题现象
运行：

```bash
./local-test.sh --qemu-only
```

时，终端看起来“没有任何输出”或者像卡死一样。

### 8.2 根因
`init_log()` 中用了：

```bash
exec > >(tee -a "$LOG_FILE") 2>&1
```

这会产生一个独立的 `tee` 子进程。外层如果再用 `timeout` 包裹，杀掉的是脚本主进程，不一定能杀掉 `tee`，导致：

- 终端看起来卡死
- 日志输出不完整
- QEMU 的输出被 tee 行为影响

### 8.3 修复方式
去掉 `exec > >(tee ...)`，改为在主流程末尾统一做：

```bash
{ ... } 2>&1 | tee -a "$LOG_FILE"
```

### 8.4 结果
`local-test.sh` 正常退出，不再出现“无输出 / 假死”现象。

---

## 9. 第八阶段：36-byte 回复问题

### 9.1 问题现象
在 inode 查询已经 `MATCH ret=0` 的情况下，用户态仍打印：

```text
(no matching sockets)
```

同时诊断显示收到的回复只有 **36 bytes**。

### 9.2 第一层定位
用户态进一步打印发现收到的是：

```text
type=2
```

也就是：

```text
NLMSG_ERROR
```

但再继续看发现：

```text
error=0
```

这说明它不是“失败”，而是一个 **ACK**。

### 9.3 根因
问题出在 `resolve_family_id()`：

- 发送 `CTRL_CMD_GETFAMILY` 请求时带了 `NLM_F_ACK`
- 内核因此返回 **两条消息**：
  1. family id 数据消息
  2. ACK（`NLMSG_ERROR error=0`）
- `resolve_family_id()` 只读了一次，把数据消息读走了
- **ACK 留在 socket 接收队列里**
- 后续真正的业务查询 `do_query()` 首先读到的不是自己的回包，而是这个残留 ACK

于是用户态误以为这次查询已经结束，直接退出，最终显示：

```text
(no matching sockets)
```

### 9.4 修复方式
去掉：

```c
NLM_F_ACK
```

改为：

```c
nlh->nlmsg_flags = NLM_F_REQUEST;
```

### 9.5 结果
修复后终于收到了真正的数据消息：

```text
recvfrom 168 bytes type=28
proto=tcp pid=... inode=... comm=nc ...
```

说明用户态与内核之间的主链路已经彻底打通。

---

## 10. 第九阶段：本地测试环境补全（iperf3 / nc 打入 initramfs）

### 10.1 问题
本地 busybox initramfs 缺少真实 `iperf3` 和 `nc`，导致测试因环境问题失败。

### 10.2 修复
在 `local-test.sh` 中新增 `copy_binary_with_libs()` 函数，将宿主机的真实
`iperf3`、`nc` 及其依赖库一起拷入 initramfs。

### 10.3 结果
initramfs 从 3.9M 增大到 5.8M，guest 里可以使用真实工具了。

---

## 11. 第十阶段：QEMU KVM/SGX 被沙箱拦截

### 11.1 问题
QEMU 启动时报：
```
Could not access KVM kernel module: Permission denied
TRAE Sandbox Error: hit restricted
Not allow operate files: /dev/sgx_vepc, /dev/kvm
```

### 11.2 根因
当前 Trae 沙箱禁止 QEMU 访问 `/dev/kvm` 和 `/dev/sgx_vepc`。

### 11.3 修复
在 `local-test.sh` 中实现 KVM→TCG 自动降级：
1. 先尝试 KVM（`-machine q35,accel=kvm,smm=off -cpu host,-sgx`）
2. 检测到 `/dev/kvm` 或 SGX 受限关键词后，自动切到 TCG
3. TCG 模式使用 `-machine q35,accel=tcg,smm=off -cpu qemu64,-sgx`

---

## 12. 第十一阶段：TCG 超时不足

### 12.1 问题
TCG 纯软件模拟比 KVM 慢很多，90 秒超时不够 guest 完成启动和测试。

### 12.2 修复
把 KVM 和 TCG 的超时拆成独立参数：
- `QEMU_TIMEOUT_KVM` 默认 90 秒
- `QEMU_TIMEOUT_TCG` 默认 240 秒
- 向后兼容旧的 `QEMU_TIMEOUT`

### 12.3 结果
240 秒足够 TCG 模式跑完所有测试。guest 完整启动，内核日志显示
family 注册、PID 查询、inode 匹配全部成功。

---

## 13. 第十二阶段：测试脚本判定逻辑 + 工具/内核剩余 bug

### 13.1 问题
guest 能跑起来了，但 9 个测试中 9 个 FAIL、2 个 PASS。
内核日志证明数据链路完全通了，但测试脚本判定不过。

### 13.2 修复的 5 类问题

| # | 问题 | 根因 | 修复 |
|---|------|------|------|
| 1 | grep "TCP" 不匹配 | 工具输出 `proto=tcp`（小写） | 改为 `grep -qi "proto=tcp"` |
| 2 | PID 列位置错误 | 脚本用 `awk '{print $(NF-2)}'`，但 PID 在第2列 | 改为 `sed -n 's/.*pid=\([0-9]*\).*/\1/p'` |
| 3 | inode grep 误匹配 | `grep -q "$INODE"` 匹配到端口号数字 | 改为 `grep -q "inode=$INODE"` |
| 4 | `[diag]` 干扰测试 | 调试日志硬编码到 stderr | 加 `--debug` 标志，默认不输出 |
| 5 | `-i` / `-R` 挂死 | 非 MULTI 回复无 NLMSG_DONE，工具永远阻塞 | 工具检测非 MULTI 后 break；内核 cmd_reset 发回复 |

### 13.3 最终结果

```
[PASS] output contains inode 1306                           ← test_inode_query
[PASS] output has exactly 1 data line
[SKIP] test_multi_socket.sh (dependencies not met)           ← test_multi_socket (无 python3)
[PASS] output has 2 line(s)                                  ← test_pid_query
[PASS] output contains TCP type
[PASS] all counters are zero/N/A after reset                 ← test_reset
[PASS] pre-reset output was non-empty (traffic was recorded)
[PASS] TCP path: output contains TCP type                    ← test_tcp_udp
[PASS] UDP path: output contains UDP type

总计: 8 PASS / 0 FAIL / 1 SKIP
```

---

## 14. 第十三阶段：CI doit 回调未触发根因修复

### 14.1 问题现象

本地测试全部通过（8 PASS / 0 FAIL / 1 SKIP），但 CI 环境中所有查询返回
"(no matching sockets)"，内核 `pr_emerg` 调试日志不出现。核心矛盾：

- CI vmlinux **包含**所有 pr_emerg 字符串（`strings` 确认）
- CI genl family **已注册**（`framework registered v2 (family=28)` 出现在 dmesg）
- 但 CI dmesg 中 **无** doit 回调的 pr_emerg 日志
- 工具返回 0（非错误），输出 "(no matching sockets)"

### 14.2 根因

**`send_and_recv` 函数 non-multipart 路径丢弃 `mnl_cb_run` 返回值**

```c
// 旧代码 (BUG)
if (!(rnlh->nlmsg_flags & NLM_F_MULTI) &&
    rnlh->nlmsg_type != NLMSG_DONE &&
    rnlh->nlmsg_type != NLMSG_ERROR) {
    mnl_cb_run(buf, ret, seq, portid, parse_msg_cb, ctx);  // 返回值被丢弃!
    break;  // ret 仍是 recvfrom 的字节数 (正数), 非 MNL_CB_ERROR
}
return ret == MNL_CB_ERROR ? -EIO : 0;  // 总是返回 0
```

当 `mnl_cb_run` 因 seq/portid 不匹配返回 `MNL_CB_ERROR` 时，错误被静默忽略，
函数返回 0，`do_query` 打印 "(no matching sockets)"。

**叠加因素：CI 工具二进制过期** — `make tool` 未重建二进制（Make 认为目标已最新），
导致 CI 使用旧版本工具，缺少最新的 seq 检查和诊断逻辑。

### 14.3 修复

1. **send_and_recv seq 检查** — 处理消息前检查 `nlmsg_seq`，跳过 stale 消息；
   non-multipart 路径捕获 `mnl_cb_run` 返回值并正确传播错误
2. **make -B tool** — CI 脚本强制无条件重建工具二进制，避免使用过期构建
3. **-d 短选项** — `--debug` → `-d`（避免旧二进制不识别长选项）
4. **增强诊断** — printk 日志级别检查、genl family 列表、dmesg tail、
   recvfrom 详细输出（type/len/flags/seq/pid 与期望值对比）

### 14.4 结果

CI 首次出现 pr_emerg 日志，确认 doit 回调被调用、数据消息成功发送：

```
net_delayacct: cmd_get_by_pid: querying pid=81
net_delayacct: iter_task_sockets pid=81 max_fds=256
net_delayacct: iter fd=3 inode=1111 family=10 proto=6 FOUND
net_delayacct: one_reply: SEND skb->len=168 nlmsg_type=28 nlmsg_flags=2
net_delayacct: one_reply: genlmsg_reply ret=0
```

测试结果：8 PASS / 1 FAIL / 1 SKIP（仅 UDP iperf3 时序问题，下一阶段修复）。

---

## 15. 第十四阶段：selftest nc 时序修复 + CI 首次全绿

### 15.1 问题 1：selftest Test 2 — nc listener PID 查询失败

#### 现象

CI 中 Test 2 报告：

```
[FAIL] nc listener (pid 102) no socket data (output: (no matching sockets))
```

#### 根因

OpenBSD `nc -l` 的默认行为是：接受第一个连接后，处理完毕即退出。测试脚本的
时序为：先启动 nc 监听 → 客户端连接 → nc 退出 → 查询时所有 fd 已关闭。

内核日志证实：`iter_task_sockets pid=102 max_fds=256` 但没有 `iter fd=...` 行 —
进程仍在 task list 中（zombie），但所有文件描述符均已关闭。

#### 修复

在客户端连接**之前**查询 nc 监听器，此时 listening socket 保证已打开：

```bash
nc -l -p "$port" &
nc_pid=$!
sleep 1
# Query BEFORE connecting — listening socket is guaranteed open
out=$("$GET_SOCKDELAYS" -p "$nc_pid" 2>&1 || true)
# ... check output ...
# 然后再发起客户端连接（可选，不影响测试结果）
```

同样的时序修复应用到 Test 4（reset）和 Test 7（multi-socket）。

### 15.2 问题 2：test_fail() 的 exit 1 导致后续测试不执行

#### 现象

Test 2 FAIL 后，`test_fail()` 调用 `exit 1`，整个 selftest 脚本退出。
Tests 3-7 从未执行，无法判断它们是否通过。

#### 修复

从 `test_fail()` 中移除 `exit 1`，改为只递增失败计数器。所有测试都会执行完毕，
最终退出码由 `print_summary()` 的返回值决定（有失败则返回 1）。

```bash
# Before:
test_fail() {
    TEST_FAIL_COUNT=$((TEST_FAIL_COUNT + 1))
    echo "[FAIL] $1"
    exit 1               # ← 立即退出，后续测试不执行
}

# After:
test_fail() {
    TEST_FAIL_COUNT=$((TEST_FAIL_COUNT + 1))
    echo "[FAIL] $1"
    # 不退出，让所有测试跑完
}
```

### 15.3 问题 3：guest-init.sh 的 SKIP 误导信息

#### 现象

`test_multi_socket.sh` 因缺少 python3 返回 exit code 4（SKIP），
但 `guest-init.sh` 的 `|| echo "test timed out or failed"` 误导性地报告失败。

#### 修复

在 `guest-init.sh` 中正确处理 exit code 4（SKIP），区分 SKIP 和真正的失败：

```bash
set +e
timeout 30 bash "$t" 2>&1
rc=$?
set -e
if [ "$rc" -eq 4 ]; then
    echo "  (SKIP: dependencies not met)"
elif [ "$rc" -ne 0 ]; then
    echo "  (test failed or timed out, rc=$rc)"
fi
```

### 15.4 CI 验证结果

**CI 状态：Succeeded** ✅ — 首次全绿！

```
selftest:  Passed: 8, Failed: 0
  Test 1: PASS  query own PID
  Test 2: PASS  nc listener PID query        ← 之前 FAIL，已修复
  Test 3: PASS  inode query
  Test 4: PASS  reset counters
  Test 5: PASS  TCP path (iperf3)
  Test 6: PASS  UDP path (iperf3 -u)          ← 之前 FAIL，已修复
  Test 7: PASS  multi-socket (nc + iperf3)

func tests: ALL PASS
  test_inode_query.sh: PASS=2
  test_multi_socket.sh:  SKIP (requires python3)
  test_pid_query.sh:    PASS=2
  test_reset.sh:        PASS=2
  test_tcp_udp.sh:      PASS=2 (TCP + UDP)
```

---

## 16. 当前开发状态总结

### 已经解决的问题

- 静态 IP 配置完成
- Git 网络问题解决（HTTPS → SSH）
- Generic Netlink family 注册失败解决
- inode 查询失败解决（`file_inode(file)->i_ino`）
- CI/QEMU 挂死问题解决（多层 timeout/watchdog）
- `local-test.sh` 无输出 / 假死问题解决（tee 改造）
- 36-byte `NLMSG_ERROR` / ACK 残留问题解决（去掉 `NLM_F_ACK`）
- 用户态与内核态主链路已经打通
- 本地 initramfs 补全真实 iperf3/nc
- KVM→TCG 自动降级 + 独立超时
- 测试脚本判定逻辑全部修复
- `get_sockdelays --debug` 标志
- 非 MULTI 回复 break 修复
- 内核 cmd_reset 发送回复
- **send_and_recv 丢弃 mnl_cb_run 返回值修复**（CI doit 未触发根因）
- **CI 工具二进制过期修复**（`make -B tool` 强制重建）
- **selftest nc 时序修复**（OpenBSD nc 连接后退出）
- **test_fail() 移除 exit 1**（所有测试都能执行）
- **guest-init.sh 正确处理 SKIP**（exit code 4）
- **本地测试 8 PASS / 0 FAIL / 1 SKIP**
- **CI 首次全绿：selftest 8/8 PASS + func 测试全 PASS**

### 当前剩余事项

- test_multi_socket 需要 python3（guest 未安装，SKIP 而非 FAIL）

### 下一步建议

1. 整个开发链路已基本完成
2. 可考虑将 test_multi_socket 的 python3 依赖加入 CI rootfs 以消除最后一个 SKIP

---

## 18. 第十七阶段：可视化演示增强 + 严格压力测试 + 中文注释

### 18.1 问题描述

第十四阶段 CI 全绿后，功能链路已完全打通。但之前的 Demo 测试覆盖较弱：
- 最多只测 3 个 socket/进程
- RX/TX count 只有几十~几百级别
- 缺少"一个进程持有多个 socket 且每个都有高流量"的压力测试场景
- `docs/get_sockdelays_demo.log` 只有原始输出，无中文注释

### 18.2 修复内容

**1. `local-test.sh` Demo 11-13 压力测试重写**

利用 `iperf3 -P N` 并行流特性，让一个进程同时持有多个有流量的 socket：

| Demo | 旧版 | 新版 | 改进 |
|------|------|------|------|
| 11 高并发 | 10 个 nc 进程各 1 socket | iperf3 -P 6，1 进程 8 socket | socket/进程提升 8× |
| 12 大流量 | -t 2 -b 200M 限速 | -P 3 -t 5 不限速 | count 从几十提升到数百 |
| 13 混合协议 | TCP 单连接 + UDP 单连接 | TCP -P 5 (7 socket) + UDP | 多连接 + 协议隔离验证 |

每次查询后自动统计 socket 数量和最大 count 值进行验证。

**2. `-smp 1` 适配 TCG 模式**

QEMU `-smp 2` 改为 `-smp 1`，避免 sandbox 环境下 TCG 多线程被挂起。

**3. `docs/get_sockdelays_demo.log` 可视化文件**

从 QEMU TCG 实际运行日志提取 14 个 Demo 输出，每个 Demo 添加中文注释：
- 场景说明、执行命令、行尾注释、数据分析、结论验证

### 18.3 验证结果

关键压力测试数据：
- Demo 11：单进程 8 socket，data 连接 RX count 382~399/连接
- Demo 13 TCP：单进程 7 socket，全部 proto=tcp 无 UDP 混入
- Demo 3：服务端 RX count 2075
- 所有 14 个 Demo 成功执行，无崩溃、无遗漏、无溢出

### 18.4 修改文件

| 文件 | 改动 |
|------|------|
| local-test.sh | 重写 Demo 11-13 压力测试；-smp 1 |
| docs/get_sockdelays_demo.log | 新建：14 Demo 可视化输出 + 中文注释 |

---

## 17. 一句话总结

这一轮开发的主线是：

**先把 Generic Netlink 主通信链路打通，再把本地 QEMU 测试环境修到足够接近 CI，然后修复测试脚本判定逻辑和工具/内核剩余 bug，最后解决 CI 环境特有的 doit 回调未触发问题，实现 CI 全绿。**

最终结果：本地测试 8 PASS / 0 FAIL / 1 SKIP；CI selftest 8/8 PASS + func 测试全 PASS。

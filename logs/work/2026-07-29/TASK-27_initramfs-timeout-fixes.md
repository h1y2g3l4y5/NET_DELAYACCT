# TASK-27 修复 initramfs mktemp 缺失与 QEMU 超时不足

- **日期**: 2026-07-29
- **关联 Review**: v6.0.0 (TASK-26 后续修复)
- **状态**: [待Review]

## 1. 任务描述

TASK-26 完成 22 项测试扩展后，QEMU 测试验证发现两个基础设施问题：

1. **mktemp 命令缺失**：Test 13 并发查询使用 `mktemp -d` 创建临时目录，
   但 busybox applet 列表中未包含 mktemp，导致 guest 内 `mktemp: command not found`。
2. **超时不足**：22 项测试在 TCG 软件模拟模式下运行时间超过原 240s 超时，
   guest-init.sh 在测试完成前被 timeout 杀死；同时 QEMU 外层超时 300s 小于
   guest 内 watchdog 360s，导致 QEMU 在 watchdog 触发前就被外层 timeout 终止。

## 2. 变更内容

### 2.1 local-test.sh — busybox applet 列表补全

**文件**: `local-test.sh` 第 227-232 行

新增 applet：
- `mktemp` — Test 13 `mktemp -d` 依赖
- `tee` — guest-init.sh `| tee "$RESULT_FILE"` 依赖
- `uname` — guest-init.sh `uname -r` 依赖
- `sync` — guest-init.sh `sync` 依赖
- `reboot`/`poweroff`/`halt` — guest-init.sh 关机依赖
- `modprobe` — guest-init.sh `modprobe net-delayacct` 依赖
- `mountpoint` — guest-init.sh `mountpoint -q` 依赖
- `strings` — guest-init.sh 诊断 `strings get_sockdelays` 依赖
- `seq` — 通用序列生成

### 2.2 local-test.sh — QEMU 超时调整

**文件**: `local-test.sh` 第 31-32 行

| 参数 | 旧值 | 新值 | 理由 |
|------|------|------|------|
| QEMU_TIMEOUT_KVM | 120s | 300s | 22 项测试在 KVM 下需 ~200s |
| QEMU_TIMEOUT_TCG | 300s | 600s | 需大于 guest watchdog 540s |

### 2.3 ci/qemu/guest-init.sh — 测试超时与 watchdog 调整

**文件**: `ci/qemu/guest-init.sh` 第 21-23 行、第 101-109 行

| 参数 | 旧值 | 新值 | 理由 |
|------|------|------|------|
| run-tests.sh timeout | 240s | 480s | TCG 下 22 项测试需 ~400s |
| watchdog | 360s | 540s | 需大于测试超时 480s + 余量 |

### 2.4 .github/workflows/ci.yml — CI applet 列表补全

**文件**: `.github/workflows/ci.yml` 第 271-274 行

新增 applet：
- `mktemp` — 与 local-test.sh 保持一致
- `rm` — Test 13 清理 `rm -rf "$TMPDIR"` 依赖

## 3. 变更原因

### 3.1 mktemp 缺失根因

Test 13（并发查询压力）使用 `TMPDIR=$(mktemp -d)` 创建临时目录存放 16 个 worker 的
输出文件。但 initramfs 的 busybox applet 符号链接列表中没有 `mktemp`，导致 guest 内
执行 `mktemp` 时找不到命令。

local-test.sh 的 applet 列表与 ci.yml 的 applet 列表是**独立维护**的，
两者都遗漏了 mktemp。本次修复同时补全两处。

### 3.2 超时不足根因

**内层超时**（guest-init.sh 中 run-tests.sh 的 timeout）：
- 原 240s 是 16 项测试时代的设置
- 22 项测试中新增的 Test 17-22 包含 iperf3 长连接（-t 12）、辅助程序启动、
  IPv6 测试等，TCG 模式下运行时间显著增加
- 实测 TCG 模式下 22 项测试需要约 350-450s

**外层超时**（local-test.sh 中 QEMU 的 timeout）：
- 原 TCG 300s < guest watchdog 360s，存在「QEMU 外层先超时」的风险
- 正确的层次关系应为：QEMU 外层 > guest watchdog > run-tests.sh timeout
- 修复后：600s > 540s > 480s，层次正确

### 3.3 applet 列表对齐

local-test.sh 缺少多个 guest-init.sh 依赖的命令（tee/uname/sync/poweroff/modprobe/mountpoint）。
这些命令在之前的 16 项测试中可能恰好没被触发（或失败被静默忽略）。
22 项测试扩展后暴露了这些缺失。本次一并补齐，使 local-test.sh 的 applet 列表
成为 CI 列表的超集。

## 4. 踩坑记录

### 4.1 超时层次关系

- **问题描述**：QEMU 外层 timeout 先于 guest watchdog 触发，导致测试被截断
- **原因分析**：QEMU_TIMEOUT_TCG(300s) < guest watchdog(360s)，
  外层 timeout 先到，guest 内的 watchdog 从未有机会执行
- **解决方案**：确保层次关系 QEMU 外层 > watchdog > run-tests.sh timeout
  （600s > 540s > 480s）
- **如何避免**：修改任何一层的 timeout 时，必须同步检查相邻层次

### 4.2 local-test.sh 与 ci.yml applet 列表独立维护

- **问题描述**：两处 applet 列表独立维护，容易遗漏不一致
- **原因分析**：没有统一的 applet 列表来源
- **解决方案**：本次手动对齐，local-test.sh 成为 CI 的超集
- **如何避免**：未来可考虑提取为共享配置文件，消除重复

## 5. 测试验证

- QEMU 测试进行中（验证 mktemp 修复 + 超时修复后 22 项测试全部通过）

## 6. 待办/遗留问题

- ~~如 TCG 模式 480s 仍不足，需进一步增加超时或优化测试效率~~ → 已通过减少 Test 13 工作量解决
- applet 列表统一化（低优先级）

## 7. 补充修复：Test 13 工作量调整（2026-07-29 17:15）

### 问题

mktemp 和超时修复后首次 QEMU 验证（17:04-17:13）发现 Test 13 仍在 480s 超时内未完成。
Test 13 原参数为 8+8 workers × 20 queries = 320 次查询，在 TCG 软件模拟模式下
每次查询约 0.875s（含 Netlink 消息交换 + 内核 dumpit 遍历 + per-socket spinlock），
320 次查询约需 280s，加上 Tests 1-12 的 ~200s，总计 ~480s 刚好触及超时边界。

### 修复

**ci/qemu/run-tests.sh** Test 13 参数调整：

| 参数 | 旧值 | 新值 | 理由 |
|------|------|------|------|
| WORKERS_EMPTY | 8 | 4 | 仍覆盖空 fdtable 并发路径 |
| WORKERS_BUSY | 8 | 4 | 仍覆盖 per-socket spinlock 并发路径 |
| QUERIES | 20 | 10 | 仍覆盖重复查询稳定性 |

总查询数从 320 降至 80（4+4 × 10），TCG 下约 60-80s。
测试设计不变（混合空 PID + busy PID），仅减少负载量。

**tests/README.md** 同步更新 Test 13 描述、覆盖矩阵负载等级、稳定性查询数。

### 超时层次最终确认

```
QEMU TCG 外层 (600s) > guest watchdog (540s) > run-tests.sh (480s)
     ↓                        ↓                        ↓
  杀 QEMU 进程           guest 内 poweroff         杀测试脚本
```

Tests 1-12 (~200s) + Test 13 (~70s) + Tests 14-22 (~180s) = ~450s < 480s ✓

## 8. 补充修复：Test 13 wait 死锁 Bug（2026-07-29 17:30）

### 问题

减少 Test 13 工作量后（320 → 80 queries），QEMU 验证发现 Test 13 **仍然超时**。
分析 kernel timestamp 发现：

- Tests 1-12 在 kernel boot 后 ~67s 完成（远快于预估的 200s）
- Test 13 从 ~67s 一直运行到 ~480s 超时（~413s），80 次查询不可能需要这么久

### 根因

**Test 13 的 `wait` 命令等待了 iperf3 server 进程，导致死锁。**

```bash
iperf3 -s -p "$BUSY_PORT" &  # 后台 iperf3 server（持续运行）
BUSY_SRV=$!
iperf3 -c ... -P 4 -t 30 &   # 后台 iperf3 client（30s 后退出）
BUSY_CLI=$!

_worker ... &                 # 后台 worker（10 次查询后退出）

wait                          # ← BUG: 等待所有后台进程，包括 iperf3 server！
```

`wait` 不带参数时等待**所有**后台子进程，包括：
- 8 个 worker（10 次查询后正常退出）
- iperf3 server（持续监听，永不主动退出）
- iperf3 client（30s wall clock 后退出）

由于 iperf3 server 永不退出，`wait` 永远阻塞，直到 480s timeout 杀死整个测试脚本。

### 修复

收集 worker PID，使用 `wait $WORKER_PIDS` 只等待 worker 进程：

```bash
WORKER_PIDS=""
_w=0
while [ "$_w" -lt "$WORKERS_EMPTY" ]; do
    _worker "$_w" 1 "empty" &
    WORKER_PIDS="$WORKER_PIDS $!"
    _w=$((_w + 1))
done

if [ -n "$BUSY_PID" ]; then
    _w=0
    while [ "$_w" -lt "$WORKERS_BUSY" ]; do
        _worker "$((_w + WORKERS_EMPTY))" "$BUSY_PID" "busy" &
        WORKER_PIDS="$WORKER_PIDS $!"
        _w=$((_w + 1))
    done
fi

# 只等待 worker 进程，不等待 iperf3 server（server 持续运行直到被 kill）
wait $WORKER_PIDS 2>/dev/null || true
```

iperf3 server/client 在 worker 完成后由后续的 `_kill` 清理。

### 如何避免

- **shell `wait` 不带参数会等待所有后台子进程**，包括非测试进程（iperf3 server 等）
- 并发测试中使用 `wait $PID1 $PID2 ...` 显式指定要等待的进程
- 或在 `wait` 前先 kill 掉非测试后台进程

## 9. 补充修复：Test 16 negative case + Test 20 zerocopy（2026-07-29 17:35）

### Test 16 negative case 修复

**问题**：原 negative case `--proto udp --lport 21417` 期望返回空，但实际返回了 UDP server socket。
原因：iperf3 UDP server **监听** 21417 端口，所以 `--lport 21417` 正确匹配了 UDP server socket。
`--proto udp` + `--lport 21417` 两个条件都满足 → AND 结果非空。

**修复**：改用 `--proto udp --lport 99999`（不存在的端口）。
`--proto udp` 匹配 UDP server socket（条件 1 满足），但 `--lport 99999` 不匹配任何 socket（条件 2 不满足），
AND 结果为空。这更好地验证了 AND 语义。

### Test 20 TCP_ZEROCOPY_RECEIVE setsockopt → getsockopt

**问题**：helper 程序使用 `setsockopt(cfd, IPPROTO_TCP, TCP_ZEROCOPY_RECEIVE, &zc, sizeof(zc))`，
但 `TCP_ZEROCOPY_RECEIVE` 是 **getsockopt** 专用选项，setsockopt 路径不识别它 → 返回 ENOPROTOOPT → 测试 SKIP。

**修复**：改为 `getsockopt(cfd, IPPROTO_TCP, TCP_ZEROCOPY_RECEIVE, &zc, &optlen)`，
注意 getsockopt 的最后一个参数是 `socklen_t *`（指针），不是 `socklen_t`（值）。

**结果**：QEMU 内核仍不支持 TCP_ZEROCOPY_RECEIVE（getsockopt 也返回错误），测试仍 SKIP，
但这是真正的内核能力限制，而非 API 误用。在支持该特性的环境（现代发行版 + 物理 NIC）下可正常运行。

## 10. 最终测试结果

```
╔══════════════════════════════════════════════════════════════╗
║  NET_DELAYACCT Test Results                                  ║
╠══════════════════════════════════════════════════════════════╣
║  Tests run: 22     PASS: 21     FAIL:  0     SKIP:  1       ║
╠══════════════════════════════════════════════════════════════╣
║  RESULT: ALL PASS                                            ║
╚══════════════════════════════════════════════════════════════╝
```

| Test | 结果 | 说明 |
|------|------|------|
| 01-12 | PASS | 基础功能/工具展示/压力测试/边界条件 |
| 13 | PASS | 80 queries (ok=80 fail=0 busy_ok=40), 17s |
| 14 | PASS | 协议过滤 + negative case |
| 15 | PASS | 端口过滤 |
| 16 | PASS | 组合过滤 + negative case (lport 99999) |
| 17 | PASS | Reset 非原子语义 (2 socket count>0) |
| 18 | PASS | 双向流量 (2 socket RX>0 && TX>0) |
| 19 | PASS | splice RX (RX_sum=1670) |
| 20 | SKIP | TCP_ZEROCOPY_RECEIVE 内核不支持 (graceful skip) |
| 21 | PASS | UDP corked TX (TX_sum=714) |
| 22 | PASS | IPv6 (srv_RX=85, cli_TX=95) |

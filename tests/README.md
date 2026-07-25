# NET_DELAYACCT 测试套件

## 一、测试基础设施

### 1.1 整体架构

```
GitHub Actions CI
├── checkpatch    → 内核 patch 代码风格检查
├── build-kernel  → 打 patch → 编译 bzImage（ccache 加速）
├── build-tool    → 编译用户态 get_sockdelays
└── qemu-test     → 打包 initramfs → QEMU 启动 → 跑测试
```

### 1.2 QEMU 虚拟机环境

| 组件 | 说明 |
|------|------|
| 内核 | 打上所有 `kernel-patches/*.patch` 的 linux-6.6 |
| 文件系统 | 内存 initramfs（busybox + bash + iperf3 + nc + get_sockdelays） |
| 网络 | `-netdev user` user-mode 网络，e1000 网卡，lo 回环 |
| 加速 | KVM 优先（300s 超时），不可用则降级 TCG（600s） |
| init | `ci/qemu/guest-init.sh`：挂载 /proc/sys/dev → 诊断 → 调 `run-tests.sh` → poweroff |
| watch dog | `sleep 360; poweroff -f` 防挂死 |

### 1.3 流量生成工具

| 工具 | 用途 |
|------|------|
| `iperf3 -P N -t 5` | TCP 多流数据传输，产生可计量的 RX/TX |
| `iperf3 -u -b 10M -t 5` | UDP 数据流传输 |
| `nc -l -p PORT` | 产生单个 TCP 监听 socket，用于 inode 查询 |

### 1.4 判定框架（`ci/qemu/run-tests.sh`）

```bash
_PASSED=0   _FAILED=0   _SKIPPED=0   _TEST_NUM=0

_pass()   { echo "[PASS] $*"; _PASSED=$((_PASSED + 1)); }
_fail()   { echo "[FAIL] $*"; _FAILED=$((_FAILED + 1)); }
_skip()   { echo "[SKIP] $*"; _SKIPPED=$((_SKIPPED + 1)); }
_require  # 命令不存在 → SKIP + return 1（不崩溃）

_show_output()  # 失败时打印 get_sockdelays 原始输出 + 协议/计数摘要
```

末尾框式汇总：

```
╔══════════════════════════════════════════════════════════════╗
║  NET_DELAYACCT Test Results                                  ║
╠══════════════════════════════════════════════════════════════╣
║  Tests run: 13     PASS: 13     FAIL:  0     SKIP:  0      ║
╠══════════════════════════════════════════════════════════════╣
║  RESULT: ALL PASS                                            ║
╚══════════════════════════════════════════════════════════════╝
```

### 1.5 失败诊断机制

当测试失败时，自动打印：
- 触发失败的具体条件（预期值 vs 实际值）
- `get_sockdelays` 的原始输出（stdout + stderr 合并）
- 协议摘要：tcp socket 数量、udp socket 数量、RX 总量、TX 总量
- 进程存活状态（是否已退出等）

示例：

```
    [FAIL] data_lines=0, proto=tcp=0
    ┌── get_sockdelays -p 12345 ──────────────────────────
    │ (empty output)
    │ lines=0 (tcp=0, udp=0)
    └──────────────────────────────────────────────────────
```

---

## 二、测试用例详解（共 13 项）

### 第一部分：基础功能（Test 01-06）

验证 `get_sockdelays` 的核心能力——能否正确查到 socket 统计。

---

#### Test 01: PID 查询

| 项目 | 内容 |
|------|------|
| **原理** | `get_sockdelays -p <PID>` 向内核 Generic Netlink 查询指定进程持有的所有 socket 统计 |
| **实现** | 启动 iperf3 TCP server + client。客户端后台运行 `&`，在传输进行中（`sleep 2`）查询客户端 PID，检查输出是否包含 `proto=tcp` 行 |
| **断言** | `proto=tcp` 的数据行 ≥ 1 |
| **时序** | 客户端必须 `&` 后台运行，查询时 socket 仍活跃 |

#### Test 02: Inode 查询

| 项目 | 内容 |
|------|------|
| **原理** | 每个 socket 在内核中有一个唯一 inode 号。通过 `/proc/<PID>/fd/<N>` 的符号链接 `socket:[inode]` 可提取 inode，然后 `get_sockdelays -i <inode>` 按 inode 查询 |
| **实现** | `nc -l -p PORT &` 创建监听 socket → 遍历 `/proc/$PID/fd/*` 提取 `socket:[数字]` → `get_sockdelays -i $INODE` → 检查输出是否包含 `inode=$INODE` |
| **断言** | 输出中 `inode=$INODE` 匹配 |
| **依赖** | `/proc` 文件系统已挂载 |

#### Test 03: 重置计数器

| 项目 | 内容 |
|------|------|
| **原理** | `get_sockdelays -R` 向内核发送 reset 命令，将所有 socket 的 RX/TX 计数器清零 |
| **实现** | iperf3 产生流量 → 查询确认有数据 → 执行 `-R` → 再次查询 → 检查所有 socket 的 `count=` 是否全为 0 |
| **断言** | 重置后 `count > 0` 的行数 = 0 |

#### Test 04: TCP 路径

| 项目 | 内容 |
|------|------|
| **原理** | 验证内核 per-socket 延迟统计对 TCP socket 的追踪能力 |
| **实现** | iperf3 TCP 传输完成后查询 server PID → 检查 `proto=tcp` 行是否存在 + RX 计数 > 0 |
| **断言** | `proto=tcp` 行 ≥ 1，且至少一个 socket 的 `RX count >= 1` |
| **容错** | 有 TCP socket 但 RX=0 也给 PASS（标注 timing——传输可能刚结束） |

#### Test 05: UDP 路径

| 项目 | 内容 |
|------|------|
| **原理** | 验证内核 per-socket 延迟统计对 UDP socket 的追踪能力。UDP 无连接，统计行为与 TCP 不同 |
| **实现** | iperf3 UDP 客户端 `&` 后台运行（`-u -b 10M`），在传输进行中**同时查询客户端和服务端**两端的 `proto=udp` |
| **断言** | 两端汇总 `proto=udp` 总数 ≥ 1 |
| **关键修复** | 旧代码客户端同步运行（无 `&`），5s 后退出，查询时 socket 已被内核清理 |

#### Test 06: 多 Socket 枚举

| 项目 | 内容 |
|------|------|
| **原理** | 验证一个进程持有多个 socket 时，`get_sockdelays` 能否全部枚举 |
| **实现** | `iperf3 -P 4` 产生 4 条并行 TCP 数据流 → 查询服务端 PID |
| **断言** | 客户端父进程 ≥ 1 socket（control），服务端 ≥ 6 socket（1 listen + 1 control + 4 data） |
| **关键设计** | `iperf3 -P 4` 会 fork 子进程处理数据连接。客户端只查父进程 PID（子进程 socket 不在父进程 fd 表），服务端不 fork，所有 socket 可见 |

---

### 第二部分：工具展示（Test 07-08）

验证 `get_sockdelays` 的辅助输出功能。

#### Test 07: JSON 格式输出

| 项目 | 内容 |
|------|------|
| **原理** | `get_sockdelays -j` 将 socket 统计以 JSON 格式输出，便于程序解析 |
| **实现** | iperf3 TCP 传输中查询 `-j -p $_SRV` → 检查输出是否包含 `"proto"` 和 `"rx"` 字段 |
| **断言** | `"proto"` 出现 ≥ 1 次 且 `"rx"` 出现 ≥ 1 次 |

#### Test 08: Debug 诊断模式

| 项目 | 内容 |
|------|------|
| **原理** | `get_sockdelays -d` 在 stderr 输出 netlink 收发诊断信息，用于排查通信问题 |
| **实现** | `nc -l` 创建 socket → `get_sockdelays -d -p $PID 2>&1` 合并捕获 stderr+stdout |
| **断言** | 输出行数 > 0 |

---

### 第三部分：压力测试（Test 09-11）

在极端条件下验证工具的**健壮性**和**正确性**。

核心指标：不崩溃、不遗漏 socket、计数无溢出、协议隔离正确。

#### Test 09: 高并发多连接

| 项目 | 内容 |
|------|------|
| **原理** | 大量并行连接测试工具在高负载下的 socket 枚举能力和计数正确性 |
| **实现** | `iperf3 -P 8`（8 条并行流）→ 查询服务端 |
| **三重断言** | ① socket 数 ≥ 9（1 listen + 8 data）；② RX 总量 > 0；③ TX 总量 > 0 |

#### Test 10: 大流量高计数

| 项目 | 内容 |
|------|------|
| **原理** | 不限速大流量传输，验证计数不会溢出或截断。**按传输方向**分别验证 RX/TX 高计数 |
| **实现** | `iperf3 -P 4 -t 5` 不限速 → 分别查询 server 和 client → server 侧取最大 RX，client 侧取最大 TX |
| **断言** | server RX ≥ 100 且 client TX ≥ 100 |
| **关键修复** | 旧代码只查 server，server 的 TX 只有 ACK（≈2），永远不满足 TX≥100。修复后按方向分端查询 |

#### Test 11: 混合协议隔离

| 项目 | 内容 |
|------|------|
| **原理** | TCP 和 UDP 同时传输，验证内核统计按协议正确隔离，不会交叉污染 |
| **实现** | 两个 iperf3 server：TCP（端口 21411）+ UDP（端口 21412）→ 分别查询两个 server PID |
| **断言** | TCP server：tcp≥5, udp=0；UDP server：tcp≥1 (control), udp≥1 (data) |
| **关键设计** | iperf3 的 UDP 模式也用 TCP 做控制连接，所以 UDP server 会有 1 个 tcp + N 个 udp |

---

### 第四部分：边界条件（Test 12）

验证工具在极端输入下不崩溃、不泄漏、合理报错。

4 个子检查使用本地计数器避免测试计数膨胀：

| 子检查 | 原理 | 断言 |
|------|------|------|
| **(a) PID 1 (init)** | 系统进程通常没有 socket，工具不崩溃即可 | 正常退出（exit 0 或 "no matching"） |
| **(b) PID 99999** | 不存在的 PID，工具应明确报错 | 非零退出码 |
| **(c) -h 帮助** | 用户友好使用说明 | 输出包含 "usage" 或 "用法" |
| **(d) -V 版本** | 版本号输出 | 正常退出 |

---

### 第五部分：稳定性（Test 13）

#### Test 13: 并发查询压力

| 项目 | 内容 |
|------|------|
| **原理** | 多个 worker 同时对内核发起查询，验证 **内核并发安全**——无死锁、无竞态、无 Oops |
| **实现** | 16 个后台进程（`&`），每个进程连续查询 PID 1 **20 次**，共 16 × 20 = 320 次查询。汇总各 worker 的 ok/fail 计数，同时用 `dmesg` 检查 Kernel panic/Oops/BUG |
| **断言** | 无 worker 崩溃（输出文件完整）+ `dmesg` 无内核 oops |
| **关键设计** | 用 `mktemp -d` 创建临时目录收集各 worker 输出，检查输出文件完整性来检测 worker 崩溃 |

---

## 三、测试方法总结

| 维度 | 覆盖情况 |
|------|----------|
| **查询维度** | PID 查询、inode 查询、重置、JSON、debug |
| **协议覆盖** | TCP（Test 01/04/06/09/10/11）、UDP（Test 05/11） |
| **负载等级** | 单连接 → 4 并行 → 8 并行 → 16 worker 并发 |
| **数据验证** | socket 数量（不漏）、协议类型（不错）、RX/TX 计数（不溢出）、计数器重置（真清零） |
| **边界条件** | 正常 PID、PID 1、不存在 PID、help、version |
| **稳定性** | 320 次并发查询 + 内核 Oops 检测 |

**核心手段**：用 iperf3 创建已知特征的 socket（数量、协议、流量方向），用 grep/awk 解析 `get_sockdelays` 输出与预期值比较。

---

## 四、目录结构

```
tests/
  README.md                                    本文档
  selftests/
    net-delayacct/
      Makefile                                  selftests 构建文件
      test_netdelayacct.sh                      selftests 主脚本（已废弃，功能合并入 run-tests.sh）
      test_helper.sh                            辅助函数库
      kunit/
        net-delayacct-test.c                    KUnit 单元测试模块（待集成）
  func/
    test_pid_query.sh                           PID 查询（已废弃，功能合并入 run-tests.sh 的 Test 01）
    test_inode_query.sh                         inode 查询（已废弃）
    test_reset.sh                               重置（已废弃）
    test_multi_socket.sh                        多 socket（已废弃）
    test_tcp_udp.sh                             TCP/UDP 路径（已废弃）
  perf/
    baseline-vs-enabled.sh                      基线对比性能测试（待集成入 CI）
    long-run.sh                                 24h 稳定性测试（手动执行）
    concurrent-query.sh                         并发查询压力测试（待集成入 CI）
  reports/                                      测试报告输出目录（自动生成）
    local/                                      本地测试日志（test-YYYYMMDD_HHMMSS.log）

ci/qemu/
  run-tests.sh                                 **统一测试套件入口**（当前活跃，13 项 CI 测试）
  guest-init.sh                                QEMU 内部 init 脚本（挂载文件系统 + 调 run-tests.sh）
```

---

## 五、如何运行

### 5.1 本地快速测试

```bash
# 完整流程：编译内核 + 工具 + QEMU 测试
./local-test.sh

# 仅编译
./local-test.sh --kernel-only

# 仅 QEMU 测试（假设已编译）
./local-test.sh --qemu-only
```

日志自动保存到 `tests/reports/local/test-YYYYMMDD_HHMMSS.log`。

### 5.2 CI 自动化

Git push 到 `main` 或 `dev` 分支自动触发 `.github/workflows/ci.yml`：

| Job | 运行环境 | 预期耗时 |
|-----|----------|----------|
| checkpatch | ubuntu-22.04 | ~1 min |
| build-kernel | ubuntu-22.04 (ccache 加速) | ~2 min（热缓存） |
| build-tool | ubuntu-22.04 | ~30 sec |
| qemu-test | ubuntu-22.04 (KVM) | ~2 min |

### 5.3 单元测试（KUnit，待集成）

KUnit 测试需要内核启用 `CONFIG_KUNIT=y`：

```bash
# 通过 kunit_tool 运行
./tools/testing/kunit/kunit.py run --kunitconfig=tests/selftests/net-delayacct/kunit

# 模块加载方式
modprobe net-delayacct-test
cat /sys/kernel/debug/kunit/results
```

### 5.4 性能测试（手动执行）

```bash
# 基线对比（需要两个内核镜像）
cd tests/perf
./baseline-vs-enabled.sh /path/to/baseline-bzImage /path/to/enabled-bzImage

# 长时间稳定性（默认 24h）
./long-run.sh 24

# 并发查询压力
./concurrent-query.sh 32
```

---

## 六、测试环境要求

### 内核

- Linux 6.6（或兼容版本）
- `CONFIG_NET_DELAYACCT=y`（功能/性能测试）
- `CONFIG_NET_DELAYACCT=n`（回归基线对比）
- `CONFIG_KUNIT=y`（单元测试，可选）
- `CONFIG_DEBUG_KMEMLEAK=y`（长时间稳定性测试，可选）

### 用户态工具

- `get_sockdelays`（`PATH` 中或 `GET_SOCKDELAYS` 环境变量）
- `iperf3`（功能测试与压力测试）
- `nc` / `ncat`（socket 创建与 inode 测试）
- `busybox`（QEMU initramfs 基础命令）
- `qemu-system-x86_64`（CI QEMU 测试）

### 系统权限

- root 或具备 `CAP_NET_ADMIN`（网络命名空间操作）
- 可读取 `/proc/<pid>/fd/*`（inode 提取）
- 可运行 `dmesg`（稳定性测试后检查内核日志）

---

## 七、注意事项

1. **权限**：大部分测试需要 root 权限或 QEMU guest 内运行（默认 root）。

2. **端口占用**：run-tests.sh 使用端口范围 21401-21412，确保不与其它服务冲突。

3. **get_sockdelays 路径**：脚本通过以下优先级查找：
   - 环境变量 `GET_SOCKDELAYS`
   - `/usr/local/bin/get_sockdelays`（QEMU guest 内默认路径）

4. **ccache**：CI 内核编译使用稳定 ccache key，热缓存下编译仅 ~30 秒。修改 patch 后首次运行需全量编译 ~10 分钟建立缓存。

5. **KVM 降级**：`/dev/kvm` 不可用时自动降级为 TCG 软件模拟，但耗时会增加 10-20 倍，且 `sleep` 计时器可能不可靠。

# NET_DELAYACCT 测试套件

## 测试目标

本测试套件针对 `CONFIG_NET_DELAYACCT` 内核框架及用户态工具 `get_sockdelays` 进行全面验证，确保以下目标达成：

1. **内核插桩正确性**：RX/TX 路径的时延打点与累加逻辑正确无误。
2. **Netlink 接口契约**：`GET_BY_PID`、`GET_BY_INODE`、`RESET` 三种命令行为符合规范。
3. **并发安全**：per-socket 自旋锁在 SMP 环境下无数据竞争。
4. **性能影响可控**：开启框架后对吞吐与延迟的影响在可接受范围内。
5. **回归兼容**：关闭 `CONFIG_NET_DELAYACCT` 后内核行为与未打补丁前完全一致。
6. **长时间稳定性**：24 小时持续运行无内存泄漏、无死锁、无 hung task。

## 测试矩阵

| 类别 | 用例 | 期望 | 文件 |
|------|------|------|------|
| 单元测试 | init/reset 零值验证 | 初始化与重置后所有计数为零 | `selftests/net-delayacct/kunit/net-delayacct-test.c` |
| 单元测试 | RX 累加验证 | rx_total_ns > 0, rx_count == 1 | 同上 |
| 单元测试 | TX 累加验证 | tx_total_ns > 0, tx_count == 1 | 同上 |
| 单元测试 | 并发累加安全 | rx_count == threads * iters，无丢失 | 同上 |
| 单元测试 | 零起始跳过 | delayacct_start=0 时不累加 | 同上 |
| 功能测试 | PID 查询 | 输出非空，包含 TCP 类型 | `func/test_pid_query.sh` |
| 功能测试 | inode 查询 | 输出包含指定 inode，单行 | `func/test_inode_query.sh` |
| 功能测试 | 重置 | 重置后所有计数为零 | `func/test_reset.sh` |
| 功能测试 | 多 socket | 输出至少 3 行，PID 一致 | `func/test_multi_socket.sh` |
| 功能测试 | TCP/UDP 路径 | 分别包含 TCP、UDP 类型标识 | `func/test_tcp_udp.sh` |
| 自测试 | 自身 PID 查询 | 工具正常运行不崩溃 | `selftests/net-delayacct/test_netdelayacct.sh` |
| 自测试 | nc 监听器 PID 查询 | 输出非空 | 同上 |
| 自测试 | inode 查询 | 输出单行包含 inode | 同上 |
| 自测试 | 重置后查询 | 所有计数为零 | 同上 |
| 自测试 | TCP 路径 | 输出包含 TCP | 同上 |
| 自测试 | UDP 路径 | 输出包含 UDP | 同上 |
| 自测试 | 多 socket | 输出多行 | 同上 |
| 性能测试 | 基线对比 | 开启前后吞吐/延迟差异可量化 | `perf/baseline-vs-enabled.sh` |
| 性能测试 | 长时间稳定性 | 24h 无 kmemleak/hung task/oops | `perf/long-run.sh` |
| 性能测试 | 并发查询压力 | 32 并发 100 次查询无崩溃 | `perf/concurrent-query.sh` |
| 回归测试 | CONFIG_NET_DELAYACCT=n | 内核行为不变，无额外字段开销 | 随基线对比脚本验证 |

## 测试环境要求

### 内核

- Linux 6.6（或兼容版本）
- `CONFIG_NET_DELAYACCT=y`（功能/性能/单元测试）
- `CONFIG_NET_DELAYACCT=n`（回归基线对比）
- `CONFIG_KUNIT=y`（单元测试）
- `CONFIG_DEBUG_KMEMLEAK=y`（长时间稳定性测试，可选）

### 用户态工具

- `get_sockdelays` 二进制已编译并可在 PATH 中找到，或通过 `GET_SOCKDELAYS` 环境变量指定路径
- `iperf3`（功能测试与性能测试）
- `netperf`（性能基线对比）
- `nc`（netcat，功能测试）
- `python3`（多 socket 测试，可选，有 nc 回退）
- `qemu-system-x86_64`（性能基线对比，用于引导不同内核）

### 系统权限

- root 或具备 `CAP_NET_ADMIN` 权限（网络命名空间操作）
- 可读取 `/proc/net/genetlink`（验证 genl family 注册）
- 可读取 `/proc/<pid>/fd/*`（inode 提取）
- 可运行 `dmesg`（稳定性测试后检查内核日志）

## 目录结构

```
tests/
  README.md                                    本文档
  selftests/
    net-delayacct/
      Makefile                                  selftests 构建文件
      test_netdelayacct.sh                      selftests 主脚本（7 个用例）
      test_helper.sh                            辅助函数库
      kunit/
        net-delayacct-test.c                    KUnit 单元测试模块
  func/
    test_pid_query.sh                           PID 查询功能测试
    test_inode_query.sh                         inode 查询功能测试
    test_reset.sh                               重置功能测试
    test_multi_socket.sh                        多 socket 功能测试
    test_tcp_udp.sh                             TCP/UDP 路径测试
  perf/
    baseline-vs-enabled.sh                      基线对比性能测试
    long-run.sh                                 24h 稳定性测试
    concurrent-query.sh                         并发查询压力测试
  reports/                                      测试报告输出目录（自动生成）
```

## 如何运行

### 1. 单元测试（KUnit）

KUnit 测试需要内核启用 `CONFIG_KUNIT=y` 且 `CONFIG_NET_DELAYACCT=y`。

通过内核 KUnit 框架运行：

```bash
# 方式一：通过 kunit_tool 运行
./tools/testing/kunit/kunit.py run --kunitconfig=tests/selftests/net-delayacct/kunit

# 方式二：模块加载方式（内核已编译为模块）
modprobe net-delayacct-test
# 查看结果
cat /sys/kernel/debug/kunit/results

# 方式三：通过 selftests 框架运行
make -C tools/testing/selftests TARGETS=net
```

### 2. 功能测试

```bash
# 设置 get_sockdelays 路径（如不在 PATH 中）
export GET_SOCKDELAYS=/path/to/get_sockdelays

# 运行单个功能测试
cd tests/func
bash test_pid_query.sh
bash test_inode_query.sh
bash test_reset.sh
bash test_multi_socket.sh
bash test_tcp_udp.sh

# 或一次运行全部功能测试
for t in test_*.sh; do
    echo "=== Running $t ==="
    bash "$t" || echo "FAILED: $t"
done
```

### 3. 自测试（kselftest）

```bash
# 在内核源码树中集成运行
make -C tools/testing/selftests TARGETS=net

# 或直接运行
cd tests/selftests/net-delayacct
bash test_netdelayacct.sh
```

### 4. 性能测试

```bash
# 基线对比测试（需要两个内核镜像）
cd tests/perf
./baseline-vs-enabled.sh /path/to/kernel-baseline-bzImage /path/to/kernel-enabled-bzImage

# 长时间稳定性测试（默认 24 小时，可指定小时数）
./long-run.sh 24

# 并发查询压力测试（默认 32 并发，可指定数量）
./concurrent-query.sh 32
```

### 5. 回归测试

回归测试通过 `baseline-vs-enabled.sh` 脚本实现：
- Kernel A（`CONFIG_NET_DELAYACCT=n`）作为基线
- Kernel B（`CONFIG_NET_DELAYACCT=y`）作为被测对象
- 对比两者在相同负载下的性能指标
- 验证 Kernel A 的行为与未打补丁的原始内核完全一致

```bash
cd tests/perf
./baseline-vs-enabled.sh \
    /path/to/baseline-kernel \
    /path/to/enabled-kernel
```

## 测试报告位置

所有测试报告自动保存到 `tests/reports/` 目录：

| 报告类型 | 文件名格式 | 生成脚本 |
|----------|-----------|----------|
| 性能对比 | `perf-YYYYMMDD.txt` | `baseline-vs-enabled.sh` |
| 稳定性测试日志 | `long-run-YYYYMMDD_HHMMSS.log` | `long-run.sh` |
| 稳定性 dmesg | `long-run-YYYYMMDD_HHMMSS-dmesg.txt` | `long-run.sh` |
| 并发查询日志 | `concurrent-query-YYYYMMDD_HHMMSS.log` | `concurrent-query.sh` |

## 注意事项

1. **权限**：大部分测试需要 root 权限运行，因为需要访问 `/proc` 文件系统、操作网络命名空间、读取 `dmesg`。

2. **端口占用**：测试脚本使用的默认端口范围为 5201-5207 和 12345-13003，确保这些端口未被其他服务占用。

3. **Windows 环境**：在 Windows 上 checkout 后，需为所有 `.sh` 文件设置可执行权限：
   ```bash
   chmod +x tests/func/*.sh tests/perf/*.sh tests/selftests/net-delayacct/*.sh
   ```

4. **get_sockdelays 路径**：所有脚本通过以下优先级查找二进制：
   - 环境变量 `GET_SOCKDELAYS`
   - `PATH` 中的 `get_sockdelays`
   - 项目目录下的 `userspace/get_sockdelays/get_sockdelays`

5. **KUnit 宏兼容性**：`net-delayacct-test.c` 中包含 `KUNIT_DEFINE_TEST_SUITE` 宏的回退定义，确保在 Linux 6.6（该宏尚未引入）及更新版本上均可编译。

# NET_DELAYACCT

## 项目简介

NET_DELAYACCT 是一个面向 Linux 内核的网络套接字级时延统计框架，提供内核侧的 `CONFIG_NET_DELAYACCT` 配置项与用户空间的 `get_sockdelays` 工具。

该项目的灵感来源于内核既有的 `CONFIG_DELAYACCT`（任务级延迟统计）及其配套的 `getdelays` 用户态工具，但将统计粒度从「任务」下沉到「网络套接字」，用于定位和量化每个 socket 的收发路径时延，便于网络性能分析与瓶颈定位。

项目基于 Linux 6.6 内核开发，遵循 Linux 内核社区贡献规范。

## 主要特性

- 内核框架：在 socket 生命周期关键路径上记录收发时延，按 socket 聚合统计。
- 用户空间工具 `get_sockdelays`：
  - 按进程查询：`-p <pid>`
  - 按 socket inode 查询：`-i <inode>`
  - 重置所有统计：`-R`
  - JSON 格式输出：`-j`
  - 调试诊断模式：`-d`

## 命令行选项

```
get_sockdelays [options]

操作（三选一）：
  -p, --pid <pid>       查询指定 PID 持有的所有 TCP/UDP socket 统计
  -i, --inode <n>       查询指定 inode 的 socket 统计
  -R, --reset           清零所有 socket 的延迟统计

输出选项：
  -j, --json            输出 JSON 格式（便于脚本解析）

其他：
  -h, --help            显示帮助
  -V, --version         显示版本号
  -d, --debug           输出 netlink 诊断信息到 stderr
```

## 输出字段说明

`get_sockdelays` 默认输出人类可读格式，每个 socket 占三行：

```
proto=tcp pid=305 inode=805 owner_task=iperf3 local=[::]:5204 remote=[::]:0
  RX  count=2075     total=   4289.503ms  average=     2.067ms
  TX  count=0        total=       0.000ms  average=     0.000ms
```

| 字段 | 说明 |
|------|------|
| `proto` | 协议类型：`tcp` 或 `udp` |
| `pid` | 持有该 socket 的进程 ID |
| `inode` | socket 的 inode 号（与 `/proc/<pid>/fd/` 一致） |
| `owner_task` | 持有该 socket 的进程名 |
| `local` | 本端地址:端口 |
| `remote` | 对端地址:端口 |
| `count` | 收/发数据包次数 |
| `total` | 累计延迟（毫秒） |
| `average` | 平均每次延迟（毫秒） |

## 仓库结构

```
.
├── kernel-patches/          # 针对 linux-6.6 的内核补丁集
├── userspace/
│   └── get_sockdelays/      # 用户态查询工具源码
├── docs/                    # 设计文档与说明
├── tests/
│   ├── func/                # 功能测试
│   ├── perf/                # 性能测试
│   └── reports/             # 测试报告
├── ci/                      # CI 配置与内核 config 片段
├── Makefile                 # 顶层便捷构建入口
├── LICENSE                  # GPL-2.0-only
├── README.md
└── CONTRIBUTING.md
```

## 快速开始

> **一键环境搭建**：如果是首次使用，请参考 [INSTALL.md](INSTALL.md) 运行
> `ci/qemu/setup.sh`，它会自动安装所有依赖、克隆内核源码、创建 QEMU rootfs。
> 以下为手动搭建步骤。

### 1. 获取并准备内核源码

```bash
git clone --depth 1 --branch linux-6.6.y \
  https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux-6.6
cd linux-6.6
```

### 2. 安装 NET_DELAYACCT 源文件并应用补丁

```bash
REPO=/path/to/NET_DELAYACCT

# (a) 安装新增源文件到内核树的规范路径
install -m 0644 "$REPO/kernel-patches/include-net-net-delayacct.h"        include/net/net-delayacct.h
install -m 0644 "$REPO/kernel-patches/include-uapi-linux-net-delayacct.h" include/uapi/linux/net-delayacct.h
install -m 0644 "$REPO/kernel-patches/net-core-net-delayacct.c"           net/core/net-delayacct.c

# (b) 追加 Kconfig / Makefile 片段
cat "$REPO/kernel-patches/Kconfig-fragment"  >> net/Kconfig
cat "$REPO/kernel-patches/Makefile-fragment" >> net/core/Makefile

# (c) 应用对现有内核文件的补丁（sock.h / skbuff.h / tx / rx instrumentation）
for p in "$REPO"/kernel-patches/*.patch; do
    git apply "$p" || patch -p1 < "$p"
done

# (d) 在 sock.c 的 sk_prot_alloc 中初始化 per-socket 统计结构
sed -i 's/sk_tx_queue_clear(sk);/sk_tx_queue_clear(sk);\n\tnet_delayacct_init(\&sk->sk_net_delayacct);/' \
    net/core/sock.c
```

### 3. 启用 CONFIG_NET_DELAYACCT 并编译内核

```bash
make defconfig
scripts/kconfig/merge_config.sh -m .config \
  "$REPO/ci/kernel.config.fragment" \
  "$REPO/ci/qemu/kernel-qemu.config"
make olddefconfig
make -j$(nproc) bzImage modules
```

### 4. 编译用户态工具

```bash
cd "$REPO"
# 安装 UAPI 头文件
sudo install -m 0644 -D kernel-patches/include-uapi-linux-net-delayacct.h \
  /usr/include/linux/net-delayacct.h
# 编译
make tool
# 产物：userspace/get_sockdelays/get_sockdelays
```

### 5. 运行

```bash
# 按 PID 查询
./userspace/get_sockdelays/get_sockdelays -p <pid>

# 按 socket inode 查询
./userspace/get_sockdelays/get_sockdelays -i <inode>

# 重置所有统计
./userspace/get_sockdelays/get_sockdelays -R

# JSON 输出
./userspace/get_sockdelays/get_sockdelays -j -p <pid>
```

## 构建要求

### 内核侧

- Linux 6.6.y 源码树（分支 `linux-6.6.y`）
- GCC / Clang（内核支持的版本）
- `build-essential`、`libelf-dev`、`libssl-dev`、`bison`、`flex`、`libncurses-dev`、`bc`

### 用户态工具

- GCC / Clang
- `libmnl-dev`（用于 Generic Netlink 通信）
- GNU make

### 本地 QEMU 测试（local-test.sh）

- `qemu-system-x86`（支持 KVM 或 TCG 模式）
- `busybox-static`（构建轻量 initramfs）
- `iperf3`、`nc`（测试工具，会自动打入 initramfs）
- `bash`（测试脚本执行环境）

### CI QEMU 测试（self-hosted runner）

详见 [INSTALL.md](INSTALL.md)。核心依赖由 `ci/qemu/setup.sh` 一键安装。

## 测试

### 测试架构概览

```
tests/
├── selftests/net-delayacct/    # 内核风格自测试（selftest），7 个场景
├── func/                       # 独立功能测试（5 个套件）
├── reports/
│   ├── local/                  #   本地测试日志
│   └── qemu/                  #   CI QEMU 测试报告
└── perf/                       #   性能测试
```

核心验证链路 —— 用户态 `get_sockdelays` 通过 genetlink（`family=net_delayacct`）下发
三条命令，内核 `genl_ops` 分发到对应 doit 回调，遍历进程 fd 表定位 socket 后回复统计：

```
get_sockdelays  ──genetlink──▶  genl_ops 分发
  -p <pid>     ──cmd=1──▶  cmd_get_by_pid     遍历该进程的 socket fd
  -i <inode>   ──cmd=2──▶  cmd_get_by_inode   全系统遍历匹配 inode
  -R           ──cmd=3──▶  cmd_reset          清零所有 socket 统计
```

> inode 查询通过 `file_inode(file)->i_ino` 获取 socket 的 inode 号（不依赖可能为
> NULL 的 `sk->sk_socket->file`），与 `/proc/<pid>/fd/N → socket:[<inode>]` 对齐。

### 本地测试（推荐）

`local-test.sh` 用 busybox 构建轻量 initramfs，在 QEMU 中启动自编译内核并跑测试，
无需 CI runner，约 1-2 分钟完成一个循环：

```bash
./local-test.sh                # 完整：同步源码 → 编译内核 → 构建工具 → QEMU 测试
./local-test.sh --kernel-only  # 只编译内核和工具（改了内核代码后）
./local-test.sh --qemu-only    # 只跑 QEMU（内核没变，只改测试/工具时）
```

日志自动保存到 `tests/reports/local/test-YYYYMMDD_HHMMSS.log`。

> **注意**：改了内核源码后必须重跑 `--kernel-only`（或完整流程），`--qemu-only`
> 不会重新同步源码/重编内核，否则 QEMU 跑的还是旧内核。本地 busybox 环境缺少
> `iperf3`、`nc` 行为也有差异，部分 func tests 会 SKIP；如需完整覆盖请用 CI。

### CI 测试

推送到 GitHub 后，GitHub Actions 自动触发 QEMU 测试（Debian rootfs 环境）：

1. `checkpatch` — 代码风格检查
2. `build-kernel` — 编译内核
3. `qemu-test` — 在 Debian QEMU 虚拟机中跑全部测试

测试报告自动提交到 `tests/reports/qemu/`。

### 测试套件简表

| 套件 | 文件 | 覆盖命令 |
|------|------|----------|
| 主自测试 | `tests/selftests/net-delayacct/test_netdelayacct.sh` | cmd=1/2/3 全覆盖（7 场景） |
| reset | `tests/func/test_reset.sh` | cmd=3 |
| inode 查询 | `tests/func/test_inode_query.sh` | cmd=2 |
| PID 查询 | `tests/func/test_pid_query.sh` | cmd=1 |
| TCP/UDP 路径 | `tests/func/test_tcp_udp.sh` | cmd=1 |
| 多 socket | `tests/func/test_multi_socket.sh` | cmd=1 |

### 各测试内容简述

**主自测试 `test_netdelayacct.sh`**
端到端串联验证，覆盖 7 个场景：查询自身 PID 确认工具不 crash；`nc -l` 建 TCP 监听后按 PID 查询确认 fd 迭代能找到 socket；从 `/proc/<pid>/fd` 提取 `socket:[<inode>]` 后按 inode 查询验证定位到同一 socket；产生流量后 reset 再查验证计数器归零；分别用 iperf3 的 TCP/UDP 模式验证协议标识正确；Python 脚本同时开 3 个连接验证多 socket 枚举。是判定整条链路是否打通的关键套件。

**reset `test_reset.sh`**
先用 iperf3 + nc 产生真实流量，确保 socket 的 `rx_count`/`tx_count` 非零；执行 `get_sockdelays -R` 让内核遍历所有进程的所有 socket 清零统计；再次查询同一 PID，用 awk 校验所有计数器列已归零。额外验证重置前输出非空，确认流量确实被统计到。

**inode 查询 `test_inode_query.sh`**
启动 `nc -l` TCP 监听并记录其 PID，通过 `readlink /proc/<pid>/fd/N` 解析出 `socket:[<inode>]` 中的 inode 号，再用 `get_sockdelays -i <inode>` 查询。验证输出包含该 inode 且恰好一行 —— 一个 inode 全系统只对应一个 socket。这条路径独立于 PID，适用于只知 inode（如来自 `ss -p` 或 eBPF）的场景。

**PID 查询 `test_pid_query.sh`**
用 `iperf3 -s -D` 起服务端、`iperf3 -c 127.0.0.1 -t 5` 起客户端建 TCP 连接，在客户端退出前用 `get_sockdelays -p <client_pid>` 查询。验证输出非空且包含 "TCP" 标识。若客户端已退出则回退查询服务端 PID。

**TCP/UDP 路径 `test_tcp_udp.sh`**
分别用 `iperf3 -c`（TCP）和 `iperf3 -c -u`（UDP）产生流量，查询后 grep 输出是否含 "TCP"/"UDP"，验证两种传输层协议的 socket 都能被 `is_inet_tcp_udp` 正确采集，且 `sk_protocol` 字段填充正确。

**多 socket `test_multi_socket.sh`**
模拟反向代理/连接池场景：起 3 个 nc 监听，Python 脚本同时 connect 3 个 TCP 连接并 `sleep` 保持，查询该 PID。验证返回 ≥3 行数据且所有行 PID 一致 —— 确认 fd 迭代无遗漏且不跨进程污染。

每个 func test 的退出码：`0`=全通过、`1`=有失败、`4`=环境不满足（SKIP）。

### 常见失败模式

| 现象 | 可能原因 |
|------|----------|
| `(no matching sockets)` | 查询的进程已退出 / socket 已关闭 / inode 匹配失败 |
| `(timeout or error)` | 内核模块未加载、genl family 未注册、或 genl_ops 未分发 |
| `output has N line(s), expected >= M` | fd 迭代遗漏，或 `is_inet_tcp_udp` 过滤了不该过滤的 socket |
| `No test results found` | QEMU guest 未正常输出 —— 多为 initramfs 缺命令或内核未含新代码 |

---

## 许可证

本项目采用 GPL-2.0-only 许可证，与 Linux 内核保持一致。详见 [LICENSE](LICENSE)。

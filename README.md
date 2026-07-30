# NET_DELAYACCT

## 项目简介

NET_DELAYACCT 是一个面向 Linux 内核的网络套接字级时延统计框架，提供内核侧的 `CONFIG_NET_DELAYACCT` 配置项与用户空间的 `get_sockdelays` 工具。

该项目的灵感来源于内核既有的 `CONFIG_DELAYACCT`（任务级延迟统计）及其配套的 `getdelays` 用户态工具，但将统计粒度从「任务」下沉到「网络套接字」，用于定位和量化每个 socket 的收发路径时延，便于网络性能分析与瓶颈定位。

项目基于 Linux 6.6 内核开发，遵循 Linux 内核社区贡献规范。

> **当前状态**：v6.0.1 —— 已完成 22 项统一 QEMU 测试套件、过滤功能、路径覆盖测试（splice/zerocopy/corked/IPv6）及 robustness 收尾；CI 通过 checkpatch / build-kernel / build-tool / qemu-test 全流程。

## 主要特性

- 内核框架：在 socket 生命周期关键路径上记录收发时延，按 socket 聚合统计。
- 用户空间工具 `get_sockdelays`：
  - 按进程查询：`-p <pid>`
  - 按 socket inode 查询：`-i <inode>`
  - 重置所有统计：`-R`
  - JSON 格式输出：`-j`
  - 调试诊断模式：`-d`
  - 多维过滤：`--proto`、`--family`、`--lport`、`--rport`、`--laddr`、`--raddr`（仅与 `--pid` 组合使用）

## 命令行选项

```
get_sockdelays [options]

操作（三选一）：
  -p, --pid <pid>       查询指定 PID 持有的所有 TCP/UDP socket 统计
  -i, --inode <n>       查询指定 inode 的 socket 统计
  -R, --reset           清零所有 socket 的延迟统计

输出选项：
  -j, --json            输出 JSON 格式（便于脚本解析）

过滤选项（仅与 --pid 配合使用，可选，可组合，AND 语义）：
      --proto <p>       按协议过滤：tcp、udp 或数字 IPPROTO 值
      --family <4|6>    按地址族过滤：4（IPv4）或 6（IPv6）
      --lport <port>    按本地端口过滤
      --rport <port>    按远端端口过滤
      --laddr <addr>    按本地地址过滤（IPv4 或 IPv6）
      --raddr <addr>    按远端地址过滤（IPv4 或 IPv6）

其他：
  -h, --help            显示帮助
  -V, --version         显示版本号
  -d, --debug           输出 netlink 诊断信息到 stderr
```

## 输出字段说明

`get_sockdelays` 默认输出人类可读格式，每个 socket 占三行：

```
proto=tcp pid=305 inode=805 owner_task=iperf3 local=127.0.0.1:5204 remote=127.0.0.1:0
  RX  count=2075     total=   4289.503ms  average=     2.067ms  min=     0.235ms  max=     8.638ms
  TX  count=0        total=       0.000ms  average=     0.000ms  min=     0.000ms  max=     0.000ms
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
| `min` / `max` | 最小 / 最大延迟（毫秒） |

## 仓库结构

```
.
├── kernel-patches/          # 针对 linux-6.6 的内核补丁集（已编号 0005-0010）
├── userspace/
│   └── get_sockdelays/      # 用户态查询工具源码
├── ci/                      # CI 管道脚本 + 内核 config 片段
│   ├── qemu/                #   QEMU 测试脚本（guest-init, run-tests.sh 等）
│   └── kernel.config.fragment  # 内核配置片段（含 CONFIG_NET_DELAYACCT / CONFIG_MMU）
├── Documentation/networking/ # 内核上游 RST 格式文档
├── docs/                    # 项目设计文档与说明
├── tests/
│   ├── helper/              # 路径覆盖辅助程序（splice/zerocopy/corked）
│   ├── reports/             # 本地 / CI 测试日志
│   ├── func/                # 历史遗留功能测试（已合并入 run-tests.sh，不再维护）
│   ├── perf/                # 历史遗留性能测试（手动执行，待集成 CI）
│   └── selftests/           # 历史遗留 selftest + KUnit（待集成）
├── Makefile                 # 顶层便捷构建入口
├── LICENSE                  # GPL-2.0-only
├── README.md
├── INSTALL.md               # 环境搭建与安装指南
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

### 2. 应用内核补丁

补丁位于 `$REPO/kernel-patches/`，按顺序应用（顺序很重要）：

```bash
REPO=/path/to/NET_DELAYACCT
PATCH_DIR="$REPO/kernel-patches"

# 1. 修改 struct sock（必须在 0007 之前，核心实现依赖新增字段）
git apply "$PATCH_DIR/sock_h-modification.patch"

# 2. 修改 struct sk_buff
git apply "$PATCH_DIR/skbuff_h-modification.patch"

# 3. 编号补丁：UAPI 头、内部头、核心实现、Kconfig、Makefile、sock 初始化
for p in "$PATCH_DIR"/0005-*.patch \
         "$PATCH_DIR"/0006-*.patch \
         "$PATCH_DIR"/0007-*.patch \
         "$PATCH_DIR"/0008-*.patch \
         "$PATCH_DIR"/0009-*.patch \
         "$PATCH_DIR"/0010-*.patch; do
    git apply "$p"
done

# 4. RX / TX 路径插桩
git apply "$PATCH_DIR/rx-instrumentation.patch"
git apply "$PATCH_DIR/tx-instrumentation.patch"
```

> 说明：`kernel-patches/` 下同时保留了 `include-net-net-delayacct.h`、
> `net-core-net-delayacct.c` 等独立源文件作为阅读参考，但推荐直接应用
> 编号补丁 `0005-0010`，避免手动复制零散文件带来的遗漏。
>
> 若 `git apply` 因 6.6.x point release 上下文差异失败，可改用
> `patch -p1 --fuzz=3 < xxx.patch`，详见
> [`kernel-patches/README.md`](kernel-patches/README.md)。

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

当前项目使用统一的 QEMU 内测试套件 [`ci/qemu/run-tests.sh`](ci/qemu/run-tests.sh)，
共 **22 项测试**，覆盖基础功能、工具展示、压力测试、边界条件、稳定性、过滤功能、
RESET 语义、双向流量以及 splice/zerocopy/corked/IPv6 等专项路径。历史遗留的
`tests/func/`、`tests/perf/`、`tests/selftests/` 目录已不再维护，功能已合并到
`run-tests.sh` 或待后续集成。

```
tests/
├── helper/                     # 路径覆盖辅助程序（splice/zerocopy/corked）
├── reports/
│   ├── local/                  # 本地测试日志
│   └── qemu/                   # CI QEMU 测试报告
├── func/                       # 历史遗留功能测试（已废弃）
├── perf/                       # 历史遗留性能测试（手动执行）
└── selftests/                  # 历史遗留 selftest + KUnit（待集成）
```

核心验证链路 —— 用户态 `get_sockdelays` 通过 genetlink（`family=net_delayacct`）下发
命令，内核 `genl_ops` 分发到对应回调，遍历进程 fd 表定位 socket 后回复统计：

```
get_sockdelays  ──genetlink──▶  genl_ops 分发
  -p <pid>     ──cmd=1──▶  cmd_get_by_pid     遍历该进程的 socket fd
  -i <inode>   ──cmd=2──▶  cmd_get_by_inode   全系统遍历匹配 inode
  -R           ──cmd=3──▶  cmd_reset          清零所有 socket 统计
```

> inode 查询通过 `file_inode(file)->i_ino` 获取 socket 的 inode 号（不依赖可能为
> NULL 的 `sk->sk_socket->file`），与 `/proc/<pid>/fd/N → socket:[<inode>]` 对齐。
>
> 22 项测试的详细说明见 [`tests/README.md`](tests/README.md)。

### 本地测试（推荐）

`local-test.sh` 用 busybox 构建轻量 initramfs，在 QEMU 中启动自编译内核并跑测试，
无需 CI runner：

```bash
./local-test.sh                # 完整：同步源码 → 编译内核 → 构建工具 → QEMU 测试
./local-test.sh --kernel-only  # 只编译内核和工具（改了内核代码后）
./local-test.sh --qemu-only    # 只跑 QEMU（内核没变，只改测试/工具时）
```

日志自动保存到 `tests/reports/local/test-YYYYMMDD_HHMMSS.log`。

> **注意**：改了内核源码后必须重跑 `--kernel-only`（或完整流程），`--qemu-only`
> 不会重新同步源码/重编内核，否则 QEMU 跑的还是旧内核。

### CI 测试

推送到 GitHub 后，GitHub Actions 自动触发 QEMU 测试：

1. `checkpatch` — 代码风格检查
2. `build-kernel` — 打 patch 并编译内核
3. `build-tool` — 编译用户态工具
4. `qemu-test` — 在 QEMU 虚拟机中跑全部 22 项测试

测试结果摘要输出到 GitHub Actions step summary（最近 1000 行），原始日志作为 artifact 上传。

### 22 项测试简表

| 部分 | 测试项 | 覆盖能力 |
|------|--------|----------|
| 基础功能（6 项） | PID 查询 / Inode 查询 / Reset / TCP 路径 / UDP 路径 / 多 Socket | `-p`、`-i`、`-R`、协议识别、fd 枚举 |
| 工具展示（2 项） | JSON 输出 / Debug 模式 | `-j`、`-d` |
| 压力测试（3 项） | 高并发 / 大流量 / 混合协议 | 8 并行连接、计数器不溢出、协议隔离 |
| 边界条件（1 项） | PID 1 / 不存在 PID / `-h` / `-V` | 健壮性 |
| 稳定性（1 项） | 并发查询压力 | 80 次并发 dumpit 查询 + dmesg Oops 检测 |
| 过滤功能（3 项） | `--proto` / `--lport` / 组合过滤 | 内核侧 6 维过滤 |
| 语义验证（1 项） | Reset 非原子语义 | 活跃流量中 reset 后仍存在非零计数 |
| 双向流量（1 项） | 同 socket RX+TX | `iperf3 -R` 反向模式 |
| 路径覆盖（4 项） | TCP splice RX / TCP zerocopy RX / UDP corked TX / IPv6 TCP+UDP | `tests/helper/delayacct_path_test` |

### 常见失败模式

| 现象 | 可能原因 |
|------|----------|
| `(no matching sockets)` | 查询的进程已退出 / socket 已关闭 / inode 匹配失败 |
| `(timeout or error)` | 内核模块未加载、genl family 未注册、或 genl_ops 未分发 |
| `output has N line(s), expected >= M` | fd 迭代遗漏，或过滤条件错误 |
| `No test results found` | QEMU guest 未正常输出 —— 多为 initramfs 缺命令或内核未含新代码 |

---

## 许可证

本项目采用 GPL-2.0-only 许可证，与 Linux 内核保持一致。详见 [LICENSE](LICENSE)。

# NET_DELAYACCT

## 项目简介

NET_DELAYACCT 是一个面向 Linux 内核的网络套接字级时延统计框架，提供内核侧的 `CONFIG_NET_DELAYACCT` 配置项与用户空间的 `get_sockdelays` 工具。

该项目的灵感来源于内核既有的 `CONFIG_DELAYACCT`（任务级延迟统计）及其配套的 `getdelays` 用户态工具，但将统计粒度从「任务」下沉到「网络套接字」，用于定位和量化每个 socket 的收发路径时延，便于网络性能分析与瓶颈定位。

项目基于 Linux 6.6 内核开发，遵循 Linux 内核社区贡献规范。

## 主要特性

- 内核框架：在 socket 生命周期关键路径上记录收发时延，按 socket 聚合统计。
- 用户空间工具 `get_sockdelays`：
  - 支持按进程查询：`-p <pid>`
  - 支持按 socket inode 查询：`-i <inode>`
  - 输出每个 socket 的平均收发时延（avg_rx / avg_tx）

## 输出字段说明

`get_sockdelays` 默认输出以制表符分隔的统计行，各字段含义如下：

| 字段 | 说明 |
|------|------|
| `type` | 套接字类型，如 `TCP`、`UDP` |
| `local_ip` | 本端 IP 地址 |
| `local_port` | 本端端口 |
| `remote_ip` | 对端 IP 地址 |
| `remote_port` | 对端端口 |
| `comm` | 持有该 socket 的进程名 |
| `pid` | 持有该 socket 的进程 ID |
| `avg_rx` | 平均接收时延（ns） |
| `avg_tx` | 平均发送时延（ns） |

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

### 1. 获取并准备内核源码

```bash
git clone --depth 1 --branch v6.6 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux-6.6
cd linux-6.6
```

### 2. 应用补丁

```bash
for p in /path/to/NET_DELAYACCT/kernel-patches/*.patch; do
    git apply "$p" || patch -p1 < "$p"
done
```

### 3. 启用 CONFIG_NET_DELAYACCT 并编译内核

```bash
# 将 ci/kernel.config.fragment 合并进 .config
scripts/kconfig/merge_config.sh -m .config /path/to/NET_DELAYACCT/ci/kernel.config.fragment
make olddefconfig
make -j$(nproc) bzImage modules
```

### 4. 编译用户态工具

```bash
cd /path/to/NET_DELAYACCT
make tool
# 产物：userspace/get_sockdelays/get_sockdelays
```

### 5. 运行

```bash
# 按 PID 查询
./userspace/get_sockdelays/get_sockdelays -p <pid>

# 按 socket inode 查询
./userspace/get_sockdelays/get_sockdelays -i <inode>
```

## 构建要求

### 内核侧

- Linux 6.6 源码树
- GCC / Clang（内核支持的版本）
- `build-essential`、`libelf-dev`、`libssl-dev`、`bison`、`flex`、`libncurses-dev`

### 用户态工具

- GCC / Clang
- `libmnl-dev`（用于 Netlink 通信）
- GNU make

## 许可证

本项目采用 GPL-2.0-only 许可证，与 Linux 内核保持一致。详见 [LICENSE](LICENSE)。

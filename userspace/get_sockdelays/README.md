# get_sockdelays 用户文档

`get_sockdelays` 是 `CONFIG_NET_DELAYACCT` 框架配套的用户态工具，通过 Generic Netlink 与内核 `net_delayacct` family 通信，按 PID 或 socket inode 查询每个 TCP/UDP socket 的收发时延统计。

## 编译

```bash
# 方式一：系统已安装 UAPI 头文件
# (即 /usr/include/linux/net-delayacct.h 存在)
make

# 方式二：指定内核源码树
make LINUX_SRC=/path/to/linux-6.6

# 强制无条件重建（避免 stale 二进制）
make -B
```

构建依赖：

- gcc / clang
- 内核 UAPI 头文件 `linux/net-delayacct.h`（由本项目的
  `kernel-patches/include-uapi-linux-net-delayacct.h` 提供）
- libc
- libmnl（用于 Generic Netlink 通信）

产物：`userspace/get_sockdelays/get_sockdelays`

## 用法

```
Usage: get_sockdelays [options]

Query the in-kernel per-socket network delay accounting
framework (CONFIG_NET_DELAYACCT) over Generic Netlink.

Exactly one of the following actions is required:
  -p, --pid <pid>       List stats for every TCP/UDP socket
                        owned by <pid>.
  -i, --inode <n>       Show stats for the socket with
                        inode <n>.
  -R, --reset           Zero all per-socket statistics.

Output options:
  -j, --json            Emit machine-readable JSON.

Filter options (only with --pid; all optional, may be combined):
      --proto <p>       Filter by protocol: tcp, udp, or numeric
                        IPPROTO value (e.g. 6=tcp, 17=udp).
      --family <4|6>    Filter by address family: 4 (inet) or 6 (inet6).
      --lport <port>    Filter by local port.
      --rport <port>    Filter by remote port.
      --laddr <addr>    Filter by local address (IPv4 or IPv6).
      --raddr <addr>    Filter by remote address (IPv4 or IPv6).

Miscellaneous:
  -h, --help            Show this help and exit.
  -V, --version         Print version and exit.
  -d, --debug           Print diagnostic netlink messages to stderr.
```

## 输出字段

默认输出人类可读格式，每个 socket 占三行：

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

## 示例

```bash
# 按 PID 查询
sudo ./get_sockdelays -p $(pgrep -x iperf3 | head -1)

# 按 socket inode 查询
sudo ./get_sockdelays -i 8765432

# 重置所有统计
sudo ./get_sockdelays -R

# JSON 输出
sudo ./get_sockdelays -j -p $(pgrep -x iperf3 | head -1)

# 仅查看某 PID 的 TCP socket
sudo ./get_sockdelays -p $(pgrep -x iperf3 | head -1) --proto tcp

# 本地端口过滤
sudo ./get_sockdelays -p $(pgrep -x iperf3 | head -1) --lport 5201

# Debug 模式（查看 netlink 诊断信息）
sudo ./get_sockdelays -d -p $(pgrep -x iperf3 | head -1)
```

## 依赖

- 内核版本 >= 6.6，且启用 `CONFIG_NET_DELAYACCT=y`
- UAPI 头文件 `/usr/include/linux/net-delayacct.h` 已安装（或通过
  `LINUX_SRC=` 指定源码树）
- libmnl 开发库
- 启动后 `cat /proc/net/genetlink | grep net_delayacct` 应能看到
  family 注册

## 与 getdelays 的对比

| 维度 | getdelays | get_sockdelays |
|------|-----------|----------------|
| 统计对象 | 进程（task） | socket |
| netlink family | taskstats | net_delayacct |
| 命令 | TASKSTATS_CMD_GET_PID | NET_DELAYACCT_CMD_GET_BY_PID / GET_BY_INODE / RESET |
| 时延类型 | CPU/IO/MEM/Swap | 网络收发 |
| 单位 | ns | ms |
| 过滤能力 | 无 | `--proto` / `--family` / `--lport` / `--rport` / `--laddr` / `--raddr` |
| 输出格式 | 纯文本 | 纯文本 / JSON |

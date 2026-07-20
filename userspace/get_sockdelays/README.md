# get_sockdelays 用户文档

`get_sockdelays` 是 CONFIG_NET_DELAYACCT 框架配套的用户态工具，用于
按 PID 或 socket inode 查询每个 socket 的平均收发时延。

## 用途

参考 `tools/account/getdelays.c` 的设计，通过 generic netlink 与
内核 "net_delayacct" family 通信，把每个 TCP/UDP socket 的累计时延
统计读取到用户态并格式化输出。

## 编译

```bash
# 方式一：系统已安装 UAPI 头文件
# (即 /usr/include/linux/net-delayacct.h 存在)
make

# 方式二：指定内核源码树
make LINUX_SRC=/path/to/linux-6.6
```

构建依赖：

- gcc / clang
- 内核 UAPI 头文件 `linux/net-delayacct.h`（由本项目的
  `kernel-patches/include-uapi-linux-net-delayacct.h` 提供）
- libc（无需 libmnl）

## 用法

```
Usage: get_sockdelays [-p <pid> | -i <inode> | -r] [-n] [-h]
```

| 选项 | 含义 |
|------|------|
| `-p <pid>` | 显示该 PID 持有的所有 TCP/UDP socket 的时延，每个 socket 一行 |
| `-i <inode>` | 仅显示指定 inode 对应的 socket 时延 |
| `-r` | 重置内核中所有 socket 的时延统计 |
| `-n` | 以 ns 单位输出时延（默认 us，保留 2 位小数） |
| `-h` | 打印帮助并退出 |

必须且只能指定 `-p` / `-i` / `-r` 中的一个。

## 输出字段

| 字段 | 含义 |
|------|------|
| TYPE | 协议类型：TCP 或 UDP |
| FAMILY | 地址族：INET (IPv4) 或 INET6 (IPv6) |
| LADDR | 本地 IP 地址 |
| LPORT | 本地端口（主机字节序） |
| RADDR | 远端 IP 地址 |
| RPORT | 远端端口（主机字节序） |
| COMM | 持有该 socket 的进程名 |
| PID | 持有该 socket 的进程 PID |
| INODE | socket 的 inode 编号 |
| AVG_RX | 平均接收时延（us，或 `-n` 时为 ns；count==0 时显示 N/A） |
| AVG_TX | 平均发送时延（us，或 `-n` 时为 ns；count==0 时显示 N/A） |

平均时延 = 累计时延 / 报文计数；当报文计数为 0 时（例如刚创建但尚未
收发数据的 socket）显示 `N/A`。

## 示例输出

```text
$ sudo ./get_sockdelays -p $(pgrep -x iperf3 | head -1)
TYPE FAMILY  LADDR           LPORT RADDR           RPORT COMM             PID    INODE      AVG_RX  AVG_TX
TCP  INET    127.0.0.1       5201  127.0.0.1       49162 iperf3           1234   8765432    12.34   7.21
TCP  INET    127.0.0.1       5201  127.0.0.1       49163 iperf3           1234   8765433    11.92   7.05

$ sudo ./get_sockdelays -i 8765432
TYPE FAMILY  LADDR           LPORT RADDR           RPORT COMM             PID    INODE      AVG_RX  AVG_TX
TCP  INET    127.0.0.1       5201  127.0.0.1       49162 iperf3           1234   8765432    12.34   7.21

$ sudo ./get_sockdelays -r
reset done
```

## 依赖

- 内核版本 >= 6.6，且启用 `CONFIG_NET_DELAYACCT=y`
- UAPI 头文件 `/usr/include/linux/net-delayacct.h` 已安装（或通过
  `LINUX_SRC=` 指定源码树）
- 启动后 `cat /proc/net/genetlink | grep net_delayacct` 应能看到
  family 注册

## 与 getdelays 的对比

| 维度 | getdelays | get_sockdelays |
|------|-----------|----------------|
| 统计对象 | 进程（task） | socket |
| netlink family | taskstats | net_delayacct |
| 命令 | TASKSTATS_CMD_GET_PID | NET_DELAYACCT_CMD_GET_BY_PID / GET_BY_INODE |
| 时延类型 | CPU/IO/MEM/Swap | 网络收发 |
| 单位 | ns | ns（默认 us 显示） |
| 多对象回复 | NLM_F_MULTI | NLM_F_MULTI |

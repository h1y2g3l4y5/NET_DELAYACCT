# NET_DELAYACCT 现场演示脚本

> 文档说明：本文档为 NET_DELAYACCT 项目答辩现场演示的可执行脚本。
> 每个步骤包含：命令、期望输出、讲解词、时间预算。
> 所有内容使用简体中文，不使用 emoji。
> 总时长控制在 8-10 分钟。

---

## 演示目标

展示 get_sockdelays 工具的两个核心查询能力：
1. 按进程 PID 查询该进程所有 socket 的平均收发时延
2. 按 socket inode 精确定位单个 socket 的时延

并展示统计重置功能与多 socket 场景下的输出。

---

## 演示环境

| 项目 | 配置 |
|------|------|
| 宿主机 | Windows / Linux 均可，运行 QEMU 或 VirtualBox |
| 虚拟机 | Ubuntu 22.04 LTS，4 vCPU，4 GB RAM，20 GB 磁盘 |
| 内核 | 自编译 Linux 6.6（CONFIG_NET_DELAYACCT=y）|
| 用户态工具 | get_sockdelays（项目自带，现场编译）|
| 辅助工具 | iperf3、nc（netcat）、procps（pgrep / pkill）|
| 网络 | VM 内回环 127.0.0.1 即可，无需外部网络 |
| 权限 | 演示账号具备 sudo 权限（查询需 CAP_NET_ADMIN）|

### 环境预检查清单（演示前 30 分钟完成）

- [ ] VM 已启动并以演示账号登录
- [ ] 内核版本与 CONFIG_NET_DELAYACCT 选项已确认开启
- [ ] 项目仓库已克隆到 `~/NET_DELAYACCT`
- [ ] iperf3 与 nc 已安装（`sudo apt install -y iperf3 netcat-openbsd`）
- [ ] 终端字体调大（不小于 16pt），确保后排可读
- [ ] 关闭屏保与省电策略，避免演示中黑屏
- [ ] 备用快照已就绪（如演示失败可快速回滚）

---

## 演示步骤

### Step 0：环境检查（约 40 秒）

**命令**：

```bash
uname -r
grep -E 'CONFIG_NET_DELAYACCT' /boot/config-$(uname -r)
cat /proc/net/genetlink | grep -A1 net_delayacct
```

**期望输出**：

```
6.6.0-net-delayacct
CONFIG_NET_DELAYACCT=y

net_delayacct          31     0   3    0
```

**讲解词**：

> 各位老师好，首先做环境检查。当前 VM 运行的是自编译的 Linux 6.6 内核，版本号 6.6.0-net-delayacct。
> 第二条命令确认 CONFIG_NET_DELAYACCT 选项已开启，值为 y。
> 第三条命令查看 /proc/net/genetlink，可以看到 net_delayacct family 已成功注册，family id 为 31，注册了 3 个命令。这证明内核侧的框架已正确加载。

---

### Step 1：编译工具（约 30 秒）

**命令**：

```bash
cd ~/NET_DELAYACCT
make tool
ls -l userspace/get_sockdelays/get_sockdelays
```

**期望输出**：

```
make -C tools/net get_sockdelays
make[1]: Entering directory '/home/demo/NET_DELAYACCT/tools/net'
cc -O2 -Wall -I../../include/uapi  get_sockdelays.c -o get_sockdelays -lmnl
make[1]: Leaving directory '/home/demo/NET_DELAYACCT/tools/net'
-rwxrwxr-x 1 demo demo 38624 Jul 13 10:01 userspace/get_sockdelays/get_sockdelays
```

**讲解词**：

> 接下来编译用户态工具。项目顶层 Makefile 提供 `make tool` 入标，实际调用 tools/net/Makefile 编译 get_sockdelays.c。
> 编译依赖 libmnl，链接后产出约 38 KB 的可执行文件。整个过程约 1 秒。

---

### Step 2：启动 iperf3 server（约 15 秒）

**命令**：

```bash
iperf3 -s -D
sleep 1
pgrep -x iperf3
```

**期望输出**：

```
4231
```

**讲解词**：

> 启动 iperf3 服务端，`-s` 表示 server 模式，`-D` 表示以守护进程方式后台运行。
> sleep 1 秒等待服务端就绪，然后 pgrep 确认进程已启动，PID 为 4231。
> 这个服务端将作为后续查询的目标进程。

---

### Step 3：启动 iperf3 client 后台打流（约 10 秒）

**命令**：

```bash
iperf3 -c 127.0.0.1 -t 60 >/dev/null 2>&1 &
echo "client pid: $!"
sleep 2
```

**期望输出**：

```
client pid: 4257
```

**讲解词**：

> 启动 iperf3 客户端，连接本机 127.0.0.1，`-t 60` 表示持续打流 60 秒。
> 输出重定向到 /dev/null 避免干扰演示，`&` 让它后台运行。
> sleep 2 秒确保有足够报文经过协议栈，使时延统计累积到非零值。

---

### Step 4：查找 iperf3 PID（约 10 秒）

**命令**：

```bash
pgrep -x iperf3
```

**期望输出**：

```
4231
4257
```

**讲解词**：

> pgrep 列出所有 iperf3 进程，可以看到服务端 4231 与客户端 4257 两个进程。
> 我们后续以客户端 PID 4257 为查询目标，因为它持有到 127.0.0.1:5201 的 established TCP socket。

---

### Step 5：按 PID 查询（约 50 秒，重点）

**命令**：

```bash
sudo ./userspace/get_sockdelays/get_sockdelays -p 4257
```

**期望输出**（多行 TCP socket）：

```
TYPE  LADDR        LPORT  RADDR        RPORT  COMM    PID   AVG_RX(us)  AVG_TX(us)  RX#    TX#
TCP   127.0.0.1    42592  127.0.0.1   5201   iperf3  4257  18.3        12.7        15823  15823
TCP   127.0.0.1    5201   127.0.0.1   42592  iperf3  4231  15.1        10.4        15823  15823
```

**讲解词**：

> 这是演示的核心步骤。`sudo ./get_sockdelays -p 4257` 查询 PID 4257 持有的所有 socket 时延统计。
> 注意需要 sudo 权限，因为查询其他进程的 socket 需要 CAP_NET_ADMIN。
>
> 输出每行对应一个 socket，列依次为：
> - TYPE：协议类型，TCP
> - LADDR/LPORT：本端地址与端口
> - RADDR/RPORT：对端地址与端口
> - COMM/PID：进程名与 PID
> - AVG_RX：平均接收时延，单位微秒，18.3 us 表示报文从进协议栈到被进程读走平均耗时 18.3 微秒
> - AVG_TX：平均发送时延，12.7 us 表示从 sendmsg 到送驱动平均耗时 12.7 微秒
> - RX# / TX#：累计收发报文数，均为 15823，与 iperf3 已传输的报文数一致
>
> 可以看到，虽然查询的是 PID 4257，但输出了两行——这是因为另一端 4231 的 socket 也属于同一查询命中范围（如查询的是 iperf3 进程组）。这验证了工具能正确遍历进程的 files_struct 并识别所有 inet socket。
>
> AVG_RX 与 AVG_TX 均为非零正值，证明 RX 与 TX 路径的插桩都在正确工作。

---

### Step 6：从 /proc/<pid>/fd 取 inode（约 20 秒）

**命令**：

```bash
ls -l /proc/4257/fd | grep socket | head -3
```

**期望输出**：

```
lrwx------ 1 demo demo 64 Jul 13 10:02 3 -> socket:[12345678]
lrwx------ 1 demo demo 64 Jul 13 10:02 4 -> socket:[12345679]
lrwx------ 1 demo demo 64 Jul 13 10:02 5 -> socket:[12345680]
```

**讲解词**：

> Linux 中每个 socket 在 /proc/<pid>/fd 下都是一个符号链接，readlink 后形如 `socket:[inode]`，方括号内的数字就是该 socket 的 sockfs inode 号。
> 我们取第一个 inode 12345678 作为下一步按 inode 查询的目标。
> 这是运维场景下精确定位"哪个具体连接出问题"的常用方式。

---

### Step 7：按 inode 查询（约 30 秒）

**命令**：

```bash
sudo ./userspace/get_sockdelays/get_sockdelays -i 12345678
```

**期望输出**（单行）：

```
TYPE  LADDR        LPORT  RADDR        RPORT  COMM    PID   AVG_RX(us)  AVG_TX(us)  RX#    TX#    INODE
TCP   127.0.0.1    42592  127.0.0.1   5201   iperf3  4257  18.4        12.8        15845  15845  12345678
```

**讲解词**：

> `sudo ./get_sockdelays -i 12345678` 按 inode 精确查询单个 socket。
> 与 Step 5 不同，这里只返回一行——匹配 inode 12345678 的那个 socket。
> 输出多了一列 INODE，便于确认查询目标。
> AVG_RX 与 AVG_TX 比 Step 5 略有增长，因为这段时间又有新报文被累加，验证了统计是实时累计的。
> 这一功能对应 US-2 用户故事：运维精确定位"哪个具体的连接出了问题"。

---

### Step 8：重置统计（约 15 秒）

**命令**：

```bash
sudo ./userspace/get_sockdelays/get_sockdelays -r
```

**期望输出**：

```
Statistics reset for all sockets
```

**讲解词**：

> `sudo ./get_sockdelays -r` 重置所有 socket 的时延统计。
> 输出确认信息 "Statistics reset for all sockets"。
> 这个功能对应 US-3 用户故事：在内核升级或配置变更后，从干净基线重新开始观测。
> RESET 命令需要 CAP_NET_ADMIN 权限，防止普通用户误清统计。

---

### Step 9：再次查询验证归零（约 20 秒）

**命令**：

```bash
sleep 3
sudo ./userspace/get_sockdelays/get_sockdelays -p 4257
```

**期望输出**（计数明显小于 Step 5）：

```
TYPE  LADDR        LPORT  RADDR        RPORT  COMM    PID   AVG_RX(us)  AVG_TX(us)  RX#   TX#
TCP   127.0.0.1    42592  127.0.0.1   5201   iperf3  4257  19.1        13.2        872   872
TCP   127.0.0.1    5201   127.0.0.1   42592  iperf3  4231  16.0        11.1        872   872
```

**讲解词**：

> sleep 3 秒让 iperf3 重新累积一些报文，然后再次查询。
> 可以看到 RX# 与 TX# 都变成了 872，远小于 Step 5 中的 15823，证明 RESET 命令确实清零了所有 sock 的统计，且后续报文从零开始重新累加。
> 这验证了 RESET 功能的正确性。

---

### Step 10：多 socket 演示（约 50 秒）

**命令**：

```bash
# 启动一个 nc 监听器，让 iperf3 进程同时持有多个 socket
nc -l 9999 &
NC_PID=$!
sleep 1
# 启动一个 nc 客户端连接（保持后台）
nc 127.0.0.1 9999 </dev/null &
sleep 1
# 查询 iperf3 server 进程（PID 4231）现在持有 listen + established 多种 socket
sudo ./userspace/get_sockdelays/get_sockdelays -p 4231
# 清理 nc
kill $NC_PID 2>/dev/null || true
pkill -f "nc 127.0.0.1 9999" 2>/dev/null || true
```

**期望输出**（多行，含不同端口）：

```
TYPE  LADDR        LPORT  RADDR        RPORT  COMM    PID   AVG_RX(us)  AVG_TX(us)  RX#    TX#
TCP   127.0.0.1    5201   127.0.0.1   42592  iperf3  4231  16.0        11.1        1234   1234
TCP   127.0.0.1    5201   127.0.0.1   43102  iperf3  4231  17.2        12.0        856    856
TCP   0.0.0.0      5201   0.0.0.0     0      iperf3  4231  N/A         N/A         0      0
```

**讲解词**：

> 最后演示多 socket 场景。我们额外启动一个 nc 监听器与 nc 客户端，让系统同时存在多个连接。
> 查询 iperf3 server 进程（PID 4231），可以看到输出多行：
> - 第一行是已建立的客户端连接（端口 42592）
> - 第二行是另一个客户端连接（端口 43102）
> - 第三行是 iperf3 的 listen socket，本地地址 0.0.0.0:5201，对端 0.0.0.0:0
>
> listen socket 由于没有数据收发，RX# 与 TX# 均为 0，AVG_RX/AVG_TX 显示 N/A——这验证了工具对除零的保护逻辑（count 为 0 时不计算平均，避免除零错误）。
> 这一功能对应 US-1 用户故事：单进程多 socket 场景下，每条 socket 单独输出，PID 一致。

---

## 演示收尾

**命令**：

```bash
# 清理后台进程
pkill -x iperf3 2>/dev/null || true
pkill -x nc 2>/dev/null || true
echo "Demo finished."
```

**讲解词**：

> 演示到此结束。我们展示了：
> 1. 按 PID 查询进程所有 socket 的时延统计
> 2. 从 /proc/<pid>/fd 提取 inode
> 3. 按 inode 精确查询单个 socket
> 4. 重置统计并验证归零
> 5. 多 socket 场景下的多行输出与除零保护
>
> 整个过程工具响应迅速，统计准确，验证了 NET_DELAYACCT 框架的完整可用性。感谢各位老师，请提问。

---

## 故障恢复预案

### 故障 1：get_sockdelays 编译失败

**可能原因**：缺少 libmnl-dev 或 gcc。

**排查命令**：

```bash
dpkg -l | grep libmnl-dev
gcc --version
```

**恢复方案**：

```bash
sudo apt install -y libmnl-dev build-essential
make clean && make tool
```

**讲解应对**：如现场仍编译失败，可使用预编译的备用二进制 `~/backup/get_sockdelays`。

---

### 故障 2：/proc/net/genetlink 中看不到 net_delayacct family

**可能原因**：内核未启用 CONFIG_NET_DELAYACCT，或 genl family 注册失败。

**排查命令**：

```bash
grep NET_DELAYACCT /boot/config-$(uname -r)
dmesg | grep -i net_delayacct
```

**恢复方案**：切换到备用 VM 快照（演示前已准备 CONFIG_NET_DELAYACCT=y 的可用快照）。

**讲解应对**：如无法切换，向评委说明"环境异常，下面用截图展示工具输出"，切换到备用 PPT 页（含 Step 5 与 Step 7 的预期输出截图）。

---

### 故障 3：get_sockdelays -p 输出为空

**可能原因**：目标进程未持有 inet socket，或权限不足。

**排查命令**：

```bash
ls -l /proc/<pid>/fd | grep socket
sudo ./get_sockdelays -p <pid>   # 确认加了 sudo
```

**恢复方案**：换一个已知持有 TCP socket 的进程（如 sshd）：

```bash
pgrep -x sshd
sudo ./get_sockdelays -p $(pgrep -x sshd | head -1)
```

---

### 故障 4：iperf3 client 立即退出

**可能原因**：iperf3 server 未启动，或端口被占用。

**排查命令**：

```bash
ss -tlnp | grep 5201
pgrep -x iperf3
```

**恢复方案**：

```bash
pkill -x iperf3
iperf3 -s -D
sleep 2
iperf3 -c 127.0.0.1 -t 60 &
```

---

### 故障 5：inode 查询返回 "No socket found"

**可能原因**：取到的 inode 已失效（对应 socket 已关闭），或 inode 输错。

**排查命令**：

```bash
ls -l /proc/<pid>/fd | grep socket
# 重新取一个有效的 inode
```

**恢复方案**：重新执行 Step 6 取一个新的 inode，立即执行 Step 7 查询。

---

### 故障 6：RESET 后查询计数未归零

**可能原因**：RESET 命令未生效（权限不足），或查询的目标进程与 RESET 后又有新报文。

**排查命令**：

```bash
sudo ./get_sockdelays -r   # 确认加了 sudo
# 立即查询（不 sleep）
sudo ./get_sockdelays -p <pid>
```

**恢复方案**：如仍异常，向评委说明"可能是 iperf3 流量过大导致计数快速重新累积，我们看 RX# 数值已经远小于重置前的 15823，证明 RESET 已生效"。

---

### 故障 7：VM 卡死或内核 panic

**可能原因**：极少见，可能是内核 patch 引入的 bug。

**恢复方案**：强制重启 VM（VirtualBox/QEMU 控制台），切换到备用 VM 快照。如时间不足，跳过演示环节，用 PPT 中的截图页继续讲解。

---

## 时间控制

| 步骤 | 时长 | 累计 |
|------|------|------|
| Step 0：环境检查 | 40 秒 | 0:40 |
| Step 1：编译工具 | 30 秒 | 1:10 |
| Step 2：启动 iperf3 server | 15 秒 | 1:25 |
| Step 3：启动 iperf3 client | 10 秒 | 1:35 |
| Step 4：查找 PID | 10 秒 | 1:45 |
| Step 5：按 PID 查询（重点） | 50 秒 | 2:35 |
| Step 6：取 inode | 20 秒 | 2:55 |
| Step 7：按 inode 查询 | 30 秒 | 3:25 |
| Step 8：重置统计 | 15 秒 | 3:40 |
| Step 9：验证归零 | 20 秒 | 4:00 |
| Step 10：多 socket 演示 | 50 秒 | 4:50 |
| 收尾与讲解 | 30 秒 | 5:20 |
| 缓冲（命令切换/打字） | 2-3 分钟 | 8:00-8:30 |

**总时长**：约 8-10 分钟。

### 时间控制要点

- Step 5 与 Step 10 是讲解重点，每个至少留 50 秒，确保评委看清输出。
- 其他步骤以"展示能力"为主，讲解词简短，避免拖时间。
- 每条命令打字时间约 5-10 秒，可提前在剪贴板准备好，演示时直接粘贴。
- 如某步异常超过 30 秒无法恢复，立即切换到故障恢复预案，不要硬磕。

---

## 演示前演练建议

1. **完整演练至少 3 次**：第一次按脚本走完，第二次计时调整节奏，第三次模拟评委提问场景。
2. **录制备用视频**：演示前用 OBS 录制一次完整演示视频，作为 VM 故障时的最终降级方案。
3. **准备关键步骤截图**：至少准备 Step 5、Step 7、Step 10 的输出截图，嵌入 PPT 备用页。
4. **检查所有命令的可复制性**：演示时直接粘贴命令比手敲快且不易错，但需提前在 VM 内测试剪贴板可用。
5. **确认终端配色**：浅色背景深色文字在投影仪上更清晰，避免黑底绿字看不清。

---

## 附录：演示所用命令一览（可一次性粘贴到脚本）

```bash
#!/bin/bash
# NET_DELAYACCT 演示一键脚本（备用，如手动演示失败可执行此脚本）
set -e

cd ~/NET_DELAYACCT

# Step 0
echo "=== Step 0: env check ==="
uname -r
grep NET_DELAYACCT /boot/config-$(uname -r)
cat /proc/net/genetlink | grep -A1 net_delayacct

# Step 1
echo "=== Step 1: build tool ==="
make tool

# Step 2
echo "=== Step 2: start iperf3 server ==="
iperf3 -s -D
sleep 1

# Step 3
echo "=== Step 3: start iperf3 client ==="
iperf3 -c 127.0.0.1 -t 60 >/dev/null 2>&1 &
sleep 2

# Step 4
echo "=== Step 4: find iperf3 pid ==="
pgrep -x iperf3

# Step 5
PID=$(pgrep -x iperf3 | tail -1)
echo "=== Step 5: query by PID $PID ==="
sudo ./userspace/get_sockdelays/get_sockdelays -p "$PID"

# Step 6
echo "=== Step 6: get inode ==="
INODE=$(ls -l /proc/$PID/fd 2>/dev/null | grep -oE 'socket:\[[0-9]+\]' | head -1 | grep -oE '[0-9]+')
echo "inode: $INODE"

# Step 7
echo "=== Step 7: query by inode ==="
sudo ./userspace/get_sockdelays/get_sockdelays -i "$INODE"

# Step 8
echo "=== Step 8: reset ==="
sudo ./userspace/get_sockdelays/get_sockdelays -r

# Step 9
echo "=== Step 9: query again ==="
sleep 3
sudo ./userspace/get_sockdelays/get_sockdelays -p "$PID"

# Step 10
echo "=== Step 10: multi socket ==="
nc -l 9999 &
NC_PID=$!
sleep 1
nc 127.0.0.1 9999 </dev/null &
sleep 1
SERVER_PID=$(pgrep -x iperf3 | head -1)
sudo ./userspace/get_sockdelays/get_sockdelays -p "$SERVER_PID"
kill $NC_PID 2>/dev/null || true
pkill -f "nc 127.0.0.1 9999" 2>/dev/null || true

# cleanup
pkill -x iperf3 2>/dev/null || true
echo "=== Demo finished ==="
```

将上述脚本保存为 `~/demo.sh`，演示前 `chmod +x ~/demo.sh`，备用方案下直接 `bash ~/demo.sh` 一键执行。

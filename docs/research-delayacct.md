# DELAYACCT 框架研究笔记

> 对象：Linux 6.6 内核中已有的 `CONFIG_DELAYACCT` 框架及其用户态工具 `getdelays`。
> 目的：作为本项目 `CONFIG_NET_DELAYACCT` 的设计参照，提炼可复用的架构模式、API 风格与工具实现套路。
> 参考源码位置（除非特别说明，路径均相对于内核源码树根目录）：
> - `kernel/delayacct.c`
> - `include/linux/delayacct.h`
> - `include/uapi/linux/taskstats.h`
> - `kernel/taskstats.c`
> - `tools/account/getdelays.c`
> - `Documentation/accounting/delay-accounting.rst`
> - `Documentation/accounting/taskstats.rst`

---

## 1. 框架概述

`CONFIG_DELAYACCT`（Delay accounting）是 Linux 内核提供的"任务级资源等待时延"统计框架。它在每个 `struct task_struct` 中维护一个 `struct task_delay_info`，按以下几类资源累计任务被阻塞等待的纳秒级时间：

- **CPU 等待时延**（`cpu_count` / `cpu_delay_total`）：任务处于 `TASK_INTERRUPTIBLE` / `TASK_UNINTERRUPTIBLE` 状态、等待被调度上 CPU 的时间。由调度器在 `try_to_wake_up` / `wait_task_inactive` 路径上打点，对应 `delayacct_blkio_start` 的同类辅助接口 `delayacct_tsk_init` 与 `delayacct_task_switch`。
- **块 IO 等待时延**（`blkio_count` / `blkio_delay_total`）：任务在 `io_schedule` / `io_schedule_timeout` / `get_request_wait` 等处等待块设备 IO 完成的时间。
- **内存分配回收时延**（`swapin_count` / `swapin_delay_total`、`freepages_count` / `freepages_delay_total`）：任务因直接回收内存或换入页而阻塞的时间，由 `memdelay` / `vmscan.c` 在 `delayacct_freepages_start/end` 中累计。
- **压缩/thrashing 时延**（`thrashing_count` / `thrashing_delay_total`）：因等待被 thrashing 的页回写完成而阻塞的时间。
- **IRQ / softirq 内归一化统计**（部分版本中通过 `taskstats` 暴露）。

设计要点：框架关注的是"等待"而非"占用"——即任务因为某种资源不可得而被阻塞的时间，而非资源被该任务持有的时间。这与本项目关注的 socket 收发"在协议栈内滞留的时间"在思想上一脉相承。

---

## 2. 关键源码文件

### 2.1 `kernel/delayacct.c`

实现层文件，主要提供：

- `__delayacct_tsk_init(struct task_struct *tsk)`：fork 时初始化子任务的 `task->delays`，使用 `spin_lock_init` 初始化自旋锁。
- `delayacct_blkio_start()` / `delayacct_blkio_end()`：块 IO 等待起止打点。
- `delayacct_freepages_start()` / `delayacct_freepages_end()`：内存回收等待起止打点。
- `delayacct_thrashing_start()` / `delayacct_thrashing_end()`：thrashing 等待起止打点。
- `__delayacct_add_tsk(s64 *dst, const struct task_delay_info *src)`：在 taskstats 上报时把 per-task 累计值拷贝到统计结构体。
- 顶层门面函数 `delayacct_init()`：在 `start_kernel` 流程中调用，初始化内部状态。

关键实现技巧：所有 `delayacct_*_start` 都通过 `ktime_get_ns()` 取当前时间为 `start`，所有 `*_end` 都计算 `ktime_sub(now, start)` 后加到对应字段，并以 spinlock 保护累加。在没有 `CONFIG_DELAYACCT` 时，`include/linux/delayacct.h` 中将这些函数全部定义为空内联函数，让打点点位在编译期消失。

### 2.2 `include/linux/delayacct.h`

声明层头文件，提供：

- `struct task_delay_info` 的前置声明。
- 一组 `static inline` 空实现（在未配置 `CONFIG_DELAYACCT` 时）。
- 在配置 `CONFIG_DELAYACCT` 时通过 `#ifdef` 切换为真实外部函数声明。
- 辅助宏 `delayacct_on()` 判断是否启用。

这是本项目应当效仿的核心头文件组织方式：**一个头文件，两种实现，由 `#ifdef` 自动切换，调用方代码完全不变**。

### 2.3 `include/uapi/linux/taskstats.h`

UAPI 头文件，定义与用户态的二进制接口：

- `struct taskstats`：一个巨大的统计结构体（字段以 `__u64` 为主），包含 CPU/IO/MEM/Swap/Reclaim/Thrashing 等所有时延字段，以及命令行、上下文切换次数、IO 字节计数等通用任务统计。
- genl 命令常量：`TASKSTATS_CMD_GET`、`TASKSTATS_CMD_NEW`、`TASKSTATS_CMD_GET_PID` 等。
- genl 属性常量：`TASKSTATS_TYPE_PID`、`TASKSTATS_TYPE_TGID`、`TASKSTATS_TYPE_STATS`、`TASKSTATS_TYPE_AGGR_PID`、`TASKSTATS_TYPE_AGGR_TGID` 等。
- family 名字：`TASKSTATS_GENL_NAME` 为 `"TASKSTATS"`，版本 `TASKSTATS_GENL_VERSION` 为 `1`。
- `cgroupstats`、`taskstats` 命令族共用同一 family。

设计要点：所有 UAPI 字段使用定长 `__u8/__u32/__u64`，对齐明确，可跨架构稳定；属性值通过 nla 嵌套携带子属性（`AGGR_PID` 内嵌 `PID` + `STATS`），形成层次化结构。

### 2.4 `kernel/taskstats.c`

genl 后端实现，提供：

- family 注册：`taskstats_init` 注册 genl family `TASKSTATS`。
- 命令处理：`taskstats_user_cmd`（处理 `TASKSTATS_CMD_GET`）、`taskstats_cmd_get_pid`（处理 `TASKSTATS_CMD_GET_PID`）。
- 多任务回复：当查询 cgroup 或 tgid 时，对每个匹配任务发送一条独立的 genl 消息，最终以 `NLMSG_DONE` 结束。
- per-cpu 缓存：使用 `percpu_counter` 维护全局统计计数。

---

## 3. 数据流

per-task 累计的数据流如下：

```
  打点点位 (调度器/io_schedule/vmscan/...)
              |
              v
   delayacct_*_start()      <- ktime_get_ns() 写入 task->delays->XXX_start
              |
   (任务被阻塞，调度出去)
              |
   delayacct_*_end()        <- delta = now - start
              |
              v
   spin_lock(&task->delays->lock);
   task->delays->XXX_delay_total += delta;
   task->delays->XXX_count++;
   spin_unlock(&task->delays->lock);
              |
              v
   用户态 getdelays 请求 --> taskstats_cmd_get_pid
              |
              v
   __delayacct_add_tsk() 读 task->delays, 填入 struct taskstats
              |
              v
   nla_put(skb, TASKSTATS_TYPE_STATS, sizeof(struct taskstats), &stats)
              |
              v
   genlmsg_unicast() 回送到用户态
```

关键数据结构（简化版，源自 `include/linux/delayacct.h`）：

```c
struct task_delay_info {
    raw_spinlock_t lock;       /* 保护以下累加字段 */

    /* 以下为 per-task 累计值 */
    u64 blkio_start;
    u64 blkio_delay_total;     /* ns */
    u64 blkio_count;

    u64 swapin_start;
    u64 swapin_delay_total;    /* ns */
    u64 swapin_count;

    u64 freepages_start;
    u64 freepages_delay_total; /* ns */
    u64 freepages_count;

    u64 thrashing_start;
    u64 thrashing_delay_total; /* ns */
    u64 thrashing_count;
};
```

注意：`task_delay_info` 直接嵌在 `struct task_struct` 的 `delays` 字段中（在 `CONFIG_DELAYACCT` 关闭时通过 `#ifdef` 不存在），所以无需独立分配、无需 RCU，只需 spinlock 保护累加。

---

## 4. 打点机制

### 4.1 start/end 配对模式

所有时延都通过一对函数记录：

```c
/* 调用方在进入"可能阻塞"的等待前调用 */
void delayacct_blkio_start(void)
{
    current->delays->blkio_start = ktime_get_ns();
}

/* 调用方在等待结束时调用 */
void delayacct_blkio_end(void)
{
    u64 now = ktime_get_ns();
    u64 delta = now - current->delays->blkio_start;
    /* ... */
    raw_spin_lock(&current->delays->lock);
    current->delays->blkio_delay_total += delta;
    current->delays->blkio_count++;
    raw_spin_unlock(&current->delays->lock);
}
```

要点：

- start 一定在 `current` 上下文，记录到当前任务的 `delays` 中。
- end 也在 `current` 上下文，与 start 配对，假定二者之间没有跨任务传递。
- start/end 之间允许调度出去（事实上正是要测量这种调度出去的时间），所以 `*_start` 字段必须放在不会被其他任务误读的位置——per-task 字段天然满足。
- count 与 total 配对累计，便于用户态计算平均值。

### 4.2 调用点示例

`delayacct_blkio_start()` 主要被 `kernel/sched/core.c`、`block/blk-core.c` 等调用。例如 `io_schedule` 流程中：

```c
void io_schedule(void)
{
    /* ... */
    delayacct_blkio_start();
    io_schedule_timeout(MAX_SCHEDULE_TIMEOUT);
    delayacct_blkio_end();
}
```

`delayacct_freepages_start/end` 被 `mm/vmscan.c` 在 `shrink_folio_list` / `try_to_free_pages` 等路径调用。

`delayacct_thrashing_start/end` 在 `mm/filemap.c` 等待被 thrashing 的页时调用。

### 4.3 与本项目的差异

- DELAYACCT 的 start/end 都在 `current` 任务上下文，时延绑定到 `task_struct`。
- 本项目 NET_DELAYACCT 的时延绑定到 `struct sock`，且 RX 路径存在跨上下文传递：报文在中断/SOFTIRQ 上下文进入协议栈，但被进程在 `recvmsg` 系统调用上下文读出。**起始时间戳必须挂在 `skb` 上而非任务上**——这是本项目与 DELAYACCT 最大的不同，详见 `design.md` 与 `protocol-stack.md`。

---

## 5. taskstats 接口

### 5.1 Generic Netlink Family

taskstats 通过 Generic Netlink（genl）暴露给用户态：

- **family 名字**：`TASKSTATS_GENL_NAME = "TASKSTATS"`
- **family 版本**：`TASKSTATS_GENL_VERSION = 1`
- **命令**：
  - `TASKSTATS_CMD_UNSPEC`
  - `TASKSTATS_CMD_GET`：根据属性里的 PID 或 TGID 取统计
  - `TASKSTATS_CMD_NEW`（内核内部用，用户态一般不发送）
  - `TASKSTATS_CMD_GET_PID`：早期接口，按 PID 直接取
- **属性**：
  - `TASKSTATS_TYPE_UNSPEC`
  - `TASKSTATS_TYPE_PID`
  - `TASKSTATS_TYPE_TGID`
  - `TASKSTATS_TYPE_STATS`：值为 `struct taskstats` 二进制
  - `TASKSTATS_TYPE_AGGR_PID`：嵌套属性，包含 `PID` + `STATS`，用于单条消息携带一个任务完整统计
  - `TASKSTATS_TYPE_AGGR_TGID`：同上，但按 TGID 聚合
  - `TASKSTATS_TYPE_NULL`
  - `TASKSTATS_TYPE_AGGR_NONE`

### 5.2 请求与响应

请求格式（用户态发送）：

```
+--------------------------+
| struct nlmsghdr          |  nlmsg_type = family_id
|                          |  nlmsg_flags = NLM_F_REQUEST
+--------------------------+
| struct genlmsghdr        |  cmd = TASKSTATS_CMD_GET
|                          |  version = 1
+--------------------------+
| NLA: TASKSTATS_TYPE_PID  |  u32 pid
+--------------------------+
```

响应格式（内核返回，可能多条）：

```
+------------------------------+
| struct nlmsghdr              |  nlmsg_flags = NLM_F_MULTI
+------------------------------+
| struct genlmsghdr            |
+------------------------------+
| NLA: TASKSTATS_TYPE_AGGR_PID |  嵌套
|   +------------------------+ |
|   | NLA: TASKSTATS_TYPE_PID| |  u32 pid
|   +------------------------+ |
|   | NLA: TASKSTATS_TYPE_   | |  struct taskstats
|   |       STATS            | |
|   +------------------------+ |
+------------------------------+
...
+------------------------------+
| struct nlmsghdr              |  nlmsg_type = NLMSG_DONE
+------------------------------+
```

### 5.3 内核侧处理流程

`taskstats_user_cmd` 处理 `TASKSTATS_CMD_GET`：

1. `genlmsg_parse` 解析属性，取出 `PID` 或 `TGID`。
2. 若是 TGID，遍历线程组每个任务；若是 PID，仅查一个任务。
3. 对每个任务调用 `fill_tgid` / `fill_pid`：
   - `rcu_read_lock` 保护 `task_struct`。
   - `task_lock` 拿到稳定 `mm` / `signals` 引用。
   - 调用 `__delayacct_add_tsk` 把 `task->delays` 累计值拷入 `struct taskstats`。
   - 填充其它字段（comm、uid、上下文切换次数等）。
   - 用 `nla_put_u32` + `nla_put(skb, TASKSTATS_TYPE_STATS, ...)` 把数据塞到回送 skb。
4. 多任务场景使用 `NLM_F_MULTI` 标记每条消息，最后发送 `NLMSG_DONE`。
5. 全程在持有 RCU 读锁与必要的 task_lock 下进行，避免任务中途退出。

---

## 6. getdelays.c 工具

### 6.1 命令行参数

`tools/account/getdelays.c` 通过 `getopt` 解析参数：

| 选项 | 含义 |
|------|------|
| `-p <pid>` | 查询指定 PID 的统计 |
| `-t <tgid>` | 查询指定 TGID 的统计（含所有线程聚合） |
| `-d` | dump 模式，循环打印 |
| `-i <interval>` | dump 间隔（秒） |
| `-l` | 列出所有支持的字段 |
| `-c` | 自定义字段掩码 |
| `-s <subsys>` | 选择 cgroup 子系统 |
| `-v` | verbose |
| `-C <cpuid>` | per-cpu 统计 |
| `-w` | 等待任务结束 |

### 6.2 通信流程

工具主流程：

1. **打开 genl socket**：`socket(AF_GENERIC_NETLINK, SOCK_RAW, NETLINK_GENERIC)`。
2. **解析 family ID**：发送 `CTRL_CMD_GETFAMILY` 到 `CTRL_FAMILY_GENL`（nlctrl），family name = `"TASKSTATS"`，从应答中解析出 `CTRL_ATTR_FAMILY_ID`、`CTRL_ATTR_MCAST_GROUPS`（用于多播组监听）。
3. **绑定 socket**：`bind(fd, (struct sockaddr_nl*)&nl_addr, sizeof(...))`。
4. **构造请求**：
   - `genlmsg_put(skb, NL_AUTO_PID, NL_AUTO_SEQ, family_id, 0, NLM_F_REQUEST, TASKSTATS_CMD_GET, 1)`。
   - `nla_put_u32(skb, TASKSTATS_TYPE_PID, pid)`。
5. **发送**：`sendto(fd, buf, len, 0, &nl_addr, sizeof(...))`。
6. **接收多消息**：
   ```c
   while (1) {
       recvmsg(fd, &msg, 0);
       for_each_nlmsg(nlh, buf) {
           if (nlh->nlmsg_type == NLMSG_DONE) goto done;
           if (nlh->nlmsg_type == NLMSG_ERROR) { /* handle */ }
           genlmsg_parse(nlh, sizeof(struct genlmsghdr), attrs, ...);
           /* 从 attrs[TASKSTATS_TYPE_AGGR_PID] 嵌套解析 */
           nla_parse_nested(nested, ..., attrs[TASKSTATS_TYPE_AGGR_PID], ...);
           pid = nla_get_u32(nested[TASKSTATS_TYPE_PID]);
           memcpy(&stats, nla_data(nested[TASKSTATS_TYPE_STATS]),
                  sizeof(struct taskstats));
           print_taskstats(&stats);
       }
   }
   ```
7. **格式化输出**：按字段名打印，例如：
   ```
   CPU  count=12345 total=987654321ns delay=80ns/count
   IO   count=678  total=4321ms      delay=6.4us/count
   ```

### 6.3 关键实现细节

- 工具通过 `genlmsg_parse` + `nla_parse_nested` 实现层次化属性解析。
- 输出格式与 `Documentation/accounting/delay-accounting.rst` 中描述的字段一一对应。
- dump 模式（`-d`）下，每 `interval` 秒查询一次并打印差值，便于观察时延变化趋势。

---

## 7. 关键 API

| API | 用途 | 来源 |
|-----|------|------|
| `genlmsg_put(skb, portid, seq, family, hdrlen, flags, cmd, version)` | 在 skb 头部填充 genlmsghdr | `include/net/genetlink.h` |
| `genlmsg_unicast(net, skb, portid)` | 单播 genl 消息给用户态 | `net/netlink/genetlink.c` |
| `genlmsg_multicast(...)` | 多播 genl 消息 | 同上 |
| `genlmsg_parse(nlh, hdrlen, tb, maxtype, policy)` | 解析 genl 消息属性到 `tb[]` 数组 | `include/net/genetlink.h` |
| `nla_put_u32(skb, type, value)` | 写入 u32 属性 | `include/net/netlink.h` |
| `nla_put_u64_64bit(skb, type, value, padattr)` | 写入 u64 属性（带对齐 padding） | 同上 |
| `nla_put(skb, type, len, data)` | 写入任意二进制属性 | 同上 |
| `nla_put_string(skb, type, str)` | 写入字符串属性 | 同上 |
| `nla_get_u32(nla)` / `nla_get_u64(nla)` | 从属性读标量 | 同上 |
| `nla_parse_nested(tb, max, nla, policy, extack)` | 解析嵌套属性 | 同上 |
| `nla_data(nla)` / `nla_len(nla)` | 取属性数据指针与长度 | 同上 |
| `nlmsg_new(payload, gfp)` | 分配新 skb | `include/linux/skbuff.h` |
| `nlmsg_put(skb, port, seq, type, payload, flags)` | 写 nlmsghdr | 同上 |
| `nlmsg_end(skb, nlh)` | 设置 skb 长度并返回 | 同上 |
| `genl_register_family(family)` | 注册 genl family | `net/netlink/genetlink.c`（旧接口） |
| `genl_ops` 结构体 | 命令操作表，6.6 推荐用 `.cmd` + `.doit` | 同上 |

### 7.1 6.6 内核推荐写法

在 Linux 6.6 中，genl family 注册推荐使用 `struct genl_family` + `genl_small_ops`：

```c
static const struct genl_small_ops net_delayacct_ops[] = {
    { .cmd = NET_DELAYACCT_CMD_GET_BY_PID,
      .doit = net_delayacct_get_by_pid, },
    { .cmd = NET_DELAYACCT_CMD_GET_BY_INODE,
      .doit = net_delayacct_get_by_inode, },
    { .cmd = NET_DELAYACCT_CMD_RESET,
      .doit = net_delayacct_reset, },
};

static struct genl_family net_delayacct_family = {
    .name     = "net_delayacct",
    .version  = 1,
    .maxattr  = NET_DELAYACCT_A_MAX,
    .module   = THIS_MODULE,
    .ops      = net_delayacct_ops,
    .n_ops    = ARRAY_SIZE(net_delayacct_ops),
    .resv_start_op = NET_DELAYACCT_CMD_GET_BY_INODE + 1,
};
```

`resv_start_op` 是 6.x 引入的"未定义命令拒绝"机制，本项目应当使用。

---

## 8. 借鉴点

### 8.1 per-task / per-socket 存储模式

DELAYACCT 把 `struct task_delay_info` 直接嵌进 `struct task_struct`，无需独立分配，无 RCU 复杂度。本项目把 `struct net_delayacct` 直接嵌进 `struct sock`（受 `#ifdef` 保护），同样的思路。

### 8.2 #ifdef 切换头文件模式

`include/linux/delayacct.h` 提供两套声明：开启时为 `extern` 函数声明，关闭时为 `static inline` 空实现。**调用方代码完全相同**，让插桩点处不需要再写 `#ifdef`，代码可读性最好。本项目 `include/net/net-delayacct.h` 应严格遵循这一模式。

### 8.3 start/end 配对 + 累加模式

`*_start()` 写入时间戳，`*_end()` 计算 delta 并在 spinlock 下累加。count + total 配对维护，便于用户态算平均。本项目完全沿用，只是把 start 的时间戳放在 `skb->delayacct_start` 而非 `task->delays->XXX_start`，因为跨上下文。

### 8.4 genl 接口设计

- family 名字简短小写带前缀，便于 `genl_ctrl_search_by_name` 解析。
- 命令与属性都用 UAPI 枚举 + `_MAX` + `_MAX - 1` 的命名约定。
- 多对象回复用 `NLM_F_MULTI` + `NLMSG_DONE`。
- 大型统计结构用 `nla_put(skb, TYPE, sizeof(struct), &stats)` 一次性塞入，而非拆成多个标量属性。

### 8.5 dump 迭代模式

getdelays 的 dump 模式（`-d -i <interval>`）持续轮询并打印差值，对于观察时延变化趋势很有用。本项目 `get_sockdelays` 应提供类似模式。

### 8.6 内联辅助函数保护

DELAYACCT 的所有 `delayacct_*_start/end` 都是 `static inline`，在关闭时为空函数体。编译器会消除所有调用，零开销。本项目所有 `net_delayacct_*_start/end` 都应遵循此模式。

### 8.7 不破坏现有 ABI

DELAYACCT 在 `struct task_struct` 中嵌入 `delays` 字段，关闭时通过 `#ifdef` 完全不存在，结构体大小不变。本项目在 `struct sock` / `struct sk_buff` 中嵌入新字段时同样使用 `#ifdef CONFIG_NET_DELAYACCT` 保护，确保关闭选项的内核 ABI 与性能与原生 6.6 完全一致。

---

## 9. 与本项目的对应关系总览

| DELAYACCT 概念 | NET_DELAYACCT 对应 |
|----------------|---------------------|
| `struct task_delay_info` | `struct net_delayacct`（嵌入 `struct sock`） |
| `task->delays` | `sk->sk_net_delayacct` |
| `current->delays->blkio_start` | `skb->delayacct_start`（跨上下文用 skb 携带） |
| `delayacct_blkio_start/end` | `net_delayacct_rx_start/end`、`net_delayacct_tx_start/end` |
| `CONFIG_DELAYACCT` | `CONFIG_NET_DELAYACCT` |
| `TASKSTATS` genl family | `net_delayacct` genl family |
| `TASKSTATS_CMD_GET_PID` | `NET_DELAYACCT_CMD_GET_BY_PID` |
| `struct taskstats` | `struct net_delayacct_stats` |
| `tools/account/getdelays.c` | `tools/net/get_sockdelays.c` |
| `Documentation/accounting/delay-accounting.rst` | `Documentation/networking/net-delayacct.rst` |

---

## 10. 参考文档

- `Documentation/accounting/delay-accounting.rst`：用户态视角的 delayacct 说明，含字段表与 getdelays 示例。
- `Documentation/accounting/taskstats.rst`：taskstats genl 协议规范，含属性表与命令格式。
- `Documentation/userspace-api/netlink/index.rst`：Generic Netlink 用户态 API 文档。
- `Documentation/core-api/genetlink.rst`（如果存在）：genl 内核侧开发者文档。
- 内核源码：`kernel/delayacct.c`、`kernel/taskstats.c`、`tools/account/getdelays.c`。

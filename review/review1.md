# NET_DELAYACCT 内核工程 Review（第一次）

> 评审视角：专业 Linux 内核工程师
> 评审时间：2026-07-26
> 评审对象：当前仓库已"跑通"的工程状态

整体架构清晰：UAPI/内核头/插桩/genl/工具分层合理，`#ifdef`-only-when-disabled 的设计正确实现了"零开销兜底"，测试链路也已打通。但**距离能投 netdev 的状态还有不小差距**，主要是几处正确性/并发 bug、几处违反内核惯例的写法，以及 patch 系列本身不符合 `submitting-patches` 规范。

---

## 一、阻塞性正确性 bug（必须修复）

### 1. `cmd_get_by_inode` 在 RCU 临界区里睡眠 — 调度器原子上下文违例

[net-core-net-delayacct.c:439-504](file:///workspace/kernel-patches/net-core-net-delayacct.c#L439-L504) 全程持有 `rcu_read_lock()`，但在 [L486-L494](file:///workspace/kernel-patches/net-core-net-delayacct.c#L486-L494) 调用 `net_delayacct_one_reply()`，后者 [L184](file:///workspace/kernel-patches/net-core-net-delayacct.c#L184) 执行 `genlmsg_new(NLMSG_DEFAULT_SIZE, GFP_KERNEL)`，**`GFP_KERNEL` 会睡眠**。RCU 临界区内任何可能睡眠的操作都是非法的，跑得通只是因为大多数情况下分配立即成功；一旦内存紧张触发回收，立刻 `scheduling while atomic` + RCU stall。

`cmd_get_by_pid` 没这个问题（先 `rcu_read_unlock()` 再调 `iter_task_sockets`）。`cmd_get_by_inode` 必须按同样模式改：在循环里只做匹配 + `sock_hold()`/`get_file()` 拿引用，**找到后先退出 RCU 临界区再构造回复**。`cmd_reset` 的 `net_delayacct_reset()` 只取 spinlock，不睡眠，是 OK 的。

### 2. `task->comm` 在 `cmd_get_by_inode` 中无锁读取 — 数据竞争

[net-core-net-delayacct.c:488](file:///workspace/kernel-patches/net-core-net-delayacct.c#L488):

```c
ret = net_delayacct_one_reply(info, 0, sk, task_pid_nr(task),
                              task->comm, ino);
```

`iter_task_sockets` 在 [L322-L323](file:///workspace/kernel-patches/net-core-net-delayacct.c#L322-L323) 里特意 `task_lock(task); comm = task->comm;` 来安全读取 comm。`cmd_get_by_inode` 这里却裸读。`task->comm` 在另一线程 `set_task_comm()` 时可能撕裂（虽然 `TASK_COMM_LEN=16` 在 64 位上一次原子读可得，但内核约定仍要求 `task_lock` 或 `get_task_comm`）。和 #1 一起改：在持 `task_lock` 期间把 comm 拷出来。

### 3. `sock_from_file_safe` 重新发明 `sock_from_file()`

[net-core-net-delayacct.c:277-300](file:///workspace/kernel-patches/net-core-net-delayacct.c#L277-L300) 里 `TODO` 注释说 6.6 上 `sock_from_file()` 不可用，**这个判断是错的**。`sock_from_file()` 自 5.5 起就导出（见 `net/sock.c`），6.6 直接可用。直接换成：

```c
sk = sock_from_file(file);
```

否则会被 netdev reviewer 一眼挑出来。同时 `pr_info_ratelimited` 的 NULL 分支是死代码，整段删掉。

### 4. `__ro_after_init` 用在 `genl_family` 上不安全

[net-core-net-delayacct.c:89](file:///workspace/kernel-patches/net-core-net-delayacct.c#L89):

```c
static struct genl_family net_delayacct_genl_family __ro_after_init = { ... };
```

`genl_register_family()` 内部会写 `.id`、`.mcgenl_id` 等字段，发生在 `module_init` 之后（被外部子系统调用时）。`__ro_after_init` 只允许在 init 阶段写，注册后框架再写会触发 `rodata write fault`（看 `taskstats.c`、`sock_diag.c` 都是 `static struct genl_family`，不带 `__ro_after_init`）。直接去掉这个修饰符。

### 5. GSO 段未被记账 — "1 sample per packet" 不成立

[tx-instrumentation.patch:36-40](file:///workspace/kernel-patches/tx-instrumentation.patch) 只在 `tcp_sendmsg_locked` 新分配的 GSO 头 skb 上打 `tx_start`。但 `dev_hard_start_xmit` 里 GSO 会调用 `tcp_gso_segment` 拆出 N 个新 skb，**这些子 skb 的 `delayacct_start` 都是 0**，[tx-instrumentation.patch:23](file:///workspace/kernel-patches/tx-instrumentation.patch) 里 `net_delayacct_tx_end(skb->sk, skb)` 对它们都是 no-op。结果：**1 个 GSO skb 实际只计 1 个样本**，10 Gbps 大包场景下统计严重失真。

文档 [net-delayacct.rst:361-363](file:///workspace/Documentation/networking/net-delayacct.rst#L361-L363) 说"matches the accounting granularity of the start point" — 这是事后找补，不是真的对。要么在 `dev_hard_start_xmit` 循环里**对每个子 skb 都重新打 `tx_start = parent_skb->delayacct_start`**，要么明确文档化"GSO 视为 1 包"并接受精度损失。建议前者（5 行代码）。

### 6. `tx_end` 读取 `skb->sk` 可能 Use-After-Free

[tx-instrumentation.patch:23](file:///workspace/kernel-patches/tx-instrumentation.patch): `net_delayacct_tx_end(skb->sk, skb)` 在 `dev_hard_start_xmit` 里。从 `tcp_sendmsg_locked` 到这里之间 skb 经过 qdisc，可能被 `skb_orphan()` 把 `skb->sk` 置 NULL（保护），但也可能没被 orphan 而对应 sock 已经 `close()`+`sock_put()` 释放。`tx_end` 只检查 `if (!sk) return` 不防 UAF。

虽然实际中 qdisc 路径大部分会 orphan，但**没有契约保证**。要么在 tx_start 时调 `sock_hold(sk)` 并在 skb 的 destructor 里 `sock_put`（成本高），要么把 tx_end 移到 `tcp_write_xmit`/`udp_send_skb` 这种 socket 还活着的更早的位置（语义会变，但更安全）。

---

## 二、命名空间与权限

### 7. `netnsok = true` 但 handler 系统级遍历 — 命名空间泄漏

[net-core-net-delayacct.c:93](file:///workspace/kernel-patches/net-core-net-delayacct.c#L93) 设了 `netnsok = true`，让用户态可以从任意 netns 解析 family。但 `cmd_get_by_inode` 和 `cmd_reset` [L440](file:///workspace/kernel-patches/net-core-net-delayacct.c#L440)/[L512](file:///workspace/kernel-patches/net-core-net-delayacct.c#L512) 都用 `for_each_process` **跨 netns 遍历所有进程的所有 socket**。容器内 root 用 `-i <inode>` 能看到宿主机进程的 socket 五元组——**信息泄漏**。

要么改成 `for_each_process_thread_in_netns(current->nsproxy->net_ns, ...)`（无现成宏，需手动按 `task->nsproxy->net_ns` 过滤），要么干脆设 `netnsok = false` 让查询只在 init_netns 工作。配 #8 一起改。

### 8. `GENL_ADMIN_PERM` 已被弃用

[net-core-net-delayacct.c:72/78/84](file:///workspace/kernel-patches/net-core-net-delayacct.c#L72) 三个 op 都用 `GENL_ADMIN_PERM`，5.2 起新代码应使用 `GENL_NS_ADMIN_PERM` 配合 `netnsok`。否则容器内非 root 用户（带 `CAP_NET_ADMIN`）也无法查询。

### 9. `find_get_pid` 而非 `find_vpid` — PID 命名空间不一致

[net-core-net-delayacct.c:403](file:///workspace/kernel-patches/net-core-net-delayacct.c#L403) `find_get_pid(pid)` 在 init namespace 解析 PID，但用户从 `ps`/`/proc/<pid>` 看到的是当前 ns 内的 vpid。容器场景下两者不同。改用 `find_vpid(pid)` + `get_pid_task()`。

---

## 三、热路径 / 性能

### 10. 每个 RX/TX 报文都取 spinlock — 高 PPS 争用

[net-core-net-delayacct.c:590-593/609-612](file:///workspace/kernel-patches/net-core-net-delayacct.c#L590-L612) 在 RX/TX end 路径里 `spin_lock(&n->lock); +=; spin_unlock`。10 Gbps 小包 14.88 Mpps 单 socket，即使 4 核也至少 4 路 cache line 争用。`design.md` 提到 per-cpu counter 是 v3+ 远期计划，但 v1 起码应该：

- 用 `u64_stats_sync` + per-cpu 计数器（`u64_stats_fetch_begin/..._retry` 读，per-cpu 写无锁），或
- 至少用 `local_irq_save` 形式避免中断嵌套，或
- 用 `atomic64_add` + `atomic64_inc` 替代 spinlock（无锁但失去 total/count 原子一致性，对延迟统计可接受）。

`design.md §6.1` 评论"标准 spin_lock 即可，不需 spin_lock_bh" — **这是错的**。RX 路径在 softirq 上下文跑，TCP sendmsg 在 process 上下文跑，softirq 可打断 process 并同时操作同一 sock 的 RX/TX 累加（虽然 RX 用 rx_count，TX 用 tx_count 字段不同，但同 spinlock 保护两者）。必须 `spin_lock_bh(&n->lock)`。

### 11. `delayacct_start` 加在 `sk_buff` 热缓存行里

[skbuff_h-modification.patch:23-30](file:///workspace/kernel-patches/skbuff_h-modification.patch) 把 `delayacct_start` 加在 `tstamp/skb_mstamp_ns` union 后面，紧贴 hot fields。`sk_buff` 是内核最热数据结构之一，多 8B 会把后续字段挤到下一缓存行。建议：放到 struct 末尾（紧贴 `cb` 之前）或复用 `skb->cb` 区域（每协议层 cb 语义不同，需谨慎）。即使不优化也应跑 `pahole` 测一下 cache footprint。

### 12. `pr_debug` 参数里有 `sock_inode_for(sk)` 调用

[net-core-net-delayacct.c:346-354](file:///workspace/kernel-patches/net-core-net-delayacct.c#L346-L354) 里 `pr_debug(..., sock_inode_for(sk), ...)`。`pr_debug` 默认编译进但运行时跳过格式化（除非 `CONFIG_DYNAMIC_DEBUG`），但**参数仍然求值**。每次迭代都调用 `sock_inode_for()` 解引用 `sk->sk_socket->file`。改用 `pr_debug_ratelimited` 或加 `#define DEBUG` 守卫，或干脆删除这些调试日志（项目已发布阶段了）。

### 13. `ktime_get_ns()` 调用 2 次/包

不算严重，但 10Gbps 下累积可观。考虑用 `local_clock()`（不跨 CPU 同步，更快）或一次 `ktime_get()` 拿 `ktime_t` 再两次转 ns。

---

## 四、UAPI / ABI

### 14. UAPI 缺 `nla_put_be32` 的字节序约定文档

[net-core-net-delayacct.c:144/146](file:///workspace/kernel-patches/net-core-net-delayacct.c#L144-L146) 用 `nla_put(skb, NET_DELAYACCT_A_LADDR, sizeof(__be32), &inet->inet_rcv_saddr)` 直接写网络序字节。用户态 [get_sockdelays.c:255](file:///workspace/userspace/get_sockdelays/get_sockdelays.c#L255) 用 `inet_ntop` 直接解释为网络序字节。**协议上没毛病**，但 UAPI 头文件里没注明"LADDR/RADDR 是网络字节序"。建议加注释到 `include-uapi-linux-net-delayacct.h`，避免后续误用。

### 15. `net_delayacct_stats` UAPI 结构体实际未被使用

UAPI 定义了 `struct net_delayacct_stats`，但内核不把它整体作为 NLA 发出，而是逐字段 `nla_put_u64_64bit`。结构体目前只是文档作用。要么删除（UAPI 最小化原则），要么用 `NET_DELAYACCT_A_STATS` 二进制属性整包发（不推荐，不利扩展）。建议删除结构体，在头文件里用注释说明各字段含义。

### 16. `genl_ops` vs `genl_small_ops`

[net-core-net-delayacct.c:68](file:///workspace/kernel-patches/net-core-net-delayacct.c#L68) 用 `struct genl_ops`。3 个 op 的小家族应使用 `struct genl_small_ops`（更紧凑，`sizeof` 更小）。`design.md §5.1` 写的就是 `genl_small_ops`，实现和设计文档不一致。

### 17. `resv_start_op = __NET_DELAYACCT_CMD_MAX` 取值

[net-core-net-delayacct.c:97](file:///workspace/kernel-patches/net-core-net-delayacct.c#L97) `resv_start_op` 应设为「最后一个 op 的 cmd + 1」，即 `NET_DELAYACCT_CMD_RESET + 1`。当前 `__NET_DELAYACCT_CMD_MAX` 也等于 `RESET+1`，结果对，但语义上 `resv_start_op` 表达的是"从这里开始的 cmd 是保留的、不做 strict validation"。`design.md` 写法是对的，代码里这种隐式等价容易后续加 cmd 时翻车。改成显式 `NET_DELAYACCT_CMD_RESET + 1`。

---

## 五、锁设计与文档不一致

### 18. `cmd_get_by_inode` 缺 `task_lock` 保护 `task->files`

[L446-L451](file:///workspace/kernel-patches/net-core-net-delayacct.c#L446-L451) 用了 `task_lock(task)` 取 `files`，但 [L488](file:///workspace/kernel-patches/net-core-net-delayacct.c#L488) 读 `task->comm` 在锁外。#2 已说。

### 19. `atomic_inc(&files->count)` 重复造轮子

[L326/L449/L519](file:///workspace/kernel-patches/net-core-net-delayacct.c#L326) 三处用 `atomic_inc(&files->count)` 手动增引用。内核有 `get_files_struct()`（已导出），且语义更全（同步 `task_lock`）。直接 `files = get_files_struct(task)` 拿引用，用完 `put_files_struct(files)`。

### 20. `task_pid_nr(task)` 与锁顺序

[L319](file:///workspace/kernel-patches/net-core-net-delayacct.c#L319) `pid = task_pid_nr(task)` 在 `task_lock` 之前调用。`task_pid_nr` 读 `task->signal`，需要 `task_lock` 或 RCU。当前在 RCU 临界区内或下取决于调用路径——`cmd_get_by_pid` 在 `rcu_read_unlock()` 之后才调 `iter_task_sockets`，所以这里读 `task->signal` **没在 RCU 临界区内**。可能 UAF。建议在 `task_lock` 内调用 `task_tgid_nr_nr(task)` 或在外面用 `pid_vnr(find_vpid(...))`。

---

## 六、Patch 系列不符合上游规范

### 21. 缺少 `sock_init_data` 初始化补丁

[README.md:118-120](file:///workspace/README.md#L118-L120) 让用户跑 `sed -i 's/sk_tx_queue_clear(sk);/...net_delayacct_init.../'` 来改 `net/core/sock.c`。**这不是内核提交流程**。要么新增 `sock.c` 改动 patch 加入系列，要么把 `net_delayacct_init` 调用塞进 `sock_h-modification.patch` 里。否则 `git apply` 流程是断的。

### 22. Patch 命名混乱

仓库实际文件 `0005-0009-net-*.patch` + 4 个无序号 `*-modification.patch`/`*-instrumentation.patch`。`DEVELOPMENT_FLOW.md §18.3` 又提到另一套 `0001-0009`。统一成 `git format-patch` 输出风格的 `XXXX-<subsys>-<verb>.patch`，并按 [submitting-patches.rst](https://www.kernel.org/doc/html/latest/process/submitting-patches.html) 写好每个 commit message + `Signed-off-by`。

### 23. 不应混合 `cp` 和 `git apply`

[kernel-patches/README.md:30-61](file:///workspace/kernel-patches/README.md#L30-L61) 流程是"复制文件 + 应用补丁"混合。上游所有改动都应是 `git format-patch` 风格的标准 patch（包括新增文件也用 `--- /dev/null` 形式）。CI 里 `git apply` 才能跑通。

### 24. 身份信息

- [net-core-net-delayacct.c:2](file:///workspace/kernel-patches/net-core-net-delayacct.c#L2) `Copyright (c) 2026 h1y2g3l4y5`
- [L659](file:///workspace/kernel-patches/net-core-net-delayacct.c#L659) `MODULE_AUTHOR("h1y2g3l4y5 <h1y2g3l4y5@example.com>")`
- patch 文件里 `Signed-off-by: laiguo-liang <2909269677@qq.com>`

三处身份不一致。netdev 评审会立刻挑：`submitting-patches.rst` 要求真实姓名 + 可联系邮箱，匿名 handle 和 `@example.com` 不通过。

---

## 七、文档与代码不同步

### 25. `Documentation/networking/net-delayacct.rst` 描述的 CLI 完全不对

[RST §get_sockdelays tool §Usage](file:///workspace/Documentation/networking/net-delayacct.rst#L262-L311) 写：

- `-r` for reset —— 实际是 `-R`
- `-n` for nanoseconds —— 实际未实现
- 默认 microseconds —— 实际是 milliseconds
- 输出表格式 `TYPE LADDR LPORT ...` —— 实际是 `proto=tcp pid=... inode=... owner_task=...`

整段 [net-delayacct.rst:252-312](file:///workspace/Documentation/networking/net-delayacct.rst#L252-L312) 要重写对齐 [get_sockdelays.c](file:///workspace/userspace/get_sockdelays/get_sockdelays.c) 的实际输出。

### 26. `design.md` 的 UAPI/struct 与实际实现严重不一致

[design.md §3.2](file:///workspace/docs/design.md#L172-L236) 写的 `struct net_delayacct` 包含 `rx_start/tx_start/rx_pending/tx_pending` 字段。**实际实现** [include-net-net-delayacct.h:30-33](file:///workspace/kernel-patches/include-net-net-delayacct.h#L30-L33) 只有 `lock + stats`，没有这些"备用字段"。design.md §3.5 的字段汇总表也错。

design.md §5.1 写 `genl_small_ops` + `resv_start_op = NET_DELAYACCT_CMD_RESET + 1`，代码是 `genl_ops` + `__NET_DELAYACCT_CMD_MAX`。文档 vs 代码至少一处对不上。

文档需要根据当前实现回写一遍。

---

## 八、测试问题

### 27. KUnit 测试位置不规范

[tests/selftests/net-delayacct/kunit/](file:///workspace/tests/selftests/net-delayacct/kunit/net-delayacct-test.c) 把 KUnit 测试放在 selftests 目录下，不符合内核惯例。KUnit 测试应该放在被测代码旁边（`net/core/net-delayacct-test.c`），在 `lib/Kconfig.kunit` 注册 `CONFIG_NET_DELAYACCT_KUNIT_TEST`。`tools/testing/selftests/` 和 KUnit 是两套独立框架，别混。

### 28. KUnit 测试 `kzalloc(sizeof(struct sock))` 浪费且不真实

[kunit/net-delayacct-test.c:50](file:///workspace/tests/selftests/net-delayacct/kunit/net-delayacct-test.c#L50) 分配整个 `struct sock`（~440 字节）只测其中一个字段。要么直接 `kunit_kzalloc(sizeof(struct net_delayacct), ...)` 测纯逻辑，要么用 `sock_init_data()` 真正初始化一个 sock（更接近真实场景）。当前是"刚好能编过"的伪测试，对回归保护有限。

### 29. 并发测试 `kthread_stop` 已退出的线程

[kunit/net-delayacct-test.c:209-222](file:///workspace/tests/selftests/net-delayacct/kunit/net-delayacct-test.c#L209-L222):

```c
while (atomic_read(&ctx->remaining) > 0)
    fsleep(1000);
for (i = 0; i < CONCURRENCY_THREADS; i++)
    kthread_stop(tasks[i]);
```

线程 `atomic_dec` 后 `return 0` 退出。主线程等到 `remaining == 0` 时所有线程已退出，再 `kthread_stop` 会触发 `kernel/kthread.c` 的 warning。正确做法：线程里 `while (!kthread_should_stop()) { ... }`，主线程发完 `kthread_stop` 后再 join。

### 30. `KUNIT_DEFINE_TEST_SUITE` 回退宏是死代码

[kunit/net-delayacct-test.c:32-39](file:///workspace/tests/selftests/net-delayacct/kunit/net-delayacct-test.c#L32-L39) 为 6.6 提供 fallback。6.6 已经有 `KUNIT_DEFINE_TEST_SUITE`（`include/kunit/test.h`），fallback 是死代码，删掉。

### 31. 测试覆盖不到上述 #1-#6 bug

- 没有 KUnit 测 `cmd_get_by_inode` 在 RCU 临界区睡眠（这是 review 才发现的）。
- 没有压力测试触发 GSO（iperf3 默认会 GSO，但断言不检查 count 与实际包数比例）。
- 没有命名空间测试（在 netns 里跑 `get_sockdelays` 验证看不看得到 init_ns 的 socket）。

---

## 九、代码风格小问题

### 32. `static int cmd_*()` 前向声明多余

[net-core-net-delayacct.c:60-66](file:///workspace/kernel-patches/net-core-net-delayacct.c#L60-L66) 把三个 `static int cmd_*()` 前向声明了。直接把函数定义放到 `genl_ops` 数组之前即可，前向声明是 C++ 习惯，内核一般不这么写。

### 33. `sock_inode_for()` 与 `file_inode(file)->i_ino` 双轨制

`cmd_get_by_inode` 用 `file_inode(file)->i_ino`（[L473](file:///workspace/kernel-patches/net-core-net-delayacct.c#L473)），但 `iter_task_sockets` 又用 `sock_inode_for(sk)`（[L347/353/363](file:///workspace/kernel-patches/net-core-net-delayacct.c#L347)）。前者更可靠（不依赖 `sk->sk_socket->file`）。**统一用 `file_inode(file)->i_ino`**，删掉 `sock_inode_for()` 函数（[L241-L253](file:///workspace/kernel-patches/net-core-net-delayacct.c#L241-L253)）。

### 34. `pr_info` 调试日志应清掉

[net-core-net-delayacct.c:206-211/644/652](file:///workspace/kernel-patches/net-core-net-delayacct.c#L206-L211) 大量 `pr_debug` 在生产路径里。`module_init`/`module_exit` 里 `pr_info` 可保留，但 `one_reply` 里的 `pr_debug` 应改为 `net_dbg_ratelimited` 或删除。`pr_debug` 在 dynamic_debug 关闭时编译进二进制但运行时跳过格式化，**仍占代码段空间**。

### 35. `MODULE_LICENSE("GPL v2")` 与 SPDX 一致 — OK

[net-core-net-delayacct.c:658](file:///workspace/kernel-patches/net-core-net-delayacct.c#L658) `GPL v2` 对应 SPDX `GPL-2.0-only`，匹配。

---

## 修复优先级建议

| 优先级 | 项目 | 说明 |
|------|------|------|
| **P0**（阻塞上游） | #1 #2 #3 #4 | RCU 睡眠、comm 竞争、`sock_from_file`、`__ro_after_init` |
| **P0** | #5 #6 | GSO 与 orphan UAF，影响统计正确性 |
| **P0** | #7 #8 #9 | 命名空间隔离与权限 |
| **P0** | #21 #22 #23 #24 | patch 系列规范与身份信息 |
| **P1** | #10 #11 #12 #13 | 热路径性能 |
| **P1** | #14 #15 #16 #17 | UAPI 收尾 |
| **P1** | #25 #26 | 文档同步 |
| **P2** | #27-#31 | 测试规范化与覆盖 |
| **P2** | #32-#34 | 风格清理 |

---

## 附录：#1 + #2 + #3 的修法草图

```c
static int net_delayacct_cmd_get_by_inode(struct sk_buff *skb,
                                          struct genl_info *info)
{
    u64 target_inode;
    struct task_struct *task;
    struct sock *target_sk = NULL;
    struct file *target_file = NULL;
    char comm[TASK_COMM_LEN] = {0};
    u32 owner_pid = 0;
    int sock_count = 0;

    if (!info->attrs[NET_DELAYACCT_A_INODE])
        return -EINVAL;
    target_inode = nla_get_u64(info->attrs[NET_DELAYACCT_A_INODE]);

    rcu_read_lock();
    for_each_process(task) {
        struct files_struct *files;
        struct fdtable *fdt;
        unsigned int fd;

        task_lock(task);
        files = task->files;
        if (files)
            get_files_struct_atomic(files);  /* 或 get_files_struct() */
        task_unlock(task);
        if (!files)
            continue;

        spin_lock(&files->file_lock);
        fdt = files_fdtable(files);
        for (fd = 0; fd < fdt->max_fds; fd++) {
            struct file *file = fdt->fd[fd];
            struct sock *sk;
            u64 ino;

            if (!file)
                continue;
            sk = sock_from_file(file);
            if (!sk || !is_inet_tcp_udp(sk))
                continue;
            sock_count++;
            ino = file_inode(file)->i_ino;
            if (ino != target_inode)
                continue;

            /* 匹配命中：拿引用，拷 comm，然后跳出所有锁再回包 */
            get_file(file);
            sock_hold(sk);
            owner_pid = task_pid_nr(task);
            get_task_comm(comm, task);   /* 也可 task_lock 内 memcpy */
            spin_unlock(&files->file_lock);
            put_files_struct(files);
            rcu_read_unlock();

            target_sk = sk;
            target_file = file;
            goto out_rcu_dropped;
        }
        spin_unlock(&files->file_lock);
        put_files_struct(files);
    }
    rcu_read_unlock();
    return -ENOENT;

out_rcu_dropped:
    {
        int ret = net_delayacct_one_reply(info, 0, target_sk,
                                          owner_pid, comm, target_inode);
        sock_put(target_sk);
        fput(target_file);
        return ret;
    }
}
```

关键点：**RCU 临界区里只做匹配 + 拿引用 + 拷 comm，回包在 RCU 外做**。

---

## 总结

整体评价：**主线功能跑通是好的第一步，但作为内核 patch 投 netdev，目前的并发正确性、命名空间语义、patch 规范三块都不达标**。建议按 P0 优先级修复后再走一次 `checkpatch.pl --strict` + `get_maintainer.pl`，然后投 `netdev` 邮件列表 RFC。

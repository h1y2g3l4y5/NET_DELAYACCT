# 审查报告 - v2.0.0

- **审查日期**: 2026-07-26
- **审查范围**: 当前仓库整体工程状态
- **审查人**: Reviewer
- **总体评分**: 6.8/10 → 6.5/10 → 6.2/10
- **状态**: [复审中-发现patch同步问题] — 修复逻辑正确但0007 patch未同步，CI构建仍含锁序bug

## 阅读说明

本报告中每一条问题都按 **现象 → 为什么是问题 → 触发条件 → 后果 → 修法 → 为什么这么修** 的结构写。
这样做的目的是让 Worker 不仅知道"哪里有问题"，还能看懂"这为什么是问题、什么时候会出事、怎么改才对"。

---

## 一、审查概览

整体评价：这个工程已经从"概念验证"推进到了"可运行、可测试、可展示"的阶段。内核实现、UAPI、用户态工具、QEMU 测试、CI 基本串成了闭环，说明作者不仅关注功能本身，也关注验证和交付链路。

但如果目标是进一步达到长期维护级别或接近上游内核可接受标准，当前版本仍有几类关键问题没有解决：

1. **内核并发与上下文正确性风险仍然存在**（最危险，平时不炸，炸就是 stall/oops）
2. **命名空间与权限语义不够干净**（接口宣称的语义和实现不一致）
3. **patch 交付链不自洽**（CI 还在用 `sed` 热改内核源码）
4. **文档与实现漂移明显**（RST/design.md 已落后于代码）
5. **测试覆盖面广，但对高风险 correctness 问题覆盖不足**（测试多但没测到点上）

| 审查项 | 评分 | 说明 |
|--------|------|------|
| 代码质量 | 7/10 | 结构清晰，但关键路径仍有上下文/并发正确性问题 |
| 设计合理性 | 7/10 | 主体思路成立，但 netns / PID namespace / TX 语义未完全收敛 |
| 测试覆盖 | 7/10 | 测试数量多、展示性强，但对最危险的内核级问题覆盖不足 |
| 文档/日志质量 | 6/10 | 文档较完整，但与实际实现有明显漂移 |
| **综合评分** | **6.8/10** | 工程性较强，但离"可放心交付"的状态仍有距离 |

---

## 二、各项审查详情

### 2.1 代码质量 (7/10)

#### 优点
- 核心模块边界清晰：内核实现、UAPI、用户态工具、CI、QEMU 测试链路基本分层完成。
- 用户态工具 [get_sockdelays.c](file:///home/lai/Code/NET_DELAYACCT/userspace/get_sockdelays/get_sockdelays.c) 已具备较完整的 CLI、JSON、debug、family 解析与结果处理能力，不是一次性脚本。
- 内核内部头 [include-net-net-delayacct.h](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/include-net-net-delayacct.h) 的零开销开关思路是正确方向：关闭配置时接口退化为空 inline，避免额外运行时开销。

#### 问题

| # | 严重度 | 问题描述 | 建议 | Worker反馈 |
|---|--------|----------|------|-------------|
| 1 | 高 | 见下文「问题 2.1.1」 | 见下文 | 已修复 |
| 2 | 高 | 见下文「问题 2.1.2」 | 见下文 | 已修复-引入锁序问题 |
| 3 | 中 | 见下文「问题 2.1.3」 | 见下文 | 已修复 |
| 4 | 中 | 见下文「问题 2.1.4」 | 见下文 | 已修复 |
| 5 | 低 | 见下文「问题 2.1.5」 | 见下文 | 已修复 |
| 6 | 高 | 见下文「问题 2.1.6」 | 见下文 | 待回应 |

##### 问题 2.1.1 — RCU 临界区内构造 netlink reply（可能睡眠）

**现象**：[net_delayacct_cmd_get_by_inode()](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L424-L504) 在 [L439](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L439) 调用 `rcu_read_lock()` 进入 RCU 读临界区，命中 inode 后在 [L486-L494](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L486-L494) 直接调用 [net_delayacct_one_reply()](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L176-L213)。后者在 [L184](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L184) 执行 `genlmsg_new(NLMSG_DEFAULT_SIZE, GFP_KERNEL)`。

**为什么是问题**：
- RCU 读临界区（`rcu_read_lock()` 到 `rcu_read_unlock()` 之间）等价于"原子上下文"，**禁止任何可能睡眠的操作**。
- `GFP_KERNEL` 是允许睡眠的分配标志：当内存紧张时，分配器会触发页面回收，回收过程可能阻塞当前线程。
- 把"可能睡眠"放进"禁止睡眠"的上下文，是内核里最经典的正确性违例之一。

**触发条件**：
- 命中 inode 查询（不是 PID 查询，PID 查询路径已经先 `rcu_read_unlock()` 了）。
- `genlmsg_new` 不能从 cache 直接拿到内存，需要进入回收路径。
- 触发概率随系统内存压力上升而上升——这就是为什么本地 QEMU 跑一万次都不炸，但生产环境一上量就出事。

**后果**：
- 轻则内核打印 `scheduling while atomic` 警告。
- 重则 RCU stall、CPU 软死锁、甚至 oops。
- 这类 bug 在 review 阶段是"一眼挑出来"的，投上游必被拒。

**修法**：在 RCU 临界区内只做四件事——匹配 inode、`get_file()`/`sock_hold()` 拿引用、拷贝 comm、记录 pid；然后 `rcu_read_unlock()` 退出临界区，再构造并发送 reply。参考同文件 [cmd_get_by_pid()](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L402-L417) 的写法——它就是先 `rcu_read_unlock()` 再调 `iter_task_sockets`，是对的。

**为什么这么修**：RCU 读临界区的语义是"读者不允许睡眠、不允许被调度"，这个约束不能动；能动的只有"把可能睡眠的工作挪出去"。这是内核社区对所有 RCU 路径的统一要求，没有第二种合规写法。

---

##### 问题 2.1.2 — `task->comm` 在 RCU 临界区里裸读

**现象**：[net_delayacct_cmd_get_by_inode()](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L486-L488) 命中后直接把 `task->comm` 作为参数传给 `net_delayacct_one_reply()`。

**为什么是问题**：
- `task->comm` 是 `char[TASK_COMM_LEN]`（16 字节），任何线程都可以通过 `set_task_comm()` 改写自己进程的 comm。
- 内核约定：读 `task->comm` 必须在 `task_lock(task)` 保护下读，或用 `get_task_comm(buf, task)`。
- 同一个文件里的 [iter_task_sockets()](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L319-L327) 就遵守了这个约定：`task_lock(task); comm = task->comm; ...`。
- 同一个作者在同一个文件里对同一字段用了两套访问规则，说明锁语义没有收敛。

**触发条件**：
- 命中 inode 的同时，目标进程或它的子线程正在执行 `prctl(PR_SET_NAME, ...)` 或 `set_task_comm()`。
- 在 64 位系统上 16 字节不一定是单次原子读，存在撕裂可能。

**后果**：
- 轻则 reply 里 comm 字段是部分旧值部分新值（脏读）。
- 重则 KCSAN 等数据竞争检测器报 `data-race`，CI 会挂。

**修法**：和问题 2.1.1 一起改。在 `task_lock(task)` 持锁期间把 comm `memcpy` 到本地栈变量 `char comm[TASK_COMM_LEN]`，再退出锁、退出 RCU，用本地副本发包。

**为什么这么修**：`task_lock` 是为 comm 访问设计的标准同步原语；拷到栈上后再发包，既不违反 RCU 原子约束，也不依赖锁外还能不能读原字段。

---

##### 问题 2.1.3 — `sock_from_file_safe()` 重新发明轮子

**现象**：[sock_from_file_safe()](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L269-L300) 自己实现"从 struct file 取 struct sock"：`file_inode(file)` → `SOCKET_I(inode)` → `sock->sk`，并配了 NULL 分支的 `pr_info_ratelimited` 日志。

**为什么是问题**：
- 内核已有现成 helper `sock_from_file(file)`（`net/sock.c` 导出，5.5 起可用，6.6 当然有）。
- 自己再写一遍等价逻辑，第一会被 reviewer 一眼挑出来"为什么不用 helper"，第二自己写的版本往往漏掉上游 helper 后来补的边角 case。
- 配套的 `pr_info_ratelimited` NULL 分支实际上是死代码——`SOCKET_I(inode)` 对 S_IFSOCK inode 永远不会返回 NULL。

**触发条件**：永远在跑，但永远没有正面收益。

**后果**：
- 维护成本上升（上游 helper 改了，这里不会跟着改）。
- 给 reviewer 留下"作者不熟悉内核 API"的印象。

**修法**：直接换成 `sk = sock_from_file(file);`，删除整个 `sock_from_file_safe()` 函数和它的 NULL 日志分支。

**为什么这么修**：内核工程的基本原则之一是"优先用现成 helper"，它经过了社区审查、覆盖了所有边角、并且会被上游统一维护。

---

##### 问题 2.1.4 — `genl_family` 上的 `__ro_after_init`

**现象**：[net-core-net-delayacct.c#L89](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L89) 写成 `static struct genl_family net_delayacct_genl_family __ro_after_init = { ... };`。

**为什么是问题**：
- `__ro_after_init` 的语义是"init 阶段后该内存变为只读"。它依赖 `rodata_after_init` ELF 段，需要编译期 + 链接期 + 启动期三处配合。
- `genl_register_family()` 在 `module_init` 阶段调用，但 genl 框架会在注册时和后续运行时写入 family 结构的某些字段（如内部 id、多播组 id 等）。
- 把 family 整体标 `__ro_after_init` 等于"承诺注册后再也不写"，但实际不是这样。
- 对比内核里其他 genl family（`taskstats.c`、`sock_diag.c`），都是 `static struct genl_family xxx = { ... }`，**不带任何修饰符**。

**触发条件**：取决于内核版本、`CONFIG_DEBUG_RODATA`、`CONFIG_STRICT_KERNEL_RWX` 等配置；某些配置下会触发写保护异常。

**后果**：
- 轻则（默认配置）侥幸不炸。
- 重则 `rodata write fault`、oops。

**修法**：删掉 `__ro_after_init` 修饰符，回归 `static struct genl_family net_delayacct_genl_family = { ... };`。

**为什么这么修**：和内核其他 genl family 保持一致是最低风险的选择；`__ro_after_init` 的收益（一点点只读保护）远小于它的风险（写保护异常）。

---

##### 问题 2.1.5 — 热路径上的调试日志残留

**现象**：[net-core-net-delayacct.c](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L203-L211) 在 `net_delayacct_one_reply()` 里有 `pr_debug` 打印 skb 长度/类型/flags；[L334-L355](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L334-L355) 在 `iter_task_sockets()` 里每个 fd 都打 `pr_debug`。

**为什么是问题**：
- `pr_debug` 默认编译进二进制，只在 dynamic_debug 关闭时跳过格式化——但**参数仍然求值**。
- 比如 [L347](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L347) 的 `sock_inode_for(sk)` 每次迭代都会真的执行 `sk->sk_socket->file` 解引用，跑了一次完整函数调用，只是结果被丢弃。
- 项目已经过了调试阶段，热路径上的诊断输出应该清掉。

**触发条件**：每次查询。

**后果**：
- 性能损耗（虽然不大，但属于"无收益开销"）。
- 给 reviewer 留下"代码还没收尾"的印象。

**修法**：保留 `module_init`/`module_exit` 里的 `pr_info`，删掉所有热路径 `pr_debug`；如果确实需要保留诊断能力，改用 `net_dbg_ratelimited` 并配 `#define DEBUG` 守卫。

**为什么这么修**：调试日志是开发期工具，发布前应清掉；保留少量启动/退出日志足够定位"模块有没有加载"。

---

##### 问题 2.1.6 — `cmd_get_by_inode()` 修复 2.1.1/2.1.2 时引入锁顺序反转（潜在 ABBA 死锁）

**现象**：在修复问题 2.1.1（RCU 睡眠）和 2.1.2（comm 裸读）的过程中，Worker 在 [cmd_get_by_inode()](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L428-L465) 匹配命中分支里，**在持有 `files->file_lock` spinlock 的情况下再次调用 `task_lock(task)`**：

```c
spin_lock(&files->file_lock);           // L428 先拿 file_lock
for (fd = 0; fd < fdt->max_fds; fd++) {
    ...
    if (match) {
        char comm[TASK_COMM_LEN];
        task_lock(task);                // L461 ← 在持有 file_lock 时嵌套拿 task_lock
        memcpy(comm, task->comm, TASK_COMM_LEN);
        task_unlock(task);
        spin_unlock(&files->file_lock); // L465
        rcu_read_unlock();
        ...
    }
}
```

而同文件 [net_delayacct_iter_task_sockets()](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L294-L304) 的锁顺序是**先 task_lock，拿 files 引用后立即 task_unlock，再拿 file_lock**，完全相反。

**为什么是问题**：
- Linux 内核 spinlock 的锁顺序必须全局一致，否则会发生 ABBA 死锁。
- `task_lock(task)`（即 `spin_lock(&task->alloc_lock)`）和 `files->file_lock` 都是 spinlock，内核中其他常见路径（procfs 遍历、ptrace、cgroup 文件读取、`/proc/<pid>/fd` 读取等）普遍采用"先 task_lock 拿 task 引用 → 再遍历 files"的顺序（因为 files_struct 从属于 task）。
- 本路径采用反向顺序：先拿 file_lock → 再 task_lock。如果并发场景下：
  - CPU A 走 `iter_task_sockets`/procfs 路径：持有 task_lock，等待 file_lock
  - CPU B 走 `cmd_get_by_inode` 路径：持有 file_lock，等待 task_lock
  - 两个 CPU 互相持有对方等待的锁，永久自旋 → 死锁。
- 这不是"可能有问题"，而是明确的 lock ordering rule violation。

**触发条件**：
- 并发执行 `get_sockdelays -i <inode>` 查询，同时系统中存在 procfs 读 fd 目录、ptrace、cgroup 等持 task_lock 遍历 files 的操作。
- 平时单机测试很难触发，但生产环境高并发下具备触发条件。

**后果**：
- 双 CPU 死锁 → RCU stall → 内核软死锁 → 节点 hung。
- 和问题 2.1.1 的"scheduling while atomic"属于同一严重级别：平时不炸，炸就是灾难性的。

**修法**：把 comm 拷贝前移到 L420-L424 拿 files 引用的那个 `task_lock` 临界区内，一次加锁同时完成"拿 files 引用 + 拷贝 comm"，不在 file_lock 内嵌套 task_lock。例如：

```c
char comm[TASK_COMM_LEN];  // 提前声明在循环外

task_lock(task);
files = task->files;
memcpy(comm, task->comm, TASK_COMM_LEN);  // 顺便拷贝 comm
if (files) atomic_inc(&files->count);
task_unlock(task);

// 之后拿 file_lock、遍历 fd，匹配时直接用已拷贝好的 comm
```

**为什么这么修**：
- 消除锁序反转，与 `iter_task_sockets()` 保持一致顺序（task_lock → file_lock）。
- 不增加额外的锁操作次数，反而减少了一次 task_lock/task_unlock 配对。
- comm 只需要拷贝一次（在循环外），匹配命中时直接用即可。

---

### 2.2 设计合理性 (7/10)

#### 优点
- 以 Generic Netlink 暴露 per-socket 统计结果，整体接口形态是合理的。
- 通过 [run-tests.sh](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh) 与 [ci.yml](file:///home/lai/Code/NET_DELAYACCT/.github/workflows/ci.yml) 形成"构建-启动-QEMU 内验证"的工程闭环。
- 用户态工具和内核模块的职责边界较清楚：内核只暴露 totals/counts，平均值交给用户态计算。

#### 问题

| # | 严重度 | 问题描述 | 建议 | Worker反馈 |
|---|--------|----------|------|-------------|
| 1 | 高 | 见下文「问题 2.2.1」 | 见下文 | 已修复 |
| 2 | 高 | 见下文「问题 2.2.2」 | 见下文 | 已修复 |
| 3 | 高 | 见下文「问题 2.2.3」 | 见下文 | UAF部分共识已修复，GSO时间戳方向问题重开 |
| 4 | 中 | 见下文「问题 2.2.4」 | 见下文 | 已修复（删fallback） |

##### 问题 2.2.1 — `netnsok = true` 与全局 `for_each_process()` 矛盾

**现象**：[genl_family](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L89-L99) 设了 `.netnsok = true`，告诉 genl 框架"这个 family 支持网络命名空间隔离"。但 [cmd_get_by_inode()](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L439-L499) 和 [cmd_reset()](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L511-L548) 都用 `for_each_process(task)` 遍历**全系统所有进程**，没有任何 netns 过滤。

**为什么是问题**：
- `netnsok = true` 等于向用户态承诺"你从任意 netns 都能查，并且只能看到自己 netns 的东西"。
- 实际实现是"你从任意 netns 都能查，但能看到全系统所有进程的 socket"。
- 这两件事**语义不一致**，属于接口契约违例。
- 在容器场景下，这就是信息泄漏：容器内 root 用 `get_sockdelays -i <inode>` 能看到宿主机进程的 socket 五元组。

**触发条件**：任何容器/命名空间环境下使用本工具。

**后果**：
- 信息泄漏（容器逃逸式信息收集）。
- `reset` 命令更严重——容器内 root 调一次 reset，会把宿主机所有 socket 的统计清零，影响其他容器的监控数据。

**修法**：二选一。
- 方案 A（已达成共识）：保留 `netnsok = true`，在 `for_each_process` 循环里加 `nsproxy` NULL 检查 + netns 过滤；`cmd_reset()` 同步修正；`cmd_get_by_pid()` 在按 `find_vpid` 解决 pidns 语义后，再补一层 task netns 一致性检查。
- 方案 B（保守）：去掉 `.netnsok = true`，让 family 只在 init netns 可见。

**为什么这么修**：接口语义必须和实现一致，这是基础工程纪律。当前 Worker 已明确产品定位是"容器内可用的诊断工具"，因此采纳方案 A 最符合产品目标。

---

##### 问题 2.2.2 — `find_get_pid` 与 PID 命名空间语义

**现象**：[cmd_get_by_pid()](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L387-L421) 在 [L403](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L403) 用 `find_get_pid(pid)` 解析用户传入的 pid。

**为什么是问题**：
- `find_get_pid(pid)` 在**当前进程的 PID 命名空间**解析 pid，但它的语义偏向"按 init namespace 解释"——具体行为依赖内核版本。
- 容器内用户用 `ps` 看到的 pid 是 vpid（容器内 pid），用户把这个 vpid 传给工具，工具再交给内核，内核是否认得这个 vpid，取决于 helper 选择。
- 应该用 `find_vpid(pid)` + `get_pid_task()`，它们会按调用者的 PID namespace 正确解释。

**触发条件**：容器场景下用 `get_sockdelays -p <pid>`。

**后果**：
- 容器内传入 vpid，内核按 init namespace 找不到对应 task，返回 `-ESRCH`，工具报"no such process"。
- 用户感受是"工具坏了"，但其实是语义没对齐。

**修法**：`pidp = find_vpid(pid);` 然后继续 `task = get_pid_task(pidp, PIDTYPE_PID);`。

**为什么这么修**：`find_vpid` 是为"按调用者 PID namespace 解释"设计的；`find_get_pid` 的语义在容器场景下含糊。这是 PID namespace 处理的标准范式。

---

##### 问题 2.2.3 — TX 路径统计语义不扎实

**现象**：[tx_start](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/include-net-net-delayacct.h#L84-L87) 在 `tcp_sendmsg_locked` 给新分配的 skb 打时间戳；[tx_end](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L596-L613) 在 `dev_hard_start_xmit` 读 `skb->sk` 并累加。

**为什么是问题**：两个子问题都没闭环。

**(a) GSO 分段**：一个 GSO skb 在 `dev_hard_start_xmit` 里会被 `tcp_gso_segment` 拆成 N 个子 skb。父 skb 的 `delayacct_start` 不会自动复制到子 skb，所以只有"父 skb 这一次"被记账，子 skb 的 `tx_end` 看到的是 `delayacct_start == 0`，直接 return。结果是 10 Gbps 大包场景下，1 个 send 实际只计 1 个样本，统计严重失真。

**(b) `skb->sk` 生命周期**：从 `tcp_sendmsg_locked` 到 `dev_hard_start_xmit` 之间，skb 会经过 qdisc、可能被 `skb_orphan()` 把 `skb->sk` 置 NULL（这是 socket close 时的保护）。但**没有契约保证**所有路径都会 orphan——也存在 skb 没被 orphan、但对应 sock 已经 `close()` + `sock_put()` 释放的情况。这时 `tx_end(skb->sk, skb)` 读到的 `sk` 是悬垂指针，[L602](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L602) 的 `if (!sk) return` 防不住 UAF。

**触发条件**：
- (a) 任何 GSO 大包传输。
- (b) 高并发短连接 + qdisc 排队 + socket 快速关闭。

**后果**：
- (a) TX 统计数字与实际包数比例严重失真，监控数据不可信。
- (b) UAF，可能 oops。

**修法**（重开后最终共识）：
- (a) ~~在 GSO 拆分时，子 skb 已通过 `__copy_skb_header` 自动继承父 skb 的 `delayacct_start`，无需额外代码，统计粒度正确。~~
  - **代码核查发现此说法不成立**，(a) 子问题需重开：
  - `__copy_skb_header` 是逐字段复制，不会自动拷贝新增的 `delayacct_start` 字段（patch 集中没有修改 `__copy_skb_header` 的 patch）；
  - [tx-instrumentation.patch#L31-L33](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/tx-instrumentation.patch#L31-L33) 中的手动继承代码方向反了（从 `skb->next` 复制而非从父/prev 复制），且条件 `skb_is_gso(skb) && !skb->delayacct_start` 永远不成立（GSO 大包已在 tx_start 打戳，子段不再是 GSO skb），是死代码；
  - 软件 GSO 递归调用 `dev_hard_start_xmit()` 遍历 segs 时，每个 segment 的 `delayacct_start == 0`，tx_end 直接 return，仍然只记 1 次样本。
  - **待 Worker 确认 `__copy_skb_header` 的行为并修正继承逻辑**。
- (b) **不做任何额外的 `sock_hold()`/`sock_put()`**。依赖内核网络栈既有的生命周期保证：TCP/UDP 在分配 skb 时通过 `skb_set_owner_w` / `tcp_skb_entail` 设置 `skb->destructor = sock_wfree`，`sock_wfree` 在 skb 释放时递减 `sk->sk_wmem_alloc`，而 `__sk_destruct` 只有在 `sk_wmem_alloc` 归零时才会真正释放 socket。因此在 `dev_hard_start_xmit` 统计点（skb 递交给驱动之前），skb 仍然持有 wmem 引用，`skb->sk` 必然有效，不存在 UAF 风险。sock_hold/sock_put 已移除，此部分共识成立、修复正确。
- 代码中保留详细注释解释这个设计决策，避免后续维护者重复引入 `sock_hold/sock_put` 导致 GSO 场景下 refcount 失衡崩溃。

**为什么这么修**：
- 上一轮建议的"`sock_hold` + 生命周期终点 `sock_put`"方案在静态分析层面看似合理，但实际在 GSO 场景下会立即触发 NULL deref：`skb_segment()` 会复制 `skb->sk` 指针给 N 个子段，但不会对称增加 `sk_refcnt`，导致 N 次 `sock_put` 对应 1 次 `sock_hold`，refcount 过度递减、socket 被提前释放。
- 依赖既有的 `sk_wmem_alloc` 机制是内核网络栈的标准做法，零额外开销、零侵入性、天然兼容所有 skb 生命周期路径（正常发送、drop、重路由等），比自定义引用计数方案更可靠。
- 13/13 QEMU 全量测试通过，无崩溃，验证了 UAF 修复（b）的正确性；但测试未覆盖软件 GSO 场景下的计数精度，(a) 仍需修复。

---

##### 问题 2.2.4 — KUnit 测试位置与风格偏离

**现象**：KUnit 测试放在 [tests/selftests/net-delayacct/kunit/](file:///home/lai/Code/NET_DELAYACCT/tests/selftests/net-delayacct/kunit/net-delayacct-test.c)，并且自己写了 `KUNIT_DEFINE_TEST_SUITE` 的 fallback 宏（[L32-L39](file:///home/lai/Code/NET_DELAYACCT/tests/selftests/net-delayacct/kunit/net-delayacct-test.c#L32-L39)）。

**为什么是问题**：
- KUnit 和 selftests 是内核里**两套独立的测试框架**，不应混放。
- 内核惯例是 KUnit 测试放在被测代码旁边（如 `net/core/net-delayacct-test.c`），在 `lib/Kconfig.kunit` 注册 `CONFIG_NET_DELAYACCT_KUNIT_TEST`。
- 6.6 内核已经有 `KUNIT_DEFINE_TEST_SUITE` 宏，fallback 是死代码。

**触发条件**：长期维护时，尤其是项目进入 upstream 化阶段时。

**后果**：上游 reviewer 一眼挑出"测试布局不对"，影响接收。

**修法**：分阶段处理。
- 当前阶段（已达成共识）：立即删除 fallback 宏；现有 out-of-tree 目录布局可暂时保留。
- 若以 upstream 为目标：后续必须把测试文件移到 `net/core/` 下，并在 `lib/Kconfig.kunit` 注册。

**为什么这么修**：这一条的核心不是"现在目录名不好看"，而是"当前 out-of-tree 便利性"与"未来 upstream 规范"之间需要阶段性取舍。先删死代码，再把路径迁移作为 upstream 化改造项，符合当前工程阶段。

---

### 2.3 测试覆盖 (7/10)

#### 优点
- [run-tests.sh](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh) 测试展示性强，包含原理、实现、断言、实际工具输出，便于人工审查与答辩。
- [ci.yml](file:///home/lai/Code/NET_DELAYACCT/.github/workflows/ci.yml) 不只做构建，还做 QEMU 启动和工具级验证。
- 覆盖了 PID 查询、inode 查询、reset、JSON、debug、并发/流量场景等常见正向路径。

#### 问题

| # | 严重度 | 问题描述 | 建议 | Worker反馈 |
|---|--------|----------|------|-------------|
| 1 | 高 | 见下文「问题 2.3.1」 | 见下文 | 共识-v2.0先netns，v2.1补剩余 |
| 2 | 中 | 见下文「问题 2.3.2」 | 见下文 | 接受 |
| 3 | 中 | 见下文「问题 2.3.3」 | 见下文 | 接受 |
| 4 | 低 | 见下文「问题 2.3.4」 | 见下文 | 共识-v2.1延期处理 |

##### 问题 2.3.1 — 测试没有覆盖最危险的 correctness 路径

**现象**：当前测试覆盖了"工具能不能查到 socket"这类正向功能，但没有覆盖这轮 review 发现的高风险问题。

**为什么是问题**：
- RCU 临界区睡眠（问题 2.1.1）只在内存压力下触发，当前测试永远不会触发。
- netns 隔离（问题 2.2.1）需要容器场景，当前测试在单一 init netns 跑。
- TX GSO（问题 2.2.3 a）需要 iperf3 大包 + 抓包对比 count，当前测试只断言"有数据"。
- UAF（问题 2.2.3 b）需要并发短连接 + 内存压力，当前测试不触发。

测试很多，但**没测到点上**——这就是为什么最危险的问题靠 review 静态发现，而不是测试暴露。

**触发条件**：长期维护。

**后果**：回归保护不足，下次重构容易把已知 bug 重新引入而不自知。

**修法**：分两轮推进。
- v2.0.x：先补 **netns 隔离测试**，在新建 netns 里跑 `get_sockdelays`，验证看不到 init netns 的 socket。这一项实现最简单，也最直接覆盖问题 2.2.1 的修复。
- v2.1.0：再补 **fault-injection**（验证 RCU 路径在内存压力下不睡眠）和 **iperf3 GSO 统计对比**（验证 GSO 子段都被记）。

**为什么这么修**：这条问题没有被撤回，仍然成立；只是实施计划按工程优先级拆成两轮。测试的价值不在于"证明功能能用"，而在于"防止已知风险回归"。

---

##### 问题 2.3.2 — KUnit 并发测试的线程控制不干净

**现象**：[net-delayacct-test.c#L191-L223](file:///home/lai/Code/NET_DELAYACCT/tests/selftests/net-delayacct/kunit/net-delayacct-test.c#L191-L223) 里，工作线程 `atomic_dec(&ctx->remaining); return 0;` 退出，主线程 `while (atomic_read(&ctx->remaining) > 0) fsleep(1000);` 等所有线程退出后，再 `kthread_stop(tasks[i])`。

**为什么是问题**：
- `kthread_stop()` 的语义是"请求线程退出并 join"。如果线程已经 `return 0` 退出了，再 `kthread_stop` 会触发 `kernel/kthread.c` 的 warning（"kthread_stop called on already exited thread"）。
- 标准范式是：线程循环 `while (!kthread_should_stop()) { ... }`，主线程 `kthread_stop` 后 join。

**触发条件**：每次跑并发测试。

**后果**：dmesg 里会出现 warning，污染测试输出，长期可能演变成"狼来了"——真有 warning 时被忽略。

**修法**：线程改成 `for (i = 0; i < ITERS && !kthread_should_stop(); i++) { ... }`，主线程去掉 `while` 轮询，直接 `for (i = 0; i < N; i++) kthread_stop(tasks[i]);`。

**为什么这么修**：`kthread_stop` 本身就是 join 原语，不需要额外轮询；让线程主动检查 `kthread_should_stop` 是 kthread API 的标准用法。

---

##### 问题 2.3.3 — KUnit 用 stub sock/skb，证明力有限

**现象**：[net-delayacct-test.c#L46-L68](file:///home/lai/Code/NET_DELAYACCT/tests/selftests/net-delayacct/kunit/net-delayacct-test.c#L46-L68) 用 `kunit_kzalloc(sizeof(*sk))` 分配一个全零的 `struct sock`，只测其中 `sk_net_delayacct` 字段。

**为什么是问题**：
- 真实 `struct sock` 有 ~440 字节，需要 `sock_init_data()` 完整初始化才能正常工作。
- 全零 stub 只能测纯逻辑（累加、reset），测不出"真实协议栈里的并发/上下文问题"。
- 让 stub 测试承担 correctness 证明责任，是过度信任它。

**触发条件**：永远。

**后果**：单元测试 PASS，但真实场景下的 bug（如 RCU 睡眠）照样过不了。

**修法**：区分两类测试：
- 纯逻辑测试：直接 `kunit_kzalloc(sizeof(struct net_delayacct))` 测累加/reset，不需要 sock。
- 集成测试：用 `sock_init_data()` 真正初始化一个 sock，更接近真实场景。

**为什么这么修**：明确测试边界，不让 stub 测试假装覆盖了它覆盖不了的东西。

---

##### 问题 2.3.4 — `run-tests.sh` 演化为复杂框架

**现象**：[run-tests.sh](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh) 已经是一个大型 shell 脚本，包含原理说明、实现说明、断言、输出美化、统计、盒子绘制等多个层次。

**为什么是问题**：
- 测试脚本本身复杂度开始接近"小框架"，维护成本上升。
- 失败时定位"是测试脚本错了还是被测对象错了"变难。

**触发条件**：长期维护、新增用例时。

**后果**：测试脚本演化为"第二份代码"，需要同等审查力度。

**修法**：把"展示逻辑"（盒子、原理说明、输出美化）和"断言逻辑"（PASS/FAIL 判定）拆开，前者可以放到 helper，后者保持简洁。

**为什么这么修**：测试的可信度取决于"测试本身是否简单到不会出错"。但这一项当前不是阻塞问题，已和 Worker 达成共识：延后到 v2.1 再处理。

---

### 2.4 文档/日志质量 (6/10)

#### 优点
- 工程内有设计文档、RST 文档、CI 脚本、测试脚本，说明作者有记录意识。
- 文档覆盖了概念、接口、工具、测试等多个层面，材料完整性较好。

#### 问题

| # | 严重度 | 问题描述 | 建议 | Worker反馈 |
|---|--------|----------|------|-------------|
| 1 | 高 | 见下文「问题 2.4.1」 | 见下文 | 已修复 |
| 2 | 高 | 见下文「问题 2.4.2」 | 见下文 | 已修复 |
| 3 | 中 | 见下文「问题 2.4.3」 | 见下文 | 已修复-未完全（sed残留） |
| 4 | 中 | 见下文「问题 2.4.4」 | 见下文 | 已修复 |
| 5 | 高 | 见下文「问题 2.4.5」 | 见下文 | 待回应 |

##### 问题 2.4.1 — RST 文档与实际 CLI 漂移

**现象**：[Documentation/networking/net-delayacct.rst#L252-L312](file:///home/lai/Code/NET_DELAYACCT/Documentation/networking/net-delayacct.rst#L252-L312) 描述的 CLI、输出格式、reset 语义，与 [get_sockdelays.c](file:///home/lai/Code/NET_DELAYACCT/userspace/get_sockdelays/get_sockdelays.c) 的实际实现不一致。

**为什么是问题**：
- RST 文档是面向用户的"接口契约"。文档说 `-r` 是 reset，实际是 `-R`；文档说默认微秒，实际是毫秒——用户照文档用一定出错。
- 文档漂移说明项目"实现了改、改了没回写文档"，长期积累会让文档从资产变成负担。

**触发条件**：任何用户照文档使用工具时。

**后果**：用户体验差，且 reviewer 会怀疑"作者自己有没有跑过这套文档"。

**修法**：以 [get_sockdelays.c#L46-L73](file:///home/lai/Code/NET_DELAYACCT/userspace/get_sockdelays/get_sockdelays.c#L46-L73) 的 `usage()` 为准，重写 RST 的 Usage/Output/Options 三节，并粘贴一段真实输出作为样例。

**为什么这么修**：文档的事实来源必须是代码；任何文档与代码不一致，以代码为准并回写文档。

---

##### 问题 2.4.2 — design.md 保留已失效字段

**现象**：[docs/design.md#L172-L235](file:///home/lai/Code/NET_DELAYACCT/docs/design.md#L172-L235) 仍描述 `struct net_delayacct` 包含 `rx_start/tx_start/rx_pending/tx_pending` 字段。但 [include-net-net-delayacct.h#L20-L33](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/include-net-net-delayacct.h#L20-L33) 已经简化为只有 `lock + stats`。

**为什么是问题**：
- design.md 是设计规范文档，应该和实现对齐。
- 保留已删字段会让新读者以为"这些字段还在"，基于错误前提做扩展设计。

**触发条件**：任何基于 design.md 的二次开发。

**后果**：误导后续工作。

**修法**：明确 design.md 定位——是"当前实现规范"还是"设计演进历史"。
- 若是规范：删除已失效字段，回写为 `lock + stats`。
- 若是历史：在文档顶部加 `> 注：本文档保留历史设计记录，当前实现以代码为准` 标注。

**为什么这么修**：文档定位不清是文档腐烂的根源；先定位，再处理。

---

##### 问题 2.4.3 — patch 系列不自洽，CI 用 `sed` 热改内核

**现象**：[ci.yml#L141-L147](file:///home/lai/Code/NET_DELAYACCT/.github/workflows/ci.yml#L141-L147) 里有一段：

```sh
sed -i 's/sk_tx_queue_clear(sk);/sk_tx_queue_clear(sk);\n\tnet_delayacct_init(\&sk->sk_net_delayacct);/' \
  "$LINUX_SRC/net/core/sock.c"
```

**为什么是问题**：
- 这说明 `sock.c` 里"调用 `net_delayacct_init`"这段修改**没有体现在 patch 系列里**。
- 上游 patch 流程要求：所有修改都用 `git format-patch` 风格的标准 patch 表达，包括新增文件用 `--- /dev/null` 形式。
- 用 `sed` 在 CI 里热改源码，意味着 `kernel-patches/*.patch` 不是自洽的——别人拿走 patch 不会得到相同结果。

**触发条件**：任何尝试用 patch 集复现环境的人。

**后果**：patch 集无法独立交付，必须配 CI 脚本才能跑通；上游接收不可能。

**修法**：新增一个 `0001-sock-init-net-delayacct.patch`，把 `sock.c` 的修改正式纳入 patch 系列。删除 CI 里的 `sed` 步骤。

**为什么这么修**：patch 自洽是 upstream 接收的硬性要求；CI 不应该承担"补 patch 漏洞"的职责。

---

##### 问题 2.4.4 — 作者身份信息不统一

**现象**：
- [net-core-net-delayacct.c#L2](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L2) `Copyright (c) 2026 h1y2g3l4y5`
- [L660](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L660) `MODULE_AUTHOR("h1y2g3l4y5 <h1y2g3l4y5@example.com>")`
- patch 文件里 `Signed-off-by: laiguo-liang <2909269677@qq.com>`

三处身份不一致。

**为什么是问题**：
- `submitting-patches.rst` 要求真实姓名 + 可联系邮箱。
- 匿名 handle（`h1y2g3l4y5`）和占位邮箱（`@example.com`）不通过上游审查。
- 三处不一致会让 reviewer 怀疑"作者身份到底是谁"。

**触发条件**：投上游时。

**后果**：上游接收受阻。

**修法**：统一为真实姓名 + 真实邮箱，三处（Copyright、MODULE_AUTHOR、Signed-off-by）一致。

**为什么这么修**：身份一致性是上游接收的基本要求；也是版权追溯的需要。

---

##### 问题 2.4.5 — 0007 patch 未同步导致 CI 构建产物仍含锁序 bug

**现象**：TASK-06 修复了锁序反转（问题 2.1.6）和 GSO 时间戳继承（问题 2.2.3(a)），standalone 文件 [net-core-net-delayacct.c](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c#L421-L426) 中锁序修复已正确落地。但 [0007-net-core-add-module.patch](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/0007-net-core-add-module.patch#L486-L491) 中嵌入的 `net/core/net-delayacct.c` 代码仍是修复前的旧版本——在持有 `files->file_lock` 时嵌套 `task_lock(task)` 拷贝 comm，锁序反转 bug 仍然存在。

**为什么是问题**：
- CI（[ci.yml#L136-L139](file:///home/lai/Code/NET_DELAYACCT/.github/workflows/ci.yml#L136-L139)）和 local-test.sh（[L89-L116](file:///home/lai/Code/NET_DELAYACCT/local-test.sh#L89-L116)）的构建流程是 `glob` 遍历 `kernel-patches/*.patch` 并用 `git apply`/`patch` 逐个应用。
- 0007 patch 通过 `create mode 100644` 从 `/dev/null` 创建 `net/core/net-delayacct.c`，应用后内核树中的该文件内容完全由 0007 的嵌入代码决定。
- 后续的 patch（skbuff_h-modification.patch、tx-instrumentation.patch 等）只修改 skbuff.h 和网络栈文件，不会更新 net/core/net-delayacct.c。
- 因此，**CI 从 clean tree 构建出的内核，net/core/net-delayacct.c 仍是旧版代码，锁序 bug 并未被修复**。standalone 文件的修复形同虚设。
- 同样的问题也存在于 0006 patch（include/net/net-delayacct.h），虽然注释差异不影响功能，但表明"standalone 文件作为 source of truth"和"numbered patches 作为构建输入"之间存在同步断层。

**触发条件**：
- 任何 CI clean build（GitHub Actions 每次都是 clean checkout + fresh clone）
- 用户按 README 描述的手动 cp 流程不会触发此问题（因为直接 cp standalone 文件），但按 patch 流程构建的都会触发

**后果**：
- CI 构建通过但产物包含已知 bug（锁序反转 → 潜在 ABBA 死锁）
- "修复已验证"的结论是基于 standalone 文件审查，而非实际构建产物审查
- 这和问题 2.4.3（CI sed 热改内核源码）是同类问题的复发：patch 交付链不自洽，standalone 文件与 numbered patches 不同步

**修法**：从当前 standalone 文件重新生成 0007-net-core-add-module.patch（必要时也重新生成 0005、0006），确保 patch 嵌入内容与 standalone 完全一致。同时删除 local-test.sh 中残留的 sed 行（L112-113），与 CI 流程统一。

**为什么这么修**：之前修复 2.4.3 时已经确立原则——"所有修改都必须体现在 patch 中，不能依赖 CI sed 或 standalone 文件未同步"。这个原则同样适用于反向：standalone 文件改了，对应的新建文件 patch 必须同步重新生成。patch 交付链必须自洽——"patch apply 后的内核树"应该等于"standalone 文件 + 修改 patch 应用后的结果"。

---

## 三、突出问题总结

### 严重问题（必须修复）
1. **问题 2.1.1**：RCU 临界区内构造 netlink reply，可能睡眠 → **已修复**（reply 移到 RCU 外）。
2. **问题 2.1.2**：`task->comm` 裸读 → **已修复**（在 task_lock 内 memcpy 到局部 buf）。
3. **问题 2.1.6**：cmd_get_by_inode 锁序反转 → **修复逻辑正确但 0007 patch 未同步（问题 2.4.5），CI 构建仍含 bug，待重新生成 patch**。
4. **问题 2.2.1**：`netnsok = true` 与全局遍历矛盾 → **已修复**（加 netns 过滤）。
5. **问题 2.2.2**：PID namespace 语义含糊 → **已修复**（改用 find_vpid）。
6. **问题 2.2.3(b)**：sk->sk 生命周期 UAF → **已修复**（移除 sock_hold/sock_put，依赖 sk_wmem_alloc）。
7. **问题 2.2.3(a)**：GSO 时间戳继承逻辑方向反/死代码 → **已修复**（delayacct_start 移入 headers struct_group，死代码已删；skbuff_h-modification.patch 和 tx-instrumentation.patch 已同步）。
8. **问题 2.4.3**：patch 系列不自洽（CI sed 热改）→ **已修复**（0010 patch 已加）但 local-test.sh 仍残留 sed 行（待清理）。
9. **问题 2.4.5**：0007 patch 未同步，CI 构建产物仍含锁序 bug → **待修复（阻塞闭环）**。

### 改进建议（建议采纳）
1. **问题 2.1.3**：`sock_from_file_safe` 收敛到 `sock_from_file` → **已修复**（改为 wrapper 调 sock_from_file）。
2. **问题 2.1.4**：去掉 `__ro_after_init` → **已修复**。
3. **问题 2.2.4 + 2.3.2 + 2.3.3**：KUnit 测试布局、线程控制、stub 使用 → **部分修复**（fallback 宏已删，kthread_should_stop 已加，布局延后）。
4. **问题 2.1.5**：清理热路径调试日志 → **已修复**。

### 优化建议（可选）
1. **问题 2.4.1 + 2.4.2**：文档统一回写，明确文档定位 → **已修复**（-r→-R 已改，design.md 已更新）。
2. **问题 2.3.4**：测试脚本拆分展示层与断言层 → 延后至 v2.1。
3. **问题 2.4.4**：统一身份信息 → **已修复**（MODULE_AUTHOR 已统一）。
4. 后续如追求性能，评估 per-cpu / 无锁统计方案。

---

## 四、踩坑点评

- **闭环能力较强**：从测试脚本与 CI 可以看出，作者遇到过真实环境问题（KVM/TCG 回退、nc 监听行为、initramfs busybox 符号链接等），并主动把验证链路补上了。这种"不停在本地能跑"的意识是明显优点。
- **语义边界收敛不足**：当前最明显的问题不是"不会写代码"，而是接口承诺（netnsok）、命名空间（pid/netns）、锁上下文（RCU/comm）、生命周期（skb->sk）这些边界没有完全统一。这是内核工程从"能工作"走向"能维护"的常见门槛。
- **文档演进跟不上实现演进**：design.md 和 RST 都说明项目经历过多轮迭代，但回写动作不足，文档开始从资产变负担。
- **测试数量不等于 correctness 证明强度**：当前测试很多，但最危险的问题靠 review 静态发现，说明测试策略需要重新聚焦高风险点。

---

## 五、总体评价

整体来看，这不是一个"拼凑出来能跑"的工程，而是一个已经具备工程意识的内核方向项目。工具链、QEMU 测试、CI、输出展示等部分说明作者具备把功能落地为"可验证成果"的能力。

但从 Reviewer 角度，当前状态仍不能定义为"可放心交付"：主功能已经证明可行，但 **patch 交付链自洽性** 仍是反复出现的短板——standalone 文件作为开发时的 source of truth 修改了，却忘记同步重新生成对应的 numbered patch，导致 CI clean build 出的内核仍然带着已"修复"的 bug。

换句话说：
- 以课程/实验项目标准看：这是一个偏强的工程；
- 以长期维护或接近上游标准看：当前还处在"修复逻辑正确但交付链不自洽"的阶段，需要在流程上确保"改了代码 → patch 同步 → clean build 验证"三步缺一不可。

---

## 六、下版本关注点

- **问题 2.4.5（P0，阻塞）**：重新生成 0007-net-core-add-module.patch（从当前 standalone net-core-net-delayacct.c），确保 CI clean build 中 net/core/net-delayacct.c 包含锁序修复和更新后的注释；同时清理 local-test.sh 残留 sed 行。
- **Patch 同步流程建议**：每次修改 standalone 文件后，必须重新生成对应的 numbered patch；建议在 CI 或 pre-commit 中加一步校验：clean build 后提取 net/core/net-delayacct.c 与 standalone 文件 diff，确认无差异。
- 0007 patch 同步完成 + CI clean build QEMU 测试全 PASS 后，v2.0.0 可正式闭环（17/17 议题解决）。

---

**[复审中-发现patch同步问题]**
- Worker 已完成 TASK-02（16 个修复项）+ TASK-03（2.2.3 重开：移除 sock_hold/sock_put）+ TASK-04（patch 同步修复 put_pid 崩溃）+ TASK-05（TX 测试断言修复）+ TASK-06（2.1.6 锁序 + 2.2.3(a) GSO headers group 修复），本地 QEMU 13/13 全 PASS。
- Round 2 代码核查结果：
  1. **议题 7（GSO 时间戳继承）✅ 修复正确**：delayacct_start 移入 headers struct_group，__copy_skb_header 自动 memcpy；tx-instrumentation.patch 死代码已删除；skbuff_h-modification.patch 和 tx-instrumentation.patch 均已同步更新。
  2. **议题 6（锁序反转）⚠️ 逻辑正确但 patch 未同步**：standalone net-core-net-delayacct.c 中 comm 拷贝已移入初始 task_lock 临界区，消除 ABBA 风险——但 **0007-net-core-add-module.patch 未重新生成**，其中嵌入的代码仍是修复前版本，CI clean build 出的内核仍含锁序 bug（问题 2.4.5，阻塞闭环）。
  3. **附加问题**：local-test.sh L112-113 仍残留 sed 插入 net_delayacct_init 的命令，与问题 2.4.3 的修复目标不完全一致。
- 17 个议题中 16 个修复逻辑已确认正确，唯一阻塞项是问题 2.4.5（0007 patch 同步）。Worker 需重新生成 0007 patch 并验证 CI clean build 后才能闭环。


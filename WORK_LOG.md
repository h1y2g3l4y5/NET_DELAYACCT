# NET_DELAYACCT 工作日志

---

## 2026-07-20

### 任务概述
搭建并调试 QEMU 自动化测试流程：`poll-and-test.sh` 脚本拉取最新代码 → 编译内核 → 编译用户态工具 → QEMU 启动测试 → 收集结果。

### 遇到的问题及解决方案

**1. poll-and-test.sh 路径硬编码问题**
- 问题：脚本默认路径 `$HOME/linux-6.6` 等与 `setup.sh` 实际使用的 `$NETDELAY_REPO/../linux-6.6` 不一致
- 解决：`poll-and-test.sh` 改为与 `setup.sh` 相同的路径推导逻辑

**2. SCRIPT_DIR 使用前未定义**
- 问题：路径推导代码引用了 `$SCRIPT_DIR` 但定义在后面
- 解决：将 `SCRIPT_DIR` 定义移到配置区最前面

**3. 内核编译进度不可见**
- 问题：`make bzImage | tail -5` 只显示最后 5 行，编译期间看起来像卡住
- 解决：移除 `tail -5`，显示完整编译输出

**4. rmdir 权限拒绝**
- 问题：`sudo mkdir` 创建的挂载目录无法被普通用户 `rmdir` 删除
- 解决：`prepare_rootfs` 和 `extract_results` 中改为 `sudo rmdir`

**5. QEMU 内核 panic**
- 问题：`guest-init.sh` 中 `set -e` 导致 `mount -t devtmpfs` 因 /dev 已挂载而失败，init 进程退出触发 panic
- 解决：所有 mount 命令增加 `mountpoint -q` 检查，已挂载则跳过

**6. git 推送交互卡住**
- 问题：`sudo` 运行脚本时 git push 触发用户名/密码交互提示
- 解决：git 命令添加 `GIT_TERMINAL_PROMPT=0` 禁止交互，失败静默跳过

**7. genl family 检测误报**
- 问题：`/proc/net/genetlink` 文件不存在或为空，导致检测失败，但 dmesg 确认 family=28 已注册
- 解决：改用 `get_sockdelays -p 1` 实际调用验证 genl family 可用性

**8. git remote URL 被反引号污染**
- 问题：复制命令时 Markdown 代码块的反引号字符 ` 被带入 URL
- 解决：`poll-and-test.sh` 增加自动检测并修正 remote URL 逻辑

**9. 增量编译未生效**
- 问题：每次运行都完整重编内核，耗时长
- 解决：添加 `.netdelay_build_marker` 记录上次构建 commit；`.config` 存在时跳过 defconfig；只变用户态代码时不重编内核

**10. 新增 CONFIG_TASK_DELAY_ACCT 未生效**
- 问题：`kernel-qemu.config` 新增配置后 `.config` 已存在，跳过 reconfig 导致新选项不生效
- 解决：全量重置时 `rm -f .config` 强制重配置

### 已添加的功能
- QEMU 内核新增 `CONFIG_TASK_DELAY_ACCT`、`CONFIG_TASKSTATS`、`CONFIG_TASK_XACCT`、`CONFIG_TASK_IO_ACCOUNTING`
- 编译内核自带的 `tools/accounting/getdelays.c` 用户态工具并安装到 QEMU rootfs

### 待解决问题
- VMware NAT 服务不定期断连，需在 Windows 管理员命令行重启 `net stop/start "VMware NAT Service"`
- `net_delayacct` genl family 注册成功但 socket 延迟数据未采集（测试输出 `(no matching sockets)`），需排查 RX/TX instrumentation 逻辑

### 提交记录
| 提交 | 说明 |
|------|------|
| dba91e5 | fix: poll-and-test.sh use same derived paths as setup.sh |
| b65f53c | fix: define SCRIPT_DIR before using it in poll-and-test.sh |
| e7c8d85 | fix: show kernel build progress and fix rmdir permission |
| 6225c92 | fix: make mount commands idempotent in guest-init.sh |
| fcc1db7 | feat: incremental kernel build |
| 310f9da | fix: disable git interactive prompt, fix rmdir, add dmesg debugging |
| f5c6a31 | fix: improve genl family detection |
| 5db78b2 | fix: auto-fix git remote URL and verify genl via get_sockdelays |
| 60add19 | feat: enable CONFIG_TASK_DELAY_ACCT and build getdelays |
| d9cf918 | fix: require_net_delayacct_family uses get_sockdelays instead of /proc/net/genetlink |
| 44ae2f4 | feat: register GitHub self-hosted runner, add network fix script |

### GitHub Actions 自托管 Runner
- 在 VMware Linux VM 上注册了 GitHub 自托管 runner
- Runner 安装为 systemd 服务，开机自启
- 仓库 `.github/workflows/ci.yml` 已配置 `qemu-test` 任务，push 时自动触发
- 网络问题修复：切换至桥接模式获取稳定 IP (10.36.128.232)，摆脱 VMware NAT 不稳定问题
- 创建 `ci/qemu/fix-network.sh` 一键网络修复脚本
- 解决 sudo 权限问题：配置 `lai ALL=(ALL) NOPASSWD: ALL`，CI 结束后 `chown` 修复 root 文件
- Workflow 添加 `permissions: contents: write` 解决 git push 403 错误

---

## 2026-07-20（下午）— 代码 Bug 分析与修复

### 工作总结
对内核态 net-delayacct 框架的完整代码进行静态分析（涉及 4 个 patch 文件 + 3 个内核源码文件 + 用户态工具 + 测试脚本），定位 socket 延迟数据无法采集的根因，并完成 P0 级别修复。

### Bug 1（P0 / 致命）：`sk_net_delayacct` 从未被初始化

**定位文件：**
- [sock_h-modification.patch](kernel-patches/sock_h-modification.patch) — 在 `struct sock` 中嵌入了 `struct net_delayacct sk_net_delayacct`
- [include-net-net-delayacct.h](kernel-patches/include-net-net-delayacct.h#L41-L45) — 定义了 `net_delayacct_init()` 初始化函数

**根因：** `struct net_delayacct` 包含 `spinlock_t lock` 和 `struct net_delayacct_stats stats`。spinlock 必须通过 `spin_lock_init()` 初始化才能使用，stats 必须清零。但 `net_delayacct_init()` 在整个内核的 sock 分配路径（`sk_prot_alloc` / `sk_alloc` / `sock_init_data`）中从未被调用。内核通过 `kmem_cache_alloc` 分配的 sock 内存不保证清零，因此 `sk_net_delayacct.lock` 中包含随机垃圾值。后续所有 `spin_lock(&n->lock)` 操作行为未定义，tx/rx count 和 total_ns 永远为 0。

**修复方案：** 在 `net/core/sock.c` 的 `sk_prot_alloc()` 中，sock 分配成功后立即调用 `net_delayacct_init(&sk->sk_net_delayacct)`。该函数在 `CONFIG_NET_DELAYACCT=n` 时是空实现，无需 ifdef 保护。详见新增的 [sock-init-net-delayacct.patch](kernel-patches/sock-init-net-delayacct.patch)。

**影响范围：** 所有 TCP/UDP socket 的 RX/TX 延迟统计全部为 0。

---

### Bug 2（P0 / 致命）：GRO 合并导致 RX 路径 `delayacct_start` 丢失

**定位文件：**
- [rx-instrumentation.patch](kernel-patches/rx-instrumentation.patch) — RX 打点：`net_delayacct_rx_start(skb)` 在 `__netif_receive_skb_core` 入口
- [net-core-net-delayacct.c](kernel-patches/net-core-net-delayacct.c#L502-L519) — `net_delayacct_rx_end()` 中 `if (!start) return;` 提前退出

**根因：** TCP GRO（Generic Receive Offload）会在 `napi_gro_receive` → `tcp_gro_receive` 路径中将多个到达的 skb 合并为一个。被合并的原始 skb（带有 `delayacct_start` 时间戳）被 `kfree_skb` 释放掉，仅保留合并后的 GRO skb。GRO skb 的 `delayacct_start` 只继承第一个 skb 的值，后续合并进来的 skb 的时间戳全部丢失。当 `tcp_recvmsg_locked` 最终从接收队列取出 skb 调用 `net_delayacct_rx_end(sk, skb)` 时：
- 对于后续合并的包：`delayacct_start == 0` → 函数直接 return，数据丢失
- 对于第一个包：延迟测量为"第一个包到达时间"而非"当前包到达时间"，数据不准确

**设计缺陷：** 把时间戳存在 `sk_buff` 上本质上是不可靠的，因为 skb 在内核中会被 clone、merge、split、free。本框架需要的是 per-socket 级别的状态追踪，而不是 per-skb。

**影响范围：** 非 loopback 场景下（如真实网卡、virtio-net），RX 延迟数据大量丢失。loopback 场景下无 GRO，不受影响。

**待修复。**

---

### Bug 3（P1 / 重要）：Genl dump 机制设计错误

**定位文件：**
- [net-core-net-delayacct.c](kernel-patches/net-core-net-delayacct.c#L68-L84) — 所有 genl ops 都用 `.doit` 回调
- [get_sockdelays.c](userspace/get_sockdelays/get_sockdelays.c#L308-L309) — 用户态发送 `NLM_F_REQUEST | NLM_F_DUMP`

**根因：** 内核 genl 框架中，`NLM_F_DUMP`（多消息回复）应与 `.dumpit` 回调搭配使用，并配合 `netlink_dump_start` 机制。但当前代码使用 `.doit` 回调手动逐个发送多消息 + NLMSG_DONE 终结符，这不是标准的内核 dump 流程。可能引起：
- 用户态接收超时或数据不完整
- netlink 消息乱序（.doit 不走 dump 专用 socket）

**影响范围：** 多 socket 查询场景下（如 `get_sockdelays -p <pid>` 返回多个 socket），用户态可能接收到不完整的数据（部分 socket 被截断或丢失）。

**待修复。**

---

### 代码审查总结

| 组件 | 状态 | 说明 |
|------|------|------|
| `sock_h-modification.patch` | 正确 | `struct sock` 中正确嵌入了 `sk_net_delayacct` |
| `skbuff_h-modification.patch` | 正确 | `struct sk_buff` 中正确添加了 `delayacct_start` |
| `rx-instrumentation.patch` | 打点位置正确，但受 Bug2 影响 | `__netif_receive_skb_core` 入口 + `tcp/udp_recvmsg` 出口 |
| `tx-instrumentation.patch` | 打点位置正确 | `tcp_sendmsg_locked`/`udp_sendmsg` 入口 + `dev_hard_start_xmit` 出口 |
| `net-core-net-delayacct.c` | 逻辑正确 | genl family 注册、sock 遍历、netlink 回复均正确 |
| `net_delayacct_rx_end()` | 受 Bug1+Bug2 影响 | spinlock 未初始化 + GRO 丢失时间戳 |
| `net_delayacct_tx_end()` | 受 Bug1 影响 | spinlock 未初始化 |
| `net_delayacct_get_stats()` | 受 Bug1 影响 | spinlock 未初始化 |
| `get_sockdelays.c` | 正确 | 用户态 netlink 通信逻辑正确 |

### 提交记录
| 提交 | 说明 |
|------|------|
| (待提交) | fix: add net_delayacct_init() call in sk_prot_alloc (Bug1) |

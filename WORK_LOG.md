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

**11. Trae Agent SSH 远程连接后卡在"正在分析问题"**
- 问题：Trae IDE 通过 SSH Remote 连接 VM（桥接模式 IP 10.36.128.232），使用 Agent 功能时一直卡在"正在分析问题"
- 排查：VM 内 `ai-agent` 进程已运行但无响应，最初怀疑内存不足（VM 仅 3.8 GB，Trae 相关服务占用约 930 MB）
- 根因：**DNS 不通**。桥接模式 DHCP 下发网关 `10.36.128.196` 作为 DNS 服务器，但该网关不提供 DNS 服务，导致 `systemd-resolved`（127.0.0.53）所有 DNS 请求超时。Agent 需要解析 AI 服务域名，DNS 超时导致卡死
- 解决：临时观察到 DNS 恢复（网关可能间歇性响应），永久方案是将 `/etc/resolv.conf` 改为静态公共 DNS：
  ```bash
  sudo rm /etc/resolv.conf
  echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf
  echo "nameserver 114.114.114.114" | sudo tee -a /etc/resolv.conf
  sudo chattr +i /etc/resolv.conf
  ```

---

## 2026-07-21

### 任务概述
解决 CI 流程中 QEMU 测试阶段挂死、无法到达 Step 7（提取测试结果）的问题，修复 get_sockdelays netlink 通信协议不匹配问题。

---

### 问题 1：CI 卡在 QEMU 启动阶段，永远走不到 Step 7

#### 现象
CI 输出停在 QEMU 内核启动日志处，后续没有任何输出，`========== TEST RESULTS ==========` 从未出现。这意味着 `ci-test.sh` 的 Step 6（`timeout 300 qemu-system-x86_64 ...`）没有正常退出，或退出后脚本异常终止。

#### 根因与执行链分析

**ci-test.sh 依赖链**：
```
ci-test.sh Step 6: timeout 300 qemu-system-x86_64 ...
    └── QEMU 启动，init=/sbin/qemu-init
        └── guest-init.sh 执行
            ├── 挂载文件系统
            ├── get_sockdelays -p 1   ← 阻塞式 netlink 调用，可能挂死
            ├── 运行 test_netdelayacct.sh
            ├── 运行 func/test_*.sh
            └── poweroff -f           ← 只有走到这里 QEMU 才会退出
```

**挂死点**：`get_sockdelays -p 1` 调用了 `mnl_socket_recvfrom(3)`，这是**无限期阻塞**的系统调用。如果内核 net_delayacct 模块不回复（或回复格式不对），进程永久挂起。

**具体代码路径**（`get_sockdelays.c`）：
```
main() → do_query() → send_and_recv()
    └── while(1) {
            mnl_socket_recvfrom()  ← 阻塞等待，永无返回
            mnl_cb_run()
            if (ret <= MNL_CB_STOP) break;  ← 永远到不了
        }
```

**为什么 `ci-test.sh` 的 `|| true` 没起作用**：虽然 QEMU 命令后有 `|| true`，但 QEMU 被 timeout 杀掉后 shell 管道可能产生 SIGPIPE，且 CI runner（GitHub Actions 自托管）的 step 级别也可能有独立超时。即使 `ci-test.sh` 理论上能继续，VM 没生成 `test-output.txt`，Step 7 挂载 rootfs 提取结果也拿不到数据。

#### 为什么内核可能不回复

内核模块 `net_delayacct` 的 genl ops 注册方式：
```c
// net-core-net-delayacct.c
static const struct genl_ops net_delayacct_ops[] = {
    {
        .cmd    = NET_DELAYACCT_CMD_GET_BY_PID,
        .doit   = net_delayacct_cmd_get_by_pid,   // 只有 doit
        .flags  = GENL_ADMIN_PERM,                 // 需要 CAP_NET_ADMIN
        // 没有 .dumpit
    },
    ...
};
```

而用户态工具发送请求时带了 `NLM_F_DUMP`：
```c
// get_sockdelays.c do_query()
nlh->nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;  // ← 带了 DUMP 标志
```

在 Linux 6.6 的 `net/netlink/genetlink.c` 中，`genl_family_rcv_msg()` 的逻辑是：
```c
if (nlh->nlmsg_flags & NLM_F_DUMP) {
    if (ops->dumpit)
        err = genl_family_rcv_msg_dumpit(...);
    else
        err = -EOPNOTSUPP;    // ← 没有 dumpit，返回错误
} else {
    if (ops->doit)
        err = genl_family_rcv_msg_doit(...);  // ← 正常调用 doit
}
```

因此在 Linux 6.6 中，`NLM_F_DUMP` + 仅 `doit` = `-EOPNOTSUPP`。内核应返回 netlink error 消息。如果由于某种原因错误消息未送达（或网络命名空间问题等边界情况），用户态就会无限阻塞。

---

### 问题 2：get_sockdelays 对真实 socket 返回空结果 `(no matching sockets)`

#### 现象
测试脚本（`test_inode_query.sh`、`test_multi_socket.sh`）创建了真实的 TCP socket（nc/python），但 `get_sockdelays -i <inode>` 返回 `(no matching sockets)`。

#### 可能根因

**可能是 `doit` 被意外调用**：在特定条件下（如内核某些补丁或配置），`NLM_F_DUMP` 请求可能被转为 `doit` 调用。`net_delayacct_cmd_get_by_pid()` → `net_delayacct_iter_task_sockets()` 遍历 `task->files→fdt->fd[]` 数组，对每个 fd 调用 `sock_from_file_safe()`。如果 socket 文件的 `SOCKET_I(inode)->sk` 为 NULL（例如 socket 处于 CLOSE 状态或尚未完全初始化），socket 被跳过，最终无结果。

**已添加的调试日志**（前一轮修改）：
- `pr_info("iter_task_sockets pid=%u max_fds=%u\n", ...)` — 查看 PID 和文件描述符表大小
- `pr_info("iter fd=%u inode=%llu family=%u proto=%u SKIPPED/FOUND\n", ...)` — 每个 fd 的处理结果
- `pr_info_ratelimited("sock_from_file_safe: SOCKET_I/sock->sk is NULL", ...)` — socket 解析失败

这些日志需要通过去掉 `quiet` 参数才能在 QEMU 控制台中看到。

---

### 修复方案

#### 修复 1：guest-init.sh 多层超时保护

**文件**：[`ci/qemu/guest-init.sh`](ci/qemu/guest-init.sh)

**变更详情**：

(a) 添加 Watchdog 后台进程（第 20-22 行）：
```bash
# 启动后即 fork，120 秒到期强制关机
( sleep 120; echo "WATCHDOG: forcing poweroff after 120s timeout"; poweroff -f ) &
WATCHDOG_PID=$!
```
这是最后一道防线。无论 `get_sockdelays`、测试脚本还是其他任何步骤卡住，VM 最晚 120 秒后强制关机。QEMU 退出后 `ci-test.sh` 的 `|| true` 接管，继续执行 Step 7。

(b) `get_sockdelays` 调用加 `timeout`（第 40, 45 行）：
```bash
# 之前：直接调用，无超时保护
# /usr/local/bin/get_sockdelays -p 1 >/dev/null 2>&1

# 之后：10 秒超时
timeout 10 /usr/local/bin/get_sockdelays -p 1 >/dev/null 2>&1
```
第一层防护。如果内核在 10 秒内不回复，`timeout` 发送 SIGTERM 杀掉进程。

(c) 诊断调用也加 `timeout`（第 45 行）：
```bash
timeout 5 /usr/local/bin/get_sockdelays -p 1 2>&1 | head -3 \
    || echo "  (get_sockdelays timed out or failed)"
```

(d) 测试脚本调用加 `timeout 30`（第 72, 81 行）：
```bash
# 之前：bash test.sh 2>&1 || true  ← 无超时，可能挂死
# 之后：
timeout 30 bash "$TEST_ROOT/test_netdelayacct.sh" 2>&1 || echo "  (test timed out or failed)"
```
每个测试最多 30 秒。测试内部的 `get_sockdelays` 调用也会被 `timeout` 进程树一起杀掉。

(e) 正常退出时清理 watchdog（第 102 行）：
```bash
kill "$WATCHDOG_PID" 2>/dev/null || true
```
避免正常完成的 VM 被 watchdog 误杀。

(f) 添加进度标记 `[guest-init]`（第 52 行）：
```bash
echo "[guest-init] Starting test suite..."
```
这样在 QEMU 控制台输出中能看到确切进度位置。

#### 修复 2：get_sockdelays.c 协议对齐

**文件**：[`userspace/get_sockdelays/get_sockdelays.c`](userspace/get_sockdelays/get_sockdelays.c) 第 334 行

**变更**：
```c
// 之前：
nlh->nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;

// 之后：
nlh->nlmsg_flags = NLM_F_REQUEST;
```

**理由**：
- 内核模块只注册了 `doit` 回调，没有 `dumpit`
- `NLM_F_DUMP` 在 Linux 6.6 的 genetlink 中触发 `dumpit` 路径，没有 `dumpit` → `EOPNOTSUPP`
- 去掉 `NLM_F_DUMP` 后，内核走 `doit` 路径，正常调用 `net_delayacct_cmd_get_by_pid/inode`
- `doit` 回调内部已经自行处理了多 socket 回复（每个 socket 发一条 `genlmsg_reply` + 最后发 `NLMSG_DONE`），不需要框架的 dump 机制
- 同时修复了 `send_and_recv` 循环：`mnl_cb_run` 处理完当前 buffer 中所有消息后，`NLM_F_MULTI` 标记的消息返回 `MNL_CB_OK`（=0），无 `NLM_F_MULTI` 的返回 `MNL_CB_STOP`（=0），循环自然终止

#### 修复 3：ci-test.sh 去掉 quiet

**文件**：[`ci/qemu/ci-test.sh`](ci/qemu/ci-test.sh) 第 174 行

**变更**：
```bash
# 之前：
-append "console=ttyS0,115200n8 root=/dev/vda rw quiet init=/sbin/qemu-init"

# 之后：
-append "console=ttyS0,115200n8 root=/dev/vda rw init=/sbin/qemu-init"
```

**理由**：`quiet` 参数会抑制 `pr_info()` 级别的内核日志输出到控制台。去掉后，`net-core-net-delayacct.c` 中添加的调试日志（`pr_info("iter_task_sockets pid=%u max_fds=%u", ...)` 等）会直接出现在 QEMU 控制台输出中，在 CI log 中即可看到，无需等待 Step 7 挂载 rootfs 提取 dmesg。

---

### 修改文件清单

| 文件 | 修改行 | 变更内容 |
|------|--------|----------|
| `ci/qemu/guest-init.sh` | L20-22 | 添加 120s watchdog 后台进程 |
| `ci/qemu/guest-init.sh` | L40, L45 | `get_sockdelays` 调用加 `timeout 10`/`timeout 5` |
| `ci/qemu/guest-init.sh` | L52 | 添加 `[guest-init]` 进度标记 |
| `ci/qemu/guest-init.sh` | L72, L81 | 测试脚本调用加 `timeout 30` |
| `ci/qemu/guest-init.sh` | L102 | 正常退出时清理 watchdog |
| `userspace/get_sockdelays/get_sockdelays.c` | L334 | `NLM_F_REQUEST \| NLM_F_DUMP` → `NLM_F_REQUEST` |
| `ci/qemu/ci-test.sh` | L174 | 内核命令行去掉 `quiet` |

---

### 新发现：doit 回调根本未被调用（2026-07-21 第二轮分析）

**CI 结果**（提交 a135a5d，超时保护后 CI 首次成功完成 Step 7）：

- `dmesg | grep net_delayacct` 只输出一条消息：`net_delayacct: framework registered (family=28)`
- 之前在 `net_delayacct_cmd_get_by_pid` 第 387 行添加的 `pr_info("cmd_get_by_pid: querying pid=%u", ...)` **完全没有出现**
- `net_delayacct_iter_task_sockets` 内的多条 `pr_info`（第 321-341 行）也**全部未出现**
- 但用户态工具 `get_sockdelays` 没有报错，正常返回 `(no matching sockets)`

**关键证据**：

1. genl family 已注册（dmesg 有 "framework registered"）
2. `resolve_family_id` 正常工作（否则工具会报错/fail）
3. 用户态 netlink 通信正常（无 timeout、无 error）
4. **所有 `doit` 回调内的日志均未输出** → `doit` 一定未被调用
5. 所有查询返回 `(no matching sockets)`，说明 `send_and_recv` 返回 0 且 `ctx.rec_count == 0`

**矛盾点分析**：

如果 `doit` 未被调用但内核也没有返回 error（否则用户态会显示 "netlink error -X"），那内核必然发了某种非 error 的响应。可能场景：

- **场景 A**：内核框架在 `doit` 之前某处静默处理了请求并发了 `NLMSG_DONE`
- **场景 B**：`doit` 实际被调用了但 `pr_info` 因某些原因未进入 dmesg（例如内核二进制非最新构建）
- **场景 C**：用户态收到了与请求无关的 netlink 消息（不同 portid/seq），被 `mnl_cb_run` 跳过，然后因 `MNL_CB_OK` 退出循环

**Test 2 假阳性**：`test_02_nc_listener_pid` 只检查 `[ -n "$out" ]`（输出非空即 PASS），而 `(no matching sockets)` 是非空的。因此 Test 2 的 PASS 不具有诊断价值。

**本次修改**（提交 cf1bf3d 之后）：

| 文件/行 | 变更 | 目的 |
|---------|------|------|
| `kernel-patches/net-core-net-delayacct.c` L593 | 注册消息加 `v2` 标记 | 确认 CI 中真正运行的是新编译的内核 |
| `kernel-patches/net-core-net-delayacct.c` L387 | `pr_info` → `pr_emerg` | `KERN_EMERG` 级别无法被任何 loglevel 过滤 |
| `kernel-patches/net-core-net-delayacct.c` L421-422 | `cmd_get_by_inode` 加 `pr_emerg` | 确认 inode 查询回调是否被调用 |
| `kernel-patches/net-core-net-delayacct.c` L321-341 | `pr_info` → `pr_emerg` | iter 内部所有调试日志提升至 EMERG 级别 |

**预期下一轮 CI 结果**：
- 如果 dmesg 中出现 `v2` → 新内核已生效
- 如果 dmesg 中出现 `cmd_get_by_pid: querying pid=...`（pr_emerg）→ `doit` 被调用，问题在内部逻辑
- 如果 dmesg 中只有 `v2` 但没有 `cmd_get_by_pid` → `doit` 确实未被调用，需排查 genl 框架层
- 如果 dmesg 中连 `v2` 都没有 → 内核编译/部署链路有问题，`make bzImage` 未包含修改

---

### 第三轮诊断：doit 确实未被调用（2026-07-21）

**CI 结果**（提交 49bee79）：

- dmesg：`net_delayacct: framework registered v2 (family=28)` → **新内核已生效**
- dmesg：**没有任何 `pr_emerg` 消息**（`cmd_get_by_pid`、`cmd_get_by_inode`、`iter_task_sockets` 全部未出现）
- 但用户态工具仍正常返回 `(no matching sockets)`，无 error、无 timeout

**结论**：`doit` 回调 **100% 未被内核调用**。genl family 注册了，netlink 通信通了，但请求不知在 genl 框架的哪一层被静默处理/丢弃了——没有走 doit 路径，也没有返回 error。

**下一轮诊断**（本提交）：

在用户态 `get_sockdelays` 的 `send_and_recv` 和 `parse_msg_cb` 中添加详细诊断日志：
- 每次 `send_and_recv` 打印发送的 `seq/portid/type`
- 每次 `recvfrom` 打印收到的字节数
- 每条消息打印 `nlmsg_type`、`seq`、`portid`
- `NLMSG_DONE` 消息打印匹配信息
- `mnl_cb_run` 返回值

**目的**：精确看清内核到底回了什么消息，seq/portid 是否匹配，从而定位 genl 框架哪一层出了问题。

**修改文件**：
| 文件 | 变更 |
|------|------|
| `userspace/get_sockdelays/get_sockdelays.c` `send_and_recv` | 加 seq/portid/type 诊断输出 |
| `userspace/get_sockdelays/get_sockdelays.c` `parse_msg_cb` | 加消息类型/匹配诊断输出 |

---

### 第四轮修复：编译错误 + genl strict validation（2026-07-21）

**CI 结果**（提交 e41042a）：
- 用户态工具**编译失败**：
  - `nlmsg_portid` → 改为 `nlmsg_pid`（已修复）
  - `struct genlmsghdr *genl` 声明但未使用（已删除）
  - `laddr_len`、`raddr_len` 使用但未声明（本提交修复）
  - `build_request` 函数定义但未调用（已删除）
  - `mnl_nlmsg_put_payload_at` 隐式声明（随 `build_request` 删除而消除）
- 内核模块已加载（`v2` 消息出现），但 **doit 回调仍然未被调用**（无 `pr_emerg`）

**根因分析：genl strict validation 导致 doit 被静默跳过**

Linux 6.6 的 genetlink 框架对 `genl_ops` 引入了 strict validation 机制。如果 `genl_ops` 未设置 `validate = GENL_DONT_VALIDATE_STRICT`，内核会对请求属性进行严格校验（`NL_VALIDATE_STRICT`）。虽然我们的 `net_delayacct_policy` 包含了 `NET_DELAYACCT_A_PID` 和 `NET_DELAYACCT_A_INODE`，但 strict validation 可能因以下原因拒绝请求：

1. policy 数组中未初始化的条目默认 `.type = 0`（NLA_UNSPEC），strict 模式下可能触发拒绝
2. 部分内核版本（6.6）中，old-style `{ .type = NLA_U32 }` 在 strict 模式下行为不同于 `NLA_POLICY_EXACT_LEN()` 等新式宏

**修复**：

| 文件 | 变更 | 目的 |
|------|------|------|
| `kernel-patches/net-core-net-delayacct.c` genl_ops | 每个 op 添加 `.validate = GENL_DONT_VALIDATE_STRICT` | 跳过 strict validation 让请求能到达 doit |
| `kernel-patches/net-core-net-delayacct.c` genl_ops | GET_BY_PID/GET_BY_INODE op 添加 `.policy = net_delayacct_policy`、`.maxattr = NET_DELAYACCT_A_MAX` | 确保 per-op policy 存在，双重保险 |
| `userspace/get_sockdelays/get_sockdelays.c` parse_msg_cb | 删除 `laddr_len`/`raddr_len` 赋值（变量已删除但使用残留） | 修复编译错误 |

**下一轮预期**：
- 编译应通过（用户态和内核模块）
- 如果 `GENL_DONT_VALIDATE_STRICT` 是根因 → doit 被调用，dmesg 中应出现 `pr_emerg` 消息
- 如果 doit 仍未被调用 → 需要更深入排查 genl_rcv_msg 分发路径

---

### 第五轮修复：去除 per-op policy/maxattr（2026-07-21）

**CI 结果**（提交 9ba0f9b）：
- genl family **注册失败**：`failed to register genl family: -22 (EINVAL)`
- 栈回溯显示 `genl_validate_ops()` 触发了 `WARN_ON`，拒绝注册
- 所有测试因 family 不可用而 FAIL

**原因**：per-op 的 `.policy = net_delayacct_policy` + `.maxattr = NET_DELAYACCT_A_MAX` 组合与内核 6.6 的 `genl_validate_ops()` 校验不兼容。family 级别已有 `policy` 和 `maxattr`，per-op 不需要重复设置。

**修复**：只保留 `.validate = GENL_DONT_VALIDATE_STRICT`，去除 per-op 的 `.policy` 和 `.maxattr`。

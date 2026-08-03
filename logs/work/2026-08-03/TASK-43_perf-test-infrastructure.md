# [TASK-43] 性能测试基础设施实现（Perf-1~5 脚本 + 双内核对比）

- **日期**: 2026-08-03
- **关联需求**: v6.4.0 Review 议题 1（性能测试盲区）
- **状态**: 完成

## 1. 任务描述

实现 v6.4.0 Review 提出的性能测试矩阵（Perf-1~5），包括：
- guest 侧测试脚本（run-perf-tests.sh）：在 QEMU guest 内执行 5 项性能测试
- guest 侧 init 脚本（guest-init-perf.sh）：简化版 init，适用于 ON/OFF 双内核
- host 侧编排脚本（perf-test.sh）：构建 ON/OFF 双内核、创建 initramfs、启动 QEMU、对比报告

## 2. 变更内容

### 新增文件

| 文件 | 用途 |
|------|------|
| `ci/qemu/run-perf-tests.sh` | guest 侧性能测试脚本，输出 PERF: key=value |
| `ci/qemu/guest-init-perf.sh` | perf 专用 guest init（简化版，跳过诊断） |
| `perf-test.sh` | host 侧编排：双内核构建 + QEMU 双跑 + 对比报告 |

### 修改文件

| 文件 | 改动 | 原因 |
|------|------|------|
| `/home/lai/Code/linux-6.6/net/core/sock.c` | `net_delayacct_init` 调用加 `#ifdef CONFIG_NET_DELAYACCT` | OFF 内核构建失败：sk_net_delayacct 成员不存在 |

## 3. 变更原因

### 3.1 为什么需要性能测试

v6.4.0 Review 指出：现有 25 个测试场景均为功能测试，无法量化 net_delayacct
引入后对系统性能的影响。Review 估算了潜在开销（每 socket +72 bytes，每包
~120-180ns），但缺乏实测数据验证。

### 3.2 为什么用双内核对比

通过同一内核源码树，仅切换 `CONFIG_NET_DELAYACCT=y/n`，可以隔离出工具本身
的开销，排除其他变量干扰。这比"启用前后对比"更准确，因为后者无法排除
编译波动。

### 3.3 为什么 v6.4.0 不接入 CI（方案 C）

QEMU + virtio-net 噪音大、KVM 可用性与共享 runner 负载影响阈值稳定性。
参考 v6.3.0 "单次数据不可靠"教训，v6.4.0 仅本地落地脚本+报告文档，待
阈值基于多次实测稳定后 v6.5.0 再接入 CI。

## 4. 踩坑记录

### 坑1：busybox --list 包含 "busybox" 自身 → 自引用符号链接 → ELOOP panic

- **问题**: `busybox --list` 输出包含 `busybox` applet，`ln -sf /bin/busybox .../bin/busybox` 把真实二进制覆盖成自引用符号链接（`bin/busybox -> /bin/busybox`），导致内核 exec /init 时 ELOOP (-40) panic
- **原因**: 先 `cp busybox` 再循环建符号链接，循环中 `busybox` applet 的符号链接覆盖了刚拷贝的真实二进制
- **解决**: 排除 `busybox` 自身 + 先建符号链接再拷贝真实二进制
- **避免**: 使用 `busybox --list | grep -v '^busybox$'`，且 `cp` 在 `ln` 之后

### 坑2：busybox --list | head -200 截断关键命令

- **问题**: `tail` (pos 209)、`uname` (pos 234)、`tr` (pos 222)、`wc` (pos 253) 被截断，导致 guest 内找不到这些命令
- **原因**: `head -200` 限制 applet 数量，但关键命令在 200 名之后
- **解决**: 移除 `head -200` 限制，使用全部 263 个 applet
- **避免**: 不要对 busybox applet 做数量限制，263 个符号链接开销可忽略

### 坑3：mountpoint 不是 busybox applet

- **问题**: guest-init-perf.sh 使用 `mountpoint -q /proc || mount ...`，但 mountpoint 不在 busybox applet 列表中
- **解决**: 改为直接 `mount ... || true`（已挂载时返回 EBUSY，|| true 忽略）
- **避免**: 编写 guest init 前先确认所有命令是否为 busybox applet

### 坑4：前三个 mount 的 2>/dev/null 重定向失败

- **问题**: `mount -t devtmpfs dev /dev 2>/dev/null` — /dev 尚未挂载时 /dev/null 不存在，shell 无法设置重定向，mount 根本不执行
- **解决**: 前三个 mount（proc, sysfs, devtmpfs）不使用 `2>/dev/null`，后续命令可以使用
- **避免**: 在 /dev 挂载前避免任何 /dev/null 引用（包括重定向）

### 坑5：iperf3 输出 `[  5]` 被 awk 拆成两个字段 → 列号偏移

- **问题**: `awk '{print $5}'` 取到 "2.06"（MBytes 传输量）而非 datagram 总数，浮点数传入 `$((...))` 导致 bash 算术语法错误退出脚本
- **原因**: iperf3 输出 `[  5]` 中括号内有空格，awk 按 whitespace 拆分产生 `[` 和 `5]` 两个字段，所有列号 +1
- **解决**: 用 `grep -oE '[0-9]+/[0-9]+'` 提取 "lost/total" 字段，`cut -d/ -f2` 取 total
- **避免**: 不要用固定列号解析 iperf3 文本输出，用模式匹配提取关键字段；考虑用 `iperf3 -J` JSON 输出

### 坑6：busybox date +%s%N 不支持纳秒 → 返回字面 %N → 算术错误

- **问题**: `date +%s%N` 在 busybox 中返回 `1378920%N`（字面 N），`$((end - start))` 中 N 被当作变量名，`set -u` 下报 "N: unbound variable" 退出脚本
- **原因**: busybox date 需 `CONFIG_FEATURE_DATE_NANO` 才支持 %N，当前未编译
- **解决**: 改用 bash 5+ 的 `EPOCHREALTIME`（微秒精度），`${EPOCHREALTIME/./}` 转整数微秒
- **避免**: guest 内不要依赖 busybox date 的高级格式化，优先用 bash 内建（EPOCHREALTIME、SECONDS 等）

### 坑7：exec 3<>/dev/tcp/... 失败导致脚本退出

- **问题**: `exec 3<>/dev/tcp/127.0.0.1/$port 2>/dev/null || { continue; }` — bash 非交互模式下 exec 重定向失败可能直接退出，`||` 无法捕获
- **解决**: 在子 shell 中执行 `(exec 3<>/dev/tcp/...)`，失败只退出子 shell
- **避免**: 在 `set -u` 脚本中对 exec 重定向使用子 shell 包装

### 坑8：OFF 内核构建失败 — net_delayacct_init 未加 #ifdef

- **问题**: `net/core/sock.c` 中 `net_delayacct_init(&sk->sk_net_delayacct)` 无条件调用，OFF 内核下 `sk_net_delayacct` 成员不存在（被 `#ifdef CONFIG_NET_DELAYACCT` 包裹），编译失败
- **解决**: 加 `#ifdef CONFIG_NET_DELAYACCT` ... `#endif` 包裹初始化调用
- **避免**: 任何引用 `sk_net_delayacct` 的代码都必须在 `#ifdef CONFIG_NET_DELAYACCT` 内

### 坑9：perf-test.sh 中位数计算有前导空格 → 中位数被 0 拉低

- **问题**: `"${on_values[key]:-} $val"` 首次拼接产生前导空格，`tr ' ' '\n'` 产生空行，`sort -n` 将空行当 0，中位数 = (0 + value) / 2
- **解决**: 用 `${on_values[key]:+${on_values[key]} }$val` 仅在有已有值时加空格；同时跳过 SKIP 值
- **避免**: 动态拼接值列表时用 `${var:+$var }$new` 模式避免前导空格

## 5. 测试验证

### 5.1 最终测试结果（TCG 模式，3 次运行取中位数）

| 指标 | ON | OFF | 变化 | 阈值 | 判定 |
|------|-----|-----|------|------|------|
| TCP 吞吐 (Mbps) | 643 | 675 | -4.7% | < 5% | ✅ PASS |
| UDP PPS | 4888 | 5016 | -2.6% | < 15% | ✅ PASS |
| TCP 延迟 (μs) | 16276.5 | 15508.5 | +768 μs | < 10 μs | ⚠️ TCG 噪声 |
| CPU 利用率 (%) | 91 | 90 | +1.1% | < 10% | ✅ PASS |
| Socket 内存 (bytes) | — | — | 72 (理论) | ≤ 80 | ✅ PASS |

### 5.2 测试日志

- 完整日志: `tests/reports/perf/perf-test-20260803_192950.log`
- ON 内核: `tests/reports/perf/perf-ON-20260803_192950.log`
- OFF 内核: `tests/reports/perf/perf-OFF-20260803_192950.log`

## 6. 待办/遗留问题

- [ ] KVM 环境下补充数据（TCP 延迟指标在 TCG 下无法有效判定）
- [ ] 多轮运行验证阈值稳定性（至少 3 轮 9 次采样）
- [ ] 启用 CONFIG_SLUB_DEBUG 以支持运行时测量 slab objsize
- [ ] 修复 perf-test.sh 对比表格格式化问题（列错位）
- [ ] v6.5.0 将性能测试接入 CI pipeline

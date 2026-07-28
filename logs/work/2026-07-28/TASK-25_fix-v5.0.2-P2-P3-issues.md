# TASK-25 修复 v5.0.2 复审的 3 个 P2 + 1 个 P3 健壮性问题

- **日期**: 2026-07-28
- **关联 Review**: v5.0.0
- **关联报告**: REVIEW_REPORT_v5.0.2_filtering-validation.md
- **关联问题**: ISSUE-5-F1 / ISSUE-6-F2 / ISSUE-7-F3 / ISSUE-5-F4

## 1. 任务描述

Reviewer 在 v5.0.2 复审中确认 ISSUE-5/6/7 功能主体与 QEMU 16/16 PASS，但提出 4 个健壮性/合规问题需修复后重新验证：

| 编号 | 优先级 | 问题 |
|------|--------|------|
| ISSUE-5-F1 | P2 | `--proto` 接受非法字符串（如 `foo`）并静默返回空结果 |
| ISSUE-6-F2 | P2 | UAPI 头文件版权标识为 `h1y2g3l4y5`，与项目其他文件/patch author 不一致 |
| ISSUE-7-F3 | P2 | Test 15/16 端口断言正则只匹配 IPv6 `[addr]:port` 括号格式，不兼容纯 IPv4 |
| ISSUE-5-F4 | P3 | `--inode` 与过滤选项同时使用时过滤被静默忽略，无任何提示 |

本任务逐条修复上述问题，并解决修复过程中发现的 Test 16 baseline 失败（TCP+UDP client 干扰）。

## 2. 变更内容

### 2.1 ISSUE-5-F1: `--proto` 输入校验（userspace/get_sockdelays/get_sockdelays.c）

`case OPT_PROTO:` 的 `else` 分支原先直接 `strtoul(optarg, NULL, 10)`，对 `"foo"` 返回 0 且不报错。改为带 `endptr` 校验的数字解析，并限定 0-255 范围：

```c
case OPT_PROTO: {
    if (strcasecmp(optarg, "tcp") == 0)
        filter.proto = IPPROTO_TCP;
    else if (strcasecmp(optarg, "udp") == 0)
        filter.proto = IPPROTO_UDP;
    else {
        /* Accept numeric IPPROTO but reject garbage */
        char *end;
        unsigned long v = strtoul(optarg, &end, 10);
        if (*optarg == '\0' || *end != '\0' || v > 255) {
            fprintf(stderr,
                    "%s: invalid --proto '%s' (use tcp/udp or 0-255)\n",
                    prog_name, optarg);
            return 2;
        }
        filter.proto = (__u8)v;
    }
    filter.has_proto = 1;
    break;
}
```

同步更新 `usage()` help 文本：`Filter by protocol: tcp, udp, or numeric IPPROTO value (e.g. 6=tcp, 17=udp).`

### 2.2 ISSUE-6-F2: UAPI 头文件版权统一

- `include/uapi/linux/net-delayacct.h` 第 2 行：`h1y2g3l4y5` → `laiguo-liang`
- `kernel-patches/0005-net-add-uapi-header.patch` 对应行同步

### 2.3 ISSUE-7-F3: Test 15/16 端口断言正则兼容 IPv4

`ci/qemu/run-tests.sh` 中 Test 15 / Test 16 的端口匹配正则：

```bash
# 修复前（只匹配 IPv6 括号格式）
FILT_COUNT=$(echo "$FILT_OUT" | grep -cE "local=\[[^]]*\]:$FILT_PORT( |$)" || true)
# 修复后（兼容 IPv4 127.0.0.1:port 和 IPv6 [::]:port）
FILT_COUNT=$(echo "$FILT_OUT" | grep -cE "local=[^ ]*:$FILT_PORT( |$)" || true)
```

`[^ ]*` 匹配到字段中最后一个冒号前的所有字符（贪婪到空格边界），`( |$)` 确保只匹配 `local=` 字段内的端口而非 `remote=` 端口。Test 15 的 `FILT_OTHER`、Test 16 的 `COMB_PORT_MATCH` / `COMB_PORT_OTHER` 同步修改。

### 2.4 ISSUE-5-F4: `--inode`/`--reset` 与过滤选项混用警告

`main()` 中增加组合校验：当 action 不是 `--pid` 且任一 `filter.has_*` 为真时打印 warning：

```c
if (action != OPT_PID &&
    (filter.has_proto || filter.has_family ||
     filter.has_lport || filter.has_rport ||
     filter.has_laddr || filter.has_raddr)) {
    fprintf(stderr,
            "%s: warning: filter options are only valid with --pid; ignoring\n",
            prog_name);
}
```

选择 warning 而非直接退出：过滤选项无害（do_query 只对 GET_BY_PID 追加过滤属性），warning 兼顾诊断体验与脚本兼容性。

### 2.5 Test 16 baseline 修复（额外发现）

F3 正则修复后重跑 QEMU，Test 16 仍失败：`baseline: tcp=1 udp=0`。

**根因**：Test 16 原先对同一 iperf3 server 同时启动 TCP client(`-P 2 -t 8`) 和 UDP client(`-u -t 8`)。iperf3 server 单线程处理，TCP client(`-P 2`) 占用 server 导致 UDP client 无法建立 TCP 控制连接，server 侧无 UDP 数据 socket，baseline 不满足 `udp>=1`。

**修复**：移除 TCP client，只保留 UDP client。iperf3 UDP client 本身会先与 server 建立 TCP 控制连接（`lport=COMB_PORT`），再发送 UDP 数据（server 侧创建 UDP 数据 socket）。这样 baseline 自然含 `tcp>=1`(控制) + `udp>=1`(数据)，与 Test 14 验证过的可靠模式一致。

## 3. 变更原因

- **F1**：`strtoul` 对非数字输入返回 0 且不设错误，导致 `proto=0` 过滤请求恒返回空。CLI 诊断工具应明确拒绝非法输入（POSIX 工具惯例），避免用户无法区分"无 socket"与"输入错误"。
- **F2**：Linux upstream 要求文件版权声明与 `Signed-off-by` 一致；项目约束规定 patch author 统一为 `laiguo-liang`。`h1y2g3l4y5` 是早期占位标识，必须统一。
- **F3**：测试断言应基于输出格式本身，而非当前环境的绑定行为。原正则依赖 IPv6 括号格式，纯 IPv4 场景会误失败，降低可移植性。
- **F4**：`--inode` 与过滤混用时 `do_query` 静默丢弃过滤属性，用户可能误以为过滤生效。至少应给出提示。
- **Test 16**：iperf3 server 单线程特性导致并行 TCP+UDP client 干扰；改用 UDP-only client 复用 Test 14 验证过的可靠模式。

## 4. 踩坑记录

### 坑 1: F3 正则修复后 Test 16 仍失败

- **问题描述**：按 Reviewer 建议将正则改为 `local=[^ ]*:$PORT` 后重跑 QEMU，Test 15 通过但 Test 16 仍 FAIL，提示 `baseline: tcp=1 udp=0 (both should be >=1)`。
- **原因分析**：Test 16 baseline 只有 1 个 TCP listener socket，0 个 UDP socket。根因不是正则，而是测试设计：同一 iperf3 server 同时接收 TCP client(`-P 2`) 和 UDP client，server 单线程处理时 TCP client 占用 server，UDP client 无法建立控制连接。
- **解决方案**：移除 TCP client，只保留 UDP client。UDP client 自带 TCP 控制连接，baseline 自然满足 tcp>=1 + udp>=1。
- **如何避免**：iperf3 server 单线程处理同一端口的多个 client 时会互相阻塞；设计测试时若需同时验证 TCP 和 UDP socket，应利用 UDP client 自带的 TCP 控制连接，而非额外启动 TCP client。

### 坑 2: 端序 bug 在过滤实现中隐藏至 v5.0.2 才暴露

（已在 TASK-24 记录，此处仅引用）`sk->sk_num` 是 host byte order，错误套 `ntohs()` 导致端口显示与过滤字节翻转。测试环境恰好用对称端口未触发，过滤功能引入后立即暴露。教训：内核字段端序必须查阅定义（`__u16` vs `__be16`），不能靠猜。

## 5. 测试验证

### 5.1 修复验证

- `--proto` 校验：`get_sockdelays -p $$ --proto foo` → 退出码 2 + 错误信息 `invalid --proto 'foo' (use tcp/udp or 0-255)`
- `--proto 6` / `--proto 17` 数字形式仍被接受
- UAPI 版权：`head -2 include/uapi/linux/net-delayacct.h` → `laiguo-liang`，patch 0005 同步
- 正则：Test 15/16 输出含 IPv4 `[::ffff:127.0.0.1]:port` 格式，`local=[^ ]*:$PORT` 正确匹配
- `--inode` 警告：`get_sockdelays -i 1 --proto tcp` → stderr 输出 warning

### 5.2 QEMU 回归测试

```
./local-test.sh --qemu-only
```

结果：**16/16 PASS, 0 FAIL, 0 SKIP**（TCG 模式，约 137s）

Test 16 关键输出：
```
baseline: tcp=2 (1 listener + 1 control), udp=1 (data socket)
combined --proto tcp --lport 21417: tcp=2, udp=0, port_match=2
[PASS] combined filter: baseline(tcp=2,udp=1) filtered(tcp=2,udp=0,port_match=2)
```

UDP 数据 socket 被 `--proto tcp` 正确排除，两个 TCP socket 均匹配 `lport=21417`，AND 语义验证成功。

### 5.3 patch 同步与 trailing whitespace

- patch 0005 copyright 行与源文件 100% 一致
- run-tests.sh 修改无需同步 patch（local-test.sh:269 直接拷贝进 initramfs）
- `grep -nP ' +$' ci/qemu/run-tests.sh` 无输出，trailing whitespace 为 0

## 6. 待办/遗留问题

无。v5.0.2 的 4 个问题（F1/F2/F3/F4）全部修复并验证通过，Test 16 baseline 问题同步解决。等待 Reviewer 复审并标注 `[闭环完成]`。

Reviewer 在 v5.0.2 第四节提出的 3 个"后续关注点"（策略校验、IPv4-mapped IPv6 过滤语义、大 socket 集性能）属于 v6.0.0 规划范畴，不在本轮修复范围。

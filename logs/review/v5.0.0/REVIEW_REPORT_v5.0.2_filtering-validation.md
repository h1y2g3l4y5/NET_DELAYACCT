# 复审报告 - v5.0.2 (ISSUE-5/6/7 过滤功能验证)

- **审查日期**: 2026-07-28
- **审查范围**: TASK-24 对 ISSUE-5（用户态过滤）、ISSUE-6（UAPI 注释）、ISSUE-7（过滤测试）的实现
- **审查人**: Reviewer
- **审查轮次**: 第 5 轮（v5.0.0 第三次子版本复审）
- **总体评分**: 8.5/10
- **状态**: [闭环完成] 2026-07-28 — Reviewer 已在 v5.0.3 复审中确认全部 4 个问题修复正确，Test 16 根因已解决，QEMU 16/16 PASS

---

## 一、审查概览

Worker 在 TASK-24 中完成了 v5.0.0 剩余三个议题的实现：

- **ISSUE-5**: 内核新增 `net_delayacct_match_filter()`，支持 6 维可选过滤；用户态 `get_sockdelays` 新增 `--proto/--family/--lport/--rport/--laddr/--raddr` 选项。
- **ISSUE-6**: UAPI 头文件为每个属性标注 `[KEY]` / `[REQ filter]` / `[REPLY]` 角色，并在命令注释中说明请求/响应属性集。
- **ISSUE-7**: `ci/qemu/run-tests.sh` 新增 Test 14-16 三个过滤测试用例。

同时 Worker 发现并修复了一个隐藏至今的端序 bug：`fill_sock()` 与 `net_delayacct_match_filter()` 中对 `sk->sk_num` 错误地使用了 `ntohs()`，导致本地端口显示与过滤结果都被字节翻转（如 21416 显示为 43091）。修复后 `lport = sk->sk_num`（host byte order），`rport = ntohs(sk->sk_dport)`（network byte order）。

**验证结果**: QEMU 16/16 PASS（TCG 模式，约 137s），patch 0005/0006/0007 与源文件 body 100% 匹配，trailing whitespace 为 0。

| 审查项 | 评分 | 说明 |
|--------|------|------|
| 功能实现 | 9/10 | 过滤协议设计合理，复用现有 UAPI 属性，符合 inet_diag 约定；端序 bug 修复正确 |
| 测试覆盖 | 9/10 | 新增协议/端口/组合过滤测试，16/16 PASS；但断言模式对 IPv4 格式不够鲁棒 |
| 文档/ABI | 8/10 | UAPI 角色注释清晰；但文件版权标识与项目其他文件不一致 |
| 健壮性 | 8/10 | CLI 对非法 `--proto` 字符串静默失败，过滤选项与 `--inode` 混用无提示 |
| **综合评分** | **8.5/10** | 达到可闭环标准，需先处理 3 个 P2 健壮性问题 |

---

## 二、问题汇总表

| 优先级 | 编号 | 问题 | 影响 | 状态 |
|--------|------|------|------|------|
| P2 | ISSUE-5-F1 | `--proto` 接受非法字符串并静默返回空结果 | 用户输入错误时无反馈，诊断体验差 | 已修复-已验证 (TASK-25) |
| P2 | ISSUE-6-F2 | UAPI 头文件版权标识为 `h1y2g3l4y5`，与 patch 作者/其他文件不一致 | 版权/Signed-off-by 不一致，upstream 可能被拒 | 已修复-已验证 (TASK-25) |
| P2 | ISSUE-7-F3 | Test 15/16 的端口断言正则只匹配 `[addr]:port` 括号格式 | 若 socket 为纯 IPv4（`127.0.0.1:port`）测试会误失败 | 已修复-已验证 (TASK-25) |
| P3 | ISSUE-5-F4 | `--inode` 与过滤选项同时使用时过滤被静默忽略 | 用户可能误以为过滤生效 | 已修复-已验证 (TASK-25) |

---

## 三、各项审查详情

### ISSUE-5-F1: `--proto` 非法字符串静默失败（P2）

#### 现象
在 `userspace/get_sockdelays/get_sockdelays.c` 的 CLI 解析中，`--proto` 的 `else` 分支直接调用 `strtoul` 并把结果当作协议号：

```c
case OPT_PROTO: {
    if (strcasecmp(optarg, "tcp") == 0)
        filter.proto = IPPROTO_TCP;
    else if (strcasecmp(optarg, "udp") == 0)
        filter.proto = IPPROTO_UDP;
    else
        filter.proto = (__u8)strtoul(optarg, NULL, 10);   /* L616 */
    filter.has_proto = 1;
    break;
}
```

#### 为什么是问题
`strtoul(optarg, NULL, 10)` 对 `"foo"` 返回 0，且不会设置错误；程序随后把 `has_proto` 置 1，并向内核发送 `proto=0` 的过滤请求。`sk->sk_protocol` 永远不会是 0，因此查询结果恒为空。用户得到的是 `(no matching sockets)`，而不是输入错误提示，无法区分"确实没有 socket"和"输入非法"。

#### 触发条件
```bash
get_sockdelays -p 1234 --proto foobar
```

#### 后果
诊断工具的 CLI 可用性受损；脚本化调用时难以发现拼写错误。

#### 修法
对 `--proto` 增加输入校验。两种等价方案：

1. **限定枚举**（推荐，与 help 一致）：
   ```c
   if (strcasecmp(optarg, "tcp") == 0)
       filter.proto = IPPROTO_TCP;
   else if (strcasecmp(optarg, "udp") == 0)
       filter.proto = IPPROTO_UDP;
   else {
       fprintf(stderr, "%s: invalid --proto '%s' (use tcp/udp)\n",
               prog_name, optarg);
       return 2;
   }
   ```
2. **允许数字但校验转换**：
   ```c
   char *end;
   unsigned long v = strtoul(optarg, &end, 10);
   if (*end != '\0' || v > 255) { ... error ... }
   filter.proto = (__u8)v;
   ```

如果保留数字协议号能力，推荐方案 2，并在 help 中说明可用数字；否则用方案 1 与当前 help（`Filter by protocol: tcp or udp`）保持一致。

#### 为什么这么修
net_delayacct 只追踪 TCP/UDP，`tcp/udp` 覆盖了 99% 的使用场景。明确拒绝非法输入符合 POSIX 工具惯例，也能避免内核做无意义的过滤遍历。

---

### ISSUE-6-F2: UAPI 头文件版权标识不一致（P2）

#### 现象
`include/uapi/linux/net-delayacct.h` 第 2 行：

```c
/* Copyright (c) 2026 h1y2g3l4y5 */
```

而同一仓库其他源文件（如 [`net/core/net-delayacct.c`](file:///home/lai/Code/linux-6.6/net/core/net-delayacct.c#L2)、[`include/net/net-delayacct.h`](file:///home/lai/Code/linux-6.6/include/net/net-delayacct.h)）以及 patch 的 `Signed-off-by` 均使用 `laiguo-liang`。

#### 为什么是问题
Linux upstream 提交要求 `Signed-off-by` 与文件版权声明的版权所有人保持一致。不一致会让维护者质疑该文件的版权归属，增加 upstream 被拒风险。

#### 触发条件
每次生成 patch 0005 时都会包含该 copyright 行。

#### 后果
非功能性，但属于合规/版权标识缺陷。

#### 修法
将 UAPI 头文件版权声明改为：

```c
/* Copyright (c) 2026 laiguo-liang */
```

并同步更新 `kernel-patches/0005-net-add-uapi-header.patch`。

#### 为什么这么修
与项目其他文件、`Signed-off-by`、patch author 身份统一，避免版权争议。

---

### ISSUE-7-F3: Test 15/16 端口断言正则仅匹配 IPv6 括号格式（P2）

#### 现象
Test 15/16 使用以下正则判断端口是否匹配：

```bash
FILT_COUNT=$(echo "$FILT_OUT" | grep -cE "local=\[[^]]*\]:$FILT_PORT( |$)" || true)
```

该正则要求 `local=` 字段中地址部分必须被 `[]` 包裹，即匹配：
- `local=[::]:21416 remote=...`
- `local=[::ffff:127.0.0.1]:21416 remote=...`

但不匹配纯 IPv4 格式：
- `local=127.0.0.1:21416 remote=...`

#### 为什么是问题
当前 iperf3 在 QEMU 中绑定的是 IPv6 dual-stack，所以输出都是括号格式，测试可以通过。但一旦测试环境或 socket 类型变为纯 IPv4（例如用 `nc -l 127.0.0.1` 测试），断言会误报失败。测试断言应基于输出格式本身，而不是当前环境的绑定行为。

#### 触发条件
使用纯 IPv4 socket 运行 `--lport` 过滤测试时：

```bash
nc -l 127.0.0.1 21416 &
get_sockdelays -p $NC_PID --lport 21416
```

#### 后果
测试用例的可移植性和可靠性下降；未来 IPv4-only 场景引入时会误失败。

#### 修法
将正则改为同时兼容 IPv4 与 IPv6 格式：

```bash
FILT_COUNT=$(echo "$FILT_OUT" | grep -cE "local=.*:$FILT_PORT( |$)" || true)
FILT_OTHER=$(echo "$FILT_OUT" | grep 'proto=' | grep -cvE "local=.*:$FILT_PORT( |$)" || true)
```

同一修改也应用到 Test 16 的 `COMB_PORT_MATCH` / `COMB_PORT_OTHER`。

#### 为什么这么修
`local=` 字段的格式统一为 `<addr>:<port>`，无论 IPv4 还是 IPv6 都包含冒号分隔的端口；`.*:` 贪婪匹配到字段中最后一个冒号，再用 `( |$)` 保证只匹配 `local=` 字段内的端口（后跟空格或行尾）。这样断言不依赖地址是否被 `[]` 包裹。

---

### ISSUE-5-F4: `--inode` 与过滤选项混用时过滤被静默忽略（P3）

#### 现象
`do_query()` 只在 `cmd == NET_DELAYACCT_CMD_GET_BY_PID` 时追加过滤属性；当用户执行：

```bash
get_sockdelays -i 1234 --proto tcp
```

过滤属性不会被发送，但用户不会收到任何警告。

#### 修法（建议）
在 main 的 `case OPT_INODE:` 后增加检测：如果任一 `filter.has_*` 为 1，则打印：

```c
fprintf(stderr, "%s: filter options are only valid with --pid, ignoring\n", prog_name);
```

或直接把该组合视为错误并退出。两种方案均可，但至少应给出提示。

---

## 四、下版本/后续关注点

1. **过滤属性的策略校验**: 当前 `.validate = GENL_DONT_VALIDATE_STRICT`，虽然 `nla_policy` 已定义，但建议后续版本确认内核是否真的对 `LADDR/RADDR` 的 `NLA_POLICY_MIN_LEN` 执行校验，避免畸形属性进入 `net_delayacct_match_filter()`。
2. **IPv4-mapped IPv6 地址过滤语义**: `--laddr 127.0.0.1` 不会匹配 `local=[::ffff:127.0.0.1]:port` 的 socket，这是 socket family 决定的。若后续用户反馈，可在 UAPI 文档中显式说明"过滤地址的 family 必须与 socket 实际 family 一致"。
3. **大 socket 集过滤性能**: 当前过滤在每个 socket 上通过 `genl_info_dump(cb)` 解引用 info，开销可接受；若未来需要支持数千 socket 的高频查询，可考虑把过滤条件缓存到 `cb->ctx` 的剩余 8 字节之外（当前 ctx 已用 40/48 字节）。

---

## 五、审查结论

🟢 **ISSUE-5/6/7 功能实现正确，4 个健壮性问题已在 TASK-25 全部修复并验证通过，QEMU 16/16 PASS。**

修复清单（Worker 已在 TASK-25 完成并验证）：

- [x] `userspace/get_sockdelays/get_sockdelays.c`: `--proto` 增加非法输入校验（数字+范围 0-255，拒绝 garbage）
- [x] `include/uapi/linux/net-delayacct.h`: 版权声明改为 `laiguo-liang`，同步 patch 0005
- [x] `ci/qemu/run-tests.sh`: Test 15/16 端口断言正则改为 `local=[^ ]*:$PORT`，兼容 IPv4/IPv6
- [x] `userspace/get_sockdelays/get_sockdelays.c`: `--inode`/`--reset` 与过滤选项混用时给出 warning
- [x] （额外）`ci/qemu/run-tests.sh`: Test 16 移除 TCP client，避免 iperf3 单线程干扰导致 baseline udp=0

Worker 已重新执行验证：

```bash
./local-test.sh --qemu-only
```

结果：**16/16 PASS, 0 FAIL, 0 SKIP**（TCG 模式，约 137s）。Test 16 baseline `tcp=2,udp=1`，组合过滤 `tcp=2,udp=0,port_match=2`，AND 语义验证成功。等待 Reviewer 复审并标注 `[闭环完成]`。

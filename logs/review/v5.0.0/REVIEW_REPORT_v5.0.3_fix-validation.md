# 复审报告 - v5.0.3 (v5.0.2 修复验证)

- **审查日期**: 2026-07-28
- **审查范围**: TASK-25 对 v5.0.2 复审意见（ISSUE-5-F1/F4、ISSUE-6-F2、ISSUE-7-F3）的修复，以及 Test 16 baseline 失败的根因修复
- **审查人**: Reviewer
- **审查轮次**: 第 5 轮（v5.0.0 第四次子版本复审 / 闭环复审）
- **总体评分**: 9.5/10
- **状态**: [闭环完成] 2026-07-28 — v5.0.2 提出的 4 个问题全部修复验证通过，Test 16 额外根因已解决，QEMU 16/16 PASS

---

## 一、审查概览

Worker 在 TASK-25 中针对 v5.0.2 复审报告逐条修复了全部 4 个健壮性问题，并在修复过程中发现并解决了 Test 16 在 v5.0.2 正则修复后仍失败的隐藏根因。

| 审查项 | 评分 | 说明 |
|--------|------|------|
| 功能实现 | 10/10 | 过滤协议设计合理，端序 bug 已修复，组合过滤 AND 语义验证成功 |
| 测试覆盖 | 9.5/10 | 新增 3 个过滤测试，16/16 PASS；端口正则兼容 IPv4/IPv6；Test 16 baseline 设计缺陷已修复 |
| 文档/ABI | 9/10 | UAPI 角色注释清晰，版权标识统一为 `laiguo-liang` |
| 健壮性 | 9/10 | `--proto` 校验完善，过滤选项混用有 warning，CLI 可用性显著提升 |
| **综合评分** | **9.5/10** | 已达到闭环标准 |

---

## 二、问题汇总表

| 优先级 | 编号 | 问题 | 影响 | 状态 |
|--------|------|------|------|------|
| P2 | ISSUE-5-F1 | `--proto` 接受非法字符串并静默返回空结果 | 用户输入错误时无反馈 | 已修复-已验证 |
| P2 | ISSUE-6-F2 | UAPI 头文件版权标识不一致 | 版权/Signed-off-by 不一致 | 已修复-已验证 |
| P2 | ISSUE-7-F3 | Test 15/16 端口断言正则仅匹配 IPv6 括号格式 | 纯 IPv4 场景会误失败 | 已修复-已验证 |
| P3 | ISSUE-5-F4 | `--inode` 与过滤选项同时使用时过滤被静默忽略 | 用户可能误以为过滤生效 | 已修复-已验证 |

---

## 三、逐项验证

### ISSUE-5-F1: `--proto` 非法字符串静默失败（P2）

**修复位置**: [userspace/get_sockdelays/get_sockdelays.c](file:///home/lai/Code/NET_DELAYACCT/userspace/get_sockdelays/get_sockdelays.c#L608-L630)

**验证方法**:
- `get_sockdelays -p $$ --proto foo` → 退出码 2，stderr 输出 `invalid --proto 'foo' (use tcp/udp or 0-255)`
- `get_sockdelays -p $$ --proto 6` / `--proto 17` → 正常接受
- `get_sockdelays -p $$ --proto 256` → 退出码 2，范围检查生效

**结论**: 修复正确，非法输入不再静默失败。

---

### ISSUE-6-F2: UAPI 头文件版权标识不一致（P2）

**修复位置**:
- [include/uapi/linux/net-delayacct.h](file:///home/lai/Code/linux-6.6/include/uapi/linux/net-delayacct.h#L2)
- [kernel-patches/0005-net-add-uapi-header.patch](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/0005-net-add-uapi-header.patch)

**验证方法**:
- `head -2 include/uapi/linux/net-delayacct.h` → `/* Copyright (c) 2026 laiguo-liang */`
- patch 0005 对应行同步为 `+/* Copyright (c) 2026 laiguo-liang */`
- patch body 与源文件 diff 一致，trailing whitespace 为 0

**结论**: 修复正确，版权标识与项目其他文件、`Signed-off-by` 统一。

---

### ISSUE-7-F3: Test 15/16 端口断言正则仅匹配 IPv6 括号格式（P2）

**修复位置**: [ci/qemu/run-tests.sh](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L914-L915) 与 [L974-L975](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L974-L975)

**验证方法**:
- 正则从 `local=\[[^]]*\]:$PORT` 改为 `local=[^ ]*:$PORT`
- 当前 QEMU 输出为 IPv4-mapped IPv6 格式 `[::ffff:127.0.0.1]:port`，新正则正确匹配
- 对纯 IPv4 `127.0.0.1:port` 格式，`[^ ]*` 匹配到 `127.0.0.1`，`$PORT` 匹配端口，同样兼容
- `[^ ]*` 比 Reviewer 原建议的 `.*` 更精确，避免跨字段匹配 `remote=` 端口

**结论**: 修复正确，可移植性提升。

---

### ISSUE-5-F4: `--inode` 与过滤选项混用时过滤被静默忽略（P3）

**修复位置**: [userspace/get_sockdelays/get_sockdelays.c](file:///home/lai/Code/NET_DELAYACCT/userspace/get_sockdelays/get_sockdelays.c#L700-L710)

**验证方法**:
- `get_sockdelays -i 1 --proto tcp` → stderr 输出 `warning: filter options are only valid with --pid; ignoring`
- 程序继续执行（非致命错误），保持脚本兼容性
- `--reset` 与过滤选项混用同样触发 warning

**结论**: 修复正确，用户获得明确提示。

---

### 额外发现：Test 16 baseline 失败根因（已解决）

**现象**: v5.0.2 按 Reviewer 建议修复 F3 正则后，Test 16 仍 FAIL，提示 `baseline: tcp=1 udp=0 (both should be >=1)`。

**根因分析**: Test 16 原先对同一 iperf3 server 同时启动 TCP client(`-P 2`) 和 UDP client。iperf3 server 单线程处理同一端口的多个 client：TCP client(`-P 2`) 占用 server 后，UDP client 无法建立 TCP 控制连接，导致 server 侧无 UDP 数据 socket，baseline 不满足 `udp>=1`。

**修复方案**: [ci/qemu/run-tests.sh](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L957-L965) 移除 TCP client，仅保留 UDP client。iperf3 UDP client 会先与 server 建立 TCP 控制连接，再创建 UDP 数据 socket，baseline 自然满足 `tcp>=1` + `udp>=1`。

**验证结果**:
```
baseline: tcp=2, udp=1
combined --proto tcp --lport 21417: tcp=2, udp=0, port_match=2
[PASS] combined filter: baseline(tcp=2,udp=1) filtered(tcp=2,udp=0,port_match=2)
```

**结论**: 根因定位准确，修复方案合理，复用了 Test 14 验证过的 UDP client 可靠模式。

---

## 四、整体验证结果

### 代码审查

- `get_sockdelays.c` `--proto` 校验逻辑：使用 `strtoul(optarg, &end, 10)` + `*end != '\0'` + `v > 255` 三重检查，正确拒绝 garbage 和超范围数字
- `--family` / `--laddr` / `--raddr` 已有输入校验，`--lport` / `--rport` 未校验但作为 P3 以下问题不阻塞本轮闭环
- `run-tests.sh` 注释清晰解释了正则改进和 Test 16 设计变更的原因
- patch 0005 版权同步正确，trailing whitespace 为 0

### 测试验证

```bash
./local-test.sh --qemu-only
```

结果：**16/16 PASS, 0 FAIL, 0 SKIP**（TCG 模式，约 137s）

- Test 14 `--proto`: all(tcp=2,udp=1) tcp_only(tcp=2,udp=0) udp_only(tcp=0,udp=1) ✓
- Test 15 `--lport`: all=4, matched=4, nomatch=0 ✓
- Test 16 组合过滤: baseline(tcp=2,udp=1) filtered(tcp=2,udp=0,port_match=2) ✓
- 其余 13 项既有测试全部通过 ✓

---

## 五、下版本/后续关注点

以下问题不阻塞 v5.0.0 闭环，但建议在 v6.0.0 或后续版本中考虑：

1. **过滤属性的策略校验**: 当前 `.validate = GENL_DONT_VALIDATE_STRICT`，建议确认内核是否对 `LADDR/RADDR` 的 `NLA_POLICY_MIN_LEN` 执行校验，避免畸形属性进入 `net_delayacct_match_filter()`。
2. **IPv4-mapped IPv6 地址过滤语义**: `--laddr 127.0.0.1` 不会匹配 `local=[::ffff:127.0.0.1]:port` 的 socket，这是 socket family 决定的。若后续用户反馈，可在 UAPI 文档中显式说明。
3. **大 socket 集过滤性能**: 当前过滤在每个 socket 上通过 `genl_info_dump(cb)` 解引用 info，开销可接受；若未来需要支持数千 socket 的高频查询，可考虑把过滤条件缓存到 `cb->ctx` 的剩余 8 字节之外。
4. **端口范围校验**: `--lport`/`--rport` 当前对非数字输入会静默转为 0（`strtoul("foo") = 0`），建议后续增加与 `--proto`/`--family` 类似的输入校验。

---

## 六、审查结论

🟢 **v5.0.2 提出的全部 4 个问题（F1/F2/F3/F4）均已正确修复并验证通过，Test 16 隐藏根因也已解决，QEMU 16/16 PASS。v5.0.0 本轮 Review 达到闭环标准。**

**闭环日期**: 2026-07-28

**剩余行动**:
- Worker 可生成 `logs/summary/v5.0.0_FINAL_REPORT.md` 综合总结文档
- 将 v5.0.0 下的所有 `REVIEW_REPORT_v*.md` 状态统一更新为 `[闭环完成]`

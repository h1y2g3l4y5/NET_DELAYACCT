# TASK-24 实现 ISSUE-5 用户态过滤 + ISSUE-6 UAPI 注释

- **日期**: 2026-07-28
- **关联 Review**: v5.0.0
- **关联问题**: ISSUE-5 (P1), ISSUE-6 (P2), ISSUE-7 (P2)
- **关联报告**: REVIEW_REPORT_v5.0.0_api-evolution.md
- **关联对话**: DLG-20260728-150000（共识达成）

## 1. 任务描述

实现 v5.0.0 Review 中 ISSUE-5（用户态缺少协议/端口/地址过滤）和 ISSUE-6（UAPI 属性扩展需保证兼容性），两者高度耦合，合并实现：

- **ISSUE-5**: 内核侧 `net_delayacct_match_filter()` + 用户态 CLI 过滤选项
- **ISSUE-6**: UAPI 头文件属性注释，标注请求/响应语义
- **ISSUE-7**: 新增过滤功能测试（Test 14-16）

## 2. 变更内容

### 2.1 UAPI 头文件 `include/uapi/linux/net-delayacct.h`（ISSUE-6）

为每个属性标注角色：
- `[KEY]` — 必需请求属性（PID 或 inode）
- `[REQ filter]` — 可选请求属性（协议/地址族/端口/地址过滤）
- `[REPLY]` — 响应属性（socket 统计）

新增命令级文档说明每条命令的请求/响应属性集。过滤属性全部可选，遵循 inet_diag 约定复用 reply 属性 ID 作为过滤输入，零 ABI 风险。

### 2.2 内核 `net/core/net-delayacct.c`（ISSUE-5）

**nla_policy 扩展**：新增 TYPE/FAMILY/LPORT/RPORT/LADDR/RADDR 的 policy，LADDR/RADDR 使用 `NLA_POLICY_MIN_LEN(sizeof(__be32))` 确保至少 IPv4 长度。

**`net_delayacct_match_filter()` 函数**（新增 ~75 行）：
- 检查 6 个可选过滤属性：proto/family/lport/rport/laddr/raddr
- 缺失属性视为通配符（match all）
- 地址比较按 socket family 区分 IPv4（4 字节 `__be32`）/IPv6（16 字节 `in6_addr`）
- 地址长度与 socket family 不匹配时返回 false（跳过该 socket）

**`.dumpit` 集成**：
- 通过 `genl_info_dump(cb)` 获取 `const struct genl_info *info`
- 在 `is_inet_tcp_udp(sk)` 检查之后调用 `net_delayacct_match_filter(sk, info)`
- 不匹配的 socket 被静默跳过（`fd++; continue;`）

**`fill_sock()` 端序 bug 修复**（关键修复）：
- 原代码 `lport = ntohs(sk->sk_num)` 错误地将 host byte order 的 `sk_num` 再次翻转
- `sk->sk_num` 类型是 `__u16`（host byte order），不需要 `ntohs`
- 修复为 `lport = sk->sk_num`，并添加注释说明 `sk_dport` 才是 `__be16` 需要 `ntohs`
- 此 bug 影响所有 lport 输出，但之前测试未检查具体端口号所以未发现

**`net_delayacct_match_filter()` 端序 bug 修复**：
- 原代码 `ntohs(sk->sk_num) != lport` 同样错误
- 修复为 `sk->sk_num != lport`，并添加注释

### 2.3 用户态 `userspace/get_sockdelays/get_sockdelays.c`（ISSUE-5）

**新增 `struct net_delayacct_filter`**：6 个可选字段，每个带 `has_*` 标志。

**新增 CLI 选项**（long-only，无 short alias）：
- `--proto <tcp|udp|6|17>` — 协议过滤
- `--family <4|6|inet|inet6>` — 地址族过滤
- `--lport <port>` / `--rport <port>` — 端口过滤
- `--laddr <addr>` / `--raddr <addr>` — 地址过滤（inet_pton 自动检测 IPv4/IPv6）

**`do_query()` 修改**：新增 `const struct net_delayacct_filter *filter` 参数，GET_BY_PID 时追加过滤属性到请求消息。

### 2.4 测试脚本 `ci/qemu/run-tests.sh`（ISSUE-7）

新增 3 个过滤测试（Test 14-16）：
- **Test 14**：`--proto tcp` / `--proto udp` 协议过滤
- **Test 15**：`--lport` 端口过滤
- **Test 16**：`--proto tcp --lport` 组合过滤（AND 语义）

测试脚本修复：
- Test 14/16：iperf3 client `-t 3` → `-t 8`，避免查询期间 UDP 数据 socket 被关闭
- Test 15/16：grep 模式从 `lport=<port>` 改为 `local=\[.*\]:<port>`，匹配实际输出格式
- Test 16：移除重复的 iperf3 server（原代码在同一端口启动两个 server，第二个必然失败）

### 2.5 patch 文件同步

- `0005-net-add-uapi-header.patch`: 85 → 114 行，commit message 文档化属性角色注释
- `0006-net-add-internal-header.patch`: 无变化
- `0007-net-core-add-module.patch`: 769 → 887 行，commit message 文档化过滤功能 + 端序修复注释

## 3. 变更原因

### 设计决策

**为什么复用现有 UAPI 属性而非新增过滤属性**：
- 遵循 inet_diag 约定（同套属性 ID 兼做请求过滤和响应输出）
- 零 ABI 扩展风险（不新增 enum 值，不改变属性顺序）
- 符合 ISSUE-6 的兼容性要求

**为什么在 `.dumpit` 中通过 `genl_info_dump(cb)` 获取 info 而非存入 `cb->ctx`**：
- `cb->ctx` 仅 48 字节，当前 `net_delayacct_dump_ctx` 已占 40 字节
- 过滤条件（6 个字段 + 标志）约需 50+ 字节，远超剩余 8 字节
- `genl_info_dump(cb)` 在 `.dumpit` 中可用，每次调用只需指针解引用
- nla 解析很快（指针遍历），每个 socket 一次的开销可忽略

**为什么不在 GET_BY_INODE 中添加过滤**：
- inode 已唯一标识一个 socket
- 添加过滤会改变 GET_BY_INODE 的语义
- 用户需要过滤应使用 GET_BY_PID

**为什么地址比较按长度区分 IPv4/IPv6**：
- NLA 属性是变长的（4 或 16 字节）
- `NLA_POLICY_MIN_LEN(sizeof(__be32))` 确保至少 4 字节
- 过滤地址长度与 socket family 不匹配时跳过，避免类型混淆

### Bug 根因分析

**fill_sock() lport 端序 bug**：
- `sk->sk_num` 类型是 `__u16`，存储的是 host byte order 的本地端口号
- `ntohs()` 是 network-to-host 转换，对已经是 host order 的值会错误翻转字节
- x86 是小端架构，`ntohs(21416)` = `0xA853` = 43091（字节翻转后的错误值）
- 此 bug 自项目初始就存在，但因之前测试只检查 proto=tcp/udp 不检查具体端口，一直未暴露

**match_filter() lport 端序 bug**：
- 与 fill_sock() 相同的根因，复制了错误的 `ntohs(sk->sk_num)` 模式
- 导致 `--lport 21416` 过滤时，内核用 `ntohs(21416)=43091` 与用户传入的 `21416` 比较，永远不匹配

**注意 sk_dport 不同**：
- `sk->sk_dport` 类型是 `__be16`（network byte order），`ntohs(sk->sk_dport)` 是正确的
- `sk->sk_num` 类型是 `__u16`（host byte order），不需要 `ntohs`

## 4. 踩坑记录

### 坑1: fill_sock() 端序 bug 隐藏至今

- **问题描述**：`--lport 21416` 过滤返回 4 个 socket（过滤逻辑正确），但测试检查 `lport=21416` 匹配数为 0
- **原因分析**：fill_sock() 输出 `lport = ntohs(sk->sk_num) = 43091`（错误翻转），测试 grep `lport=21416` 找不到
- **解决方案**：fill_sock() 改为 `lport = sk->sk_num`，match_filter() 改为 `sk->sk_num != lport`
- **如何避免**：`sk->sk_num` 是 `__u16`（host order），`sk->sk_dport` 是 `__be16`（network order），两者端序不同，不能统一用 `ntohs`。修改网络代码前必须确认每个字段的类型注释

### 坑2: Test 14 --proto udp 返回空

- **问题描述**：`--proto udp` 过滤返回空，但无过滤时有 UDP socket
- **原因分析**：iperf3 UDP client `-t 3` 传输结束后，server 关闭与该 client 关联的 UDP 数据 socket。三次顺序查询（all/tcp/udp）中，第三次查询时 UDP socket 已不存在
- **解决方案**：iperf3 client `-t 3` → `-t 8`，确保三次查询都在传输期间完成
- **如何避免**：iperf3 server 的 UDP 数据 socket 生命周期与 client 绑定，测试多轮查询时必须确保 client 仍在传输

### 坑3: Test 16 端口冲突

- **问题描述**：Test 16 "iperf3 server failed to start"
- **原因分析**：原代码在同一端口 21417 启动两个 iperf3 server（`iperf3 -s -p 21417 &` 两次），第二个因端口被占用而失败
- **解决方案**：iperf3 server 默认同时监听 TCP 和 UDP，只需一个 server 实例
- **如何避免**：iperf3 server 默认同时处理 TCP 和 UDP，不需要为每个协议启动单独的 server

### 坑4: 测试 grep 模式不匹配输出格式

- **问题描述**：Test 15/16 grep `lport=<port>` 但实际输出是 `local=[addr]:port`
- **原因分析**：用户态输出格式是 `local=%-26s`（地址:端口），不是 `lport=port`
- **解决方案**：grep 模式改为 `local=\[[^]]*\]:$PORT( |$)` 匹配实际格式
- **如何避免**：编写测试断言前必须先确认工具的实际输出格式，不能凭属性名猜测

## 5. 测试验证

- [x] 内核 `net-delayacct.o` 编译通过（0 errors, 0 warnings）
- [x] 用户态工具编译通过（0 errors, 0 warnings，-Wall -Wextra）
- [x] 所有源文件 0 trailing whitespace
- [x] patch 0005/0006/0007 重新生成，body MATCH，作者统一
- [x] 完整 bzImage 编译通过（#58）
- [x] QEMU 16 项测试全部通过（13 基础 + 3 过滤）

### QEMU 测试结果（16/16 PASS, 0 FAIL, 0 SKIP, TCG 模式, ~137s）

| Test | 描述 | 结果 |
|------|------|------|
| 01 | PID 查询 | PASS: data_lines=2, proto=tcp |
| 02 | Inode 查询 | PASS: inode=492 matched |
| 03 | 重置计数器 | PASS: all counters=0 |
| 04 | TCP 路径 | PASS: proto=tcp found |
| 05 | UDP 路径 | PASS: proto=udp (server=1, client=1) |
| 06 | 多 Socket 枚举 | PASS: client=5, server=6 |
| 07 | JSON 输出 | PASS: valid JSON |
| 08 | Debug 模式 | PASS: 10 debug lines |
| 09 | 高并发 | PASS: 10 sockets, RX=2485 |
| 10 | 大流量 | PASS: RX=692, TX=868 |
| 11 | 混合协议 | PASS: TCP隔离正确 |
| 12 | 边界条件 | PASS: 4/4 checks |
| 13 | 并发压力 | PASS: 320 queries, no oops |
| **14** | **--proto 过滤** | **PASS: all(tcp=2,udp=1) tcp_only(tcp=2,udp=0) udp_only(tcp=0,udp=1)** |
| **15** | **--lport 过滤** | **PASS: all=4, matched=4, nomatch=0** |
| **16** | **组合过滤** | **PASS: baseline(tcp=2,udp=1) filtered(tcp=2,udp=0,port_match=2)** |

- 测试日志: `tests/reports/local/test-20260728_201401.log`

## 6. 待办/遗留问题

- ISSUE-7（过滤测试补充）已在本 TASK 中一并完成（Test 14-16）
- 过滤功能已全部实现并验证通过，无遗留问题
- 等待 Reviewer 复审确认 ISSUE-5/6/7 闭环

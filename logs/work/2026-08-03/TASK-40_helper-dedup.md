# [TASK-40] helper 代码去重（提取公共 corked_send_loop）

- **日期**: 2026-08-03
- **关联需求/Issue**: v6.3.0 SCOPE_AND_TASKS.md TASK-40（v6.2.0 问题 2.1.3）

## 1. 任务描述

将 [tests/helper/delayacct_path_test.c](file:///home/lai/Code/NET_DELAYACCT/tests/helper/delayacct_path_test.c) 中 `do_corked_udp_client` 与 `do_corked_udp6_client` 的 ~90% 重复代码提取为公共函数 `corked_send_loop`，消除 v6.2.0 问题 2.1.3 指出的代码重复。

两个函数在重构前各自包含完整的 sendto 循环 + cork/uncork burst 逻辑 + 最终 flush + 错误处理，仅 socket 创建和地址结构不同（AF_INET vs AF_INET6）。

## 2. 变更内容

### 文件: [tests/helper/delayacct_path_test.c](file:///home/lai/Code/NET_DELAYACCT/tests/helper/delayacct_path_test.c)

#### 2.1 新增公共函数 `corked_send_loop`（L306-353）

```c
#define CORK_BURST 8
static int corked_send_loop(int s, struct sockaddr *addr, socklen_t addrlen,
                            int duration, const char *label)
```

封装以下逻辑（调用方负责 socket 创建 + UDP_CORK 设置 + 目标地址）：
- 1000 字节包缓冲区初始化
- sendto 循环（duration 秒内持续发送）
- 每 CORK_BURST 个包 uncork → usleep(500) → 重新 cork（触发 flush）
- 最终 uncork flush 剩余缓冲区
- close(s) + 日志输出

#### 2.2 `do_corked_udp_client` 精简（L356-382）

重构后仅保留：
- `socket(AF_INET, SOCK_DGRAM, 0)` 创建
- `setsockopt(IPPROTO_UDP, UDP_CORK)` 设置
- `sockaddr_in` 地址结构填充 + `inet_pton` 解析
- 调用 `corked_send_loop(s, ..., "corked-udp-client")`

#### 2.3 `do_corked_udp6_client` 精简（L387-420）

重构后仅保留：
- `socket(AF_INET6, SOCK_DGRAM, 0)` 创建
- `setsockopt(IPPROTO_IPV6, IPV6_V6ONLY)` 设置（限制 IPv6 only）
- `setsockopt(IPPROTO_UDP, UDP_CORK)` 设置
- `sockaddr_in6` 地址结构填充 + `inet_pton` 解析
- 调用 `corked_send_loop(s, ..., "corked-udp6-client")`

#### 2.4 重构前后行数对比

| 函数 | 重构前 | 重构后 |
|------|--------|--------|
| `do_corked_udp_client` | 64 行 | 27 行（含函数签名+大括号） |
| `do_corked_udp6_client` | 71 行 | 34 行 |
| `corked_send_loop`（新增） | — | 41 行 |
| **合计** | **135 行** | **102 行** |

净减少 33 行（24%），但更重要的是消除了 ~40 行 sendto/cork 逻辑的**完全重复**（重构前在两个函数中各存在一份）。

## 3. 变更原因

### 3.1 为什么提取公共函数

v6.2.0 问题 2.1.3 指出两个函数代码重复约 90%，仅地址族不同。重复代码导致：
- 修改 cork 逻辑需同时改两处，容易遗漏（如 burst 数量、uncork 时机）
- 错误处理风格不一致的风险（IPv4 用 `perror("sendto")`，IPv6 可能写成不同消息）
- 代码审查时需对比两份近乎相同的代码

### 3.2 为什么用 `struct sockaddr *` + `socklen_t` 参数

- `sendto` 的地址参数本身就是 `const struct sockaddr *`，直接传递无需转换
- `sockaddr_in` 和 `sockaddr_in6` 都可安全 cast 为 `struct sockaddr *`（POSIX 保证）
- `addrlen` 参数让公共函数兼容 IPv4（`sizeof(sockaddr_in)`）和 IPv6（`sizeof(sockaddr_in6)`）

### 3.3 为什么 `label` 参数

- 重构前 IPv4 打印 `"corked-udp-client: sending to %s:%d for %ds pid=%d"`，IPv6 打印 `"corked-udp6-client: sending to [%s]:%d for %ds pid=%d"`
- 重构后公共函数不再持有 IP/port 信息（这些在调用方填充地址后就不再需要），改用 `label` 参数区分日志来源
- 日志简化为 `"%s: sending for %ds pid=%d"`，足够诊断（IP/port 在 socket 创建阶段已由调用方验证）

## 4. 踩坑记录

### 坑1：`yes` 变量作用域变化导致 shadow warning

- **问题描述**：重构前 `do_corked_udp_client` 在函数顶部声明 `int yes = 1` 用于 `setsockopt(UDP_CORK)`，然后在 burst 循环内复用 `yes = 1` 重新 cork。提取到公共函数后，burst 循环内的 `yes` 需要重新声明，否则引用的是调用方的局部变量（不存在）
- **原因分析**：公共函数 `corked_send_loop` 没有 `yes` 变量，burst 循环内需要独立的 `int yes = 1`
- **解决方案**：在 burst 循环内 `int no = 0; ... int yes = 1;` 局部声明，作用域限定在 if 块内
- **如何避免**：提取公共函数时，需检查所有引用的外部变量是否应作为参数传入或在函数内重新声明

## 5. 测试验证

### 5.1 编译验证

```bash
$ make -B -C tests/helper CC="gcc"
  CC+LD   delayacct_path_test
  (static linked)
# EXIT=0, 无 warning
```

### 5.2 本地测试（TCG 模式）

重构后本地测试 25/25 PASS（与 TASK-39 同次验证），关键路径测试不受影响：

- Test 19（TCP splice RX path）：PASS — 不涉及 corked 逻辑
- Test 20（UDP corked TX path）：PASS — `do_corked_udp_client` 调用 `corked_send_loop` 正常触发 `udp_push_pending_frames`
- Test 21（IPv6 UDP corked TX path）：PASS — `do_corked_udp6_client` 调用 `corked_send_loop` 正常触发 `udp_v6_push_pending_frames`

### 5.3 行为等价性确认

重构前后 Test 19/20 的测试输出一致：
- corked-udp-client 日志格式略有变化（`sending to %s:%d for %ds` → `sending for %ds`），但不影响测试断言
- burst/uncork 行为完全一致（CORK_BURST=8, usleep(500)）
- 最终 flush 逻辑一致

## 6. 待办/遗留问题

- [x] 提取公共 `corked_send_loop` — **已完成**
- [x] IPv4/IPv6 调用方精简为 socket 创建 + 地址设置 — **已完成**
- [x] 编译验证无 warning — **已完成**
- [x] 本地测试 25/25 PASS — **已完成（与 TASK-39 同次）**
- [ ] CI KVM 模式验证 — 待推送后 CI 验证

### SCOPE_AND_TASKS.md 注意事项回应

SCOPE 中提到"同步检查 `tcp-sender`：若 tcp-sender 也有可提取的公共发送逻辑，一并去重"。

检查结果：`do_tcp_sender`（L424-478）的发送逻辑与 corked 发送有本质区别：
- tcp-sender 用 `send()`（面向连接，无地址参数），corked 用 `sendto()`（无连接，需地址）
- tcp-sender 无 cork/uncork burst 逻辑，仅线性发送 + usleep(200)
- tcp-sender 设置 TCP_MAXSEG（MSS 调整），corked 不涉及

两者无重复逻辑可提取，故不重构 tcp-sender。

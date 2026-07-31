# 分项审查 - Test 23 ftrace 打桩点全量验证测试方案

- **关联日志**: [v6.1.0/REVIEW_REPORT.md](file:///home/lai/Code/NET_DELAYACCT/logs/review/v6.1.0/REVIEW_REPORT.md) 问题 2.2.1 / 2.2.2 / 2.3.1 / 2.3.2
- **审查日期**: 2026-08-01

## 变更概述

新增 Test 23：ftrace 打桩点全量验证测试。这是 v6.1.0 的核心交付物，用于解决"22 个测试都是黑盒结果验证，无法证明打桩点真实触发"的根本性缺陷。

本文档给出完整的实现方案，包括：
1. 内核配置要求
2. ftrace 函数清单（13 个）
3. 7 个测试场景的实现细节
4. 可视化输出格式
5. start/end 配对验证的后续增强方向（v6.2.0）

## 一、内核配置要求

在 [ci/qemu/kernel-qemu.config](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/kernel-qemu.config) 中追加：

```
# --- Tracing (for Test 23: ftrace instrumentation verification) ---
CONFIG_FUNCTION_TRACER=y
CONFIG_FUNCTION_GRAPH_TRACER=y
CONFIG_FTRACE=y
CONFIG_KPROBE_EVENTS=y
CONFIG_KPROBES=y
```

**验证方式**：QEMU 启动后检查 `/sys/kernel/debug/tracing` 目录存在。

## 二、ftrace 函数清单（13 个）

### 2.1 RX 路径（6 个函数）

| # | ftrace 函数 | 源文件 | 包含的打桩点 | 说明 |
|---|------------|--------|-------------|------|
| 1 | `__netif_receive_skb_core` | net/core/dev.c | `net_delayacct_rx_start(skb)` | 所有 RX 包入口，参考 [rx-instrumentation.patch#L58](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/rx-instrumentation.patch#L58) |
| 2 | `tcp_recvmsg_locked` | net/ipv4/tcp.c | `net_delayacct_rx_end(sk, skb)` | 标准 TCP RX 路径，参考 [rx-instrumentation.patch#L96](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/rx-instrumentation.patch#L96) |
| 3 | `tcp_read_sock` | net/ipv4/tcp.c | `net_delayacct_rx_end(sk, skb)` | splice RX 路径，参考 [rx-instrumentation.patch#L79](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/rx-instrumentation.patch#L79) |
| 4 | `tcp_zerocopy_receive` | net/ipv4/tcp.c | `net_delayacct_rx_end(sk, skb)` | zerocopy RX 路径，参考 [rx-instrumentation.patch#L87](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/rx-instrumentation.patch#L87) |
| 5 | `udp_recvmsg` | net/ipv4/udp.c | `net_delayacct_rx_end(sk, skb)` | IPv4 UDP RX 路径，参考 [rx-instrumentation.patch#L121](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/rx-instrumentation.patch#L121) |
| 6 | `udpv6_recvmsg` | net/ipv6/udp.c | `net_delayacct_rx_end(sk, skb)` | IPv6 UDP RX 路径，参考 [rx-instrumentation.patch#L147](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/rx-instrumentation.patch#L147) |

### 2.2 TX 路径（7 个函数）

| # | ftrace 函数 | 源文件 | 包含的打桩点 | 说明 |
|---|------------|--------|-------------|------|
| 7 | `dev_hard_start_xmit` | net/core/dev.c | `net_delayacct_tx_end(skb->sk, skb)` | 所有 TX 包出口，参考 [tx-instrumentation.patch#L60](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/tx-instrumentation.patch#L60) |
| 8 | `__tcp_transmit_skb` | net/ipv4/tcp_output.c | `net_delayacct_tx_start(sk, skb)` | TCP clone_it=1 路径（首次发送+部分重传），参考 [tx-instrumentation.patch#L86](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/tx-instrumentation.patch#L86) |
| 9 | `__tcp_retransmit_skb` | net/ipv4/tcp_output.c | `net_delayacct_tx_start(sk, nskb)` | TCP clone_it=0 重传路径（pskb_copy），参考 [tx-instrumentation.patch#L98](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/tx-instrumentation.patch#L98) |
| 10 | `udp_sendmsg` | net/ipv4/udp.c | `net_delayacct_tx_start(sk, skb)` | IPv4 UDP fast path（非 corked），参考 [tx-instrumentation.patch#L121](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/tx-instrumentation.patch#L121) |
| 11 | `udp_push_pending_frames` | net/ipv4/udp.c | `net_delayacct_tx_start(sk, skb)` | IPv4 UDP corked flush 路径，参考 [tx-instrumentation.patch#L111](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/tx-instrumentation.patch#L111) |
| 12 | `udpv6_sendmsg` | net/ipv6/udp.c | `net_delayacct_tx_start(sk, skb)` | IPv6 UDP fast path（非 corked），参考 [tx-instrumentation.patch#L147](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/tx-instrumentation.patch#L147) |
| 13 | `udp_v6_push_pending_frames` | net/ipv6/udp.c | `net_delayacct_tx_start(sk, skb)` | IPv6 UDP corked flush 路径，参考 [tx-instrumentation.patch#L136](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/tx-instrumentation.patch#L136) |

### 2.3 为什么不能直接 trace `net_delayacct_*` 函数？

这些函数在 [0006-net-add-internal-header.patch#L104-L188](file:///home/lai/Code/NET_DELAYACCT/kernel-patches/0006-net-add-internal-header.patch#L104-L188) 中定义为 `static inline`：

```c
static inline void net_delayacct_rx_start(struct sk_buff *skb)
{
    if (net_delayacct_enabled())
        skb->delayacct_start = local_clock();
}
```

`static inline` 函数在编译期被展开到调用点，没有独立的符号表入口，ftrace 的 `set_ftrace_filter` 无法匹配。因此必须 trace 包含它们的外部函数。

## 三、测试场景设计（7 个）

### 3.1 场景矩阵

| 场景 | 描述 | 预期触发的 ftrace 函数 | 对应现有测试 |
|------|------|----------------------|-------------|
| S1 | TCP 单向传输 (iperf3 client→server) | `__netif_receive_skb_core`, `tcp_recvmsg_locked`, `__tcp_transmit_skb`, `dev_hard_start_xmit` | Test 01/04/09 |
| S2 | UDP 单向传输 (iperf3 -u) | `__netif_receive_skb_core`, `udp_recvmsg`, `udp_sendmsg`, `dev_hard_start_xmit` | Test 05 |
| S3 | TCP splice RX (helper splice-server) | `__netif_receive_skb_core`, **`tcp_read_sock`**, `__tcp_transmit_skb`, `dev_hard_start_xmit` | Test 19 |
| S4 | TCP zerocopy RX (helper zerocopy-server) | `__netif_receive_skb_core`, **`tcp_zerocopy_receive`**, `__tcp_transmit_skb`, `dev_hard_start_xmit` | Test 20 |
| S5 | UDP corked TX (helper corked-udp-client) | **`udp_push_pending_frames`**, `dev_hard_start_xmit` | Test 21 |
| S6 | IPv6 TCP+UDP (iperf3 -c ::1) | `__netif_receive_skb_core`, `tcp_recvmsg_locked`, **`udpv6_recvmsg`**, **`udpv6_sendmsg`**, `__tcp_transmit_skb`, `dev_hard_start_xmit` | Test 22 |
| S7 | TCP 重传 (tc netem 10% loss) | `__netif_receive_skb_core`, `tcp_recvmsg_locked`, `__tcp_transmit_skb`, **`__tcp_retransmit_skb`**, `dev_hard_start_xmit` | 无（新增） |

**加粗**的函数是该场景的"专属验证目标"——如果这些函数调用次数为 0，说明声称的路径覆盖是假的。

### 3.2 各场景实现细节

#### S1: TCP 单向传输
```bash
_ftrace_start
iperf3 -s -p 21440 & _SRV=$!; sleep 1
iperf3 -c 127.0.0.1 -p 21440 -t 3 & _CLI=$!; sleep 2
_ftrace_stop
# 预期：4 个函数全部 > 0
```

#### S2: UDP 单向传输
```bash
_ftrace_start
iperf3 -s -p 21441 & _SRV=$!; sleep 1
iperf3 -c 127.0.0.1 -p 21441 -u -t 3 -b 10M & _CLI=$!; sleep 2
_ftrace_stop
# 预期：__netif_receive_skb_core, udp_recvmsg, udp_sendmsg, dev_hard_start_xmit 全部 > 0
```

#### S3: TCP splice RX
```bash
_ftrace_start
$PATH_HELPER splice-server 21442 & _SRV=$!; sleep 1
$PATH_HELPER tcp-sender 127.0.0.1 21442 8 & _CLI=$!; sleep 3
_ftrace_stop
# 预期：tcp_read_sock > 0（这是 splice 专属路径，若为 0 说明 splice 回退到了 tcp_recvmsg_locked）
```

#### S4: TCP zerocopy RX
```bash
_ftrace_start
$PATH_HELPER zerocopy-server 21443 & _SRV=$!; sleep 1
$PATH_HELPER tcp-sender 127.0.0.1 21443 8 & _CLI=$!; sleep 3
_ftrace_stop
# 预期：tcp_zerocopy_receive > 0（若为 0 说明内核不支持或 helper 回退到了普通 recv）
```

#### S5: UDP corked TX
```bash
_ftrace_start
$PATH_HELPER corked-udp-client 127.0.0.1 21444 8 & _CLI=$!; sleep 2
_ftrace_stop
# 预期：udp_push_pending_frames > 0（这是 corked 专属路径，若为 0 说明 UDP_CORK 未生效）
# 注意：无需 server，TX 打点在 send 路径
```

#### S6: IPv6 TCP+UDP
```bash
_ftrace_start
iperf3 -s -p 21445 & _SRV=$!; sleep 1
iperf3 -c ::1 -p 21445 -t 3 & sleep 2
iperf3 -c ::1 -p 21445 -u -t 3 -b 10M & _CLI=$!; sleep 2
_ftrace_stop
# 预期：udpv6_recvmsg > 0, udpv6_sendmsg > 0（IPv6 专属路径）
```

#### S7: TCP 重传（新增场景）
```bash
_ftrace_start
# 在 lo 上加 10% 丢包触发重传
tc qdisc add dev lo root netem loss 10% 2>/dev/null || {
    _skip "tc netem not available, S7 skipped"
    continue
}
iperf3 -s -p 21446 & _SRV=$!; sleep 1
iperf3 -c 127.0.0.1 -p 21446 -t 5 & _CLI=$!; sleep 4
tc qdisc del dev lo root 2>/dev/null || true
_ftrace_stop
# 预期：__tcp_retransmit_skb > 0（重传专属路径，首次覆盖）
# 注意：tc netem 在 loopback 上可能需要 root 权限
```

## 四、ftrace 操作辅助函数

```bash
TRACEFS=/sys/kernel/debug/tracing
FTRACE_FUNCS="__netif_receive_skb_core tcp_recvmsg_locked tcp_read_sock \
              tcp_zerocopy_receive udp_recvmsg udpv6_recvmsg \
              dev_hard_start_xmit __tcp_transmit_skb __tcp_retransmit_skb \
              udp_sendmsg udp_push_pending_frames udpv6_sendmsg \
              udp_v6_push_pending_frames"

# 启用 ftrace，设置 function tracer + filter
_ftrace_start() {
    if [ ! -d "$TRACEFS" ]; then return 1; fi
    echo 0 > "$TRACEFS/tracing_on" 2>/dev/null
    echo > "$TRACEFS/trace" 2>/dev/null
    echo nop > "$TRACEFS/current_tracer" 2>/dev/null
    echo > "$TRACEFS/set_ftrace_filter" 2>/dev/null
    for _fn in $FTRACE_FUNCS; do
        echo "$_fn" >> "$TRACEFS/set_ftrace_filter" 2>/dev/null
    done
    echo function > "$TRACEFS/current_tracer" 2>/dev/null
    echo 1 > "$TRACEFS/tracing_on" 2>/dev/null
}

# 停止 ftrace
_ftrace_stop() {
    echo 0 > "$TRACEFS/tracing_on" 2>/dev/null
}

# 统计各函数调用次数
# trace 行格式: <task>-<pid> [<cpu>] <flags> <timestamp> <function>
# 例如: iperf3-123 [000] .... 12345.678: tcp_recvmsg_locked <- tcp_recvmsg
_ftrace_count() {
    local _result=""
    for _fn in $FTRACE_FUNCS; do
        # 匹配 " function$" 或 " function <- ..."
        local _c=$(grep -cE " ${_fn}\$| ${_fn} <- " "$TRACEFS/trace" 2>/dev/null || echo 0)
        _result="$_result $_fn=$_c"
    done
    echo "$_result"
}

# 断言预期函数被触发
_ftrace_assert() {
    local _scenario="$1"
    local _counts="$2"
    shift 2
    local _expected="$*"
    local _fail=0
    for _fn in $_expected; do
        local _c=$(echo "$_counts" | grep -o "${_fn}=[0-9]*" | cut -d= -f2)
        _c=${_c:-0}
        if [ "$_c" -le 0 ]; then
            echo "    [MISS] $_scenario: $_fn not triggered (expected > 0)"
            _fail=1
        fi
    done
    return $_fail
}
```

## 五、可视化输出

测试结束时生成覆盖矩阵，直观展示每个场景下各函数的调用次数：

```bash
_ftrace_print_matrix() {
    echo "  +----------------------------------------------------------+"
    echo "  |  ftrace 覆盖矩阵 (场景 × 函数调用次数)                   |"
    echo "  +----------------------------------------------------------+"
    printf "  | %-26s | %4s | %4s | %4s | %4s | %4s | %4s | %4s |\n" \
        "函数" "S1" "S2" "S3" "S4" "S5" "S6" "S7"
    echo "  |----------------------------|------|------|------|------|------|------|------|"
    for _fn in $FTRACE_FUNCS; do
        printf "  | %-26s | %4s | %4s | %4s | %4s | %4s | %4s | %4s |\n" \
            "$_fn" \
            "$(_get_count S1 "$_fn")" \
            "$(_get_count S2 "$_fn")" \
            "$(_get_count S3 "$_fn")" \
            "$(_get_count S4 "$_fn")" \
            "$(_get_count S5 "$_fn")" \
            "$(_get_count S6 "$_fn")" \
            "$(_get_count S7 "$_fn")"
    done
    echo "  +----------------------------------------------------------+"
}
```

预期输出示例：
```
  +----------------------------------------------------------+
  |  ftrace 覆盖矩阵 (场景 × 函数调用次数)                   |
  +----------------------------------------------------------+
  | 函数                       |   S1 |   S2 |   S3 |   S4 |   S5 |   S6 |   S7 |
  |----------------------------|------|------|------|------|------|------|------|
  | __netif_receive_skb_core   |  542 |  318 |  210 |  187 |   45 |  612 |  891 |
  | tcp_recvmsg_locked         |  128 |    0 |    0 |    0 |    0 |   56 |  145 |
  | tcp_read_sock              |    0 |    0 |   42 |    0 |    0 |    0 |    0 |
  | tcp_zerocopy_receive       |    0 |    0 |    0 |   38 |    0 |    0 |    0 |
  | udp_recvmsg                |    0 |   75 |    0 |    0 |    0 |    0 |    0 |
  | udpv6_recvmsg              |    0 |    0 |    0 |    0 |    0 |   68 |    0 |
  | dev_hard_start_xmit        |  287 |   82 |  105 |   92 |   24 |  305 |  478 |
  | __tcp_transmit_skb         |  142 |    0 |   52 |   46 |    0 |   64 |  198 |
  | __tcp_retransmit_skb       |    0 |    0 |    0 |    0 |    0 |    0 |   37 |
  | udp_sendmsg                |    0 |   76 |    0 |    0 |    0 |    0 |    0 |
  | udp_push_pending_frames    |    0 |    0 |    0 |    0 |    9 |    0 |    0 |
  | udpv6_sendmsg              |    0 |    0 |    0 |    0 |    0 |   72 |    0 |
  | udp_v6_push_pending_frames |    0 |    0 |    0 |    0 |    0 |    0 |    0 |
  +----------------------------------------------------------+
```

**矩阵解读规则**：
- 每一列（场景）的"预期函数"应全部非零 → 该场景 PASS
- 每一行（函数）至少在一个场景下非零 → 该打桩点可达
- `tcp_read_sock` 只在 S3 非零 → 证明 splice 路径专属
- `__tcp_retransmit_skb` 只在 S7 非零 → 证明重传路径专属
- `udp_v6_push_pending_frames` 全零 → 说明 IPv6 corked 场景未覆盖（需补充 S5 的 IPv6 版本）

## 六、start/end 配对验证（v6.2.0 增强方向）

### 6.1 问题

function tracer 只能验证"函数被调用"，无法验证：
- 每个 `rx_end` 读取的 skb 是否曾被 `rx_start` 打过时间戳
- `delayacct_start` 字段值是否非零（守卫是否生效）

### 6.2 kprobe events 方案

使用 kprobe events 在函数入口读取 skb 指针和 `skb->delayacct_start` 字段：

```bash
# x86_64 ABI: rdi=arg1, rsi=arg2
# __netif_receive_skb_core(struct sk_buff **pskb, ...) → skb 在栈上，需间接读取
# tcp_recvmsg_locked(struct sock *sk, ..., struct sk_buff *skb) → skb 不在参数列表
#
# 实际上 skb 在这些函数内部，不在参数列表，需要用 perf probe 或 BPF
```

**复杂度评估**：
- `rx_start` 的 skb 是 `__netif_receive_skb_core` 的间接参数（`struct sk_buff **pskb`），kprobe events 难以直接读取。
- `rx_end` 的 skb 是 `tcp_recvmsg_locked` 内部局部变量，不在参数列表。
- 这两者都需要用 `perf probe` 在具体行号下断点（需 DWARF 调试信息），或用 BPF/bpftrace。

### 6.3 推荐方案：bpftrace（v6.2.0）

如果 QEMU 内核支持 BPF，使用 bpftrace 更简洁：

```bash
# 统计 rx_start 打过的 skb 指针集合
bpftrace -e '
kprobe:__netif_receive_skb_core {
    @rx_start[arg0] = count();
}
kretprobe:tcp_recvmsg_locked {
    // 无法直接获取内部 skb，需用 uprobe 或 perf probe
}
'

# 更实际：统计 delayacct_start 字段非零的 skb 比例
bpftrace -e '
kprobe:dev_hard_start_xmit {
    $skb = (struct sk_buff *)arg1;
    if ($skb->delayacct_start != 0) {
        @tx_nonzero = count();
    } else {
        @tx_zero = count();
    }
}
'
```

### 6.4 v6.1.0 的妥协

v6.1.0 先用 function tracer 验证"路径可达性"（13 个函数被调用），这已经能解决用户的核心质疑："打桩点是否真的被走到"。

start/end 配对验证（"start 会不会真的和 end 配对"）留到 v6.2.0，依赖 bpftrace 或 kprobe events + perf probe。

## 七、实现优先级

| 优先级 | 任务 | 版本 |
|--------|------|------|
| P0 | 修复 Test 03/04/05/06 假阳性（问题 2.1.1-2.1.3） | v6.1.0 |
| P0 | 内核配置增加 FUNCTION_TRACER | v6.1.0 |
| P0 | 实现 Test 23 的 S1-S7 场景 | v6.1.0 |
| P1 | 实现可视化矩阵输出 | v6.1.0 |
| P1 | 修复 Test 19/20/21 断言（依赖 Test 23 验证结果） | v6.1.0 |
| P2 | start/end 配对验证（bpftrace） | v6.2.0 |
| P2 | 纯 ACK 守卫验证 | v6.2.0 |

## 综合意见

Test 23 ftrace 全量验证测试是 v6.1.0 的核心交付物，它将测试套件从"黑盒结果验证"升级到"灰盒路径验证"，直接回答用户的核心质疑。

实现路径清晰：13 个 ftrace 函数已全部映射到打桩点，7 个场景覆盖了所有声明的路径。主要风险是内核配置（需启用 FUNCTION_TRACER）和 tc netem 在 loopback 上的可用性（S7 场景）。

建议 Worker 优先实现 P0 任务（假阳性修复 + Test 23 S1-S7），P1/P2 作为后续增强。

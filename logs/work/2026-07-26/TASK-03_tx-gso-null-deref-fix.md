# TASK-03 修复 TX GSO 场景下的 NULL pointer dereference

- **日期**: 2026-07-26
- **关联 Review**: v2.0.0 议题 2.2.3（重开）
- **状态**: 修复完成，已重开对话等 Reviewer 回应

## 1. 任务描述

CI QEMU 测试报告 `BUG: kernel NULL pointer dereference, address: 0x0`，发生在内核启动 3.1 秒、PID 0 (swapper/0) 上下文。需要定位根因并修复。

## 2. 变更内容

### 2.1 修改的文件

| 文件 | 改动 |
|------|------|
| `kernel-patches/net-core-net-delayacct.c` | `tx_start` 移除 `sock_hold(sk)`；`tx_end` 移除 `sock_put(sk)`；新增详细注释解释原因 |
| `kernel-patches/include-net-net-delayacct.h` | `tx_start` 文档注释重写 |
| `kernel-patches/0006-net-add-internal-header.patch` | 同步上述头文件注释，行数 145→147 |
| `kernel-patches/0007-net-core-add-module.patch` | 从源文件完整重新生成 |
| `logs/dialogue/DLG-20260727-010000.md` | 重开议题 2.2.3，记录新根因和新建议 |

### 2.2 核心代码变更

**变更前**（共识方案，引入 bug）:
```c
void net_delayacct_tx_start(struct sock *sk, struct sk_buff *skb)
{
    skb->delayacct_start = ktime_get_ns();
    sock_hold(sk);          // ← 引用计数 +1
}

void net_delayacct_tx_end(struct sock *sk, struct sk_buff *skb)
{
    ...
    sock_put(sk);           // ← 引用计数 -1
}
```

**变更后**（依赖 skb->destructor 自动管理）:
```c
void net_delayacct_tx_start(struct sock *sk, struct sk_buff *skb)
{
    skb->delayacct_start = ktime_get_ns();
    /* 不调用 sock_hold(sk) */
}

void net_delayacct_tx_end(struct sock *sk, struct sk_buff *skb)
{
    ...
    /* 不调用 sock_put(sk) */
}
```

## 3. 变更原因

### 3.1 错误现象

```
[    3.105631]  slab kmalloc-128 start ffff973441a1bd80 pointer offset 80 size 128
[    3.106357] BUG: kernel NULL pointer dereference, address: 0000000000000000
[    3.106357] RIP: 0010:0x0
[    3.106357] CPU: 0 PID: 0 Comm: swapper/0
[    3.106355] WARNING: CPU: 1 PID: 104 at kernel/rcu/tree.c:2255 rcu_core+0x912/0x980
```

- `RIP: 0x0` → 调用了 NULL 函数指针
- `RDI: ffff973441a1bdd0` → 第一参数指向 kmalloc-128 slab 偏移 80 处
- 两个 CPU 的事件：CPU 0 swapper/0 NULL deref + CPU 1 kworker/104 RCU warning
- 时间戳 3.1s，属于 init 启动后

### 3.2 根因分析

Review v2.0.0 议题 2.2.3 的共识方案（`sock_hold` + `sock_put`）在 GSO 场景下不配对：

```
tcp_sendmsg_locked:
    skb = sk_stream_alloc_skb(sk, ...)
    tcp_skb_entail(sk, skb)        # 设置 skb->destructor = sock_wfree
    net_delayacct_tx_start(sk, skb) # sock_hold(sk) → sk_refcnt += 1

↓ GSO 切片（tcp_gso_segment / skb_segment）
↓ skb_segment 用 __copy_skb_header 复制父 skb 的字段到 N 个子段
↓ 子段继承 delayacct_start（非零）和 skb->sk
↓ 但 skb_segment 不会调用 sock_hold

dev_hard_start_xmit:
    while (skb) {
        net_delayacct_tx_end(skb->sk, skb)  # sock_put(sk) → sk_refcnt -= 1
        xmit_one(skb, ...)
        skb = next
    }
    # 循环 N 次，sk_refcnt -= N
```

**引用计数不配对**：`sk_refcnt += 1`（父 skb 一次） vs `sk_refcnt -= N`（N 个子段各一次）。

经过若干次 TX 后 `sk_refcnt` 提前归零，socket 被 `__sk_free` 释放。但 RCU 回调 `__sk_destruct` 已经被 `call_rcu` 排队，执行时调用 `sk->sk_destruct(sk)` —— 此时 `sk` 已被释放/复用，函数指针为 NULL → `RIP: 0x0`。

### 3.3 为什么原共识是错的

原 Review 2.2.3 担忧的 UAF 场景："skb 在 qdisc 被 drop，sk 已被 free，dev_hard_start_xmit 访问悬垂 skb->sk"。

实际上**这个场景不会发生**：
- TCP/UDP 的 skb 在 `tcp_skb_entail` / `skb_set_owner_w` 时设置 `skb->destructor = sock_wfree`
- `sock_wfree` 在 skb 释放时减少 `sk->sk_wmem_alloc`
- `__sk_destruct` 中检查 `sk_wmem_alloc` 是否归零
- 只要 skb 还没释放，`sk_wmem_alloc > 0`，socket 就不会被 free

即：**skb 持有的 `sk_wmem_alloc` 引用已经保证了 skb->sk 的生命周期**，不需要额外的 `sock_hold`。

### 3.4 为什么选择移除 sock_hold/sock_put 而不是其他方案

| 方案 | 评估 | 是否采纳 |
|------|------|----------|
| **A. 移除 sock_hold/sock_put** | 简单、正确、依赖内核既有的 destructor 机制 | ✅ 采纳 |
| B. 在 skb_segment 中给子段 sock_hold | 修改核心 GSO 代码，影响范围过大 | ❌ |
| C. 用 skb->cb 存标志区分父子 | cb 在不同层会被覆盖，不可靠 | ❌ |
| D. 在 tx_end 检查 skb 是否为 GSO 子段 | 没有可靠方法区分 | ❌ |

## 4. 踩坑记录

### 4.1 踩坑 1：共识方案未经 GSO 验证

**问题描述**: Review v2.0.0 议题 2.2.3 的共识"sock_hold + sock_put"在静态分析层面看似合理，但运行时在 GSO 场景下立即崩溃。

**原因分析**:
1. 共识讨论时只考虑了单 skb 的引用计数配对，忽略了 GSO 切片
2. `skb_segment` 的引用计数语义没有在对话中明确
3. 没有跑过 GSO 流量就达成了共识

**解决方案**: 移除 sock_hold/sock_put，依赖 skb->destructor 自动管理。

**如何避免**:
1. 涉及 skb 引用计数的修改，必须考虑 GSO/GRO 切片场景
2. 共识方案中涉及内核核心机制（如 skb_segment）时，必须验证其对所修改字段的处理
3. 引用计数修改必须问自己："这个增加和减少是否真的成对？在所有 skb 生命周期路径上？"

### 4.2 踩坑 2：误诊为编译问题

**问题描述**: 第一次看到 NULL deref 错误时，以为是 sock_from_file 编译错误同类问题，差点又去检查 patch 同步。

**原因分析**: NULL deref 是运行时错误，不是编译错误。RIP=0x0 是调用 NULL 函数指针，不是签名不匹配。

**解决方案**: 区分编译时错误（签名不匹配、缺头文件）和运行时错误（NULL deref、refcount 错乱）。

**如何避免**: 看到 Oops 日志先看 RIP 值，RIP=0x0 几乎总是 NULL 函数指针调用，应聚焦"哪个回调是 NULL"。

### 4.3 踩坑 3：0010 patch 应用位置错误

**问题描述**: 在排查过程中发现 `net_delayacct_init(&sk->sk_net_delayacct)` 在 sock.c 中插入位置缩进异常（L2180 无缩进），但 patch 标的 hunk 是 sk_prot_alloc L1990。

**原因分析**: patch 工具按上下文行匹配，不在乎 hunk header 的函数名和行号。0010 patch 的上下文行（`sk_tx_queue_clear(sk); }`）在 6.6 中实际位于 sk_alloc L2179，patch 应用到了那里，缩进丢失。

**解决方案**: 重新生成 0010 patch，修正 hunk header 和上下文行。

**如何避免**: patch 的 hunk header 函数名和行号只是辅助信息，真正决定应用位置的是上下文行。生成 patch 时必须验证上下文行在目标内核中唯一。

## 5. 测试验证

- 静态检查：通过
  - `sock_hold` / `sock_put` 在 .c 中已无残留调用
  - `tx_start` / `tx_end` 签名不变，调用方无需修改
  - 0006/0007 patch 行数自洽
- 运行时验证：待 CI 重新跑 QEMU 测试

## 6. 待办/遗留问题

- [ ] 等 Reviewer 回应重开的议题 2.2.3
- [ ] CI QEMU 测试通过后，本轮 Review v2.0.0 才能最终闭环
- [ ] 如果 Reviewer 不同意移除 sock_hold/sock_put，需要寻找第三种方案（如 skb->destructor hook）

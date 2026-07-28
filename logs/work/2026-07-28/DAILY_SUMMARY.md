# 每日工作汇总 - 2026-07-28

## 关联 Review 进度
- 当前响应的 Review: v4.0.0（设计深度审查）
- 今日修复问题数: 1/P1 (BUG-1 min/max), 1/P2 (ISSUE-4 overflow), 1/P2 (BUG-2 文档化)
- 对话结果: Reviewer 接受 BUG-2 降级、ISSUE-3/5 延后，所有议题已达成最终决议
- v4.0.0 状态: **待 Reviewer 最终闭环验证**

## 今日完成任务
| 编号 | 任务 | 关联问题 | 状态 | 备注 |
|------|------|----------|------|------|
| TASK-18 | 修复 BUG-1: min/max 延迟极值统计 | BUG-1 [P1] | ✅ 已验证通过 | uapi+内部头+内核模块+用户态工具 |
| TASK-19 | 同步 0005/0006/0007 patch 文件 | BUG-1+ISSUE-4 | 完成 | 3 patch + 3 standalone 全部同步 |
| TASK-20 | 修复 ISSUE-4: 64 位计数器溢出检测 | ISSUE-4 [P2] | ✅ 已验证通过 | pr_warn_once + U64_MAX-delta 检查 |
| TASK-21 | 补充 BUG-2 RESET 语义文档 | BUG-2 [P2] | ✅ 已验证通过 | UAPI+内部头注释补充，patch同步，13/13 PASS |

## 关键决策
- **min_ns 初始化为 U64_MAX**: 确保第一个样本总是更小，避免初始化为 0 导致 min 永远为 0 的 bug。用户态在 count==0 时归一化为 0 显示。
- **overflow 用 pr_warn_once 而非 pr_warn**: 高吞吐场景下每次包都检查，pr_warn 会导致日志洪泛；pr_warn_once 仅首次告警。溢出后仍执行累加（回绕），不丢弃统计。
- **patch 生成用 Python 脚本**: 从源文件逐行添加 `+` 前缀，确保 patch body 与源文件 100% 一致，避免手动编辑出错。
- **BUG-2 共识**: Reviewer 接受降级为 P2，承认初始 TOCTOU 分析有误，定性为"设计特性，需文档化"；per-socket 原子性已由 spinlock 保证，全局快照不一致是多 socket 遍历框架共性。
- **ISSUE-3/5 共识**: Netlink 标准 dump 重构和用户态过滤功能延后至 v5.0.0。

## 踩坑总结
- **坑1**: 初次 patch 同步遗漏了 0006（内部头文件）
  - **原因**: 只检查了 0005 和 0007，未发现 0006 的 `net_delayacct_init` 也新增了 min/max 初始化
  - **解决方案**: 用 `grep -c` 检查所有 patch 文件的 min/max/U64_MAX 引用
  - **避免方法**: 同步 patch 时必须全量检查所有相关 patch，不能只检查"明显相关"的
- **坑2**: 直接执行 `make bzImage` 遇到 nfs 子目录增量编译错误（与本次修改无关）
  - **原因**: 之前后台编译中断导致部分目标文件状态不一致
  - **解决方案**: 使用项目提供的 `./local-test.sh --qemu-only` 脚本，自动从干净补丁状态重建
  - **避免方法**: 优先使用项目级测试脚本而非手动 make，确保构建环境一致

## 验证结果
- trailing whitespace: 0005/0006/0007 均为 0 ✓
- patch body vs source diff: 三个 patch 均 MATCH ✓
- 内核模块编译: net/core/net-delayacct.o 编译通过 ✓
- 用户态工具编译: get_sockdelays 重编译成功 ✓
- QEMU 测试 (TASK-18/19/20 修复后): **13/13 PASS, 0 FAIL, 0 SKIP** (TCG 模式, 132s)
- QEMU 测试 (TASK-21 文档补充后): **13/13 PASS, 0 FAIL, 0 SKIP** (TCG 模式, 137s)
- min/max 输出验证: `RX count=4 min=0.877ms max=6.332ms` — min < avg < max ✓
- count=0 归一化: min=0.000ms max=0.000ms ✓
- overflow 告警: 无（预期，584 年才溢出）✓
- 并发压力测试: 320 queries, ok=320 fail=0, no oops ✓

## v4.0.0 议题状态总览
| 编号 | 优先级 | 问题 | 最终状态 | 行动 |
|------|--------|------|----------|------|
| BUG-1 | P1 | 缺少 min/max 统计 | 已验证通过 | ✅ 闭环 |
| BUG-2 | P2 | RESET 语义文档化 | 已修复-待Reviewer验证 | UAPI+内部头注释已补充，patch已同步，13/13 PASS |
| ISSUE-3 | P2 | Netlink 非 dump | 共识-延后 v5.0.0 | v5.0.0 重构 |
| ISSUE-4 | P2 | 64 位溢出 | 已验证通过 | ✅ 闭环 |
| ISSUE-5 | P2 | 用户态过滤缺失 | 共识-延后 v5.0.0 | v5.0.0 实现 |

## 明日计划
- 等待 Reviewer 对 TASK-21 文档补充的最终验证
- 如 Reviewer 确认通过，推动 v4.0.0 正式闭环
- 生成 v4.0.0 FINAL_REPORT 综合总结文档

---

## 下午补充：v5.0.0 TASK-22 dumpit 重构（17:00-17:31）

### 关联 Review 进度更新
- 当前响应的 Review: v5.0.0（API 演进与功能扩展）
- v4.0.0 已闭环，ISSUE-3/5 正式进入 v5.0.0 实现阶段
- 今日完成: ISSUE-3 dumpit 重构（TASK-22）

### TASK-22 完成情况
| 编号 | 任务 | 关联问题 | 状态 | 备注 |
|------|------|----------|------|------|
| TASK-22 | dumpit 重构 GET_BY_PID | ISSUE-3 [P1] | ✅ 已验证通过 | .start/.dumpit/.done + cb->ctx 内联数组，patch 0007 同步 760 行，QEMU 13/13 PASS |

### 关键技术决策（v5.0.0）
- **cb->ctx 内联数组而非堆分配**: 内核 6.6 中 `struct netlink_callback` 的 `ctx` 是 `u8 ctx[48]` 内联数组（非 `void *` 指针），不需要 kzalloc/kfree，直接 cast 结构体到 `cb->ctx`。结构体 40 字节 < 48 字节限制。这与 ITEM-01 草案假设不同。
- **get_task_files() 不可用**: 内核 6.6 中未导出，使用 `task_lock + atomic_inc(&files->count) + task_unlock` 替代。
- **genl_info_dump() 返回 const**: `.start` 中声明为 `const struct genl_info *info`。
- **GET_BY_INODE 保持 doit**: 单条回复场景不需要 dumpit，保留 `net_delayacct_one_reply` 函数。

### 踩坑总结（v5.0.0）
- **坑3**: cb->ctx 不是指针
  - **原因**: ITEM-01 草案假设 cb->ctx 是 `void *` 指针，使用 kzalloc 分配
  - **解决方案**: 直接 cast 结构体到 cb->ctx，不需要分配/释放
  - **避免方法**: 修改内核代码前必须查看实际结构体定义
- **坑4**: net_delayacct_one_reply 被删除但 GET_BY_INODE 仍引用
  - **原因**: 重构时误删 one_reply，但 cmd_get_by_inode 仍调用它
  - **解决方案**: 保留 one_reply，仅用于 GET_BY_INODE 的 doit handler

### 验证结果（v5.0.0 TASK-22）
- trailing whitespace: 0007 patch 为 0 ✓
- patch body vs source diff: MATCH ✓
- 作者身份: laiguo-liang 统一 ✓
- bzImage 编译: 17:17 通过 ✓
- QEMU 测试: **13/13 PASS, 0 FAIL, 0 SKIP** (TCG 模式)
  - Test 11 多 socket dump: iperf3 server PID 318 的 TCP+UDP socket 全部正确返回 ✓
  - Test 13 并发压力: 16 workers × 20 = 320 次查询，无 oops/无死锁 ✓
- 测试日志: `tests/reports/local/test-20260728_172821.log`

### v5.0.0 议题状态总览
| 编号 | 优先级 | 问题 | 当前状态 | 行动 |
|------|--------|------|----------|------|
| ISSUE-3 | P1 | Netlink 非 dump | ✅ 已闭环 | TASK-22 + TASK-23 |
| REV-1 | P2 | `.start` 显式清零 `cb->ctx` | ✅ 已修复-已验证 | TASK-23 |
| REV-2 | P3 | `.dumpit` 末尾 return 0 | ✅ 已修复-已验证 | TASK-23 |
| ISSUE-5 | P1 | 用户态过滤缺失 | 共识-待实现 | TASK-24 |
| ISSUE-6 | P2 | UAPI 兼容性注释 | 共识-待实现 | TASK-25 |
| ISSUE-7 | P2 | dump/过滤测试补充 | 共识-待实现 | TASK-26/27 |

---

## 晚间补充：v5.0.0 TASK-23 REV-1/REV-2 修复（19:10-19:20）

### 关联 Review 进度更新
- Reviewer 复审（REVIEW_REPORT_v5.0.1）提出 2 个新议题：REV-1 (P2) + REV-2 (P3)
- Worker 接受两条意见，完成修复并验证

### TASK-23 完成情况
| 编号 | 任务 | 关联问题 | 状态 | 备注 |
|------|------|----------|------|------|
| TASK-23 | 修复 REV-1/REV-2 防御性改进 | REV-1 [P2] + REV-2 [P3] | ✅ 已验证通过 | 入口处显式 memset cb->ctx + 末尾 return 0，patch 0007 同步 769 行，QEMU 13/13 PASS |

### 关键技术决策（TASK-23）
- **REV-1 接受**: 防御性清零 `cb->ctx`，消除对 `__netlink_dump_start()` zero-init 的隐式依赖。在 `.start` 入口处显式 `memset(ctx, 0, sizeof(*ctx))`，删除末尾重复的 memset。
- **REV-2 接受**: `.dumpit` 末尾 `return skb->len` 改为 `return 0`，语义更清晰。遍历完成时 skb 为空（len==0），两者功能等价，但 `return 0` 是标准结束信号。

### 验证结果（TASK-23）
- trailing whitespace: 源文件和 patch 均为 0 ✓
- patch body vs source diff: MATCH ✓
- net-delayacct.o 编译: 19:15 通过 ✓
- bzImage 编译: 19:17 通过 ✓
- QEMU 测试: **13/13 PASS, 0 FAIL, 0 SKIP** (TCG 模式)
- 测试日志: `tests/reports/local/test-20260728_191710.log`

### 明日计划（v5.0.0 更新）
- 开始 TASK-24: 用户态过滤功能（ISSUE-5），复用现有 UAPI 属性作为过滤输入
- 同步实现内核 `net_delayacct_match_filter()` 和用户态 CLI 选项（--proto/--lport/--rport/--laddr/--raddr/--family）
- 补充 UAPI 属性注释（ISSUE-6）和过滤测试（ISSUE-7）

---

## 夜间补充：v5.0.0 TASK-24 ISSUE-5/6/7 实现（20:00-20:20）

### 关联 Review 进度更新
- 完成 ISSUE-5（用户态过滤）、ISSUE-6（UAPI 注释）、ISSUE-7（过滤测试）的全部实现
- 发现并修复了 2 个端序 bug（fill_sock + match_filter 中的 `ntohs(sk->sk_num)`）
- QEMU 测试从 13 项扩展到 16 项，全部通过

### TASK-24 完成情况
| 编号 | 任务 | 关联问题 | 状态 | 备注 |
|------|------|----------|------|------|
| TASK-24 | ISSUE-5/6/7 过滤功能+UAPI注释+测试 | ISSUE-5 [P1] + ISSUE-6 [P2] + ISSUE-7 [P2] | ✅ 已验证通过 | 内核过滤+用户态CLI+3新测试，patch 0005/0007 同步，QEMU 16/16 PASS |

### 关键技术决策（TASK-24）
- **复用现有 UAPI 属性作为过滤输入**：遵循 inet_diag 约定，零 ABI 扩展风险，符合 ISSUE-6 兼容性要求
- **过滤在 .dumpit 中通过 genl_info_dump(cb) 获取 info**：cb->ctx 仅剩 8 字节，无法存储过滤条件；genl_info_dump 每次调用只需指针解引用
- **fill_sock lport 修复**：`sk->sk_num` 是 `__u16`（host order），`ntohs()` 会错误翻转；`sk->sk_dport` 是 `__be16`（network order），`ntohs()` 正确

### 踩坑总结（TASK-24）
- **坑5**: fill_sock() 端序 bug 隐藏至今
  - **原因**: `ntohs(sk->sk_num)` 对已经是 host order 的值再次翻转，21416 → 43091
  - **解决方案**: `lport = sk->sk_num`（直接使用，不需要转换）
  - **避免方法**: `sk_num` 是 `__u16` host order，`sk_dport` 是 `__be16` network order，端序不同不能统一用 ntohs
- **坑6**: iperf3 UDP 数据 socket 生命周期与 client 绑定
  - **原因**: client 断开后 server 关闭关联的 UDP 数据 socket，多轮查询时第三次查不到
  - **解决方案**: client `-t 8` 确保查询期间 socket 存活
- **坑7**: iperf3 server 默认同时监听 TCP+UDP
  - **原因**: Test 16 在同一端口启动两个 server，第二个失败
  - **解决方案**: 只需一个 iperf3 server 实例

### 验证结果（TASK-24）
- trailing whitespace: 源文件和 patch 均为 0 ✓
- patch body vs source diff: 0005/0006/0007 全部 MATCH ✓
- 作者身份: laiguo-liang 统一 ✓
- bzImage 编译: #58 通过 ✓
- 用户态工具编译: 0 errors, 0 warnings ✓
- QEMU 测试: **16/16 PASS, 0 FAIL, 0 SKIP** (TCG 模式, ~137s)
  - Test 14 --proto: all(tcp=2,udp=1) tcp_only(tcp=2,udp=0) udp_only(tcp=0,udp=1) ✓
  - Test 15 --lport: all=4, matched=4, nomatch=0 ✓
  - Test 16 组合: baseline(tcp=2,udp=1) filtered(tcp=2,udp=0,port_match=2) ✓
- 测试日志: `tests/reports/local/test-20260728_201401.log`

### v5.0.0 议题状态总览（最终）
| 编号 | 优先级 | 问题 | 最终状态 | 行动 |
|------|--------|------|----------|------|
| ISSUE-3 | P1 | Netlink 非 dump | ✅ 已闭环 | TASK-22 + TASK-23 |
| REV-1 | P2 | `.start` 显式清零 `cb->ctx` | ✅ 已修复-已验证 | TASK-23 |
| REV-2 | P3 | `.dumpit` 末尾 return 0 | ✅ 已修复-已验证 | TASK-23 |
| ISSUE-5 | P1 | 用户态过滤缺失 | ✅ 已修复-待Reviewer验证 | TASK-24 |
| ISSUE-6 | P2 | UAPI 兼容性注释 | ✅ 已修复-待Reviewer验证 | TASK-24 |
| ISSUE-7 | P2 | dump/过滤测试补充 | ✅ 已修复-待Reviewer验证 | TASK-24 |

### 明日计划
- 等待 Reviewer 对 TASK-24 的复审验证
- 如 Reviewer 确认通过，推动 v5.0.0 正式闭环
- 生成 v5.0.0 FINAL_REPORT 综合总结文档

---

## 深夜补充：v5.0.0 TASK-25 v5.0.2 复审 P2/P3 修复（22:30-23:01）

### 关联 Review 进度更新
- Reviewer 完成 v5.0.2 复审（REVIEW_REPORT_v5.0.2_filtering-validation.md），评分 8.5/10
- 提出 3 个 P2 + 1 个 P3 健壮性问题，Worker 全部接受并修复
- 修复过程中发现 Test 16 baseline 失败（iperf3 单线程干扰），一并解决

### TASK-25 完成情况
| 编号 | 任务 | 关联问题 | 状态 | 备注 |
|------|------|----------|------|------|
| TASK-25 | 修复 v5.0.2 的 F1/F2/F3/F4 + Test 16 baseline | ISSUE-5-F1/F4 [P2/P3] + ISSUE-6-F2 [P2] + ISSUE-7-F3 [P2] | ✅ 已修复-待复审 | QEMU 16/16 PASS |

### 关键技术决策（TASK-25）
- **F1 --proto 校验采用方案2（允许数字+范围检查）**：保留数字 IPPROTO 能力（如 6=tcp），但用 `endptr` 检测非数字输入、范围检查 0-255，兼顾灵活性与健壮性
- **F4 选择 warning 而非退出**：过滤选项对 --inode/--reset 无害（do_query 只对 GET_BY_PID 追加属性），warning 兼顾诊断体验与脚本兼容性
- **Test 16 移除 TCP client**：iperf3 server 单线程处理同一端口的多个 client 会互相阻塞；UDP client 自带 TCP 控制连接，baseline 自然满足 tcp>=1+udp>=1，复用 Test 14 验证过的可靠模式

### 踩坑总结（TASK-25）
- **坑8**: F3 正则修复后 Test 16 仍失败
  - **原因**: Test 16 baseline udp=0 不是正则问题，而是 iperf3 server 单线程处理时 TCP client(-P 2) 占用 server，UDP client 无法建立控制连接
  - **解决方案**: 移除 TCP client，只保留 UDP client（自带 TCP 控制连接）
  - **避免方法**: iperf3 server 单线程特性下，不要对同一 server 同时启动多个不同协议 client

### 验证结果（TASK-25）
- `--proto foo` → 退出码 2 + 错误信息 ✓
- `--proto 6`/`--proto 17` 数字形式仍接受 ✓
- UAPI 版权: laiguo-liang 统一，patch 0005 同步 ✓
- 正则兼容 IPv4/IPv6: `local=[^ ]*:$PORT` ✓
- `--inode`+过滤 → warning 输出 ✓
- trailing whitespace: run-tests.sh 为 0 ✓
- QEMU 测试: **16/16 PASS, 0 FAIL, 0 SKIP** (TCG 模式, ~137s)
  - Test 16: baseline(tcp=2,udp=1) filtered(tcp=2,udp=0,port_match=2) ✓
- 测试日志: `tests/reports/local/test-20260728_225848.log`

### v5.0.0 议题状态总览（v5.0.2 修复后）
| 编号 | 优先级 | 问题 | 最终状态 | 行动 |
|------|--------|------|----------|------|
| ISSUE-3 | P1 | Netlink 非 dump | ✅ 已闭环 | TASK-22 + TASK-23 |
| REV-1 | P2 | `.start` 显式清零 `cb->ctx` | ✅ 已闭环 | TASK-23 |
| REV-2 | P3 | `.dumpit` 末尾 return 0 | ✅ 已闭环 | TASK-23 |
| ISSUE-5 | P1 | 用户态过滤缺失 | ✅ 已修复-待复审 | TASK-24 + TASK-25(F1/F4) |
| ISSUE-6 | P2 | UAPI 兼容性注释 | ✅ 已修复-待复审 | TASK-24 + TASK-25(F2) |
| ISSUE-7 | P2 | dump/过滤测试补充 | ✅ 已修复-待复审 | TASK-24 + TASK-25(F3+Test16) |

### 明日计划（更新）
- 等待 Reviewer 对 TASK-25 修复的复审，确认 v5.0.2 闭环
- 如 Reviewer 确认通过，推动 v5.0.0 正式闭环
- 生成 v5.0.0 FINAL_REPORT 综合总结文档

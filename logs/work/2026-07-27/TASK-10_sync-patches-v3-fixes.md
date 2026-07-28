# TASK-10 同步 tx/rx instrumentation patch 反映 v3.0.0 全部修复

- **日期**: 2026-07-27
- **关联 Review**: v3.0.0
- **关联问题**: BUG-1 ~ BUG-7 (patch 同步)
- **关联报告**: REVIEW_REPORT_v3.0.0_instrumentation-accuracy.md

## 1. 任务描述

v3.0.0 Review 中 BUG-3/4/5/6 的代码修复已在前一轮对话中完成（tcp.c 的 MSG_PEEK 守卫、UDP rx_end 移至校验和后、TCP splice/zerocopy rx_end），但对应的 patch 文件（tx-instrumentation.patch、rx-instrumentation.patch）**严重不同步**：

- rx-instrumentation.patch 仍将 rx_end 写在 udp.c:1839（旧位置，校验和之前），无 MSG_PEEK 守卫
- tx-instrumentation.patch 只有 UDP 快路径 tx_start，无 corked 路径、无 IPv6 UDP、无 TCP 重传修复
- CI 用 patch 重建源码时，BUG-3/4/5/6 会全部回归

本次任务需要完全重写两个 patch 文件，反映当前工作树的所有 instrumentation。

## 2. 变更内容

### 方法: git commit + format-patch 链式生成

由于 TX 和 RX patch 需要保持链式 hash（TX 基于 RX 之后的源码状态），采用以下流程：

1. **拆分 diff**: 编写 Python 脚本 `/tmp/split_patch.py`，将 `git diff` 输出按 hunk 分类为 RX 和 TX
   - RX hunks: includes（共享文件）、rx_start、rx_end
   - TX hunks: include（tcp_output.c 独有）、tx_start、tx_end、BUG-7 reset
2. **重置工作树**: `git checkout --` 清空 5 个文件的修改
3. **应用 RX → commit**: `git apply rx_only.patch` → `git commit` (commit hash: 14a3de193)
4. **应用 TX → commit**: `git apply tx_only.patch` → `git commit` (commit hash: 54e646847)
5. **生成 format-patch**: `git format-patch -2 HEAD`
6. **清理尾随空格**: `sed -i 's/[[:space:]]*$//'` 去除所有尾随空格
7. **重置 + 恢复**: `git reset --hard HEAD~2` → `git apply all_changes_backup.diff`

### 最终 patch 内容

**rx-instrumentation.patch** (4 文件, 22 insertions):
- `net/core/dev.c`: +include, +rx_start
- `net/ipv4/tcp.c`: +include, +rx_end×3（tcp_read_sock BUG-5, tcp_zerocopy BUG-6, tcp_recvmsg !PEEK BUG-3）
- `net/ipv4/udp.c`: +include, +rx_end（!peeking + 校验和后 BUG-3/4）
- `net/ipv6/udp.c`: +include, +rx_end（!peeking + 校验和后 BUG-1/3/4）

**tx-instrumentation.patch** (5 文件, 21 insertions, 2 deletions):
- `net/core/dev.c`: +tx_end
- `net/ipv4/tcp.c`: +tx_start (tcp_sendmsg_locked)
- `net/ipv4/tcp_output.c`: +include, +tx_start reset (__tcp_transmit_skb BUG-7)
- `net/ipv4/udp.c`: +tx_start×2（fast path + corked BUG-2）
- `net/ipv6/udp.c`: +tx_start×2（fast path BUG-1 + corked BUG-2）

## 3. 变更原因

- **根因分析**: 前一轮对话修改了源码但未同步 patch，违反项目约束 "When modifying source files, corresponding .patch files must be synchronized"
- **设计决策**: 使用 git commit + format-patch 生成正确的链式 hash，而非手动拼接。这确保了 patch 之间的依赖关系正确（TX 依赖 RX 先应用）。
- **方案选择**: 
  - 采纳方案: git commit + format-patch（链式 hash 正确，patch 格式标准）
  - 未采纳: 手动拼接 diff（容易出错，hash 不连续）
  - 未采纳: 创建 0011 增量 patch（需要 base patch + fix patch 两层，更复杂）

## 4. 踩坑记录

- **问题描述**: `git format-patch` 生成的 patch 中 blank context lines 输出为 ` ` (空格+换行)，被 CI 的 trailing whitespace 检查标记
- **原因分析**: git format-patch 对空行用单空格表示 context line
- **解决方案**: `sed -i 's/[[:space:]]*$//'` 清除所有尾随空格
- **如何避免**: 每次 format-patch 后都需检查 trailing whitespace

- **问题描述**: `git checkout --` 无法重置已 staged 的文件
- **原因分析**: `git add` 后 commit 失败（无 git config），文件停留在 staged 状态，`git checkout --` 只重置 worktree 到 index（仍含修改）
- **解决方案**: 先 `git reset HEAD <files>` unstage，再 `git checkout -- <files>`
- **如何避免**: 先设置 `git config user.email/name` 再 commit

- **问题描述**: TX patch 的 context lines 反映 clean kernel 状态，应用在 RX 之上时可能不匹配
- **原因分析**: `git diff` 输出的是 clean → all 的 diff，context 来自 clean kernel
- **解决方案**: 使用 git commit + format-patch，TX commit 的 diff 自动以 RX commit 后的状态为 base，context 正确
- **如何避免**: 涉及多 patch 链式依赖时，必须用 commit + format-patch 而非手动 diff 拆分

## 5. 测试验证

- 所有 10 个 patch 文件 trailing whitespace count = 0
- `git apply --check` RX patch on clean kernel: OK
- `git apply --check` TX patch after RX: OK
- 完整 patch 应用测试: stash → apply all patches → stash pop → diff MATCH（patch 完整复现工作树）
- 内核编译通过
- QEMU 测试 13/13 全部通过

## 6. 待办/遗留问题

- ISSUE-8/9（GRO/GSO 粒度不一致）和 ISSUE-10（rx_start 语义）属设计层面问题，本轮未修复，建议后续文档化
- 后续可考虑为 IPv6 UDP、corked、splice、zerocopy 场景添加专用测试用例

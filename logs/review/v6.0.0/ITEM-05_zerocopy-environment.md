# 分项审查 - Test 20 TCP zerocopy RX 环境支持

- **关联日志**: `logs/work/2026-07-29/TASK-26_v6.0.0-review-response.md` 第 4.1 节、TASK-27 第 9 节
- **审查日期**: 2026-07-29

## 变更概述

Worker 新增 Test 20 以回归保护 `tcp_zerocopy_receive()` 路径，并编写了 `delayacct_path_test zerocopy-server` 辅助程序。最初误用 `setsockopt(TCP_ZEROCOPY_RECEIVE)`，后修复为 `getsockopt(TCP_ZEROCOPY_RECEIVE)`。

## 逐文件审查

### 文件: `tests/helper/delayacct_path_test.c`

#### 变更内容
[delayacct_path_test.c#L204-L220](file:///home/lai/Code/NET_DELAYACCT/tests/helper/delayacct_path_test.c#L204-L220):
```c
if (getsockopt(cfd, IPPROTO_TCP, TCP_ZEROCOPY_RECEIVE, &zc, &optlen) < 0) {
    ...
    return 3;
}
```

#### 审查意见
- **第 204 行**: getsockopt 修复正确，但 QEMU 内核仍不支持该选项
  - 严重度: 中
  - 建议: 在支持 zerocopy 的环境验证 PASS；检查并启用 `CONFIG_TCP_ZEROCOPY_RECEIVE` 内核配置；或在 README 中明确标注环境依赖
  - Worker反馈: 接受 — 实际根因是 helper 误用匿名 mmap，已改为 `mmap(cfd)`；`CONFIG_MMU=y` 已在 `ci/kernel.config.fragment` 显式声明；README 已更新环境依赖说明

### 文件: `ci/qemu/run-tests.sh`

#### 变更内容
[run-tests.sh#L1286-L1287](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L1286-L1287):
```bash
_skip "kernel does not support TCP_ZEROCOPY_RECEIVE (getsockopt failed)"
```

#### 审查意见
- **第 1287 行**: SKIP 消息清晰，但需确认是否为长期状态
  - 严重度: 中
  - 建议: 区分「内核不支持」和「配置未启用」；若长期 SKIP，应在覆盖矩阵中降级该测试的回归权重
  - Worker反馈: 接受 — SKIP 消息已改为 "kernel/config does not support..."，并提示查看 /tmp/zc.log 以区分 helper 内部错误

## 综合意见

API 误用已修复，但测试的实际回归价值取决于 CI 环境是否支持 `TCP_ZEROCOPY_RECEIVE`。建议优先验证物理机/KVM 环境，再决定是启用内核配置还是调整文档。

## 附加建议

可在 `kernel.config.fragment` 中尝试显式添加 `CONFIG_TCP_ZEROCOPY_RECEIVE=y`，然后重新编译内核并验证 QEMU 内是否仍 SKIP。

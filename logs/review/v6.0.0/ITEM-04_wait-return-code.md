# 分项审查 - Test 13 wait 返回值处理

- **关联日志**: `logs/work/2026-07-29/TASK-27_initramfs-timeout-fixes.md` 第 7-8 节
- **审查日期**: 2026-07-29

## 变更概述

Worker 修复了 Test 13 的 `wait` 死锁 Bug：原实现 `wait` 不带参数会等待永不退出的 iperf3 server，改为收集 worker PID 后使用 `wait $WORKER_PIDS` 只等待 worker 进程。

## 逐文件审查

### 文件: `ci/qemu/run-tests.sh`

#### 变更内容
[run-tests.sh#L824-L825](file:///home/lai/Code/NET_DELAYACCT/ci/qemu/run-tests.sh#L824-L825):
```bash
# 只等待 worker 进程，不等待 iperf3 server（server 持续运行直到被 kill）
wait $WORKER_PIDS 2>/dev/null || true
```

#### 审查意见
- **第 825 行**: `|| true` 掩盖了 `wait` 的真实退出码
  - 严重度: 低
  - 建议: 移除 `|| true` 或显式捕获 `$?` 并打印诊断信息
  - Worker反馈: 接受

## 综合意见

死锁修复本身正确，但 `2>/dev/null || true` 过度抑制了错误信息。建议保留 `wait` 退出码用于诊断，同时仍通过 `_CRASH` 计数器检测 worker 崩溃。

## 附加建议

可将该模式抽象为通用 helper 函数，供未来其他并发测试复用。

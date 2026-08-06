# [TASK-51] ci.yml build-kernel matrix 化（ON/OFF 并行构建）

- **日期**: 2026-08-06
- **关联 Review**: v6.5.0 议题2（CI 接入实施方案）
- **状态**: [待Review]

## 1. 任务描述

将 ci.yml 的 `build-kernel` job 从单一 ON 内核构建改为 matrix 策略，并行构建 ON（CONFIG_NET_DELAYACCT=y）和 OFF（CONFIG_NET_DELAYACCT=n）两个内核，为 perf-test 双内核对比提供 OFF 基线。同步更新 qemu-test job 的 artifact 下载名称。

**v6.5.0 议题2 共识**：matrix 并行构建不增加串行时间（on/off 同时运行，等待时间 = max(on, off)）。

## 2. 变更内容

### 文件: `.github/workflows/ci.yml`

#### 2.1 build-kernel job matrix 化（L71-76）
```yaml
build-kernel:
  name: Build kernel (${{ matrix.mode }})
  runs-on: ubuntu-22.04
  strategy:
    matrix:
      mode: [on, off]
```

#### 2.2 Configure kernel 步骤按 mode 分支（L144-162）
- **ON 模式**：合并 `ci/kernel.config.fragment`（NET_DELAYACCT core）+ `ci/qemu/kernel-qemu.config`（QEMU boot + ftrace + netem）
- **OFF 模式**：仅合并 `ci/qemu/kernel-qemu.config`（QEMU boot 配置仍需，功能测试 S1-S25 不受 NET_DELAYACCT 开关影响），显式 `sed` 关闭 NET_DELAYACCT

#### 2.3 artifact 命名区分（L173）
```yaml
# 原: name: bzImage
name: bzImage-${{ matrix.mode }}   # → bzImage-on / bzImage-off
```

#### 2.4 qemu-test artifact 下载同步（L256-261）
```yaml
# 原: name: bzImage
# 原: 步骤名: Download bzImage artifact
name: bzImage-on
# 步骤名: Download bzImage artifact (ON kernel)
```

## 3. 变更原因

### 3.1 为什么需要 OFF 内核
perf-test.sh 对比 CONFIG_NET_DELAYACCT=y (ON) vs =n (OFF) 的性能开销。CI 中需并行构建两个内核 artifact，供 perf-test job 下载使用。v6.4.0 之前 CI 只构建 ON 内核，无法运行 perf 对比。

### 3.2 为什么 OFF 模式仍需 kernel-qemu.config
OFF 内核用于 perf-test 双内核对比的基线，QEMU 启动配置（console、virtio、e1000 等）和 ftrace/netem 配置仍需保留：
- perf-test 在 QEMU 中运行，需要 QEMU boot 配置
- ftrace 虽是 Test 23 功能测试用，但合并同一 fragment 避免配置分叉
- 显式 `sed` 关闭 NET_DELAYACCT 确保基线纯净

### 3.3 为什么 qemu-test 需同步改 artifact 名
matrix 化后 artifact 名从 `bzImage` 变为 `bzImage-on` / `bzImage-off`。qemu-test 原下载 `name: bzImage` 会失败（artifact 不存在），改为 `name: bzImage-on`。

这是对话 [DLG-20260806-014500](file:///home/lai/Code/NET_DELAYACCT/logs/dialogue/DLG-20260806-014500.md) 议题2 中 Worker 补充的技术点，Reviewer 方案中未提及。

## 4. 踩坑记录

### 坑1：matrix 化后 qemu-test needs 依赖两个子 job
- **现象**：`needs: [build-kernel]` 在 matrix 化后会自动展开为依赖 `build-kernel (on)` 和 `build-kernel (off)` 两个子 job
- **影响**：若 OFF 内核构建失败，qemu-test（只需 ON 内核）也不会运行
- **评估**：OFF 仅是 ON 关闭 NET_DELAYACCT，构建失败概率极低（同源码同工具链，仅 config 差异）；且若 OFF 失败说明源码本身有问题，阻断 qemu-test 也合理
- **决策**：保持 `needs: [build-kernel]` 不变，不做精细依赖。若后续 OFF 独立失败频繁，可拆分为两个独立 job

## 5. 测试验证

### 5.1 YAML 校验
```python
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"
→ ci.yml YAML valid
```

### 5.2 逻辑审查
- ON 模式 config 分支：合并两个 fragment ✓
- OFF 模式 config 分支：合并 kernel-qemu.config + sed 关闭 NET_DELAYACCT ✓
- artifact 命名：`bzImage-${{ matrix.mode }}` → `bzImage-on` / `bzImage-off` ✓
- qemu-test 下载：`name: bzImage-on` 与上传名一致 ✓
- perf-test 下载：分别下载 `bzImage-on` / `bzImage-off` 到不同目录 ✓

## 6. 待办/遗留问题
- 需 push 到 CI 验证 matrix 构建实际并行性和 artifact 命名（TASK-54）
- OFF 内核构建增加 CI 总时间约 3-5 分钟（matrix 并行，不增加串行时间，但占用额外 runner）

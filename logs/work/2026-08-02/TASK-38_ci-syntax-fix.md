# [TASK-38] 修复 CI QEMU 步骤 bash 语法错误 (done/fi 误用)

- **日期**: 2026-08-02
- **关联需求/Issue**: v6.2.0 推送后 CI 失败 (run 30743974115)

## 1. 任务描述

v6.2.0 (commit 63d93f6) 推送后 CI 的 QEMU runtime test 步骤以 exit code 2 失败，
且 `/tmp/qemu.log` 从未生成。需要定位根因并修复，使 CI 恢复全绿。

## 2. 变更内容

### 2.1 根因：tc/iptables 打包块 `done` 误用为 `fi` (commit 7d3ed90)

**文件**: [.github/workflows/ci.yml](file:///home/lai/Code/NET_DELAYACCT/.github/workflows/ci.yml)

**改动**: 第 354 行 `done` → `fi`

```bash
# 修复前 (语法错误)：
if [ "$bin" = "tc" ]; then
  for qso in ...; do
    ...
  done
done          # ← 错误：if 块应用 fi 闭合
echo "Packed $bin with shared libs"

# 修复后：
if [ "$bin" = "tc" ]; then
  for qso in ...; do
    ...
  done
fi            # ← 正确
echo "Packed $bin with shared libs"
```

### 2.2 辅助修复：测试计数 bug + ERR trap 诊断 (commit 9068ad3)

**文件**: [.github/workflows/ci.yml](file:///home/lai/Code/NET_DELAYACCT/.github/workflows/ci.yml)

1. **测试计数 bug**: `grep -c ... || echo 0` 在无匹配时产生 `"0\n0"`（grep -c 输出 "0" 且 exit 1，echo 再输出 "0"），破坏整数比较。改用 `grep -Ec ... || true` + `${VAR:-0}`，并用 `^\s*\[PASS\]` 锚定排除场景状态行 `[S1 PASS]` 的子串误匹配。
2. **ERR trap 诊断**: 新增 `trap '...::error::...' ERR`，失败时发出含失败命令 (`$BASH_COMMAND`) 与行号 (`$LINENO`) 的注解。
3. **防御式 tc/iptables 打包**: `cp "$b"` 改为 `if ! cp ...; then continue; fi`，失败仅导致 S7 SKIP 而非中止整个 CI。
4. **FAIL 行写入注解**: 测试失败时将 `[FAIL]` 行写入 `::error::` 注解，便于不经日志下载即可定位失败用例。

## 3. 变更原因

### 3.1 为什么 CI 失败而本地测试一直通过

ci.yml 中 tc/iptables 打包代码是从 local-test.sh 的函数式写法改写为内联式时引入的笔误
（`done` 误写为 `fi`）。local-test.sh 中等价代码正确使用 `fi`（第 268 行），
故本地 `./local-test.sh --qemu-only` 一直 25/25 PASS，而 CI 始终 exit 2。

### 3.2 为什么 exit code 2 且 ERR trap 不触发

bash 在执行脚本前先做完整语法解析。`done`/`fi` 不匹配是语法错误，bash 在解析阶段
即退出 (exit 2)，**整个脚本从未执行** —— 故 ERR trap 未设置/未触发、initramfs 未构建、
QEMU 未启动、`/tmp/qemu.log` 不存在。这与"测试失败"完全不同：测试失败会 exit 1 并生成 qemu.log。

### 3.3 诊断方法

GitHub Actions 日志需 admin 权限下载，但运行页注解 (annotations) 对公开仓库可见。
通过 WebFetch 抓取 run 页面注解，发现：
- "Process completed with exit code 2." （非 exit 1 → 非测试失败）
- "No files were found with the provided path: /tmp/qemu.log" （QEMU 未运行）

这两条线索锁定"initramfs 构建阶段失败"。随后用 `bash -n` 对提取出的 step 脚本做语法校验，
立即定位到 `line 89: syntax error near unexpected token 'done'`。

## 4. 踩坑记录

### 4.1 内联 bash 与函数式 bash 的结构差异

**问题描述**: local-test.sh 用 `copy_binary_with_libs` 函数 + 正确的 `fi`，ci.yml 内联改写时误用 `done`。
**原因分析**: 手工将函数式代码改写为内联 `for/if` 嵌套时，闭合关键字容易抄错（`done` 闭合 for，`fi` 闭合 if）。
**解决方案**: 改写后用 `bash -n` 校验语法。
**如何避免**: **任何修改 ci.yml 内联 `run: |` 脚本后，本地用 `bash -n` 校验语法**（提取 YAML run 块 → bash -n）。

### 4.2 exit code 2 ≠ 测试失败

**问题描述**: 初次诊断误以为 exit code 2 是测试计数 bug 导致的整数比较错误。
**原因分析**: exit code 2 来自 bash 语法错误（解析阶段），exit code 1 来自显式 `exit 1`（测试失败）。计数 bug 的 `"0\n0"` 在 `if` 条件中只会被当作 false（exit 2），不会中止脚本。
**解决方案**: 通过"无 qemu.log"判定失败发生在 QEMU 启动前，排除测试失败可能。
**如何避免**: CI 失败时先区分 exit code (1=测试失败, 2=脚本/语法错误)，再查 qemu.log 是否生成。

## 5. 测试验证

### 5.1 本地语法校验

```bash
# 提取 ci.yml 的 QEMU step 脚本并校验
python3 -c "import yaml; ..."  # 提取 run 块到 /tmp/qemu-step.sh
bash -n /tmp/qemu-step.sh && echo "SYNTAX OK"
# 修复前: line 89: syntax error near unexpected token 'done'
# 修复后: SYNTAX OK
```

### 5.2 CI 验证结果 (run 30745609797, commit 7d3ed90)

```
checkpatch on kernel patches:              success
Build userspace get_sockdelays:            success
Build kernel with CONFIG_NET_DELAYACCT:    success
QEMU runtime test (KVM):                   success   (6m 5s)
```
- 总时长 19m 6s，0 error 注解（仅 4 条 Node.js 20 弃用 warning）
- `qemu-log` artifact 22.5 KB（确认 QEMU 运行并产出日志）
- `test-summary` artifact 14.8 KB（确认测试执行）
- QEMU 步骤 success = PASS_N>0 ∧ FAIL_N=0（计数 bug 已修复，语义可靠）

## 6. 待办/遗留问题

- [x] CI 恢复全绿 — **已验证: run 30745609797 全部 success**
- [ ] 提请 Reviewer 闭环 v6.2.0（CI 已验证通过）
- [ ] 后续: ci.yml 的 Node.js 20 弃用 warning 可择机升级 actions 版本（非阻断）

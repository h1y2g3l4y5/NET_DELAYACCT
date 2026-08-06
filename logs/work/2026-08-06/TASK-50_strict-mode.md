# [TASK-50] perf-test.sh --strict 模式 + --bzimage-on/off 参数

- **日期**: 2026-08-06
- **关联 Review**: v6.5.0 议题3（--strict 模式设计）、议题6（--strict=warn 作为 CI 默认）、议题8（-smp 1）
- **状态**: [待Review]

## 1. 任务描述

为 perf-test.sh 新增 `--strict` 参数族，控制 INVALID（噪声主导测量）的判定行为；新增 `--bzimage-on/off` 参数支持 CI 中 artifact 路径指定；新增 `-h/--help`。解决 verdict exit code 通过 `{ ... } | tee` 子 shell 传递到父 shell 的问题。

**v6.5.0 议题3/6 共识**：
- 默认/warn：INVALID 告警不阻断（exit 0），但 INVALID>50%（≥3/5）时 exit 2（数据不可信）
- fail：INVALID 视作 FAIL 阻断（exit 1），用于 CI 严格回归
- CI 默认用 `--strict=warn`（共享 runner 噪声不可控，strict=fail 会频繁误报）

## 2. 变更内容

### 文件: `perf-test.sh`

#### 2.1 新增 STRICT_MODE 变量（L31-34）
```bash
# --strict 模式控制 INVALID 的判定行为（参数解析可覆盖）：
#   warn（默认）：INVALID 告警不阻断，但 INVALID>50%(≥3/5) 时 exit 2（数据不可信）
#   fail：INVALID 视作 FAIL 阻断（exit 1），用于 CI 严格回归
STRICT_MODE="warn"
```

#### 2.2 新增 PERF_EXIT_FILE 机制（L53-55）
```bash
# verdict exit code 通过临时文件传递（{ ... } | tee 的子 shell 变量不传递到父 shell）
PERF_EXIT_FILE=$(mktemp)
trap 'rm -f "$PERF_EXIT_FILE"' EXIT
```

#### 2.3 参数解析重写（L544-586）
从单 `--skip-build` 判断改为 while 循环解析多参数：
- `--skip-build`：复用已有 bzImage
- `--strict`：无参数 = fail
- `--strict=warn|fail`：指定模式，非法值 exit 2
- `--bzimage-on=PATH` / `--bzimage-off=PATH`：CI artifact 路径
- `-h|--help`：打印用法
- 未知参数：exit 2

#### 2.4 总结论三态 + strict 分级（L505-541）
```
优先级：FAIL > INVALID(视strict) > NO-DATA > PASS
exit code: 0=PASS/warn通过, 1=FAIL/strict-fail, 2=数据不可信
```
- verdict_fail > 0 → exit 1
- verdict_invalid > 0 → 按 STRICT_MODE 分级（fail→exit 1；warn→INVALID≥3 时 exit 2，否则 exit 0）
- 未知 STRICT_MODE → exit 2（防御性）

#### 2.5 exit code 传递（L624-634）
```bash
# 子 shell 内写入临时文件
echo "${PERF_EXIT:-0}" > "$PERF_EXIT_FILE"
} 2>&1 | tee "$LOG_DIR/perf-test-${TIMESTAMP}.log"
# 父 shell 读取
PERF_EXIT=$(cat "$PERF_EXIT_FILE" 2>/dev/null || echo 0)
exit "${PERF_EXIT:-0}"
```

## 3. 变更原因

### 3.1 为什么需要 --strict 模式
v6.4.0 verdict 三态引入了 INVALID（噪声主导），但未定义 INVALID 在 CI 中的处理策略。CI 共享 runner 噪声大于本地专用机：
- INVALID=PASS → 重蹈 v6.4.0 假达标覆辙
- INVALID=FAIL → CI 因噪声频繁红
- **分级方案**：warn（CI 默认，告警不阻断）+ fail（严格回归，阻断）+ INVALID>50% exit 2（数据不可信）

### 3.2 为什么需要 PERF_EXIT_FILE 机制
`{ ... } | tee` 中的命令运行在子 shell，变量赋值不传递到父 shell。`exit $PERF_EXIT` 在父 shell 执行时 PERF_EXIT 为空。用临时文件做 IPC：
- 子 shell 写入 verdict exit code
- 父 shell 读取后 exit
- trap EXIT 清理临时文件

### 3.3 为什么需要 --bzimage-on/off 参数
CI 中内核不在 LINUX_SRC 树里（artifact 下载到 /tmp/artifacts/），perf-test.sh 硬编码 `BZIMAGE_ON="$LINUX_SRC/arch/x86/boot/bzImage-on"` 无法适配。用参数显式指定路径。

## 4. 踩坑记录

### 坑1：`{ ... } | tee` 子 shell 变量不传递
- **问题**：compare_and_report 在子 shell 中设置 PERF_EXIT=1，但 `exit "$PERF_EXIT"` 在父 shell 执行时 PERF_EXIT 为空 → exit 0（掩盖 FAIL）
- **原因**：管道 `|` 创建子 shell，子 shell 的变量赋值对父 shell 不可见
- **解决**：用 mktemp 临时文件做 IPC，子 shell 写、父 shell 读
- **验证**：单元测试证实 PERF_EXIT=2 能正确传递到父 shell exit 2
- **避免**：bash 管道中子 shell 向父 shell 传值，用临时文件或文件描述符，不可依赖变量作用域

## 5. 测试验证

### 5.1 语法校验
```
bash -n perf-test.sh → OK
```

### 5.2 单元测试（15 用例全过）
- `_verdict3` 三态判定：6 用例（<0→INVALID, =thr→PASS, >thr→FAIL 等）
- 总结论逻辑：9 用例（含 NO-DATA 场景，见 TASK-52）
- exit code 传递：模拟 PERF_EXIT=2 通过 tee 子 shell 传递到父 shell，确认 exit 2

### 5.3 参数解析验证
```
./perf-test.sh --help                              → 打印用法，exit 0
./perf-test.sh --strict=invalid                    → ERROR + exit 2
./perf-test.sh --bogus                             → Unknown option + exit 2
```

## 6. 待办/遗留问题
- `--strict=fail` 模式待 KVM 数据稳定后在 CI 中启用（v6.6.0 关注点）
- exit code 语义：0/1/2 三态，CI 可根据需配置 continue-on-error 策略（见 TASK-52）

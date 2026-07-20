# NET_DELAYACCT 工作日志

---

## 2026-07-20

### 任务概述
搭建并调试 QEMU 自动化测试流程：`poll-and-test.sh` 脚本拉取最新代码 → 编译内核 → 编译用户态工具 → QEMU 启动测试 → 收集结果。

### 遇到的问题及解决方案

**1. poll-and-test.sh 路径硬编码问题**
- 问题：脚本默认路径 `$HOME/linux-6.6` 等与 `setup.sh` 实际使用的 `$NETDELAY_REPO/../linux-6.6` 不一致
- 解决：`poll-and-test.sh` 改为与 `setup.sh` 相同的路径推导逻辑

**2. SCRIPT_DIR 使用前未定义**
- 问题：路径推导代码引用了 `$SCRIPT_DIR` 但定义在后面
- 解决：将 `SCRIPT_DIR` 定义移到配置区最前面

**3. 内核编译进度不可见**
- 问题：`make bzImage | tail -5` 只显示最后 5 行，编译期间看起来像卡住
- 解决：移除 `tail -5`，显示完整编译输出

**4. rmdir 权限拒绝**
- 问题：`sudo mkdir` 创建的挂载目录无法被普通用户 `rmdir` 删除
- 解决：`prepare_rootfs` 和 `extract_results` 中改为 `sudo rmdir`

**5. QEMU 内核 panic**
- 问题：`guest-init.sh` 中 `set -e` 导致 `mount -t devtmpfs` 因 /dev 已挂载而失败，init 进程退出触发 panic
- 解决：所有 mount 命令增加 `mountpoint -q` 检查，已挂载则跳过

**6. git 推送交互卡住**
- 问题：`sudo` 运行脚本时 git push 触发用户名/密码交互提示
- 解决：git 命令添加 `GIT_TERMINAL_PROMPT=0` 禁止交互，失败静默跳过

**7. genl family 检测误报**
- 问题：`/proc/net/genetlink` 文件不存在或为空，导致检测失败，但 dmesg 确认 family=28 已注册
- 解决：改用 `get_sockdelays -p 1` 实际调用验证 genl family 可用性

**8. git remote URL 被反引号污染**
- 问题：复制命令时 Markdown 代码块的反引号字符 ` 被带入 URL
- 解决：`poll-and-test.sh` 增加自动检测并修正 remote URL 逻辑

**9. 增量编译未生效**
- 问题：每次运行都完整重编内核，耗时长
- 解决：添加 `.netdelay_build_marker` 记录上次构建 commit；`.config` 存在时跳过 defconfig；只变用户态代码时不重编内核

**10. 新增 CONFIG_TASK_DELAY_ACCT 未生效**
- 问题：`kernel-qemu.config` 新增配置后 `.config` 已存在，跳过 reconfig 导致新选项不生效
- 解决：全量重置时 `rm -f .config` 强制重配置

### 已添加的功能
- QEMU 内核新增 `CONFIG_TASK_DELAY_ACCT`、`CONFIG_TASKSTATS`、`CONFIG_TASK_XACCT`、`CONFIG_TASK_IO_ACCOUNTING`
- 编译内核自带的 `tools/accounting/getdelays.c` 用户态工具并安装到 QEMU rootfs

### 待解决问题
- VMware NAT 服务不定期断连，需在 Windows 管理员命令行重启 `net stop/start "VMware NAT Service"`
- `net_delayacct` genl family 注册成功但 socket 延迟数据未采集（测试输出 `(no matching sockets)`），需排查 RX/TX instrumentation 逻辑

### 提交记录
| 提交 | 说明 |
|------|------|
| dba91e5 | fix: poll-and-test.sh use same derived paths as setup.sh |
| b65f53c | fix: define SCRIPT_DIR before using it in poll-and-test.sh |
| e7c8d85 | fix: show kernel build progress and fix rmdir permission |
| 6225c92 | fix: make mount commands idempotent in guest-init.sh |
| fcc1db7 | feat: incremental kernel build |
| 310f9da | fix: disable git interactive prompt, fix rmdir, add dmesg debugging |
| f5c6a31 | fix: improve genl family detection |
| 5db78b2 | fix: auto-fix git remote URL and verify genl via get_sockdelays |
| 60add19 | feat: enable CONFIG_TASK_DELAY_ACCT and build getdelays |

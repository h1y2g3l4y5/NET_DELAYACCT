# kernel-patches 应用指南

本目录包含 CONFIG_NET_DELAYACCT 框架在 Linux 6.6 内核上的全部源码与
补丁。补丁按顺序应用后即可启用 per-socket 网络时延统计能力。

## 前置条件

- Linux 6.6 源码树（建议 `git clone --branch v6.6
  https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git`）
- x86_64 构建工具链：`build-essential libelf-dev libssl-dev bison
  flex libncurses-dev`
- 至少 4 GiB 空闲内存与 20 GiB 磁盘空间

## 文件清单

| 文件 | 用途 | 目标位置 |
|------|------|----------|
| `Kconfig-fragment` | Kconfig 选项 | 手动追加到 `net/Kconfig` |
| `Makefile-fragment` | 构建规则 | 手动追加到 `net/core/Makefile` |
| `include-uapi-linux-net-delayacct.h` | UAPI 头文件 | 复制为 `include/uapi/linux/net-delayacct.h` |
| `include-net-net-delayacct.h` | 内核头文件 | 复制为 `include/net/net-delayacct.h` |
| `sock_h-modification.patch` | 修改 `struct sock` | `git apply` |
| `skbuff_h-modification.patch` | 修改 `struct sk_buff` | `git apply` |
| `net-core-net-delayacct.c` | 核心实现 | 复制为 `net/core/net-delayacct.c` |
| `rx-instrumentation.patch` | RX 路径插桩 | `git apply` |
| `tx-instrumentation.patch` | TX 路径插桩 | `git apply` |

## 应用顺序（顺序很重要）

```bash
cd /path/to/linux-6.6

# 1. Kconfig 选项（手动追加到 net/Kconfig 的适当位置）
cat /path/to/NET_DELAYACCT/kernel-patches/Kconfig-fragment >> net/Kconfig

# 2. Makefile 规则（手动追加到 net/core/Makefile）
cat /path/to/NET_DELAYACCT/kernel-patches/Makefile-fragment >> net/core/Makefile

# 3. UAPI 头文件
cp /path/to/NET_DELAYACCT/kernel-patches/include-uapi-linux-net-delayacct.h \
   include/uapi/linux/net-delayacct.h

# 4. 内核头文件
cp /path/to/NET_DELAYACCT/kernel-patches/include-net-net-delayacct.h \
   include/net/net-delayacct.h

# 5. 修改 struct sock
git apply /path/to/NET_DELAYACCT/kernel-patches/sock_h-modification.patch

# 6. 修改 struct sk_buff
git apply /path/to/NET_DELAYACCT/kernel-patches/skbuff_h-modification.patch

# 7. 核心实现
cp /path/to/NET_DELAYACCT/kernel-patches/net-core-net-delayacct.c \
   net/core/net-delayacct.c

# 8. RX 路径插桩
git apply /path/to/NET_DELAYACCT/kernel-patches/rx-instrumentation.patch

# 9. TX 路径插桩
git apply /path/to/NET_DELAYACCT/kernel-patches/tx-instrumentation.patch
```

> 注意：`sock_h-modification.patch`、`skbuff_h-modification.patch`、
> `rx-instrumentation.patch`、`tx-instrumentation.patch` 中的上下文
> 行可能在不同的 6.6.x point release 之间略有差异。若 `git apply`
> 失败，请改用 `patch -p1 --fuzz=3 < xxx.patch`，或按补丁文件头部
> 注释中的描述手动定位插入点。

## 启用配置

方式一：通过 menuconfig

```bash
make menuconfig
# Networking support  --->
#   [*] Per-socket network delay accounting
```

方式二：通过配置片段合并

```bash
scripts/kconfig/merge_config.sh -m .config \
  /path/to/NET_DELAYACCT/ci/kernel.config.fragment
```

## 编译与验证

```bash
# 编译内核
make -j$(nproc)

# 验证配置选项已启用
grep CONFIG_NET_DELAYACCT .config

# 安装并引导新内核（具体步骤因发行版而异）
sudo make modules_install
sudo make install
sudo reboot

# 启动后验证 genl family 已注册
cat /proc/net/genetlink | grep net_delayacct
```

预期输出示例：

```
net_delayacct          31 (1) 0x0001
```

## 编译用户态工具

```bash
cd /path/to/NET_DELAYACCT/userspace/get_sockdelays
make
# 如需指定内核源码树：
# make LINUX_SRC=/path/to/linux-6.6

# 验证
./get_sockdelays -h
```

## 常见问题

1. **`git apply` 报告上下文不匹配**：使用 `patch -p1 --fuzz=3`，或
   手动按补丁头部注释定位插入点。

2. **`make` 报告 `net-delayacct.c` 找不到 `genl_register_family`**：
   确认 `Makefile-fragment` 已追加到 `net/core/Makefile`，且
   `CONFIG_NET_DELAYACCT=y` 已在 `.config` 中。

3. **`cat /proc/net/genetlink` 看不到 `net_delayacct`**：确认新内核
   已正确安装并被引导（`uname -r`），dmesg 中应有
   `net_delayacct: framework registered` 日志。

4. **`get_sockdelays` 报告 `family not found`**：内核未启用
   `CONFIG_NET_DELAYACCT`，或未引导新内核。

5. **checkpatch 报错**：在投稿上游前必须运行
   `scripts/checkpatch.pl --strict *.patch`，确保 0 WARNING/ERROR。

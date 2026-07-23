# 环境搭建指南

本文档介绍如何从零搭建 NET_DELAYACCT 的开发与测试环境。

提供两条路径：

- **路径 A（推荐）**：一键脚本 `ci/qemu/setup.sh`，适合 CI / self-hosted runner
- **路径 B**：手动搭建，适合开发者理解每一步

---

## 路径 A：一键脚本搭建

### 前提

- Ubuntu 22.04（或兼容的 Debian 系发行版）
- root 权限（`sudo`）
- 网络可访问 GitHub 和内核源码镜像

### 执行

```bash
sudo bash ci/qemu/setup.sh
```

### 脚本做了什么

| 步骤 | 内容 |
|------|------|
| 1 | 安装系统依赖（build-essential, qemu, libmnl-dev, iperf3, debootstrap 等） |
| 2 | 克隆 linux-6.6.y 内核源码到 `../linux-6.6` |
| 3 | 克隆 NET_DELAYACCT 仓库 |
| 4 | 用 debootstrap 创建 Debian rootfs 镜像（`../qemu-rootfs.img`，2G ext4） |
| 5 | 在 rootfs 内安装 iperf3、ncat、libmnl0 |
| 6 | 将 `ci/qemu/guest-init.sh` 安装为 guest 的 `/sbin/qemu-init` |
| 7 | 打印 self-hosted runner 注册说明 |

### 环境变量（可选覆盖）

```bash
LINUX_SRC=/custom/path/linux-6.6   # 内核源码路径（默认: ../linux-6.6）
ROOTFS_IMG=/custom/path/rootfs.img # rootfs 镜像路径（默认: ../qemu-rootfs.img）
ROOTFS_SIZE=4G                     # rootfs 大小（默认: 2G）
DEBIAN_RELEASE=bookworm            # Debian 版本（默认: bookworm）
```

### 完成后的目录布局

```
../
├── linux-6.6/          # 内核源码树
├── qemu-rootfs.img     # QEMU 用的 ext4 rootfs 镜像
└── NET_DELAYACCT/      # 本项目仓库
```

---

## 路径 B：手动搭建

### 1. 安装系统依赖

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential git libelf-dev libssl-dev \
  bison flex libncurses-dev libmnl-dev bc ccache perl \
  qemu-system-x86 iperf3 ncat busybox-static \
  debootstrap wget curl
```

### 2. 克隆内核源码

```bash
cd /path/to/parent/directory
git clone --depth 1 --branch linux-6.6.y \
  https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux-6.6
```

> 国内用户可使用镜像加速：
> ```bash
> git clone --depth 1 --branch linux-6.6.y \
>   https://mirrors.ustc.edu.cn/linux.git linux-6.6
> ```

### 3. 应用内核补丁并编译

按照 [README.md](README.md#快速开始) 的步骤 2-3 操作。

### 4. 编译用户态工具

```bash
cd NET_DELAYACCT
# 安装 UAPI 头文件
sudo install -m 0644 -D kernel-patches/include-uapi-linux-net-delayacct.h \
  /usr/include/linux/net-delayacct.h
# 编译
make tool
```

### 5. 本地 QEMU 测试（无需 rootfs 镜像）

`local-test.sh` 用 busybox 构建轻量 initramfs，不需要 debootstrap rootfs：

```bash
# 设置内核源码路径
export LINUX_SRC=/path/to/linux-6.6

# 完整测试（编译内核 + 工具 + QEMU 启动）
./local-test.sh

# 或分步执行
./local-test.sh --kernel-only   # 只编译
./local-test.sh --qemu-only      # 只跑 QEMU
```

日志自动保存到 `tests/reports/local/test-YYYYMMDD_HHMMSS.log`。

> **注意**：`--qemu-only` 不会重新同步内核源码或重编内核。改了内核代码后
> 必须先跑 `--kernel-only` 或完整流程。

### 6. CI 风格 QEMU 测试（需要 rootfs 镜像）

#### 6a. 创建 rootfs 镜像

```bash
# 创建 2G 空镜像
dd if=/dev/zero of=../qemu-rootfs.img bs=1 count=0 seek=2G
mkfs.ext4 -F ../qemu-rootfs.img

# 挂载并 debootstrap
sudo mount -o loop ../qemu-rootfs.img /mnt
sudo debootstrap --include=systemd,net-tools,iproute2,procps,util-linux,bash \
  bookworm /mnt http://mirrors.ustc.edu.cn/debian

# 安装测试依赖
sudo chroot /mnt apt-get update
sudo chroot /mnt apt-get install -y iperf3 ncat libmnl0

# 安装 guest init 脚本
sudo cp ci/qemu/guest-init.sh /mnt/sbin/qemu-init
sudo chmod +x /mnt/sbin/qemu-init

sudo umount /mnt
```

#### 6b. 运行 CI 测试

```bash
export LINUX_SRC=/path/to/linux-6.6
export ROOTFS_IMG=/path/to/qemu-rootfs.img
sudo bash ci/qemu/ci-test.sh
```

---

## Self-hosted Runner 注册（可选）

如果希望 push 后自动触发 QEMU 测试：

1. 打开 GitHub 仓库 → Settings → Actions → Runners → New self-hosted runner
2. 按页面指引下载并配置 runner
3. 安装为系统服务：
   ```bash
   cd ~/actions-runner
   sudo ./svc.sh install $USER
   sudo ./svc.sh start
   ```
4. 确认 runner 在 GitHub 页面显示为 "Idle"

注册后，每次 push 到 `main`/`dev` 分支将自动触发 CI：
- `checkpatch` — 内核补丁风格检查
- `build-kernel` — 编译带 CONFIG_NET_DELAYACCT 的内核
- `build-tool` — 编译用户态工具
- `qemu-test` — 在 self-hosted runner 上跑 QEMU 测试

---

## 常见问题

### Q: QEMU 报 "Could not access KVM kernel module"

KVM 不可用时会自动降级到 TCG 软件模拟模式（`local-test.sh` 已内置此逻辑）。
TCG 模式较慢，建议将超时调大：

```bash
QEMU_TIMEOUT_TCG=600 ./local-test.sh --qemu-only
```

### Q: git push 报 TLS/443 端口错误

防火墙可能拦截 443 端口。改用 SSH 协议：

```bash
git remote set-url origin git@github.com:h1y2g3l4y5/NET_DELAYACCT.git
```

### Q: local-test.sh 报 "busybox not found"

```bash
sudo apt-get install -y busybox-static
```

### Q: 测试输出 "(no matching sockets)"

表示查询的进程没有 TCP/UDP socket，或 socket 已关闭。确保在产生流量后、
进程退出前查询。参见 [docs/get_sockdelays_demo.log](docs/get_sockdelays_demo.log)
中的完整示例。

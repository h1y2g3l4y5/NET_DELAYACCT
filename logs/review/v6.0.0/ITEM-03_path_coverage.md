# 分项审查 - TCP/UDP 测试未覆盖全部已插桩路径

- **关联日志**: 无（本轮针对现有测试方案审查）
- **审查日期**: 2026-07-29

## 变更概述

内核补丁已为 TCP/UDP 的多条 RX/TX 路径插桩，但测试方案主要依赖 iperf3 的 sendmsg/recvmsg 路径，未覆盖 splice、zerocopy、UDP corked 等路径。

## 审查意见

### 文件: `tests/README.md`

#### 变更内容
- 第 335-345 行覆盖矩阵声称覆盖 TCP/UDP RX/TX、GRO/GSO 等，但未声明 splice/zerocopy/corked/IPv6 的覆盖缺口。

#### 审查意见
- **第 338 行**: 协议覆盖声明过于乐观。
  - 严重度: 高
  - 建议: 在覆盖矩阵中增加「未覆盖路径」行，列出 splice/zerocopy/UDP corked/IPv6 流量，并说明原因或增强计划。
  - Worker反馈: [待回应]

### 文件: `ci/qemu/run-tests.sh`

#### 变更内容
- Test 04/05/09/10/11 均使用 iperf3 TCP/UDP，只走普通 sendmsg/recvmsg 路径。

#### 审查意见
- **第 274-310 行 (Test 04)**: 未覆盖 `tcp_read_sock()` splice 路径和 `tcp_zerocopy_receive()` 路径。
  - 严重度: 中
  - 建议: 新增 splice/zerocopy 专项测试，或在文档中标注未覆盖。
  - Worker反馈: [待回应]
- **第 312-352 行 (Test 05)**: 未覆盖 UDP corked 路径（`MSG_MORE` / `UDP_CORK`）。
  - 严重度: 中
  - 建议: 新增 UDP corked TX 测试，使用 `setsockopt(UDP_CORK)` 或 `sendmsg(MSG_MORE)`。
  - Worker反馈: [待回应]

## 综合意见

项目文档（`kernel-patches/README.md`）已详细说明支持 splice、zerocopy、UDP corked、IPv6 等路径，但测试方案没有提供相应回归保护。这会导致：
- 这些路径的插桩被意外删除时，测试不会失败。
- 用户实际使用这些路径时，统计结果不可信。

## 附加建议

优先级排序：
1. **P1**: 新增 IPv6 流量专项测试（至少 TCP/UDP 各一个），因为此前已修复过 IPv6 相关 BUG。
2. **P1**: 新增 UDP corked TX 测试，实现成本较低。
3. **P2**: 新增 splice RX 测试（可用 `splice()` 到 `/dev/null`）。
4. **P2**: 新增 zerocopy RX 测试（受工具链支持限制，可标注为待集成）。

# NetworkExtension 迁移计划

本计划旨在将 EasyTier 的特权 Helper 替换为 Apple 推荐的 `NetworkExtension` (Packet Tunnel Provider)。这将移除复杂的 Helper 安装流程，提升用户体验。

## 第一阶段：Xcode 项目配置 (需手动操作)

由于我无法操作 Xcode UI，请你完成以下步骤：

1.  **添加 Network Extension Target**:
    - 在 Xcode 中，File -> New -> Target...
    - 选择 **Network Extension** (macOS)。
    - Product Name 填 `EasyTierPT` (或者你喜欢的名字，代表 Packet Tunnel)。
    - Language 选择 **Swift**。
    - Provider Type 选择 **Packet Tunnel**。
    - **重要**：Embed in Application 选择 `Swiftier`。

2.  **配置 Entitlements (App & Extension)**:
    - **主 App (`Swiftier`)**:
      - 添加 `Network Extensions` 能力 (Capability)。
      - 勾选 `Packet Tunnel`。
      - 添加 `App Groups` 能力，并创建一个 group (例如 `group.com.alick.swiftier`)，用于共享配置和日志文件。
    - **Extension (`EasyTierPT`)**:
      - 确保 `Network Extensions` 能力已启用，且勾选 `Packet Tunnel`。
      - 添加 **相同的** `App Groups` (`group.com.alick.swiftier`)。
    - **移除 Sandbox (可选但推荐)**:
      - NetworkExtension 默认必须沙盒化。如果 EasyTier core 需要访问非沙盒路径，可能需要调整。但通常我们通过 App Group 共享配置。

3.  **链接库文件**:
    - 将 `EasyTierCore` (Rust 库) 链接到新的 `EasyTierPT` target。
    - 确保 `libEasyTierCore.a` 被包含在 Extension 的 `Link Binary With Libraries` 中。
    - 确保 Bridging Header 配置正确，以便 Swift 能调用 Rust C 函数。

## 第二阶段：核心代码迁移

一旦 Target 创建完成，我将协助你：

1.  **共享 FFI 代码**:
    - 将 `EasyTierCore.swift` 和 `SharedTypes.swift` 移动到 App 和 Extension 都能访问的共享目录（或添加到两个 Target）。
    - 确保 Bridging Header 在 Extension 中也能正确引用。

2.  **实现 `PacketTunnelProvider`**:
    - 重写 `PacketTunnelProvider.swift`。
    - 在 `startTunnel` 中调用 `EasyTierCore.startNetwork`。
    - 在 `stopTunnel` 中调用 `EasyTierCore.stopNetwork`。
    - 实现日志重定向：将 Rust 日志写入 App Group 下的共享文件，以便主 App 读取。

## 第三阶段：IPC 与控制逻辑更新

1.  **更新 `CoreService`**:
    - 移除 `SMAppService` 和 `HelperManager` 相关代码。
    - 引入 `NETunnelProviderManager` 来管理 VPN 配置和生命周期。
    - 实现 `loadAllFromPreferences` -> `saveToPreferences` 流程来安装 VPN 配置文件。

2.  **日志与状态同步**:
    - **状态**: 使用 `NEVPNStatus` (connected, disconnected, etc.)。
    - **日志**: App 改为从 App Group 共享路径读取日志文件。
    - **实时信息 (Running Info)**: 使用 `provider.sendProviderMessage` 获取实时 JSON 数据。

## 第四阶段：清理与测试

1.  移除 `EasyTierHelper` target 和相关 plist 文件。
2.  测试 VPN 连接、断开、自启动行为。
3.  验证日志实时显示。

---

**准备好后，请先执行“第一阶段”的 Xcode 操作。**
完成后，请告诉我 **Extension 的 Bundle Identifier** (例如 `com.alick.swiftier.EasyTierPT`) 和 **App Group ID**。
这将用于接下来的代码编写。

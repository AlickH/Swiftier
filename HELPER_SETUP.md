# EasyTier Helper (SMAppService Daemon) 配置指南

本文档说明如何正确配置 EasyTierHelper daemon，实现以 root 权限运行 easytier-core。

## 架构概述

```
┌─────────────────────────────────────────────────────────────┐
│                    EasyTier.app (主应用)                      │
│  ┌─────────────────┐    ┌─────────────────────────────────┐ │
│  │  HelperManager  │───▶│  XPC Connection (privileged)    │ │
│  └─────────────────┘    └─────────────────────────────────┘ │
│                                     │                        │
│  Contents/Library/LaunchDaemons/    │                        │
│  └── com.alick.swiftier.helper.plist│                        │
└─────────────────────────────────────│────────────────────────┘
                                      │ XPC
                                      ▼
┌─────────────────────────────────────────────────────────────┐
│       com.alick.swiftier.helper (Helper Daemon)             │
│       运行身份: root                                         │
│       安装位置: /Library/PrivilegedHelperTools/             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  CoreProcessManager                                   │   │
│  │  └── 启动/停止 easytier-core                         │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Xcode 项目配置

### 1. Helper Target 配置

1. **创建新 Target**（如果还没有）:
   - File → New → Target
   - 选择 "macOS" → "Command Line Tool"
   - Product Name: `com.alick.swiftier.helper`
   - Bundle Identifier: `com.alick.swiftier.helper`

2. **添加源文件到 Helper Target**:
   - `EasyTierHelper/main.swift`
   - `EasyTierHelper/HelperProtocol.swift`

3. **配置 Build Settings**:
   ```
   PRODUCT_NAME = SwiftierHelper                    # 可执行文件名（人类可读）
   PRODUCT_BUNDLE_IDENTIFIER = com.alick.swiftier.helper  # Bundle ID（反向 DNS）
   INFOPLIST_FILE = EasyTierHelper/Info.plist
   CODE_SIGN_ENTITLEMENTS = EasyTierHelper/EasyTierHelper.entitlements
   SKIP_INSTALL = YES
   ```

4. **配置 Info.plist**:
   - 确保 `SMAuthorizedClients` 包含主应用的 bundle identifier

### 2. 主应用 Target 配置

1. **添加源文件**:
   - `EasyTier/HelperProtocol.swift`
   - `EasyTier/HelperManager.swift`

2. **配置 Build Settings**:
   ```
   PRODUCT_BUNDLE_IDENTIFIER = com.alick.swiftier
   INFOPLIST_FILE = EasyTier/Info.plist
   CODE_SIGN_ENTITLEMENTS = EasyTier/EasyTier.entitlements
   ```

3. **添加 SMAppService framework**:
   - Target → General → Frameworks, Libraries, and Embedded Content
   - 添加 `ServiceManagement.framework`

### 3. 嵌入 Helper 到主应用

1. **复制 launchd plist 文件**:
   - 主应用 Target → Build Phases → + → New Copy Files Phase
   - **Destination**: `Wrapper`
   - **Subpath**: `Contents/Library/LaunchDaemons`
   - 勾选 "Copy only when installing": ❌ (不勾选)
   - 添加文件: `com.alick.easytier.helper.plist`

2. **复制 Helper 可执行文件**:
   - 创建另一个 Copy Files Build Phase
   - **Destination**: `Executables`
   - **Subpath**: (留空)
   - 添加产物: `EasyTierHelper` (Helper target 的编译产物)

3. **添加 Target 依赖**:
   - 主应用 Target → Build Phases → Dependencies
   - 添加 `EasyTierHelper` target

### 4. 代码签名配置

**重要**: SMAppService daemon 需要正确的代码签名！

1. **开发环境**:
   - 使用 "Sign to Run Locally" 或开发者证书
   - 确保主应用和 Helper 使用相同的 Team ID

2. **生产环境**:
   - 必须使用 Developer ID 证书签名
   - 更新 Info.plist 中的 anchor 验证规则:

   主应用 Info.plist:
   ```xml
   <key>SMPrivilegedExecutables</key>
   <dict>
       <key>com.alick.easytier.helper</key>
       <string>identifier "com.alick.easytier.helper" and anchor apple generic and certificate leaf[subject.CN] = "Developer ID Application: YOUR_NAME (TEAM_ID)"</string>
   </dict>
   ```

   Helper Info.plist:
   ```xml
   <key>SMAuthorizedClients</key>
   <array>
       <string>identifier "com.alick.easytier" and anchor apple generic and certificate leaf[subject.CN] = "Developer ID Application: YOUR_NAME (TEAM_ID)"</string>
   </array>
   ```

## 最终目录结构

编译后的 EasyTier.app 应该包含:

```
EasyTier.app/
├── Contents/
│   ├── Info.plist
│   ├── MacOS/
│   │   ├── EasyTier (主可执行文件)
│   │   ├── easytier-core
│   │   ├── easytier-cli
│   │   └── EasyTierHelper  ← Helper 可执行文件
│   ├── Library/
│   │   └── LaunchDaemons/
│   │       └── com.alick.easytier.helper.plist  ← launchd 配置
│   └── Resources/
│       └── ...
```

## 调试

### 查看 Helper 日志

```bash
# Helper 内部日志
tail -f /var/log/easytier-helper.log

# launchd stdout/stderr
tail -f /var/log/easytier-helper-stdout.log
tail -f /var/log/easytier-helper-stderr.log

# 系统日志
log stream --predicate 'subsystem contains "com.alick.easytier"'
```

### 检查 daemon 状态

```bash
# 查看 daemon 是否加载
sudo launchctl list | grep easytier

# 查看 daemon 详细信息
sudo launchctl print system/com.alick.easytier.helper

# 手动停止 daemon
sudo launchctl bootout system/com.alick.easytier.helper
```

### 常见问题

1. **"Helper registration failed"**
   - 检查代码签名是否正确
   - 检查 Info.plist 中的 anchor 配置
   - 确保 Helper 可执行文件在正确位置

2. **"XPC connection error"**
   - 检查 MachServices 名称是否匹配
   - 检查 Helper 是否正在运行
   - 查看系统日志获取详细错误

3. **"Core executable not found"**
   - 确保 easytier-core 已复制到 app bundle 中
   - 检查 HelperManager.getCorePath() 返回的路径

## 注意事项

1. **沙箱**: SMAppService daemon 不兼容 App Sandbox，必须禁用
2. **公证**: 发布到 App Store 外需要进行公证 (notarization)
3. **版本升级**: 更新 Helper 时需要先卸载旧版本，或实现版本检查逻辑

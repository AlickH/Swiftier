# Swiftier Release Update

## ✨ New Features & Improvements

### 🛠️ Robust Configuration Editor
- **Smart Draft Persistence**: Never worry about losing your edits again. The editor now automatically saves your work-in-progress drafts. If you accidentally close the window, your edits will be restored instantly upon reopening.
- **Intelligent Loading**: Switching between different configuration files now correctly refreshes the editor, while returning to an unsaved file restores your specific draft for that file.
- **Plaintext Secrets**: Network secrets are now displayed in plaintext for easier verification and editing.

### � Rust Core Integration (Major)
- **Native Embedding**: Integrated `easytier-core` directly into the helper executable as a static library, eliminating the need for external binaries.
- **Improved Stability**: Removed complex process management and orphan detection logic. The core now runs within the `SwiftierHelper` daemon, managed via Robust XPC calls.
- **Log Reliability**: Fixed critical log rotation conflicts and enabled proper append-only logging for the Rust core to prevent data loss on startup.

### �📜 Enhanced Log Viewer
- **Polished UI**: Updated "Scroll to Top" buttons with a modern system-blue FAB design for better visibility and consistency.
- **Optimized Readability**: JSON arrays in log entries are now intelligently compacted. Short lists (like IPs or peers) are displayed on a single line, reducing vertical clutter and making logs much easier to scan.
- **Real-time Updates**: Log viewer now utilizes XPC to stream events directly from the helper, ensuring instant feedback.

### 🐛 Bug Fixes
- **SOCKS5 Port Display**: Fixed a UI glitch where the default port 1080 text would overlap with user input.
- **Editor State Management**: Resolved issues where the editor would sometimes display stale data from a previously selected configuration.

## 🔧 Under the Hood
- Refactored `ConfigGeneratorView` loading logic to prioritize memory drafts over file system reads during active sessions.
- Upgraded `ConfigDraftManager` to support concurrent drafts for multiple files (based on URL keys).
- Ensured `EasyTierConfigModel` conforms to `Equatable` for reliable state change tracking.

---

# Swiftier 更新日志 (中文版)

## ✨ 新特性与改进

### 🛠️ 更健壮的配置编辑器
- **智能草稿保存**：再也不用担心编辑丢失。编辑器现在会自动保存您的工作草稿。即使不小心关闭了窗口，重新打开时也能瞬间恢复之前的编辑状态。
- **智能加载逻辑**：在不同配置文件间切换时，编辑器会正确加载最新内容；而当您返回之前编辑过但未保存的文件时，会自动恢复当时的草稿。
- **密码明文显示**：网络密钥（Network Secret）现在以明文形式显示，方便您进行校验和修改。

### 🚀 Rust Core 内核集成 (重大更新)
- **原生内嵌**：将 `easytier-core` 作为静态库直接集成到 Helper 中，不再依赖外部二进制文件下载和管理。
- **稳定性提升**：移除了复杂的进程管理和孤儿进程检测逻辑。内核现在运行在 `SwiftierHelper` 守护进程中，通过更加健壮的 XPC 进行管理。
- **日志可靠性**：修复了严重的日志轮转冲突，并启用了 Rust 内核的追加写入模式，彻底解决了启动时可能丢失日志的问题。

### 📜 增强的日志查看器
- **界面优化**：“回到顶部”按钮升级为现代化的系统蓝色悬浮按钮（FAB），视觉效果更统一且清晰。
- **可读性优化**：日志中的 JSON 数组现在支持智能折叠。简短的列表（如 IP 地址或节点列表）将合并为单行显示，大幅减少垂直空间的占用，让日志更易于阅读。
- **实时更新**：日志功能现在通过 XPC 直接从后台 Helper 流式获取事件，确保数据的即时性和准确性。

### 🐛 问题修复
- **SOCKS5 端口显示**：修复了高级设置中默认端口 1080 提示文本与用户输入内容重叠的 UI 问题。
- **编辑器状态管理**：彻底解决了编辑器在某些情况下会错误显示上一次选中配置内容的 Bug。

## 🔧 底层优化
- 重构了 `ConfigGeneratorView` 的数据加载逻辑，确立了“草稿优先”原则，防止文件读取覆盖用户未保存的修改。
- 升级 `ConfigDraftManager` 以支持多文件并发草稿（基于文件 URL 管理），提升多任务处理体验。
- 实现了 `EasyTierConfigModel` 的 `Equatable` 协议，从而能够精准追踪配置变更。

# Swiftier Release Update (v1.1.1)

## ✨ New Features & Improvements

### 🚀 Rust Core Refactor
- **Source Compilation**: The `easytier-core` kernel is now compiled directly from Rust source via `SwiftierHelper`, replacing the external binary dependency. This architectural shift significantly enhances stability, observability, and long-term maintainability.

### 🎨 UI/UX Overhaul
- **Log & Event View**: Completely redesigned with a native **Split-View** layout. It now features a robust timeline with continuous visual flow, color-coded status indicators (Yellow for Connecting/Unknown states), and zebra-striped lists for superior readability.
- **Buttery Smooth Peer List**: Solved the persistent vertical bounce issue on the horizontal peer list using deep AppKit event interception (`scrollWheel` override), ensuring a rock-solid, physically locked scrolling experience.
- **Visual Polish**: Optimized the rendering of Sparkline network charts and Ripple animations for fluid performance.

### 🐛 Bug Fixes
- **Permissions**: Fixed the Full Disk Access (FDA) guide flow to ensure smoother initial setup.
- **Stability**: Enhanced the stability of configuration file I/O operations.

### ⚠️ Known Issues
- **High CPU Usage**: Users may notice higher CPU usage (approx. 50% single-core) when the main dashboard is active. This is a known performance bottleneck related to the UI rendering loop and is prioritized for optimization in the upcoming release.

---

# Swiftier 更新日志 (v1.1.1 中文版)

## ✨ 新特性与改进

### 🚀 Rust Core 内核重构
- **源码编译集成**：弃用了外部二进制文件，改用通过 `SwiftierHelper` 直接编译集成的 Rust 源码版 `easytier-core`。这一架构调整显著提升了运行稳定性、可观测性和后续维护效率。

### 🎨 界面与交互大修
- **日志与事件视图**：采用原生 **Split-View 分栏设计** 全新重构。引入了视觉连续的时间轴、状态颜色指示（连接中/未知状态显示为黄色）以及斑马纹列表背景，阅读体验大幅提升。
- **丝滑的节点列表**：通过底层的 AppKit 事件拦截技术（重写 `scrollWheel`），彻底修复了水平节点列表在滚动时的垂直回弹（抖动）问题，带来了如原生般稳固的交互手感。
- **视觉打磨**：优化了网络波形图（Sparkline）和水波纹动画的渲染流程，视觉效果更加流畅。

### 🐛 问题修复
- **权限引导**：修复了“完全磁盘访问权限”（FDA）的引导流程，确保初次配置更加顺畅。
- **IO 稳定性**：增强了配置文件读写操作的健壮性。

### ⚠️ 已知问题
- **CPU 占用偏高**：当主界面处于前台显示时，CPU 占用率可能会达到单核 50% 左右。这是由于当前 UI 渲染循环尚未完全优化导致的已知问题，我们将把它作为下一版本的首要优化目标。

---

# Swiftier Release Update

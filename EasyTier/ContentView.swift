import SwiftUI
import Combine

struct ContentView: View {
    
    @StateObject private var runner = EasyTierRunner.shared
    @StateObject private var configManager = ConfigManager.shared

    @StateObject private var permissionManager = PermissionManager.shared
    
    @State private var selectedConfig: URL?
    @State private var showLogView = false
    @State private var showSettingsView = false
    @State private var showConfigGenerator = false
    @State private var editingConfigURL: URL?
    @State private var showCreatePrompt = false
    @State private var showFDAOverlay = false
    @State private var newConfigName = ""
    @State private var isWindowVisible = true // Track window visibility to pause rendering
    
    private let windowWidth: CGFloat = 420
    private let windowHeight: CGFloat = 520
    
    var body: some View {
        ZStack {
            // 不再手动设置背景，利用 MenuBarExtra 原生窗口的 Vibrancy
            
            // 主内容层
            VStack(spacing: 0) {
                headerView
                //Divider()
                contentArea
            }
            .frame(width: windowWidth, height: windowHeight)
            
            // 日志全屏覆盖层
            // 日志全屏覆盖层
            if showLogView {
                LogView(isPresented: $showLogView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
                    // Compositing Group forces atomic rendering, preventing "content float" artifacts during slide
                    .compositingGroup()
                    .zIndex(100)
                    .transition(.move(edge: .bottom))
            }
            
            // 设置全屏覆盖层
            if showSettingsView {
                SettingsView(isPresented: $showSettingsView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
                    .zIndex(101) // 比日志层更高
                    .transition(.move(edge: .bottom))
            }
            
            // 编辑器全屏覆盖层
            if let url = editingConfigURL {
                ConfigEditorView(
                    isPresented: Binding(
                        get: { true },
                        set: { if !$0 { editingConfigURL = nil } }
                    ),
                    fileURL: url
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
                .zIndex(102) // 最高层级
                .transition(.move(edge: .bottom))
            }
            
            // 生成器全屏覆盖层 (Keep alive to persist draft state)
            ConfigGeneratorView(
                isPresented: $showConfigGenerator,
                editingFileURL: selectedConfig,
                onSave: { configManager.refreshConfigs() }
            )
            .id(selectedConfig) // Force reset state when config changes
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(103)
            .offset(y: showConfigGenerator ? 0 : windowHeight)
            .animation(.spring(response: 0.6, dampingFraction: 0.8), value: showConfigGenerator)
            
            // 新建配置弹窗
            if showCreatePrompt {
                Color.black.opacity(0.3).zIndex(104)
                    .onTapGesture { withAnimation { showCreatePrompt = false } }
                
                VStack(spacing: 20) {
                    Text("创建新网络")
                        .font(.headline)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("配置文件名:")
                        TextField("例如: my-network", text: $newConfigName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { createConfig() }
                        Text("将自动添加 .toml 后缀")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    
                    HStack {
                        Button("取消") { withAnimation { showCreatePrompt = false } }
                        Button("创建") { createConfig() }
                            .buttonStyle(.borderedProminent)
                            .disabled(newConfigName.isEmpty)
                    }
                }
                .padding()
                .frame(width: 300)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
                .shadow(radius: 20)
                .zIndex(105)
                .transition(.scale.combined(with: .opacity))
            }
            

            
            // FDA Permission Guide
            if showFDAOverlay && !permissionManager.isFDAGranted {
                FDAGuideView(isPresented: $showFDAOverlay)
                    .zIndex(1000)
            }
        }
        .onChange(of: configManager.configFiles) { newFiles in
            // 如果列表不为空，且当前没选中的，或者选中的不在新列表里 -> 选第一个
            if !newFiles.isEmpty {
                if selectedConfig == nil || !newFiles.contains(selectedConfig!) {
                    selectedConfig = newFiles.first
                }
            } else {
                selectedConfig = nil
            }
        }
        // 移除了 onChange(of: selectedConfig) 的自动连接逻辑
        .onAppear {
            // 检查权限
            permissionManager.checkFullDiskAccess()
            if !permissionManager.isFDAGranted {
                showFDAOverlay = true
            }
            
            // 初始启动时刷新一次列表
            configManager.refreshConfigs()
            
            // 刷新后立刻尝试选中
            if !configManager.configFiles.isEmpty && selectedConfig == nil {
                selectedConfig = configManager.configFiles.first
            }
            
            // 同步 Core 状态，完成后根据情况决定是否自动连接
            runner.syncWithCoreState { coreAlreadyRunning in
                // 场景1&2: 如果 Core 已经在运行，无论自动连接是否开启，都继承状态（已在 syncWithCoreState 内处理）
                // 场景3: 如果自动连接关闭且 Core 未运行，什么都不做
                // 场景4: 如果自动连接关闭但 Core 已运行，UI 已更新（在 syncWithCoreState 内处理）
                
                // 只有当 Core 未运行 且 用户开启了自动连接 时，才自动启动
                if !coreAlreadyRunning && UserDefaults.standard.bool(forKey: "connectOnStart") {
                    if let path = selectedConfig?.path {
                        print("[ContentView] Auto-Connect: Core not running, starting now...")
                        runner.toggleService(configPath: path)
                    }
                } else if coreAlreadyRunning {
                    print("[ContentView] Core already running, inheriting state")
                } else {
                    print("[ContentView] No auto-connect, waiting for user action")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            isWindowVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            isWindowVisible = false
        }
    }
    
    // MARK: - Header
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Menu {
                Section("配置文件") {
                    if configManager.configFiles.isEmpty {
                        Button("未发现配置") { }
                            .disabled(true)
                    } else {
                        ForEach(configManager.configFiles, id: \.self) { url in
                            Button(action: { selectedConfig = url }) {
                                HStack {
                                    Text(url.deletingPathExtension().lastPathComponent)
                                    if selectedConfig == url {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
                
                Divider()
                
                Button("创建新网络") {
                    newConfigName = ""
                    withAnimation { showCreatePrompt = true }
                }
                
                Button("编辑配置") {
                    withAnimation { showConfigGenerator = true }
                }
                .disabled(selectedConfig == nil)
                
                Button("编辑配置为文件") {
                    withAnimation {
                        editingConfigURL = selectedConfig
                    }
                }
                .disabled(selectedConfig == nil)
                
                Divider()
                
                Button("存储到 iCloud") { configManager.migrateToiCloud() }
                Button("选择文件夹") { configManager.selectCustomFolder() }
                Button("在 Finder 中打开") { configManager.openiCloudFolder() }

                
                Divider()
                
                Button(role: .destructive) { deleteSelectedConfig() } label: {
                    Text("删除选中的配置")
                        .foregroundColor(.red)
                }
                .disabled(selectedConfig == nil)
            } label: {
                HStack {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                    Text(selectedConfig?.deletingPathExtension().lastPathComponent ?? "请选择配置")
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .cornerRadius(6)
            }
            .menuStyle(.borderlessButton)
            
            Spacer()
            
            // 右侧按钮组：日志、设置、退出
            HStack(spacing: 6) { // 极简间距
                // 日志按钮
                Button(action: { 
                    withAnimation {
                        showLogView = true
                    }
                }) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 14))
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                // 设置按钮
                Button(action: {
                    withAnimation {
                        showSettingsView = true
                    }
                }) {
                    Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .padding(5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                // 退出按钮
                Button(action: { 
                    // 退出逻辑：根据 exitBehavior 设置决定行为
                    let behavior = UserDefaults.standard.string(forKey: "exitBehavior") ?? "stopCore"
                    
                    switch behavior {
                    case "keepRunning":
                        // 保持连接运行，直接退出 UI
                        NSApplication.shared.terminate(nil)
                        
                    case "stopCore":
                        // 断开连接，但保留 Helper
                        CoreService.shared.stop { _ in
                            DispatchQueue.main.async {
                                NSApplication.shared.terminate(nil)
                            }
                        }
                        
                    case "stopAll":
                        // 完全退出（停止 Helper + Core）
                        if #available(macOS 13.0, *) {
                            CoreService.shared.quitHelper {
                                DispatchQueue.main.async {
                                    NSApplication.shared.terminate(nil)
                                }
                            }
                        } else {
                            CoreService.shared.stop()
                            NSApplication.shared.terminate(nil)
                        }
                        
                    default:
                        NSApplication.shared.terminate(nil)
                    }
                }) {
                    Image(systemName: "power")
                        .font(.system(size: 14)) // 恢复默认粗细
                        .foregroundColor(.red)
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // 移除了 .padding(.trailing, 12)，让左右边距一致（由外层 padding 控制）
        }
        .padding(12)
        .zIndex(200) // 确保 Header 在最上层，防止点击被下方内容遮挡
    }
    
    private var contentArea: some View {
        GeometryReader { geo in
            ZStack {
                // 1) 水波纹层 (放在最底层)
                if runner.isRunning {
                    RippleRings(isVisible: runner.isRunning && isWindowVisible, duration: 4.0, maxScale: 5.5)
                        .frame(width: 500, height: 500) // Increased frame to prevent Metal clipping
                        .position(x: geo.size.width / 2, y: buttonCenterY(in: geo.size.height))
                        .zIndex(0)
                }

                // 2) 节点列表区域
                if runner.isRunning {
                    if !runner.peers.isEmpty {
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)
                                ],
                                spacing: 10
                            ) {
                                ForEach(runner.peers) { peer in
                                    PeerCard(peer: peer)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                            .padding(.top, 10) // Small top padding inside scroll
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10)) // Clip content at scroll boundaries
                        .padding(.horizontal, 12) // PeerList padding is 12
                        .padding(.top, 165) // Reduced to maximize peer list area
                        .padding(.bottom, 12)
                        .zIndex(1)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    } else {
                        VStack(spacing: 20) {
                            ProgressView().scaleEffect(1.2).controlSize(.large)
                            Text("节点加载中").font(.title3.bold()).foregroundColor(.secondary)
                        }
                        .padding(.top, 165)
                        .zIndex(1)
                    }
                }

                // 3) 启动按钮与网速仪表盘层
                HStack(spacing: -6) { // Slight negative spacing for a connected but not obscuring look
                    // Calculate unified max scale for both cards
                    let maxSpeed = max(
                        (runner.downloadHistory.max() ?? 10.0),
                        (runner.uploadHistory.max() ?? 10.0)
                    )
                    
                    // Download Card
                    SpeedCard(
                        title: "DOWNLOAD",
                        value: runner.downloadSpeed,
                        icon: "arrow.down.square.fill",
                        color: .blue,
                        history: runner.downloadHistory,
                        maxVal: maxSpeed,
                        isVisible: runner.isRunning && isWindowVisible
                    )
                    
                    // Center Power Button
                    Button {
                        let path = selectedConfig?.path ?? configManager.configFiles.first?.path ?? ""
                        runner.toggleService(configPath: path)
                    } label: {
                        StartStopButtonCore(isRunning: runner.isRunning, uptimeText: runner.uptimeText)
                    }
                    .buttonStyle(.plain)
                    .zIndex(20)
                    
                    // Upload Card
                    SpeedCard(
                        title: "UPLOAD",
                        value: runner.uploadSpeed,
                        icon: "arrow.up.square.fill",
                        color: .orange, // Changed from .green to .orange as per original content
                        history: runner.uploadHistory,
                        maxVal: maxSpeed,
                        isVisible: runner.isRunning && isWindowVisible // Modified: 2. 在 SpeedCard 调用中加入 && isWindowVisible 条件。
                    )
                }
                .padding(.horizontal, 12) // Match PeerList padding exactly
                .frame(width: geo.size.width) // Use full width, padding handles inset
                .position(x: geo.size.width / 2, y: buttonCenterY(in: geo.size.height))
                .zIndex(10)
            }
            .animation(.spring(response: 1.0, dampingFraction: 0.8), value: runner.isRunning)
            .animation(.spring(response: 0.55, dampingFraction: 0.8), value: showLogView)
        }
    }
    
    private func buttonCenterY(in contentHeight: CGFloat) -> CGFloat {
        runner.isRunning ? 105 : (contentHeight / 2) // Moved up to 105 to maximize peer list space
    }
    
    // MARK: - SpeedCard Component
    struct SpeedCard: View {
        let title: String
        let value: String // e.g. "133.3 KB/s"
        let icon: String
        let color: Color
        let history: [Double]
        let maxVal: Double
        let isVisible: Bool
        
        // Helper to split value and unit
        private var splitValue: (number: String, unit: String) {
            let components = value.components(separatedBy: " ")
            if components.count >= 2 {
                return (components[0], components[1])
            }
            return (value, "")
        }
        
        var body: some View {
            ZStack(alignment: .bottom) {
                // Content (Below the line but drawn first)
                VStack(alignment: .leading, spacing: 2) {
                    // Title (Left Aligned)
                    HStack(spacing: 4) {
                        Image(systemName: icon)
                            .foregroundColor(color)
                            .font(.system(size: 10, weight: .bold))
                        Text(title)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(color.opacity(0.8))
                    }
                    .padding(.top, 10)
                    
                    Spacer()
                    
                    // Value (Split style - Centered)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(splitValue.number)
                            .font(.system(size: 24, weight: .bold, design: .monospaced)) // Larger & Bold
                        Text(splitValue.unit)
                            .font(.system(size: 11, weight: .bold, design: .monospaced)) // Changed to .bold
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    
                    Spacer()
                    
                    Color.clear.frame(height: 12)
                }
                .padding(.horizontal, 12)
                .zIndex(1) // Above background but below sparkline path if we want sparkline on VERY top
                
                // Sparkline (On top layer as requested)
                // Sparkline (On top layer as requested)
                // Sparkline (On top layer as requested)
                Sparkline(data: history, color: color, maxScale: maxVal, paused: !isVisible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity) // Fills the card
                    .zIndex(10) // Top layer
                    .allowsHitTesting(false) // Don't block interactions
            }
            .frame(maxWidth: .infinity)
            .frame(height: 85) // Reduced from 100 to 85 to fix crowding
            .background(
                RoundedRectangle(cornerRadius: 10) // Match PeerCard (10)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(color.opacity(0.2), lineWidth: 1)
            )
            // Removed clipShape to allow pulse ripple to extend beyond card boundary
            .opacity(isVisible ? 1 : 0)
            .scaleEffect(isVisible ? 1 : 0.98)
            // Use a smoother spring for the entire card presence
            .animation(.spring(response: 0.8, dampingFraction: 0.8), value: isVisible)
        }
    }
    
    // MARK: - Sparkline Component (Swift Charts)
    // MARK: - Sparkline Component
    // MARK: - Sparkline Component
    struct Sparkline: View {
        let data: [Double]
        let color: Color
        let maxScale: Double
        let paused: Bool
        
        var body: some View {
            GeometryReader { geo in
                AnimatableSparkline(data: data, color: color, currentMax: maxScale, paused: paused)
                    .frame(width: geo.size.width + 60, height: geo.size.height + 60)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: maxScale)
            }
        }
    }
    
    struct AnimatableSparkline: View, Animatable {
        let data: [Double]
        let color: Color
        var currentMax: Double
        let paused: Bool
        
        var animatableData: Double {
            get { currentMax }
            set { currentMax = newValue }
        }
        
        @State private var ghostValue: Double? = nil
        @State private var lastUpdateTime: Date = Date()
        
        var body: some View {
            Group {
                if paused {
                    Color.clear
                } else {
                    // Limit to 24fps to balance smoothness and CPU usage (User Request)
                    TimelineView(.periodic(from: .now, by: 1.0 / 24.0)) { timeline in
                        Canvas { context, size in
                            let now = timeline.date
                            // Calculate progress for smooth interpolation (1.0s interval)
                            let refreshDuration: Double = 1.0
                            let timeDiff = now.timeIntervalSince(lastUpdateTime)
                            let progress = min(timeDiff / refreshDuration, 1.0)
                            
                            guard data.count > 1 else { return }
                            
                            let overflow: CGFloat = 60.0
                            let shift = overflow / 2.0
                            
                            // Shift coordinate system
                            context.translateBy(x: shift, y: shift)
                            
                            let w = size.width - overflow
                            let h = size.height - overflow
                            let rightPadding: CGFloat = 10.0
                            let innerWidth = w - rightPadding
                            
                            let range = max(currentMax, 0.001)
                            let stepX = innerWidth / CGFloat(data.count - 1)
                            
                            // Layout constants
                            let strokeWidth: CGFloat = 2.5
                            let bottomBuffer: CGFloat = strokeWidth / 2.0 + 0.5
                            let topBuffer: CGFloat = 8.0
                            let availableHeight = h - bottomBuffer - topBuffer

                            // 1. Prepare Base Points
                            var points = data.enumerated().map { (i, val) -> CGPoint in
                                let x = CGFloat(i) * stepX
                                let y = h - bottomBuffer - (CGFloat(val / range) * availableHeight)
                                return CGPoint(x: x, y: y)
                            }
                            
                            // 2. Apply "Growth" to the last point (Y-axis vertical interpolation)
                            if points.count >= 2 {
                                let lastIndex = points.count - 1
                                let secondLastY = points[lastIndex - 1].y
                                let targetY = points[lastIndex].y
                                let currentY = secondLastY + (targetY - secondLastY) * CGFloat(progress)
                                points[lastIndex].y = currentY
                            }
                            
                            // 3. Continuous Scroll Offset (Right to Left horizontal interpolation)
                            let scrollOffset = (1.0 - progress) * stepX
                            
                            context.withCGContext { cgContext in
                                var path = Path()
                                
                                // 4. Ghost Point (Left edge seamless fill)
                                let firstY = points.first?.y ?? (h - bottomBuffer)
                                let ghostValY = ghostValue.map { h - bottomBuffer - (CGFloat($0 / range) * availableHeight) }
                                let startY = ghostValY ?? firstY
                                
                                path.move(to: CGPoint(x: -stepX, y: startY))
                                if !points.isEmpty {
                                    path.addLine(to: points[0])
                                }
                                
                                // 5. History Line
                                for i in 1..<(points.count - 1) {
                                    let p1 = points[i-1]
                                    let p2 = points[i]
                                    path.addLine(to: p2)
                                }
                                
                                // 6. Anchored Tip
                                if let lastIdx = points.indices.last {
                                    points[lastIdx].x -= scrollOffset
                                    path.addLine(to: points[lastIdx])
                                }
                                
                                var fillPath = path
                                fillPath.addLine(to: CGPoint(x: points.last!.x, y: h))
                                fillPath.addLine(to: CGPoint(x: ghostValue != nil ? -stepX : 0, y: h))
                                fillPath.closeSubpath()
                                
                                // Content Drawing
                                var contentContext = context
                                let cardPath = Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: 10)
                                contentContext.clip(to: cardPath)
                                contentContext.translateBy(x: scrollOffset, y: 0)
                                
                                // Gradient Fill
                                contentContext.fill(fillPath, with: .linearGradient(
                                    Gradient(colors: [color.opacity(0.3), color.opacity(0)]),
                                    startPoint: .zero, endPoint: CGPoint(x: 0, y: h)
                                ))
                                
                                // Stroke Line
                                contentContext.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
                                
                                // 7. Hotspot & Pulse (Outside Clip)
                                context.withCGContext { _ in
                                     context.translateBy(x: scrollOffset, y: 0)
                                     
                                    if let lastPoint = points.last {
                                        let t = now.timeIntervalSinceReferenceDate
                                        let pulseDuration: Double = 0.8
                                        let pulseProg = (t.truncatingRemainder(dividingBy: pulseDuration)) / pulseDuration
                                        let rippleRadius = 4.0 + (12.0 * pulseProg)
                                        let rippleOpacity = 0.4 * (1.0 - pulseProg)
                                        
                                        // Ripple
                                        context.stroke(
                                            Path(ellipseIn: CGRect(x: lastPoint.x - rippleRadius, y: lastPoint.y - rippleRadius, 
                                                                  width: rippleRadius * 2, height: rippleRadius * 2)),
                                            with: .color(color.opacity(rippleOpacity)),
                                            lineWidth: 1.5
                                        )
                                        
                                        // Dot
                                        let dotSize: CGFloat = 8.0
                                        let dotRect = CGRect(x: lastPoint.x - dotSize/2, y: lastPoint.y - dotSize/2, width: dotSize, height: dotSize)
                                        
                                        context.drawLayer { innerContext in
                                            innerContext.addFilter(.shadow(color: color.opacity(0.4), radius: 3))
                                            innerContext.fill(Path(ellipseIn: dotRect), with: .color(color))
                                            innerContext.stroke(Path(ellipseIn: dotRect), with: .color(.white), lineWidth: 1.5)
                                        }
                                    }
                                }
                            }
                        }
                        .drawingGroup() // Metal Acceleration
                    }
                }
            }
            .onChange(of: data) { newData in
                if let first = data.first {
                    ghostValue = first
                }
                lastUpdateTime = Date()
            }
            .onAppear {
                if let first = data.first { ghostValue = first }
            }
        }
    }
    
    
    // MARK: - Helper Functions
    
    private func createConfig() {
        let name = newConfigName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = name.isEmpty ? "new-network" : name
        let filename = "\(safeName).toml"
        
        let header = """
        instance_name = "\(safeName)"
        instance_id = "\(UUID().uuidString.lowercased())"
        dhcp = true
        listeners = ["tcp://0.0.0.0:11010", "udp://0.0.0.0:11010", "wg://0.0.0.0:11011"]
        
        [network_identity]
        network_name = "easytier"
        network_secret = ""
        
        [[peer]]
        uri = "tcp://public.easytier.top:11010"
        
        [flags]
        mtu = 1380
        disable_ipv6 = false
        disable_encryption = false
        """
        
        guard let currentDir = configManager.currentDirectory else { return }
        let fileURL = currentDir.appendingPathComponent(filename)
        
        do {
            try header.write(to: fileURL, atomically: true, encoding: .utf8)
            let updatedFiles = configManager.refreshConfigs()
            
            // Find and select
            if let newURL = updatedFiles.first(where: { $0.lastPathComponent == filename }) {
                selectedConfig = newURL
                // Open Editor
                withAnimation {
                    showCreatePrompt = false
                    showConfigGenerator = true
                }
            } else {
                withAnimation { showCreatePrompt = false }
            }
        } catch {
            print("Failed to create file: \(error)")
        }
    }
    
    private func deleteSelectedConfig() {
        guard let url = selectedConfig else { return }
        try? FileManager.default.removeItem(at: url)
        configManager.refreshConfigs()
        
        // Auto select next if available is handled by onChange
    }
}

// MARK: - Start/Stop Button 核心视图

struct StartStopButtonCore: View {
    let isRunning: Bool
    let uptimeText: String

    var body: some View {
        ZStack {
            // 圆按钮背景
            Circle()
                // 启动前：保持原样（蓝色或逻辑原色）
                // 启动后：变为 0.9 透明度的白色
                .fill(isRunning ? Color.white : Color.blue)
                .frame(width: 84, height: 84)
                .shadow(color: .black.opacity(isRunning ? 0.12 : 0.25), radius: 10, y: 4)

            Image(systemName: "power")
                .font(.system(size: 28, weight: .regular))
                // 启动后图标为黑色，启动前为白色
                .foregroundStyle(isRunning ? Color.black : Color.white)

            if isRunning {
                Text(uptimeText)
                    .font(.system(size: 22, weight: .bold, design: .monospaced)) // Increased size & weight
                    .foregroundColor(.primary)
                    .frame(width: 140)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .offset(y: -85) // Rebalanced offset to match the new dashboard position
            }
        }
        .frame(width: 84, height: 84)
        .padding(.vertical, 6)
    }
}

// MARK: - 水波纹（以按钮为中心）
struct RippleRings: View {
    let isVisible: Bool  // 新增：跟随按钮显示状态
    var duration: Double = 4.0
    var maxScale: CGFloat = 5.0

    @Environment(\.colorScheme) private var colorScheme

    private var baseOpacity: Double {
        colorScheme == .light ? 0.9 : 0.1
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = (t.truncatingRemainder(dividingBy: duration)) / duration
            
            // Calculate progress for each ring
            let p0 = phaseShifted(phase, by: 0.0)
            let p1 = phaseShifted(phase, by: 1.0 / 3.0)
            let p2 = phaseShifted(phase, by: 2.0 / 3.0)
            
            // Sort by progress descending (Largest -> Smallest) so large rings are in back
            let sortedProgress = [p0, p1, p2].sorted(by: >)

            ZStack {
                ForEach(sortedProgress.indices, id: \.self) { i in
                   ring(progress: sortedProgress[i])
                }
            }
        }
        .opacity(isVisible ? 1.0 : 0.0)
        .animation(.easeInOut(duration: 0.5), value: isVisible)
    }

    // phaseShifted 和 ring 保持完全不变
    private func phaseShifted(_ phase: Double, by shift: Double) -> Double {
        let p = phase - shift
        return p >= 0 ? p : (p + 1.0)
    }

    private func ring(progress: Double) -> some View {
        let scale = CGFloat(progress) * (maxScale - 1.0) + 1.0 // Start from button size (scale 1.0) to maxScale
        let opacity = baseOpacity * (1.0 - progress)

        return Circle()
            .fill(Color.white)
            .frame(width: 84, height: 84) // Match button size
            .scaleEffect(scale)
            .opacity(opacity)
    }
}



struct FDAGuideView: View {
    @Binding var isPresented: Bool
    @ObservedObject var permissionManager = PermissionManager.shared
    
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            
            VStack(spacing: 24) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.orange)
                
                VStack(spacing: 12) {
                    Text("需要完全磁盘访问权限")
                        .font(.title2.bold())
                    
                    Text("为了能够读取您选择的任意文件夹及配置文件，Swiftier 需要“完全磁盘访问权限”。\n这不会泄露您的私有数据，仅用于解除系统文件夹读取限制。")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        guideStep(number: "1", text: "点击“去开启”，进入系统设置")
                        guideStep(number: "2", text: "Swiftier 应该已自动出现在列表中")
                        guideStep(number: "3", text: "只需打开旁边的开关即可")
                    }
                    .padding(.vertical)
                    
                    VStack(spacing: 12) {
                        HStack(spacing: 15) {
                            Button("在 Finder 中显示") {
                                permissionManager.revealAppInFinder()
                            }
                            .buttonStyle(.bordered)
                            
                            Button("立即去开启") {
                                permissionManager.openFullDiskAccessSettings()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        
                        Button("以后再说") {
                            withAnimation { isPresented = false }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                }
            }
            .padding(30)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor)))
            .shadow(radius: 20)
            .frame(width: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 当用户从系统设置返回时，自动重新检查
            permissionManager.checkFullDiskAccess()
        }
    }
    
    private func guideStep(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.bold())
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.orange))
            
            Text(text)
                .font(.subheadline)
        }
    }
}

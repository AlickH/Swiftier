import SwiftUI
import Combine

struct ContentView: View {
    
    // 性能优化：不再直接观察整个 runner，避免 uptime/speed 变化触发全量 Diff
    // 改为手动监听核心状态
    private var runner = EasyTierRunner.shared
    @State private var isRunning = false
    @State private var isWindowVisible = true
    @State private var sessionID = UUID()
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
    
    private let windowWidth: CGFloat = 420
    private let windowHeight: CGFloat = 520
    
    // 逻辑：判断当前是否有全屏覆盖层显示
    private var isAnyOverlayShown: Bool {
        showLogView || showSettingsView || showConfigGenerator || editingConfigURL != nil
    }
    
    var body: some View {
        ZStack {
            // 不再手动设置背景，利用 MenuBarExtra 原生窗口的 Vibrancy
            
            // 主内容层
            if isWindowVisible {
                VStack(spacing: 0) {
                    headerView
                    //Divider()
                    contentArea
                }
                .frame(width: windowWidth, height: windowHeight)
            } else {
                // 当后台运行时，仅保留最小占位，阻止 SwiftUI 大规模 Diff
                Color.clear
                    .frame(width: windowWidth, height: windowHeight)
            }
            
            // 日志全屏覆盖层
            // 优化：窗口隐藏时不渲染覆盖层
            if showLogView && runner.isWindowVisible {
                LogView(isPresented: $showLogView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
                    // Compositing Group forces atomic rendering, preventing "content float" artifacts during slide
                    .compositingGroup()
                    .zIndex(100)
                    .transition(.move(edge: .bottom))
            }
            
            // 设置全屏覆盖层
            if showSettingsView && runner.isWindowVisible {
                SettingsView(isPresented: $showSettingsView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
                    .zIndex(101) // 比日志层更高
                    .transition(.move(edge: .bottom))
            }
            
            // 编辑器全屏覆盖层
            if let url = editingConfigURL, runner.isWindowVisible {
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
            
            // 生成器全屏覆盖层
            // 优化：只有显示时才创建，避免频繁初始化
            if showConfigGenerator && isWindowVisible {
                ConfigGeneratorView(
                    isPresented: $showConfigGenerator,
                    editingFileURL: selectedConfig,
                    onSave: { configManager.refreshConfigs() }
                )
                .id(selectedConfig)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(103)
                .transition(.move(edge: .bottom))
            }
            
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
                            .textContentType(.none)
                            .disableAutocorrection(true)
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
            
            // 设置窗口可见，开始动画
            runner.isWindowVisible = true
        }
        .onDisappear {
            runner.isWindowVisible = false
        }
        .onReceive(runner.$isRunning) { self.isRunning = $0 }
        .onReceive(runner.$isWindowVisible) { self.isWindowVisible = $0 }
        .onReceive(runner.$sessionID) { self.sessionID = $0 }
        .lockVerticalScroll() // 🔒 Global Lock: Prevents the entire window container from bouncing
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
                // 1) 水波纹层 (放在最底层) - UIKit 高性能实现
                if isRunning && isWindowVisible {
                    RippleRingsView(isVisible: true, duration: 4.0, maxScale: 5.5)
                        .frame(width: 500, height: 500)
                        .position(x: geo.size.width / 2, y: buttonCenterY(in: geo.size.height))
                        .allowsHitTesting(false)
                        .transition(.opacity) // Fade in
                        .zIndex(0)
                }

                // 2) 节点列表区域 - 使用独立组件隔离刷新
                if isRunning && isWindowVisible && !isAnyOverlayShown {
                    PeerListArea()
                        .id(sessionID)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(1)
                }

                // 3) 启动按钮与网速仪表盘层 - 使用独立组件隔离刷新
                if isWindowVisible {
                    SpeedDashboard(
                        selectedConfigPath: selectedConfig?.path ?? configManager.configFiles.first?.path ?? "",
                        geoSize: geo.size,
                        buttonCenterY: buttonCenterY(in: geo.size.height),
                        isPaused: isAnyOverlayShown
                    )
                    .zIndex(10)
                }
            }
            .animation(.spring(response: 1.0, dampingFraction: 0.8), value: isRunning)
            .animation(.spring(response: 0.55, dampingFraction: 0.8), value: showLogView)
            .blur(radius: isAnyOverlayShown ? 10 : 0)
            .opacity(isAnyOverlayShown ? 0.3 : 1.0)
        }
    }
    
    private func buttonCenterY(in contentHeight: CGFloat) -> CGFloat {
        isRunning ? 133 : (contentHeight / 2) // Centered between duration (Y=20) and peer cards (Y=234)
    }
    
    // MARK: - SpeedCard Component
    struct SpeedCard: View, Equatable {
        let title: String
        let value: String // e.g. "133.3 KB/s"
        let icon: String
        let color: Color
        let history: [Double]
        let maxVal: Double
        let isVisible: Bool
        let isPaused: Bool
        
        // 性能关键：手动实现 Equatable 避开不必要的重绘
        static func == (lhs: SpeedCard, rhs: SpeedCard) -> Bool {
            lhs.value == rhs.value &&
            lhs.history == rhs.history &&
            lhs.maxVal == rhs.maxVal &&
            lhs.isVisible == rhs.isVisible &&
            lhs.isPaused == rhs.isPaused
        }
        
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
                // Sparkline (Background layer) - UIKit 高性能实现
                // 当整体可见时，传入 paused=false
                SmartSparklineView(data: history, color: color, maxScale: maxVal, paused: isPaused)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 24)
                    .zIndex(0)
                    .allowsHitTesting(false)
                
                // Content (Foreground layer - Floating above sparkline)
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
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                        Text(splitValue.unit)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    
                    Spacer()
                    
                    Color.clear.frame(height: 12)
                }
                .padding(.horizontal, 12)
                .zIndex(20)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 85)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(color.opacity(0.2), lineWidth: 1)
            )
        }
    }
    
    // MARK: - 速度仪表盘（独立组件，隔离频繁刷新）
    struct SpeedDashboard: View {
        let selectedConfigPath: String
        let geoSize: CGSize
        let buttonCenterY: CGFloat
        let isPaused: Bool // 新增：是否暂停
        
        // 直接订阅 runner，只有这个组件会被频繁刷新
        @ObservedObject private var runner = EasyTierRunner.shared
        
        var body: some View {
            let maxSpeed = runner.maxHistorySpeed // 直接使用缓存，不再遍历数组
            
            HStack(spacing: -6) {
                if runner.isRunning && runner.isWindowVisible {
                    SpeedCard(
                        title: "DOWNLOAD",
                        value: runner.downloadSpeed,
                        icon: "arrow.down.square.fill",
                        color: .blue,
                        history: runner.downloadHistory,
                        maxVal: maxSpeed,
                        isVisible: true,
                        isPaused: isPaused
                    )
                    .equatable()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                
                Button {
                    if !runner.isRunning {
                            LogParser.shared.resetForNewCoreSession()
                        }
                        runner.toggleService(configPath: selectedConfigPath)
                } label: {
                    StartStopButtonCore(isRunning: runner.isRunning, uptimeText: runner.uptimeText)
                }
                .buttonStyle(.plain)
                .zIndex(20)
                
                if runner.isRunning && runner.isWindowVisible {
                    SpeedCard(
                        title: "UPLOAD",
                        value: runner.uploadSpeed,
                        icon: "arrow.up.square.fill",
                        color: .orange,
                        history: runner.uploadHistory,
                        maxVal: maxSpeed,
                        isVisible: true,
                        isPaused: isPaused
                    )
                    .equatable()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .frame(width: geoSize.width)
            .position(x: geoSize.width / 2, y: buttonCenterY)
        }
    }
    
    // MARK: - 节点列表区域（独立组件，隔离 peers 刷新）
    struct PeerListArea: View {
        @StateObject private var runner = EasyTierRunner.shared
        
        // 定义两行网格布局，自适应宽度
        private let gridRows = [
            GridItem(.fixed(105), spacing: 12),
            GridItem(.fixed(105), spacing: 12)
        ]
        
        var body: some View {
            let peerIDs = runner.peers.map(\.id)

            return VStack {
                Spacer()

                ZStack {
                    // 1) Grid 永远存在：保证后续插入/删除是“对已有容器的增删”，让 transition 生效
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHGrid(rows: gridRows, spacing: 12) {
                            ForEach(runner.peers) { peer in
                                PeerCard(peer: peer)
                                    .equatable()
                                    .frame(width: 188)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .transition(
                                        .asymmetric(
                                            insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .opacity
                                        )
                                    )
                            }
                        }
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                    }
                    .preventVerticalBounce()
                    .frame(height: 222)

                    // 2) Loading 仅作为覆盖层，不控制 Grid 的创建/销毁（避免“只有第一张动、后面闪现”）
                    if runner.isRunning && runner.peers.isEmpty {
                        VStack(spacing: 20) {
                            ProgressView().scaleEffect(1.2).controlSize(.large)
                            Text("节点加载中")
                                .font(.title3.bold())
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 222)
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 222)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity)
            // 只对「ID 列表」绑定动画：增/减/重排会动画，纯数值刷新不会每秒抖动
            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: peerIDs)
        }
    }
    
    // MARK: - Sparkline Component (Wrapper for External Implementation)
    struct Sparkline: View {
        let data: [Double]
        let color: Color
        let maxScale: Double
        let paused: Bool

        var body: some View {
            SmartSparklineView(data: data, color: color, maxScale: maxScale, paused: paused)
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
                    .offset(y: -113) // Restored to top position (133 - 113 = 20) to match original layout while centering button below it
            }
        }
        .frame(width: 84, height: 84)
        .padding(.vertical, 6)
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

// MARK: - Native Horizontal Scroller (Fixes SwiftUI vertical bounce bug on Mac)
// MARK: - Native Horizontal Scroller (The Nuclear Option)
struct NativeHorizontalScroller<Content: View>: NSViewRepresentable {
    let content: Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content() }
    
    class HorizontalOnlyScrollView: NSScrollView {
        override func scrollWheel(with event: NSEvent) {
            // Logic: Swallow vertical-dominant events to prevent bounce propagation.
            // Allow horizontal events to pass through naturally.
            
            if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
                // Dominantly vertical: Swallow the event.
                // Do NOT call super. This stops scrolling AND stops bounce propagation upwards.
            } else {
                // Dominantly horizontal (or zero/stationary): Pass it to the scroll view to handle.
                super.scrollWheel(with: event)
            }
        }
    }
    
    func makeNSView(context: Context) -> NSScrollView {
        let scroller = HorizontalOnlyScrollView() // Use our subclass
        scroller.hasHorizontalScroller = false
        scroller.hasVerticalScroller = false
        scroller.drawsBackground = false
        scroller.autohidesScrollers = true
        scroller.horizontalScrollElasticity = .allowed
        scroller.verticalScrollElasticity = .none // The Holy Grail
        
        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        scroller.documentView = hostingView
        
        if let doc = scroller.documentView {
            // 🚫 CRITICAL FIX: Only anchor Top and Left. 
            // Do NOT anchor Bottom. This allows content (218pt) to be smaller than View (222pt).
            // When content < viewport, macOS physically cannot rubber-band vertically.
            doc.topAnchor.constraint(equalTo: scroller.contentView.topAnchor).isActive = true
            doc.leadingAnchor.constraint(equalTo: scroller.contentView.leadingAnchor).isActive = true
            // We DO need to ensure the hosting view takes its own intrinsic size
        }
        return scroller
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let host = nsView.documentView as? NSHostingView<Content> {
            host.rootView = content
            
            // 确保同步更新尺寸以适应内容变化，这能让 SwiftUI 内部的 transition 更稳定
            let fittingSize = host.fittingSize
            if host.frame.size != fittingSize {
                host.frame.size = fittingSize
            }
        }
    }
}

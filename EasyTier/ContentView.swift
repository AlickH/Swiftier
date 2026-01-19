import SwiftUI
import Combine

struct ContentView: View {
    
    @StateObject private var runner = EasyTierRunner.shared
    @StateObject private var configManager = ConfigManager.shared
    @StateObject private var downloader = CoreDownloader.shared
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
            
            // Core Downloader / Missing Alert
            if !downloader.isInstalled || downloader.isDownloading {
                DownloadingView(downloader: downloader)
                    .zIndex(999)
                    .transition(.opacity)
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
                Button("打开内核文件夹") { NSWorkspace.shared.open(CoreDownloader.shared.installDirectory) }
                
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
                // 在 contentArea 的 ZStack 中
                if runner.isRunning {
                    RippleRings(isVisible: runner.isRunning, duration: 4.0, maxScale: 5.5)
                        .frame(width: 90, height: 90)
                        .position(x: geo.size.width / 2, y: buttonCenterY(in: geo.size.height))
                        .zIndex(-1)
                }

                // 2) 节点卡片容器
                if runner.isRunning {
                    if !runner.peers.isEmpty {
                        // 2a) 节点卡片容器
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
                                        .transition(.asymmetric(
                                            insertion: .move(edge: .bottom),
                                            removal: .opacity
                                        ))
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 12)
                        .padding(.top, 180)
                        .zIndex(1)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: runner.peers.map(\.id).joined().hashValue)
                    } else {
                        // 2b) 占位提示 (正在获取节点)
                        VStack(spacing: 20) {
                            ProgressView()
                                .controlSize(.regular)
                                .scaleEffect(1.2)
                            Text("节点加载中")
                                .font(.title3.bold())
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 180)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .offset(y: -20)
                        .zIndex(1)
                        .transition(.opacity)
                    }
                }

                // 3) 启动按钮
                Button {
                    if runner.isRunning {
                        // 正在运行，直接调用 toggleService (内部会处理 stop)
                        // 或者如果 toggleService 必须传 path，我们可以传个空字符串或 dummy，只要 runner 内部处理了 stop
                        // 让我们看看 runner.toggleService 的实现。通常 stop 不需要 path。
                        // 如果 runner.toggleService 强依赖 path，我们先尝试取 selectedConfig，取不到就取列表第一个
                        let path = selectedConfig?.path ?? configManager.configFiles.first?.path ?? ""
                        runner.toggleService(configPath: path)
                    } else {
                        // 没运行，必须要有配置才能启动
                        if let path = selectedConfig?.path {
                            runner.toggleService(configPath: path)
                        }
                    }
                } label: {
                    StartStopButtonCore(isRunning: runner.isRunning, uptimeText: runner.uptimeText)
                }
                .buttonStyle(.plain)
                .position(x: geo.size.width / 2, y: buttonCenterY(in: geo.size.height))
                .zIndex(10)
            }
            // Only apply isRunning animation to the container (for layout/button transitions)
            .animation(.spring(response: 1.0, dampingFraction: 0.8), value: runner.isRunning)
            .animation(.spring(response: 0.55, dampingFraction: 0.8), value: showLogView)
        }
    }

    private func buttonCenterY(in contentHeight: CGFloat) -> CGFloat {
        runner.isRunning ? 110 : (contentHeight / 2)
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
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
                    .frame(width: 120)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .offset(y: -70)
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

    @ViewBuilder
    var body: some View {
        // 关键优化：只在可见时才渲染 TimelineView，避免不必要的帧计算
        if isVisible {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = (t.truncatingRemainder(dividingBy: duration)) / duration

                ZStack {
                    ring(progress: phaseShifted(phase, by: 0.0))
                    ring(progress: phaseShifted(phase, by: 1.0 / 3.0))
                    ring(progress: phaseShifted(phase, by: 2.0 / 3.0))
                }
            }
            .transition(.opacity.animation(.easeInOut(duration: 0.5)))
        }
    }

    // phaseShifted 和 ring 保持完全不变
    private func phaseShifted(_ phase: Double, by shift: Double) -> Double {
        let p = phase - shift
        return p >= 0 ? p : (p + 1.0)
    }

    private func ring(progress: Double) -> some View {
        let scale = 0.2 + CGFloat(progress) * (maxScale - 0.2)
        let opacity = baseOpacity * (1.0 - progress)

        return Circle()
            .fill(Color.white)
            .scaleEffect(scale)
            .opacity(opacity)
    }
}

struct DownloadingView: View {
    @ObservedObject var downloader: CoreDownloader
    @State private var errorText: String?
    
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            
            VStack(spacing: 24) {
                Image(systemName: "cube.box.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)
                
                if downloader.isDownloading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text(downloader.statusMessage)
                            .font(.headline)
                        Text("请保持网络连接")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    VStack(spacing: 12) {
                        Text("缺少内核组件")
                            .font(.title2.bold())
                        Text("Swiftier 需要核心二进制文件才能运行。\n请选择下载方式从 GitHub 获取并安装。")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                        
                        if let err = errorText {
                            Text("错误: \(err)")
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                        
                        VStack(spacing: 10) {
                            Button("GitHub 加速安装 (推荐)") {
                                installCore(useProxy: true)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            
                            Button("GitHub 直连安装") {
                                installCore(useProxy: false)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                        }
                        
                        Button("退出 Swiftier") {
                            NSApplication.shared.terminate(nil)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                    }
                }
            }
            .padding(40)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor)))
            .shadow(radius: 20)
            .frame(width: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func installCore(useProxy: Bool) {
        Task {
            do {
                errorText = nil
                try await downloader.installCore(useProxy: useProxy)
                downloader.objectWillChange.send()
            } catch {
                errorText = error.localizedDescription
            }
        }
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

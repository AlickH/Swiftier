import SwiftUI
import AppKit
import Combine

@main
struct SwiftierControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var runner = SwiftierRunner.shared
    @StateObject private var iconState = MenuBarIconState.shared
    @AppStorage("breathEffect") private var breathEffect: Bool = true
    
    var body: some Scene {
        MenuBarExtra {
            ContentView()
        } label: {
            MenuBarLabelView(iconState: iconState)
        }
        .menuBarExtraStyle(.window)
    }
}

// 优化：将 Label 提取为独立 View 隔离刷新
struct MenuBarLabelView: View {
    @ObservedObject var iconState: MenuBarIconState
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconState.currentIcon)
        }
    }
}

// 菜单栏图标状态管理
class MenuBarIconState: ObservableObject {
    static let shared = MenuBarIconState()
    
    @Published var currentIcon: String = "point.3.connected.trianglepath.dotted"
    
    private let iconOutline = "point.3.connected.trianglepath.dotted"
    private let iconFilled = "point.3.filled.connected.trianglepath.dotted"
    private var isShowingFilled = true
    private var animationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        // 优化：监听运行状态变化，按需启停 Timer
        SwiftierRunner.shared.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRunning in
                self?.handleRunningStateChange(isRunning: isRunning)
            }
            .store(in: &cancellables)
        
        // 监听 breathEffect 设置变化
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateTimerState()
            }
            .store(in: &cancellables)
    }
    
    private func handleRunningStateChange(isRunning: Bool) {
        updateIcon(isRunning: isRunning)
        updateTimerState()
    }
    
    private func updateTimerState() {
        let isRunning = SwiftierRunner.shared.isRunning
        let blinkEnabled = (UserDefaults.standard.object(forKey: "breathEffect") as? Bool) ?? true
        
        if isRunning && blinkEnabled {
            startTimer()
        } else {
            stopTimer()
        }
    }
    
    private func startTimer() {
        // 优化：避免重复启动
        guard animationTimer == nil else { return }
        
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // 呼吸效果：切换实心/空心
            self.isShowingFilled.toggle()
            self.currentIcon = self.isShowingFilled ? self.iconFilled : self.iconOutline
        }
    }
    
    private func stopTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
    
    private func updateIcon(isRunning: Bool) {
        if isRunning {
            currentIcon = iconFilled
            isShowingFilled = true
        } else {
            currentIcon = iconOutline
            isShowingFilled = true
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables = Set<AnyCancellable>()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        // 自动连接
        checkAndAutoConnect()
    }
    
    // MARK: - Lifecycle
    
    func applicationWillTerminate(_ notification: Notification) {
        // 退出行为由 ContentView 的退出按钮处理
        // 这里只处理意外关闭的情况
    }
    
    // MARK: - Auto Connect
    
    private func checkAndAutoConnect() {
        // Default true, key match SettingsView
        let autoConnect = (UserDefaults.standard.object(forKey: "connectOnStart") as? Bool) ?? true
        guard autoConnect else { return }
        
        // 等待 VPNManager 完成 Profile 加载/创建后再自动连接
        // 使用 Combine 监听 isReady 状态，避免固定延时导致的竞态
        VPNManager.shared.$isReady
            .filter { $0 } // 等待 isReady == true
            .first()       // 只触发一次
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.performAutoConnect()
            }
            .store(in: &cancellables)
    }
    
    private func performAutoConnect() {
        let vpn = VPNManager.shared
        let status = vpn.status
        print("[AutoConnect] VPN status: \(status.rawValue), isConnected: \(vpn.isConnected)")
        
        if vpn.isConnected || status == .connected {
            print("[AutoConnect] VPN already connected, syncing state...")
            SwiftierRunner.shared.syncWithVPNState()
        } else if status == .connecting {
            print("[AutoConnect] VPN is connecting, waiting...")
            // 正在连接中，不需要重复操作，statusObserver 会处理
        } else {
            // 未运行，执行自动连接
            let configs = ConfigManager.shared.refreshConfigs()
            print("[AutoConnect] Found \(configs.count) config(s)")
            if let config = configs.first {
                print("[AutoConnect] Auto-connecting with config: \(config.lastPathComponent)")
                SwiftierRunner.shared.toggleService(configPath: config.path)
            } else {
                print("[AutoConnect] No config files found, skipping auto-connect")
            }
        }
    }
}

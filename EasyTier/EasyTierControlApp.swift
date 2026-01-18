import SwiftUI
import AppKit
import Combine

@main
struct EasyTierControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var runner = EasyTierRunner.shared
    @StateObject private var iconState = MenuBarIconState.shared
    @AppStorage("breathEffect") private var breathEffect: Bool = true
    
    var body: some Scene {
        // 使用 MenuBarExtra 获得原生液态玻璃窗口效果
        MenuBarExtra {
            ContentView()
        } label: {
            // 根据状态动态切换图标
            Image(systemName: iconState.currentIcon)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)
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
        // 监听运行状态变化
        EasyTierRunner.shared.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRunning in
                self?.updateIcon(isRunning: isRunning)
            }
            .store(in: &cancellables)
        
        // 启动定时器
        startTimer()
    }
    
    private func startTimer() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let isRunning = EasyTierRunner.shared.isRunning
            let blinkEnabled = (UserDefaults.standard.object(forKey: "breathEffect") as? Bool) ?? true
            
            if isRunning && blinkEnabled {
                // 呼吸效果：切换实心/空心
                self.isShowingFilled.toggle()
                self.currentIcon = self.isShowingFilled ? self.iconFilled : self.iconOutline
            }
        }
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
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let configs = ConfigManager.shared.refreshConfigs()
            if let config = configs.first {
                print("Auto-connecting with config: \(config.lastPathComponent)")
                EasyTierRunner.shared.toggleService(configPath: config.path)
            }
        }
    }
}

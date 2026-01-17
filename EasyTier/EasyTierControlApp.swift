import SwiftUI
import AppKit
import Combine

@main
struct EasyTierControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var runner = EasyTierRunner.shared
    @AppStorage("blinkIconOnConnect") private var blinkIconOnConnect: Bool = true
    
    var body: some Scene {
        // 使用 MenuBarExtra 获得原生液态玻璃窗口效果
        MenuBarExtra {
            ContentView()
        } label: {
            // 正常显示图标（AppDelegate 会负责给它加动画）
            Image(systemName: runner.isRunning ? "network" : "network.slash")
        }
        .menuBarExtraStyle(.window)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var animationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    // 缓存找到的 MenuBarExtra 的 button
    weak var menuBarButton: NSStatusBarButton?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        // 延迟一点，确保 MenuBarExtra 已经创建完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.findMenuBarExtraButton()
            self.startAnimationTimer()
        }
        
        // 监听 Runner 状态变化
        observeRunnerState()
        
        // 自动连接
        checkAndAutoConnect()
    }
    
    // MARK: - 找到 MenuBarExtra 的 Button
    
    func findMenuBarExtraButton() {
        // MenuBarExtra 会在某个窗口中创建 NSStatusBarButton
        // 我们遍历所有窗口来找到它
        for window in NSApp.windows {
            // NSStatusBarWindow 是私有类，但我们可以通过类名判断
            let className = String(describing: type(of: window))
            if className.contains("NSStatusBarWindow") {
                if let button = window.contentView as? NSStatusBarButton {
                    menuBarButton = button
                    button.wantsLayer = true
                    return
                }
            }
        }
        
        // 备选方案：遍历所有窗口的子视图
        for window in NSApp.windows {
            if let button = findButtonInView(window.contentView) {
                menuBarButton = button
                button.wantsLayer = true
                return
            }
        }
    }
    
    func findButtonInView(_ view: NSView?) -> NSStatusBarButton? {
        guard let view = view else { return nil }
        
        if let button = view as? NSStatusBarButton {
            return button
        }
        
        for subview in view.subviews {
            if let button = findButtonInView(subview) {
                return button
            }
        }
        
        return nil
    }
    
    // MARK: - Icon Animation
    
    func startAnimationTimer() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateAnimation()
        }
    }
    
    func updateAnimation() {
        // 如果还没找到 button，尝试再次查找
        if menuBarButton == nil {
            findMenuBarExtraButton()
        }
        
        guard let button = menuBarButton else { return }
        
        let isRunning = EasyTierRunner.shared.isRunning
        // Default true, key match SettingsView
        let blinkEnabled = (UserDefaults.standard.object(forKey: "breathEffect") as? Bool) ?? true
        
        button.wantsLayer = true
        
        if isRunning && blinkEnabled {
            // 添加呼吸动画
            if button.layer?.animation(forKey: "opacityBlink") == nil {
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 1.0
                animation.toValue = 0.3
                animation.duration = 1.5
                animation.autoreverses = true
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                button.layer?.add(animation, forKey: "opacityBlink")
            }
        } else {
            // 移除动画
            if button.layer?.animation(forKey: "opacityBlink") != nil {
                button.layer?.removeAnimation(forKey: "opacityBlink")
                button.layer?.opacity = 1.0
                button.alphaValue = 1.0
            }
        }
    }
    
    // MARK: - State Observation
    
    func observeRunnerState() {
        EasyTierRunner.shared.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateAnimation()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Lifecycle
    
    func applicationWillTerminate(_ notification: Notification) {
        animationTimer?.invalidate()
        
        if UserDefaults.standard.bool(forKey: "keepRunningOnExit") {
            return
        }
        
        let shouldQuitHelper = UserDefaults.standard.bool(forKey: "quitHelperOnExit")
        if shouldQuitHelper {
            if #available(macOS 13.0, *) {
                CoreService.shared.quitHelper { }
            }
        }
        CoreService.shared.stop()
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

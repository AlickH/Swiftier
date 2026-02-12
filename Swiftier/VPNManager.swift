import Foundation
import NetworkExtension
import Combine

class VPNManager: ObservableObject {
    static let shared = VPNManager()
    
    @Published var isConnected = false
    @Published var statusText = "未连接"
    @Published var status: NEVPNStatus = .disconnected
    @Published var isReady = false
    
    var isOnDemandEnabled: Bool {
        manager?.isOnDemandEnabled ?? false
    }
    
    /// NE 隧道的实际连接时间
    var connectedDate: Date? {
        manager?.connection.connectedDate
    }
    
    private var manager: NETunnelProviderManager?
    
    init() {
        loadPreferences()
        
        // 监听状态变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnStatusDidChange),
            name: .NEVPNStatusDidChange,
            object: nil
        )
    }
    
    func loadManager() {
        loadPreferences()
    }

    private func loadPreferences() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            
            if let error = error {
                print("Error loading VPN preferences: \(error)")
                return
            }
            
            if let existingManager = managers?.first {
                // 必须在主线程同步设置所有 @Published 属性，避免竞态
                DispatchQueue.main.async {
                    self.manager = existingManager
                    // 同步更新状态（不再二次派发）
                    self.updateStatusSync()
                    // 状态已就绪后再标记 isReady，确保后续逻辑能读到正确的 isConnected
                    self.isReady = true
                    
                    // 仅在 On Demand 设置不一致时才 save，避免 saveToPreferences 导致系统重启隧道
                    let connectOnStart = (UserDefaults.standard.object(forKey: "connectOnStart") as? Bool) ?? true
                    if existingManager.isOnDemandEnabled != connectOnStart {
                        self.applyOnDemandRules(to: existingManager)
                        existingManager.saveToPreferences { error in
                            if let error = error {
                                print("VPNManager: Error updating On Demand rules: \(error)")
                            }
                        }
                    }
                }
            } else {
                self.setupVPNProfile()
            }
        }
    }
    
    private func setupVPNProfile() {
        print("VPNManager: Starting setupVPNProfile...")
        
        let manager = NETunnelProviderManager()
        manager.localizedDescription = "Swiftier VPN"
        
        let protocolConfiguration = NETunnelProviderProtocol()
        let extensionBundleID = "com.alick.swiftier.SwiftierNE"
        protocolConfiguration.providerBundleIdentifier = extensionBundleID
        protocolConfiguration.serverAddress = "Swiftier"
        
        manager.protocolConfiguration = protocolConfiguration
        manager.isEnabled = true
        
        // Connect On Demand: 网络可用时系统自动启动 NE
        applyOnDemandRules(to: manager)
        
        manager.saveToPreferences { [weak self] error in
            if let error = error {
                print("VPNManager: Error saving VPN profile: \(error.localizedDescription)")
            } else {
                print("VPNManager: VPN Profile saved successfully.")
                // 二次保存确保持久化
                manager.saveToPreferences { error in
                    if let error = error {
                        print("VPNManager: Error on second save: \(error)")
                    } else {
                        print("VPNManager: Second save successful.")
                    }
                }
                self?.loadPreferences()
            }
        }
    }
    
    /// 配置 Connect On Demand 规则
    private func applyOnDemandRules(to manager: NETunnelProviderManager) {
        let connectOnStart = (UserDefaults.standard.object(forKey: "connectOnStart") as? Bool) ?? true
        
        if connectOnStart {
            // 任何网络可用时自动连接
            let wifiRule = NEOnDemandRuleConnect()
            wifiRule.interfaceTypeMatch = .wiFi
            
            let ethernetRule = NEOnDemandRuleConnect()
            ethernetRule.interfaceTypeMatch = .ethernet
            
            manager.onDemandRules = [wifiRule, ethernetRule]
            manager.isOnDemandEnabled = true
            print("VPNManager: Connect On Demand enabled")
        } else {
            manager.onDemandRules = []
            manager.isOnDemandEnabled = false
            print("VPNManager: Connect On Demand disabled")
        }
    }
    
    /// 外部调用：更新 On Demand 设置（设置页切换时调用）
    func updateOnDemand(enabled: Bool) {
        guard let manager = manager else { return }
        
        if enabled {
            let wifiRule = NEOnDemandRuleConnect()
            wifiRule.interfaceTypeMatch = .wiFi
            let ethernetRule = NEOnDemandRuleConnect()
            ethernetRule.interfaceTypeMatch = .ethernet
            manager.onDemandRules = [wifiRule, ethernetRule]
            manager.isOnDemandEnabled = true
        } else {
            manager.onDemandRules = []
            manager.isOnDemandEnabled = false
        }
        
        manager.saveToPreferences { error in
            if let error = error {
                print("VPNManager: Error updating On Demand: \(error)")
            } else {
                print("VPNManager: On Demand updated to \(enabled)")
            }
        }
    }
    
    func saveConfigToAppGroup(configContent: String) -> URL? {
        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.alick.swiftier") else {
            print("Failed to get App Group container")
            return nil
        }
        
        let configURL = groupURL.appendingPathComponent("config.toml")
        do {
            try configContent.write(to: configURL, atomically: true, encoding: .utf8)
            return configURL
        } catch {
            print("Failed to write config to App Group: \(error)")
            return nil
        }
    }

    func startVPN(configContent: String) {
        guard let manager = manager else {
            print("VPN Manager not ready")
            return
        }
        
        // 我们不直接通过 options 传递大文本，而是保存到 App Group
        guard let _ = saveConfigToAppGroup(configContent: configContent) else {
             self.statusText = "保存配置失败"
             return
        }
        
        let options: [String: NSObject] = [:] // Config is read from App Group file by NE
        
        do {
            try manager.connection.startVPNTunnel(options: options)
            print("VPN Start requested")
        } catch {
            print("Error starting VPN: \(error)")
            self.statusText = "启动失败: \(error.localizedDescription)"
        }
    }
    
    func stopVPN() {
        manager?.connection.stopVPNTunnel()
    }
    
    /// 手动关闭：先 stop 隧道，等断开后再禁用 On Demand，防止系统自动重连
    func disableOnDemandAndStop() {
        guard let manager = manager else { return }
        
        // 先 stop
        manager.connection.stopVPNTunnel()
        
        // 监听断开后立即禁用 On Demand
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, let mgr = self.manager else { return }
            if mgr.connection.status == .disconnected {
                if let obs = observer {
                    NotificationCenter.default.removeObserver(obs)
                }
                mgr.isOnDemandEnabled = false
                mgr.saveToPreferences { error in
                    if let error = error {
                        print("VPNManager: Error disabling On Demand after stop: \(error)")
                    } else {
                        print("VPNManager: On Demand disabled after manual stop")
                    }
                }
            }
        }
    }
    
    /// Send a message to the running NE provider and get a response
    func sendProviderMessage(_ message: String, completion: @escaping (Data?) -> Void) {
        guard let session = manager?.connection as? NETunnelProviderSession,
              let messageData = message.data(using: .utf8) else {
            completion(nil)
            return
        }
        
        do {
            try session.sendProviderMessage(messageData) { response in
                completion(response)
            }
        } catch {
            print("sendProviderMessage failed: \(error)")
            completion(nil)
        }
    }
    
    /// Request running info JSON from NE via IPC
    func requestRunningInfo(completion: @escaping (String?) -> Void) {
        sendProviderMessage("running_info") { data in
            if let data = data, let json = String(data: data, encoding: .utf8) {
                completion(json)
            } else {
                completion(nil)
            }
        }
    }
    
    @objc private func vpnStatusDidChange(_ notification: Notification) {
        DispatchQueue.main.async {
            self.updateStatusSync()
        }
    }
    
    /// 同步更新状态，必须在主线程调用
    private func updateStatusSync() {
        guard let connection = manager?.connection else { return }
        
        self.status = connection.status
        
        switch connection.status {
        case .connected:
            self.isConnected = true
            self.statusText = "已连接"
        case .connecting:
            self.isConnected = false
            self.statusText = "连接中..."
        case .disconnected:
            self.isConnected = false
            self.statusText = "未连接"
        case .disconnecting:
            self.isConnected = false
            self.statusText = "断开中..."
        case .invalid:
            self.isConnected = false
            self.statusText = "无效状态"
        case .reasserting:
            self.isConnected = false
            self.statusText = "重连中..."
        @unknown default:
            self.statusText = "未知状态"
        }
    }
}

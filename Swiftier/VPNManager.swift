import Foundation
import NetworkExtension
import Combine

class VPNManager: ObservableObject {
    static let shared = VPNManager()
    
    @Published var isConnected = false
    @Published var statusText = "未连接"
    @Published var status: NEVPNStatus = .disconnected
    @Published var isReady = false
    
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
                self.manager = existingManager
                self.updateStatus()
                self.isReady = true
            } else {
                self.setupVPNProfile()
            }
        }
    }
    
    private func setupVPNProfile() {
        print("VPNManager: Starting setupVPNProfile...")
        print("VPNManager: Current Bundle ID: \(Bundle.main.bundleIdentifier ?? "Unknown")")
        
        let manager = NETunnelProviderManager()
        manager.localizedDescription = "Swiftier VPN"
        
        let protocolConfiguration = NETunnelProviderProtocol()
        // 关键点：这个 ID 必须和 Extension 的 Bundle ID 完全一致
        let extensionBundleID = "com.alick.swiftier.SwiftierNE"
        protocolConfiguration.providerBundleIdentifier = extensionBundleID
        protocolConfiguration.serverAddress = "Swiftier"
        
        print("VPNManager: Setting providerBundleIdentifier to: \(extensionBundleID)")
        
        manager.protocolConfiguration = protocolConfiguration
        manager.isEnabled = true
        
        manager.saveToPreferences { [weak self] error in
            if let error = error {
                print("VPNManager: Critical Error saving VPN profile!")
                print("VPNManager: Error Domain: \((error as NSError).domain)")
                print("VPNManager: Error Code: \((error as NSError).code)")
                print("VPNManager: Description: \(error.localizedDescription)")
                print("VPNManager: UserInfo: \((error as NSError).userInfo)")
            } else {
                print("VPNManager: VPN Profile saved successfully.")
                self?.manager = manager
                self?.isReady = true
                
                // Save again for good measure (sometimes required to persist fully)
                manager.saveToPreferences { error in
                    if let error = error {
                         print("VPNManager: Error on second save: \(error)")
                    } else {
                         print("VPNManager: Second save successful.")
                    }
                }
                
                self?.loadPreferences() // Reload to be sure
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
        updateStatus()
    }
    
    private func updateStatus() {
        guard let connection = manager?.connection else { return }
        
        DispatchQueue.main.async {
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
}

import Foundation
import ServiceManagement

@available(macOS 13.0, *)
final class HelperManager {
    static let shared = HelperManager()
    
    private let service: SMAppService
    private var xpcConnection: NSXPCConnection?
    private let connectionLock = NSLock()
    
    private init() {
        self.service = SMAppService.daemon(plistName: "com.alick.swiftier.helper.plist")
    }
    
    deinit {
        invalidateConnection()
    }
    
    // MARK: - Logging
    
    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        print("\(timestamp) [HelperManager] \(message)")
    }
    
    // MARK: - Service Status
    
    var isHelperInstalled: Bool {
        return service.status == .enabled
    }
    
    var serviceStatus: String {
        switch service.status {
        case .notRegistered:
            return "未注册"
        case .enabled:
            return "已启用"
        case .requiresApproval:
            return "需要用户授权"
        case .notFound:
            return "未找到"
        @unknown default:
            return "未知状态"
        }
    }
    
    // MARK: - XPC Connection Management
    
    private func getConnection() -> NSXPCConnection {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        
        if let connection = xpcConnection {
            return connection
        }
        
        let connection = NSXPCConnection(machServiceName: kHelperMachServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        
        connection.invalidationHandler = { [weak self] in
            self?.log("XPC connection invalidated")
            self?.connectionLock.lock()
            self?.xpcConnection = nil
            self?.connectionLock.unlock()
        }
        
        connection.interruptionHandler = { [weak self] in
            self?.log("XPC connection interrupted")
        }
        
        connection.resume()
        xpcConnection = connection
        
        return connection
    }
    
    private func invalidateConnection() {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        
        xpcConnection?.invalidate()
        xpcConnection = nil
    }
    
    private func getHelper() -> HelperProtocol? {
        let connection = getConnection()
        return connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.log("XPC Error: \(error.localizedDescription)")
        } as? HelperProtocol
    }
    
    // MARK: - Public API
    
    /// 注册并启动 Helper daemon
    func installHelper(completion: @escaping (Bool, String?) -> Void) {
        log("Installing helper daemon...")
        log("Current status: \(serviceStatus)")
        
        Task {
            do {
                if service.status == .enabled {
                    log("Helper already installed and enabled")
                    await MainActor.run { completion(true, nil) }
                    return
                }
                
                try service.register()
                log("Helper registered successfully")
                
                // 等待一下让 launchd 启动 daemon
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                
                await MainActor.run { completion(true, nil) }
            } catch {
                log("Failed to install helper: \(error)")
                await MainActor.run { completion(false, error.localizedDescription) }
            }
        }
    }
    
    /// 卸载 Helper daemon
    func uninstallHelper(completion: @escaping (Bool, String?) -> Void) {
        log("Uninstalling helper daemon...")
        
        // 先断开 XPC 连接
        invalidateConnection()
        
        Task {
            do {
                try await service.unregister()
                log("Helper unregistered successfully")
                await MainActor.run { completion(true, nil) }
            } catch {
                log("Failed to uninstall helper: \(error)")
                await MainActor.run { completion(false, error.localizedDescription) }
            }
        }
    }
    
    /// 启动 easytier-core
    func startCore(configPath: String, rpcPort: String, consoleLevel: String, completion: @escaping (Bool, String?) -> Void) {
        log("Starting core via XPC... Level: \(consoleLevel)")
        
        // 确保 helper 已安装
        guard service.status == .enabled else {
            log("Helper not installed, installing first...")
            installHelper { [weak self] success, error in
                if success {
                    self?.startCore(configPath: configPath, rpcPort: rpcPort, consoleLevel: consoleLevel, completion: completion)
                } else {
                    completion(false, error ?? "Failed to install helper")
                }
            }
            return
        }
        
        // 获取 easytier-core 可执行文件路径
        guard let corePath = getCorePath() else {
            completion(false, "Cannot find easytier-core executable")
            return
        }
        
        guard let helper = getHelper() else {
            completion(false, "Cannot connect to helper")
            return
        }
        
        // 检查 Helper 版本，如果版本不匹配（协议更新），则强制重装
        helper.getVersion { currentVersion in
            if currentVersion != kTargetHelperVersion {
                self.log("Helper version mismatch (Current: \(currentVersion), Target: \(kTargetHelperVersion)). Performing auto-update...")
                
                self.uninstallHelper { success, error in
                    if !success {
                        self.log("Failed to uninstall old helper: \(error ?? "Unknown error")")
                    }
                    // 无论卸载成功与否，都尝试安装新版本
                    self.installHelper { success, error in
                        if success {
                            self.log("Helper auto-updated successfully. Retrying start...")
                            self.startCore(configPath: configPath, rpcPort: rpcPort, consoleLevel: consoleLevel, completion: completion)
                        } else {
                            completion(false, "Failed to update helper: \(error ?? "Unknown error")")
                        }
                    }
                }
                return
            }
            
            // 版本匹配，继续启动流程
            // 解决权限问题：Helper (root) 无法读取用户 Documents/Downloads 目录
            // 将配置文件复制到临时目录
            let tmpConfigPath = "/tmp/easytier_config.toml"
            do {
                if FileManager.default.fileExists(atPath: tmpConfigPath) {
                    try FileManager.default.removeItem(atPath: tmpConfigPath)
                }
                try FileManager.default.copyItem(atPath: configPath, toPath: tmpConfigPath)
                // 确保其可读
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tmpConfigPath)
            } catch {
                self.log("Failed to copy config to tmp: \(error)")
                // 尝试直接使用原路径（虽然可能会失败）
            }
            
            let targetConfigPath = FileManager.default.fileExists(atPath: tmpConfigPath) ? tmpConfigPath : configPath
            
            helper.startCore(configPath: targetConfigPath, rpcPort: rpcPort, corePath: corePath, consoleLevel: consoleLevel) { success, error in
                DispatchQueue.main.async {
                    completion(success, error)
                }
            }
        }
    }
    
    /// 停止 easytier-core
    func stopCore(completion: @escaping (Bool) -> Void) {
        log("Stopping core via XPC...")
        
        guard let helper = getHelper() else {
            log("Cannot connect to helper")
            completion(false)
            return
        }
        
        helper.stopCore { success in
            DispatchQueue.main.async {
                completion(success)
            }
        }
    }
    
    /// 获取 core 运行状态
    func getCoreStatus(completion: @escaping (Int32) -> Void) {
        guard let helper = getHelper() else {
            completion(0)
            return
        }
        
        helper.getCoreStatus { pid in
            DispatchQueue.main.async {
                completion(pid)
            }
        }
    }
    
    /// 获取 Core 启动时间戳
    func getCoreStartTime(completion: @escaping (Double) -> Void) {
        guard let helper = getHelper() else {
            completion(0)
            return
        }
        
        helper.getCoreStartTime { timestamp in
            DispatchQueue.main.async {
                completion(timestamp)
            }
        }
    }
    
    /// 获取 Helper 版本
    func getHelperVersion(completion: @escaping (String?) -> Void) {
        guard let helper = getHelper() else {
            completion(nil)
            return
        }
        
        helper.getVersion { version in
            DispatchQueue.main.async {
                completion(version)
            }
        }
    }
    
    // 新增：请求 Helper 退出
    func quitHelper(completion: @escaping () -> Void) {
        guard let helper = getHelper() else {
            completion()
            return
        }
        
        helper.quitHelper { _ in
            completion()
        }
    }
    
    // MARK: - Private Helpers
    
    private func getCorePath() -> String? {
        // 1. Check Application Support (Auto-download location)
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
             let customPath = appSupport.appendingPathComponent("Swiftier/bin/easytier-core").path
             if FileManager.default.fileExists(atPath: customPath) {
                 return customPath
             }
        }
        
        // 2. Fallback to Bundle
        if let path = Bundle.main.path(forResource: "easytier-core", ofType: nil) {
            return path
        }
        
        // 3. Fallback: Check adjacent to executable
        if let execURL = Bundle.main.executableURL {
            let corePath = execURL.deletingLastPathComponent().appendingPathComponent("easytier-core").path
            if FileManager.default.fileExists(atPath: corePath) {
                return corePath
            }
        }
        
        return nil
    }
}

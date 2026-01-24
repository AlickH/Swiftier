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
        
        // --- 双向通信配置 ---
        // 导出接口给 Helper 调用（用于推送数据）
        connection.exportedInterface = NSXPCInterface(with: HelperClientListener.self)
        connection.exportedObject = ClientListener(manager: self)
        
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
    
    private func getHelper(errorHandler: ((Error) -> Void)? = nil) -> HelperProtocol? {
        let connection = getConnection()
        return connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.log("XPC Error: \(error.localizedDescription)")
            errorHandler?(error)
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
    func startCore(configPath: String, consoleLevel: String, completion: @escaping (Bool, String?) -> Void) {
        log("Starting core via XPC... Level: \(consoleLevel)")
        log("Current SMAppService status: \(service.status.rawValue) (\(serviceStatus))")
        
        // 确保 helper 已安装
        guard service.status == .enabled else {
            log("Helper not installed (status=\(service.status.rawValue)), installing first...")
            installHelper { [weak self] success, error in
                if success {
                    self?.log("Helper installation succeeded, retrying startCore...")
                    self?.startCore(configPath: configPath, consoleLevel: consoleLevel, completion: completion)
                } else {
                    self?.log("Helper installation failed: \(error ?? "unknown")")
                    completion(false, error ?? "Failed to install helper")
                }
            }
            return
        }
        
        log("Helper is enabled, proceeding with XPC call...")
        let corePath = "" // Embedded core, path not needed
        
        // 定义 XPC 错误处理器 - 当连接失败时强制重装 Helper
        let xpcErrorHandler: (Error) -> Void = { [weak self] error in
            guard let self = self else { return }
            self.log("XPC communication failed: \(error.localizedDescription)")
            self.log("SMAppService reports enabled but XPC failed. Forcing reinstall...")
            self.invalidateConnection()
            
            // 强制重装：先注销再注册
            self.uninstallHelper { [weak self] _, _ in
                guard let self = self else { return }
                self.log("Uninstall completed. Now reinstalling...")
                
                self.installHelper { [weak self] success, installError in
                    guard let self = self else { return }
                    if success {
                        self.log("Reinstall succeeded. Retrying startCore...")
                        // 递归调用 startCore，这次应该能连上了
                        self.startCore(configPath: configPath, consoleLevel: consoleLevel, completion: completion)
                    } else {
                        self.log("Reinstall failed: \(installError ?? "unknown")")
                        completion(false, "XPC Error and reinstall failed: \(installError ?? error.localizedDescription)")
                    }
                }
            }
        }

        guard let helper = getHelper(errorHandler: xpcErrorHandler) else {
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
                            // 递归调用（注意：这可能会导致死循环如果安装一直成功但连接一直失败，建议增加深度控制，暂且认为安装成功就能连上）
                            self.startCore(configPath: configPath, consoleLevel: consoleLevel, completion: completion)
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
            
            helper.startCore(configPath: targetConfigPath, corePath: corePath, consoleLevel: consoleLevel) { success, error in
                DispatchQueue.main.async {
                    completion(success, error)
                }
            }
        }
    }
    
    /// 停止 easytier-core
    func stopCore(completion: @escaping (Bool) -> Void) {
        log("Stopping core via XPC...")
        
        // 定义 XPC 错误处理器，确保即使 XPC 失败也调用 completion
        var completionCalled = false
        let xpcErrorHandler: (Error) -> Void = { [weak self] error in
            self?.log("stopCore XPC failed: \(error.localizedDescription)")
            self?.invalidateConnection()
            if !completionCalled {
                completionCalled = true
                DispatchQueue.main.async { completion(false) }
            }
        }
        
        guard let helper = getHelper(errorHandler: xpcErrorHandler) else {
            log("Cannot connect to helper for stopCore")
            completion(false)
            return
        }
        
        helper.stopCore { success in
            if !completionCalled {
                completionCalled = true
                DispatchQueue.main.async {
                    completion(success)
                }
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
    
    /// 获取最近的 JSON 事件（用于实时事件流）
    /// - Parameters:
    ///   - sinceIndex: 从哪个索引开始获取
    ///   - completion: 回调，返回 (JSON 事件数组, 下一个索引)
    func getRecentEvents(sinceIndex: Int, completion: @escaping ([ProcessedEvent], Int) -> Void) {
        guard let helper = getHelper() else {
            completion([], sinceIndex)
            return
        }
        
        helper.getRecentEvents(sinceIndex: sinceIndex) { data, nextIndex in
            Task {
                // Decode on background thread implicitly or MainActor later?
                // Helper sends Data. We decode.
                let events = (try? JSONDecoder().decode([ProcessedEvent].self, from: data)) ?? []
                await MainActor.run {
                    completion(events, nextIndex)
                }
            }
        }
    }
    
    /// 获取运行时信息（包含 peers、routes 等）
    /// - Parameter completion: 回调，返回 JSON 字符串（nil 表示未运行或出错）
    func getRunningInfo(completion: @escaping (String?) -> Void) {
        guard let helper = getHelper() else {
            completion(nil)
            return
        }
        
        helper.getRunningInfo { info in
            DispatchQueue.main.async {
                completion(info)
            }
        }
    }
    
    // MARK: - Client Listener Implementation
    
    // 内部类，用于处理 XPC 回调
    private class ClientListener: NSObject, HelperClientListener {
        weak var manager: HelperManager?
        
        init(manager: HelperManager) {
            self.manager = manager
        }
        
        func runningInfoUpdated(_ info: String) {
            manager?.handleRunningInfoUpdate(info)
        }
        
        func logUpdated(_ lines: [String]) {
            // Placeholder: log updates
        }
    }
    
    private var pushHandler: ((String) -> Void)?
    
    /// 设置数据推送回调
    func setPushHandler(_ handler: @escaping (String) -> Void) {
        self.pushHandler = handler
    }
    
    private func handleRunningInfoUpdate(_ info: String) {
        DispatchQueue.main.async {
            self.pushHandler?(info)
        }
    }

    // 以前用于握手的逻辑现在已经不需要了
    private func ensureBidirectionalSetup() {
        // Standard XPC handles this on resume via exportedInterface
    }
}

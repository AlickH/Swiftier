import Foundation
import ServiceManagement
import AppKit

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
        
        // 关键修复：恢复 .privileged 选项。
        // 对于通过 SMAppService.daemon 注册的系统级守护进程，必须使用 .privileged 选项，
        // 否则由于权限不足，主程序无法与特权 Helper 通信。
        let connection = NSXPCConnection(machServiceName: kHelperMachServiceName, options: .privileged)
        
        // --- 双向通信配置 ---
        connection.exportedInterface = NSXPCInterface(with: HelperClientListener.self)
        connection.exportedObject = ClientListener(manager: self)
        
        // 设置远程对象接口（Helper 侧实现的协议）
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
    
    private func getHelper(errorHandler: ((Error) -> Void)? = nil) -> HelperProtocol? {
        let connection = getConnection()
        return connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.log("XPC Error: \(error.localizedDescription)")
            errorHandler?(error)
        } as? HelperProtocol
    }
    
    // MARK: - Public API
    
    /// 注册并启动 Helper daemon
    func installHelper(force: Bool = false, completion: @escaping (Bool, String?) -> Void) {
        log("Installing helper (force: \(force), current: \(serviceStatus))...")
        log("App Path: \(Bundle.main.bundlePath)")
        
        Task {
            // 1. Translocation Check
            if Bundle.main.bundlePath.contains("/private/var/folders") {
                await MainActor.run {
                    completion(false, "App 正在随机只读路径运行，请先将 Swiftier 移动到“应用程序”文件夹后再试。")
                }
                return
            }

            do {
                // 2. Unregister if forced
                if force {
                    log("Forcing unregister...")
                    try? await service.unregister()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                } else if service.status == .enabled {
                    await MainActor.run { completion(true, nil) }
                    return
                }
                
                // 3. Register
                log("Calling SMAppService.register()...")
                try service.register()
                
                // 4. Post-Registration Check
                // 刷新状态以获得最准确的结果
                if service.status == .requiresApproval {
                    log("Status is requiresApproval. Opening settings.")
                    // 使用更精确的设置路径引导
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    } else {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    
                    await MainActor.run {
                        completion(false, "需要手动授权：请在“系统设置 -> 通用 -> 登录项”列表中，将 SwiftierHelper 的开关打开，然后重新启动服务。")
                    }
                    return
                }

                // Wait for daemon launch
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run { completion(true, nil) }
                
            } catch {
                log("SMAppService error: \(error)")
                let nsError = error as NSError
                if nsError.domain == "SMAppServiceErrorDomain" && nsError.code == 1 {
                    await MainActor.run {
                        completion(false, "系统拒绝注册 (Operation not permitted)。\n\n原因：通常是签名冲突或系统缓存错误。\n解决：请在终端执行 `sudo sfltool resetbtm` 后重启电脑重试。")
                    }
                } else {
                    await MainActor.run { completion(false, error.localizedDescription) }
                }
            }
        }
    }
    
    func uninstallHelper(completion: @escaping (Bool, String?) -> Void) {
        log("Uninstalling helper...")
        invalidateConnection()
        Task {
            do {
                try await service.unregister()
                await MainActor.run { completion(true, nil) }
            } catch {
                await MainActor.run { completion(false, error.localizedDescription) }
            }
        }
    }
    
    func startCore(configPath: String, consoleLevel: String, completion: @escaping (Bool, String?) -> Void) {
        if service.status != .enabled {
            log("Helper not enabled (\(serviceStatus)), attempting install...")
            installHelper(force: false) { [weak self] success, error in
                if success {
                    self?.startCore(configPath: configPath, consoleLevel: consoleLevel, completion: completion)
                } else {
                    completion(false, error)
                }
            }
            return
        }
        
        var completionCalled = false
        
        // 超时保护
        let timeoutWork = DispatchWorkItem {
            if !completionCalled {
                self.log("startCore timed out. XPC might be hanging.")
                completionCalled = true
                self.invalidateConnection()
                DispatchQueue.main.async { completion(false, "Helper 响应超时，请尝试重启 App。") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: timeoutWork)

        let xpcErrorHandler: (Error) -> Void = { [weak self] error in
            guard let self = self else { return }
            self.log("XPC call failed: \(error.localizedDescription)")
            self.invalidateConnection()
            
            if !completionCalled {
                timeoutWork.cancel()
                completionCalled = true
                if self.service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                    completion(false, "Helper 已被系统拦截，请在“登录项”设置中允许其运行。")
                } else {
                    completion(false, "Helper 通信异常: \(error.localizedDescription)")
                }
            }
        }

        guard let helper = getHelper(errorHandler: xpcErrorHandler) else {
            timeoutWork.cancel()
            completion(false, "无法建立 XPC 连接")
            return
        }
        
        helper.getVersion { [weak self] version in
            guard let self = self else { return }
            if !completionCalled {
                if version != kTargetHelperVersion {
                    timeoutWork.cancel()
                    completionCalled = true
                    self.log("Version mismatch (\(version) vs \(kTargetHelperVersion)). Updating...")
                    self.installHelper(force: true) { success, error in
                        if success {
                            self.startCore(configPath: configPath, consoleLevel: consoleLevel, completion: completion)
                        } else {
                            completion(false, "Helper 更新失败: \(error ?? "")")
                        }
                    }
                    return
                }
                
                // Sync config to /tmp for root access
                let tmpPath = "/tmp/easytier_config.toml"
                try? FileManager.default.removeItem(atPath: tmpPath)
                try? FileManager.default.copyItem(atPath: configPath, toPath: tmpPath)
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tmpPath)
                
                helper.startCore(configPath: tmpPath, corePath: "", consoleLevel: consoleLevel) { success, error in
                    if !completionCalled {
                        timeoutWork.cancel()
                        completionCalled = true
                        DispatchQueue.main.async { completion(success, error) }
                    }
                }
            }
        }
    }
    
    func stopCore(completion: @escaping (Bool) -> Void) {
        log("Stopping core via XPC...")
        var completionCalled = false
        
        let timeoutWork = DispatchWorkItem {
            if !completionCalled {
                self.log("stopCore timed out. Forcing completion.")
                completionCalled = true
                DispatchQueue.main.async { completion(false) }
                self.invalidateConnection()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: timeoutWork)

        let errorHandler: (Error) -> Void = { [weak self] error in
            self?.log("stopCore XPC failed: \(error.localizedDescription)")
            self?.invalidateConnection()
            if !completionCalled {
                timeoutWork.cancel()
                completionCalled = true
                DispatchQueue.main.async { completion(false) }
            }
        }
        
        guard let helper = getHelper(errorHandler: errorHandler) else {
            timeoutWork.cancel()
            completion(false)
            return
        }
        
        helper.stopCore { success in
            if !completionCalled {
                timeoutWork.cancel()
                completionCalled = true
                DispatchQueue.main.async { completion(success) }
            }
        }
    }
    
    func getCoreStatus(completion: @escaping (Int32) -> Void) {
        guard let helper = getHelper(errorHandler: { _ in completion(0) }) else {
            completion(0)
            return
        }
        helper.getCoreStatus { pid in
            DispatchQueue.main.async { completion(pid) }
        }
    }
    
    func getCoreStartTime(completion: @escaping (Double) -> Void) {
        guard let helper = getHelper(errorHandler: { _ in completion(0) }) else {
            completion(0)
            return
        }
        helper.getCoreStartTime { ts in
            DispatchQueue.main.async { completion(ts) }
        }
    }

    func quitHelper(completion: @escaping () -> Void) {
        getHelper()?.quitHelper { _ in completion() }
    }
    
    func getRecentEvents(sinceIndex: Int, completion: @escaping ([ProcessedEvent], Int) -> Void) {
        let errorHandler: (Error) -> Void = { _ in completion([], sinceIndex) }
        guard let helper = getHelper(errorHandler: errorHandler) else {
            completion([], sinceIndex)
            return
        }
        helper.getRecentEvents(sinceIndex: sinceIndex) { data, next in
            let events = (try? JSONDecoder().decode([ProcessedEvent].self, from: data)) ?? []
            DispatchQueue.main.async { completion(events, next) }
        }
    }
    
    func getRunningInfo(reply: @escaping (String?) -> Void) {
        let errorHandler: (Error) -> Void = { _ in reply(nil) }
        guard let helper = getHelper(errorHandler: errorHandler) else {
            reply(nil)
            return
        }
        helper.getRunningInfo { info in
            DispatchQueue.main.async { reply(info) }
        }
    }
    
    // MARK: - Internal
    
    private class ClientListener: NSObject, HelperClientListener {
        weak var manager: HelperManager?
        init(manager: HelperManager) { self.manager = manager }
        func runningInfoUpdated(_ info: String) { manager?.handleRunningInfoUpdate(info) }
        func logUpdated(_ lines: [String]) {}
    }
    
    private var pushHandler: ((String) -> Void)?
    func setPushHandler(_ handler: @escaping (String) -> Void) { self.pushHandler = handler }
    private func handleRunningInfoUpdate(_ info: String) {
        DispatchQueue.main.async { self.pushHandler?(info) }
    }
}

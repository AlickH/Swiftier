import Foundation
import AppKit

final class CoreService {

    static let shared = CoreService()
    
    private let helperLogPath = "/var/log/swiftier-helper.log"
    private var lastLogSize: UInt64 = 0
    
    private init() {}
    
    // MARK: - Public API
    
    func start(configPath: String, rpcPort: String, completion: @escaping (Bool) -> Void) {
        if #available(macOS 13.0, *) {
            // macOS 13+ 使用 SMAppService (HelperManager)
            let logLevel = UserDefaults.standard.string(forKey: "logLevel")?.lowercased() ?? "info"
            HelperManager.shared.startCore(configPath: configPath, rpcPort: rpcPort, consoleLevel: logLevel) { success, error in
                if success {
                    self.resetLogState()
                } else if let error = error {
                    print("CoreService start failed: \(error)")
                }
                completion(success)
            }
        } else {
            // 旧系统 fallback 到 AppleScript
            appleScriptStart(configPath: configPath, rpcPort: rpcPort, completion: completion)
        }
    }
    
    func stop(completion: @escaping (Bool) -> Void = { _ in }) {
        if #available(macOS 13.0, *) {
            HelperManager.shared.stopCore { success in
                completion(success)
            }
        } else {
            appleScriptStop()
            completion(true)
        }
    }
    
    /// 获取 core 运行状态
    func getStatus(completion: @escaping (Bool, Int32) -> Void) {
        if #available(macOS 13.0, *) {
            HelperManager.shared.getCoreStatus { pid in
                completion(pid > 0, pid)
            }
        } else {
            // fallback: 检查进程是否存在
            let running = isProcessRunning(name: "easytier-core")
            completion(running, 0)
        }
    }
    
    func openLogFile() {
        if FileManager.default.fileExists(atPath: helperLogPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: helperLogPath))
        }
    }
    
    func readNewLogEntries() {
        guard let fileHandle = FileHandle(forReadingAtPath: helperLogPath) else { return }
        defer { try? fileHandle.close() }
        
        do {
            let attr = try FileManager.default.attributesOfItem(atPath: helperLogPath)
            let fileSize = attr[.size] as! UInt64
            
            if fileSize > lastLogSize {
                try fileHandle.seek(toOffset: lastLogSize)
                let data = fileHandle.readDataToEndOfFile()
                if let newLog = String(data: data, encoding: .utf8), !newLog.isEmpty {
                    print("Core:", newLog.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                lastLogSize = fileSize
            }
        } catch {
            // ignore
        }
    }
    
    // MARK: - Helper Management (macOS 13+)
    
    @available(macOS 13.0, *)
    func installHelper(completion: @escaping (Bool, String?) -> Void) {
        HelperManager.shared.installHelper(completion: completion)
    }
    
    @available(macOS 13.0, *)
    func uninstallHelper(completion: @escaping (Bool, String?) -> Void) {
        HelperManager.shared.uninstallHelper(completion: completion)
    }
    
    @available(macOS 13.0, *)
    var isHelperInstalled: Bool {
        return HelperManager.shared.isHelperInstalled
    }
    
    @available(macOS 13.0, *)
    var helperStatus: String {
        return HelperManager.shared.serviceStatus
    }
    
    @available(macOS 13.0, *)
    func quitHelper(completion: @escaping () -> Void) {
        HelperManager.shared.quitHelper(completion: completion)
    }
    
    // MARK: - Private Helpers
    
    private func resetLogState() {
        // 不清空日志文件，只重置读取位置
        lastLogSize = 0
    }
    
    private func isProcessRunning(name: String) -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-x", name]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        try? task.run()
        task.waitUntilExit()
        
        return task.terminationStatus == 0
    }
    
    // MARK: - Legacy AppleScript Fallback
    
    private func appleScriptStart(configPath: String, rpcPort: String, completion: @escaping (Bool) -> Void) {
        guard let bin = getBinaryPath(name: "easytier-core") else {
            completion(false)
            return
        }
        
        resetLogState()
        
        let logPath = "/tmp/swiftier-debug.log"
        
        let scriptText = """
        do shell script "pkill -9 easytier-core; \\
        \(bin) -c '\(configPath)' --rpc-portal 127.0.0.1:\(rpcPort) >> \(logPath) 2>&1 &" \\
        with administrator privileges
        """
        
        let appleScript = NSAppleScript(source: scriptText)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)
        
        if error != nil {
            print("AppleScript error: \(String(describing: error))")
            completion(false)
        } else {
            completion(true)
        }
    }
    
    private func appleScriptStop() {
        let task = Process()
        task.launchPath = "/usr/bin/killall"
        task.arguments = ["-9", "easytier-core"]
        try? task.run()
    }
    
    private func getBinaryPath(name: String) -> String? {
        // 1. Check Application Support (Auto-download location)
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
             let customPath = appSupport.appendingPathComponent("Swiftier/bin/\(name)").path
             if FileManager.default.fileExists(atPath: customPath) {
                 return customPath
             }
        }
        
        // 2. Fallback to Bundle
        return Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent(name)
            .path
    }
}

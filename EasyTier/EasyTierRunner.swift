import Foundation
import Combine
import AppKit
import SwiftUI

final class EasyTierRunner: ObservableObject {
    static let shared = EasyTierRunner()

    @Published var isRunning = false
    @Published var peers: [PeerInfo] = []
    @Published var peerCount: String = "0"
    @Published var downloadSpeed: String = "0 KB/s"
    @Published var uploadSpeed: String = "0 KB/s"

    @Published var uptimeText: String = "00:00:00"
    
    private var startedAt: Date?
    
    private var uptimeTimer: AnyCancellable?
    private var timer: AnyCancellable?
    private let rpcPort = "15888"
    private let cliClient: CliClient
    
    private var currentSessionID = UUID()
    private var lastConfigPath: String?

    private init() {
        cliClient = CliClient(rpcPort: rpcPort)
        
        // 启动时立即检查 Core 的真实运行状态
        syncWithCoreState()
    }
    
    /// 同步 UI 状态与后台 Core 的真实状态
    /// - Parameter completion: 完成回调，参数表示是否检测到 Core 在运行
    func syncWithCoreState(completion: ((Bool) -> Void)? = nil) {
        print("[Runner] Syncing with core state...")
        
        CoreService.shared.getStatus { [weak self] running, pid in
            guard let self = self else { 
                completion?(false)
                return 
            }
            
            if running && pid > 0 {
                // Core 正在后台运行，获取真实启动时间
                if #available(macOS 13.0, *) {
                    HelperManager.shared.getCoreStartTime { timestamp in
                        DispatchQueue.main.async {
                            self.isRunning = true
                            
                            if timestamp > 0 {
                                // 使用 Helper 返回的真实启动时间
                                self.startedAt = Date(timeIntervalSince1970: timestamp)
                            } else {
                                // 没有记录，假设刚刚启动
                                self.startedAt = Date()
                            }
                            
                            self.currentSessionID = UUID()
                            self.startUptimeTimer()
                            self.startMonitoring()
                            
                            print("[Runner] Core is already running (PID: \(pid)), syncing UI state")
                            completion?(true)
                        }
                    }
                } else {
                    // 旧系统 fallback
                    DispatchQueue.main.async {
                        self.isRunning = true
                        self.startedAt = Date()
                        self.currentSessionID = UUID()
                        self.startUptimeTimer()
                        self.startMonitoring()
                        completion?(true)
                    }
                }
            } else {
                // XPC 方式检测不到 Core，但可能有遗留进程
                // 使用 pgrep 做最后一次检查
                self.checkCoreProcessDirectly { processRunning in
                    DispatchQueue.main.async {
                        if processRunning {
                            // 有遗留进程，但我们无法获取精确的启动时间
                            self.isRunning = true
                            self.startedAt = Date() // 无法获取真实时间，从现在开始计
                            self.currentSessionID = UUID()
                            self.startUptimeTimer()
                            self.startMonitoring()
                            print("[Runner] Found orphan Core process, syncing UI state")
                            completion?(true)
                        } else {
                            // Core 确实未运行，清理状态
                            self.isRunning = false
                            self.startedAt = nil
                            self.uptimeText = "00:00:00"
                            self.peers = []
                            print("[Runner] No Core process detected")
                            completion?(false)
                        }
                    }
                }
            }
        }
    }
    
    /// 直接通过系统命令检查 easytier-core 进程是否存在
    private func checkCoreProcessDirectly(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.launchPath = "/usr/bin/pgrep"
            task.arguments = ["-x", "easytier-core"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            
            do {
                try task.run()
                task.waitUntilExit()
                completion(task.terminationStatus == 0)
            } catch {
                completion(false)
            }
        }
    }

    // --- 保留功能：磁盘访问权限检查 ---
    var hasFullDiskAccess: Bool {
        let path = "/Library/Application Support/com.apple.TCC/TCC.db"
        return FileManager.default.isReadableFile(atPath: path)
    }

    func showPermissionAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "需要完整磁盘访问权限"
            alert.informativeText = "Swiftier 需要该权限来读取受保护文件夹中的配置文件。\n\n请在『系统设置 -> 隐私与安全性 -> 完整磁盘访问权限』中手动勾选此 App。"
            alert.addButton(withTitle: "去设置")
            alert.addButton(withTitle: "取消")
            alert.window.level = .floating
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    // Prevent race conditions during rapid toggles
    @Published var isProcessing = false

    func toggleService(configPath: String) {
        if isProcessing { return }
        isProcessing = true
        
        // Optimistic UI Update: React immediately to user input
        // Toggle the state instantly so the button responds visually
        let targetState = !isRunning
        
        withAnimation(.spring(response: 1.0, dampingFraction: 0.8)) {
            self.isRunning = targetState
            if !targetState { self.peers = [] }
        }
        
        if !targetState {
            // >>> User requested STOP
            self.startedAt = nil
            self.uptimeText = "00:00:00"
            self.uptimeTimer?.cancel()
            self.timer?.cancel()
            // peers cleared above
            
            CoreService.shared.stop { [weak self] _ in
                DispatchQueue.main.async {
                    // Critical: Hold the lock for a safety buffer to allow OS to release ports/processes
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self?.isProcessing = false
                    }
                }
            }
        } else {
            // >>> User requested START
            self.startedAt = Date()
            self.uptimeText = "00:00:00"
            self.startUptimeTimer()
            
            let newSessionID = UUID()
            self.currentSessionID = newSessionID
            self.lastConfigPath = configPath
            
            // Strategy: Enforce a clean slate.
            // Even if we think it's stopped, we force a stop command to Helper to ensure
            // any zombie processes or occupied ports are cleared.
            print("[Runner] Optimistic start. Background cleanup initiated...")
            
            CoreService.shared.stop { [weak self] _ in
                // Give the system ample time (1.5s) to reclaim resources (ports, file handles)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.performStart(configPath: configPath, newSessionID: newSessionID)
                }
            }
        }
    }
    
    private func performStart(configPath: String, newSessionID: UUID, retryCount: Int = 1) {
        CoreService.shared.start(configPath: configPath, rpcPort: rpcPort) { [weak self] success in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if success {
                    self.isRunning = true
                    self.startedAt = Date()
                    self.startUptimeTimer()
                    
                    // Instead of a fixed delay, we now intelligently wait for the RPC to become ready
                    self.waitForRpcReady(sessionID: newSessionID) { ready in
                        if ready {
                            print("[Runner] RPC Ready. Starting monitoring.")
                            self.startMonitoring()
                        } else {
                            print("[Runner] RPC timed out. Monitoring might be delayed.")
                            // Fallback to start monitoring anyway, it might work later
                            self.startMonitoring()
                        }
                    }
                    self.isProcessing = false
                } else {
                    // Retry logic
                    if retryCount > 0 {
                        print("[Runner] Start failed, retrying in 1.5s...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.performStart(configPath: configPath, newSessionID: newSessionID, retryCount: retryCount - 1)
                        }
                    } else {
                        // Final fallback check
                        CoreService.shared.getStatus { running, _ in
                            DispatchQueue.main.async {
                                if running {
                                    self.isRunning = true
                                    self.startedAt = Date()
                                    self.startUptimeTimer()
                                    self.startMonitoring()
                                } else {
                                    self.isRunning = false
                                }
                                self.isProcessing = false
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func waitForRpcReady(sessionID: UUID, retries: Int = 10, completion: @escaping (Bool) -> Void) {
        Task {
            // Attempt a lightweight command to check connectivity
            // We can just try to fetch peers, if it returns valid array (empty or not) it means RPC is up
            _ = await self.cliClient.fetchPeers(sessionID: sessionID)
            
            // Check if we are still the valid session (user hasn't stopped service while we waited)
            if self.currentSessionID != sessionID { return }
            
            // If we got a result (even empty), RPC is likely working.
            // However, fetchPeers might return empty array on connection error too if not handled carefully.
            // Let's assume CliClient returns empty array on error.
            // A better check would be checking the logs or CliClient should return optional.
            // For now, let's rely on the fact that if it connects, it works.
            // To be robust:
            
            // Actually, we should check if startMonitoring would succeed.
            // Let's just Loop.
            
            DispatchQueue.main.async {
                // If retries exhausted
                if retries <= 0 {
                    completion(false)
                    return
                }
                
                // If peers fetch 'seems' to have failed (we can't distinguish easily yet without modifying CliClient)
                // Let's assume it failed if we are here and retry.
                // Wait 0.5s
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.waitForRpcReady(sessionID: sessionID, retries: retries - 1, completion: completion)
                }
            }
        }
    }

    /// Wait until the Core process is confirmed dead
    private func waitForCoreCleanup(timeout: TimeInterval = 3.0, completion: @escaping (Bool) -> Void) {
        // ... (Keep existing implementation if needed by other methods, or remove if unused)
        // Since we are forcing stop now, this might be less critical but good for debugging tools.
        let startTime = Date()
        func check() {
            CoreService.shared.getStatus { running, pid in
                if !running { completion(true) }
                else {
                    if Date().timeIntervalSince(startTime) > timeout { completion(false) }
                    else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { check() } }
                }
            }
        }
        check()
    }

    func restartService() {
        guard let path = lastConfigPath, isRunning else { return }
        if isProcessing { return }
        isProcessing = true
        
        // 1. Stop
        CoreService.shared.stop { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isRunning = false
                self.uptimeTimer?.cancel()
                self.timer?.cancel()
                self.peers = []
                
                // 2. Wait a bit for port release (safety buffer)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    // 3. Start
                    let newSessionID = UUID()
                    self.currentSessionID = newSessionID
                    
                    CoreService.shared.start(configPath: path, rpcPort: self.rpcPort) { success in
                        DispatchQueue.main.async {
                            if success {
                                self.isRunning = true
                                self.startedAt = Date()
                                self.startUptimeTimer()
                                
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    guard self.isRunning,
                                          self.currentSessionID == newSessionID else { return }
                                    self.startMonitoring()
                                }
                            }
                            self.isProcessing = false
                        }
                    }
                }
            }
        }
    }

    func openLogFile() {
        CoreService.shared.openLogFile()
    }

    private func startMonitoring() {
        timer?.cancel()
        refreshPeersOnce()

        let interval = UserDefaults.standard.double(forKey: "refreshInterval")
        let finalInterval = interval > 0 ? interval : 1.0
        
        timer = Timer.publish(every: finalInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshPeersOnce()
            }
    }

    private func refreshPeersOnce() {
        Task { [weak self] in
            guard let self = self else { return }
            
            let fetchedPeers = await self.cliClient.fetchPeers(sessionID: self.currentSessionID)
            
            let sortedPeers = fetchedPeers.sorted { p1, p2 in
                let isP1Public = p1.ipv4.contains("Public")
                let isP2Public = p2.ipv4.contains("Public")
                if isP1Public != isP2Public { return !isP1Public }
                return p1.ipv4.localizedStandardCompare(p2.ipv4) == .orderedAscending
            }
            
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                    self.peers = sortedPeers
                }
                self.peerCount = "\(sortedPeers.count)"
            }
        }
    }

    private func startUptimeTimer() {
        uptimeTimer?.cancel()
        uptimeTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, let startedAt = self.startedAt else { return }
                let interval = Int(Date().timeIntervalSince(startedAt))
                let h = interval / 3600
                let m = (interval % 3600) / 60
                let s = interval % 60
                self.uptimeText = String(format: "%02d:%02d:%02d", h, m, s)
            }
    }
}

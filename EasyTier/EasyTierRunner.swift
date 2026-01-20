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
    
    private var currentSessionID = UUID()
    private var lastConfigPath: String?
    
    // Speed calculation
    private var lastTotalRx: Int = 0
    private var lastTotalTx: Int = 0
    private var lastPollTime: Date?
    
    @Published var virtualIP: String = "-"
    
    // Speed history for graphs
    @Published var downloadHistory: [Double] = Array(repeating: 0.0, count: 20)
    @Published var uploadHistory: [Double] = Array(repeating: 0.0, count: 20)

    private init() {
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
                            self.resetSpeedCounters()
                            self.startUptimeTimer()
                            self.startMonitoring()
                            
                            print("[Runner] Core is already running (PID: \(pid)), syncing UI state")
                            completion?(true)
                        }
                    }
                } else {
                    // 旧系统 fallback (其实已经不再需要，因为 target >= 13.0)
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
                // Core 未运行
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.startedAt = nil
                    self.uptimeText = "00:00:00"
                    self.peers = []
                    self.downloadHistory = Array(repeating: 0.0, count: 20)
                    self.uploadHistory = Array(repeating: 0.0, count: 20)
                    print("[Runner] No Core process detected via Helper")
                    completion?(false)
                }
            }
        }
    }
    
    // checkCoreProcessDirectly removed as it's not applicable for embedded core

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
        CoreService.shared.start(configPath: configPath) { [weak self] success in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if success {
                    self.isRunning = true
                    self.startedAt = Date()
                    self.startUptimeTimer()
                    
                    print("[Runner] Service started successfully. Starting monitoring.")
                    self.startMonitoring()
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
                    
                    CoreService.shared.start(configPath: path) { success in
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
        let logPath = "/var/log/swiftier-helper.log"
        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
        }
    }

    private func startMonitoring() {
        // OPTIMIZATION: Do NOT start LogParser file monitoring here.
        // LogParser.shared.startMonitoring() reads the log file every second, consuming high CPU.
        // Events are already fetched via getRunningInfo RPC in refreshPeersOnce.
        // File monitoring should only be active when LogView is visible (handled in LogView.swift).
        
        resetSpeedCounters()
        
        timer?.cancel()
        
        let interval = UserDefaults.standard.double(forKey: "refreshInterval")
        let finalInterval = interval > 0 ? interval : 2.0
        
        timer = Timer.publish(every: finalInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshPeersOnce()
            }
    }
    
    private func resetSpeedCounters() {
        lastTotalRx = 0
        lastTotalTx = 0
        lastPollTime = nil
        downloadHistory = Array(repeating: 0.0, count: 20)
        uploadHistory = Array(repeating: 0.0, count: 20)
    }

    private func refreshPeersOnce() {
        guard #available(macOS 13.0, *) else { return }
        
        HelperManager.shared.getRunningInfo { [weak self] jsonStr in
            guard let self = self, let jsonStr = jsonStr else { return }
            
            guard let data = jsonStr.data(using: .utf8) else { return }
            
            // Decode using the new model
            guard let status = try? JSONDecoder().decode(EasyTierStatus.self, from: data) else {
                print("Failed to decode EasyTierStatus")
                return
            }
            
            // 1. Update Events
            LogParser.shared.updateEventsFromRunningInfo(status.events)
            
            // 2. Update Peers
            var fetchedPeers: [PeerInfo] = []
            
            // Add Local Node as a card (per USER preference)
            if let myNode = status.myNodeInfo {
                let localPeer = PeerInfo(
                    sessionID: self.currentSessionID,
                    ipv4: "\(myNode.virtualIPv4?.description ?? "-") (Local)",
                    hostname: myNode.hostname,
                    cost: "本机",
                    latency: "0",
                    loss: "0.0%",
                    rx: "-",
                    tx: "-",
                    tunnel: "LOCAL",
                    nat: self.natTypeString(myNode.stunInfo?.udpNATType ?? 0),
                    version: myNode.version
                )
                fetchedPeers.append(localPeer)
            }
            
            for pair in status.peerRoutePairs {
                // ... (rest of peer loop unchanged)
                // Route Info
                let ipv4 = pair.route.ipv4Addr?.description ?? ""
                let hostname = pair.route.hostname
                let costStr = pair.route.cost == 1 ? "P2P" : "Relay(\(pair.route.cost))"
                let version = pair.route.version
                
                // Aggregation Vars
                var latencyVal = ""
                var lossVal = ""
                var rxVal = ""
                var txVal = ""
                var tunnelVal = ""
                
                if let peer = pair.peer {
                    var totalRx = 0
                    var totalTx = 0
                    var latencySum = 0
                    var latencyCount = 0
                    var lossSum = 0.0
                    var lossCount = 0
                    var tunnelTypes: Set<String> = []
                    
                    for conn in peer.conns {
                        // Stats
                        if let stats = conn.stats {
                            latencySum += stats.latencyUs
                            latencyCount += 1
                            totalRx += stats.rxBytes
                            totalTx += stats.txBytes
                        }
                        
                        // Loss
                        lossSum += conn.lossRate
                        lossCount += 1
                        
                        // Tunnel
                        if let type = conn.tunnel?.tunnelType {
                            tunnelTypes.insert(type.uppercased())
                        }
                    }
                    
                    // Averages & Formatting
                    if latencyCount > 0 {
                        let avgLatencyMs = Double(latencySum) / Double(latencyCount) / 1000.0
                        latencyVal = String(format: "%.1f", avgLatencyMs)
                    } else if let pathLat = pair.route.pathLatency, pathLat > 0 {
                         latencyVal = String(format: "%.1f", Double(pathLat) / 1000.0)
                    }
                    
                    if lossCount > 0 {
                        let avgLoss = lossSum / Double(lossCount)
                        lossVal = String(format: "%.1f%%", avgLoss * 100)
                    }
                    
                    rxVal = self.formatBytes(totalRx)
                    txVal = self.formatBytes(totalTx)
                    tunnelVal = tunnelTypes.sorted().joined(separator: "&")
                } else {
                     // No direct connection, use route info if available
                    if let pathLat = pair.route.pathLatency, pathLat > 0 {
                         latencyVal = String(format: "%.1f", Double(pathLat) / 1000.0)
                    }
                }
                
                // NAT Type
                var natVal = ""
                if let natType = pair.route.stunInfo?.udpNATType {
                    natVal = self.natTypeString(natType)
                }
                
                let peerInfo = PeerInfo(
                    sessionID: self.currentSessionID,
                    ipv4: ipv4,
                    hostname: hostname,
                    cost: costStr,
                    latency: latencyVal,
                    loss: lossVal,
                    rx: rxVal,
                    tx: txVal,
                    tunnel: tunnelVal,
                    nat: natVal,
                    version: version
                )
                fetchedPeers.append(peerInfo)
            }
            
            // 3. Update Speeds
            let now = Date()
            var totalRx = 0
            var totalTx = 0
            
            for pair in status.peerRoutePairs {
                if let peer = pair.peer {
                    for conn in peer.conns {
                        if let stats = conn.stats {
                            totalRx += stats.rxBytes
                            totalTx += stats.txBytes
                        }
                    }
                }
            }
            
            if let lastTime = self.lastPollTime, let lastRx = Optional(self.lastTotalRx), let lastTx = Optional(self.lastTotalTx) {
                let duration = now.timeIntervalSince(lastTime)
                if duration > 0 {
                    let rxSpeed = Double(totalRx - lastRx) / duration
                    let txSpeed = Double(totalTx - lastTx) / duration
                    
                    DispatchQueue.main.async {
                        self.downloadSpeed = "\(self.formatSpeed(rxSpeed))"
                        self.uploadSpeed = "\(self.formatSpeed(txSpeed))"
                        
                        // Update history
                        self.downloadHistory.append(rxSpeed)
                        if self.downloadHistory.count > 20 { self.downloadHistory.removeFirst() }
                        
                        self.uploadHistory.append(txSpeed)
                        if self.uploadHistory.count > 20 { self.uploadHistory.removeFirst() }
                    }
                }
            }
            
            self.lastTotalRx = totalRx
            self.lastTotalTx = totalTx
            self.lastPollTime = now
            
            // 4. Update Node Info (Global state for speeds, but card handles IP)
            if let myIp = status.myNodeInfo?.virtualIPv4?.description {
                DispatchQueue.main.async { self.virtualIP = myIp }
            }
            
            let sortedPeers = fetchedPeers.sorted { p1, p2 in
                // Original Rule: Local first, then IP sorted, Public at the end
                let isP1Local = p1.ipv4.contains("Local")
                let isP2Local = p2.ipv4.contains("Local")
                if isP1Local != isP2Local { return isP1Local }
                
                // Public nodes have empty IP or "Public" in hostname/IP
                let isP1Public = p1.ipv4.isEmpty || p1.ipv4.contains("Public") || p1.hostname.lowercased().contains("public")
                let isP2Public = p2.ipv4.isEmpty || p2.ipv4.contains("Public") || p2.hostname.lowercased().contains("public")
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
    
    private func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 { return String(format: "%.0f B/s", bytesPerSec) }
        let kb = bytesPerSec / 1024.0
        if kb < 1024 { return String(format: "%.1f KB/s", kb) }
        let mb = kb / 1024.0
        return String(format: "%.1f MB/s", mb)
    }

    
    private func natTypeString(_ type: Int) -> String {
        switch type {
        case 1: return "Open"
        case 2: return "NoPAT"
        case 3: return "FullCone"
        case 4: return "Restricted"
        case 5: return "PortRestricted"
        case 6: return "Symmetric"
        case 7: return "SymUDPFirewall"
        case 8, 9: return "SymEasy"
        default: return "Unknown"
        }
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024.0
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        let gb = mb / 1024.0
        return String(format: "%.2f GB", gb)
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

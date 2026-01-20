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
    @Published var isWindowVisible = true // 新增：全局追踪窗口可见性，优化后台 CPU

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
    
    // Peer-level speed tracking
    private var lastPeerStats: [Int: (rx: Int, tx: Int, time: Date)] = [:]
    private let jsonDecoder = JSONDecoder()
    
    // 最小化解码结构，用于后台静默模式以极速解析字节数
    private struct MinimalStatus: Codable {
        struct Pair: Codable {
            struct Peer: Codable {
                struct Conn: Codable {
                    struct Stats: Codable {
                        let rx_bytes: Int
                        let tx_bytes: Int
                    }
                    let stats: Stats?
                }
                let conns: [Conn]?
            }
            let peer: Peer?
        }
        let peer_route_pairs: [Pair]?
    }
    
    @Published var virtualIP: String = "-"
    
    // Speed history for graphs
    @Published var downloadHistory: [Double] = Array(repeating: 0.0, count: 20)
    @Published var uploadHistory: [Double] = Array(repeating: 0.0, count: 20)

    private init() {
        // 启动时立即检查 Core 的真实运行状态
        syncWithCoreState()
    }
    
    func syncWithCoreState(completion: ((Bool) -> Void)? = nil) {
        let wasAlreadyRunning = self.isRunning
        print("[Runner] Syncing with core state (current: \(wasAlreadyRunning))...")
        
        CoreService.shared.getStatus { [weak self] running, pid in
            guard let self = self else { 
                completion?(false)
                return 
            }
            
            let isDiscovery = running && pid > 0
            
            if isDiscovery {
                // Core 正在后台运行，获取真实启动时间
                if #available(macOS 13.0, *) {
                    HelperManager.shared.getCoreStartTime { [weak self] timestamp in
                        guard let self = self else { return }
                        DispatchQueue.main.async {
                            // 只有状态改变才触发 UI 更新，防止循环刷新
                            if !self.isRunning {
                                self.isRunning = true
                            }
                            
                            if timestamp > 0 {
                                self.startedAt = Date(timeIntervalSince1970: timestamp)
                            } else if self.startedAt == nil {
                                self.startedAt = Date()
                            }
                            
                            // 只有在之前认定为停止的情况下，才重新初始化监控逻辑
                            if !wasAlreadyRunning {
                                print("[Runner] Inheriting running core state, initializing monitoring...")
                                self.currentSessionID = UUID()
                                self.resetSpeedCounters()
                                self.startUptimeTimer()
                                self.startMonitoring()
                            }
                            
                            print("[Runner] Core detected (PID: \(pid)). Sync complete.")
                            completion?(true)
                        }
                    }
                } else {
                    // 旧系统 fallback
                    DispatchQueue.main.async {
                        if !self.isRunning { self.isRunning = true }
                        if !wasAlreadyRunning {
                            self.startedAt = Date()
                            self.currentSessionID = UUID()
                            self.startUptimeTimer()
                            self.startMonitoring()
                        }
                        completion?(true)
                    }
                }
            } else {
                // Core 未运行
                DispatchQueue.main.async {
                    if self.isRunning {
                        self.isRunning = false
                    }
                    self.startedAt = nil
                    
                    // 自动连接逻辑：仅在 App 刚启动、且发现 Core 未跑、且开启了开关时触发一次
                    if !wasAlreadyRunning && UserDefaults.standard.bool(forKey: "connectOnStart") {
                        print("[Runner] Initial sync: Core not running, auto-connecting...")
                        if let lastConfig = ConfigManager.shared.configFiles.first?.path {
                             self.toggleService(configPath: lastConfig)
                        }
                    }
                    
                    self.uptimeText = "00:00:00"
                    self.peers = []
                    self.downloadHistory = Array(repeating: 0.0, count: 20)
                    self.uploadHistory = Array(repeating: 0.0, count: 20)
                    if wasAlreadyRunning {
                        print("[Runner] Core process disappeared.")
                    }
                    completion?(false)
                }
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

    @Published var isProcessing = false

    func toggleService(configPath: String) {
        if isProcessing { return }
        isProcessing = true
        
        let targetState = !isRunning
        
        withAnimation(.spring(response: 1.0, dampingFraction: 0.8)) {
            self.isRunning = targetState
            if !targetState { self.peers = [] }
        }
        
        if !targetState {
            // STOP
            self.startedAt = nil
            self.uptimeText = "00:00:00"
            self.uptimeTimer?.cancel()
            self.timer?.cancel()
            
            CoreService.shared.stop { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.isProcessing = false
                }
            }
        } else {
            // START
            self.startedAt = Date()
            self.uptimeText = "00:00:00"
            self.startUptimeTimer()
            
            let newSessionID = UUID()
            self.currentSessionID = newSessionID
            self.lastConfigPath = configPath
            
            print("[Runner] Optimistic start. Background cleanup initiated...")
            
            CoreService.shared.stop { [weak self] _ in
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
                    if retryCount > 0 {
                        print("[Runner] Start failed, retrying in 1.5s...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.performStart(configPath: configPath, newSessionID: newSessionID, retryCount: retryCount - 1)
                        }
                    } else {
                        self.isProcessing = false
                        self.syncWithCoreState()
                    }
                }
            }
        }
    }
    
    func restartService() {
        guard let path = lastConfigPath, isRunning else { return }
        if isProcessing { return }
        isProcessing = true
        
        CoreService.shared.stop { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let self = self else { return }
                let newSessionID = UUID()
                self.currentSessionID = newSessionID
                self.performStart(configPath: path, newSessionID: newSessionID)
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
        resetSpeedCounters()
        timer?.cancel()
        
        if #available(macOS 13.0, *) {
            HelperManager.shared.setPushHandler { [weak self] jsonStr in
                self?.processRunningInfo(jsonStr)
            }
            refreshPeersOnce()
        } else {
             // Fallback for older macOS (Timer based)
             timer = Timer.publish(every: 1.0, on: .main, in: .common)
                 .autoconnect()
                 .sink { [weak self] _ in
                     self?.refreshPeersOnce()
                 }
        }
    }
    
    private func resetSpeedCounters() {
        lastTotalRx = 0
        lastTotalTx = 0
        lastPollTime = nil
        lastPeerStats = [:]
        downloadHistory = Array(repeating: 0.0, count: 20)
        uploadHistory = Array(repeating: 0.0, count: 20)
    }

    private func refreshPeersOnce() {
        guard #available(macOS 13.0, *) else { return }
        HelperManager.shared.getRunningInfo { [weak self] jsonStr in
             if let str = jsonStr {
                 self?.processRunningInfo(str)
             }
        }
    }

    private func processRunningInfo(_ jsonStr: String) {
        let now = Date()
        guard let data = jsonStr.data(using: .utf8) else { return }
        
        var totalRx = 0
        var totalTx = 0
        var fetchedPeers: [PeerInfo] = []
        
        if !isWindowVisible {
            // --- 静默模式：极致性能，仅解析字节数用于图表连贯性 ---
            if let mini = try? jsonDecoder.decode(MinimalStatus.self, from: data), let pairs = mini.peer_route_pairs {
                for pair in pairs {
                    if let conns = pair.peer?.conns {
                        for conn in conns {
                            if let s = conn.stats {
                                totalRx += s.rx_bytes
                                totalTx += s.tx_bytes
                            }
                        }
                    }
                }
            }
        } else {
            // --- 活跃模式：全量解析并更新 UI ---
            guard let status = try? jsonDecoder.decode(EasyTierStatus.self, from: data) else { return }
            
            // 1. IP & 事件更新 (不直接触发 UI 刷新)
            LogParser.shared.updateEventsFromRunningInfo(status.events)
            if let myIp = status.myNodeInfo?.virtualIPv4?.description, self.virtualIP != myIp {
                DispatchQueue.main.async { self.virtualIP = myIp }
            }
            
            // 2. 统计流量 & 构建节点列表
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
            
            // 3. 构建本地节点卡片
            if let myNode = status.myNodeInfo {
                fetchedPeers.append(PeerInfo(
                    sessionID: self.currentSessionID,
                    ipv4: myNode.virtualIPv4?.description ?? "-",
                    hostname: myNode.hostname,
                    cost: "本机",
                    latency: "0",
                    loss: "0.0%",
                    rx: self.formatBytes(totalRx),
                    tx: self.formatBytes(totalTx),
                    tunnel: "LOCAL",
                    nat: myNode.stunInfo?.udpNATType.description ?? "Unknown",
                    version: myNode.version,
                    myNodeData: myNode
                ))
            }
            
            // 4. 构建远程节点列表
            for pair in status.peerRoutePairs {
                // peerId unused
                var rxVal = "0 B", txVal = "0 B", latencyVal = "", lossVal = "", tunnelVal = ""
                
                if let peer = pair.peer {
                    var cRx = 0, cTx = 0, latSum = 0, latCount = 0, lossSum = 0.0, lossCount = 0, tunnels = Set<String>()
                    for conn in peer.conns {
                        // Note: stats is optional in new model
                        if let s = conn.stats { 
                            latSum += s.latencyUs; latCount += 1
                            cRx += s.rxBytes; cTx += s.txBytes 
                        }
                        
                        lossSum += conn.lossRate
                        lossCount += 1
                        
                        if let t = conn.tunnel?.tunnelType { tunnels.insert(t.uppercased()) }
                    }
                    rxVal = formatBytes(cRx); txVal = formatBytes(cTx)
                    if latCount > 0 { latencyVal = String(format: "%.1f", Double(latSum)/Double(latCount)/1000.0) }
                    if lossCount > 0 { lossVal = String(format: "%.1f%%", (lossSum/Double(lossCount))*100.0) }
                    tunnelVal = tunnels.sorted().joined(separator: "&")
                } else if let pathLat = pair.route.pathLatency as Int?, pathLat > 0 {
                    // New model has pathLatency as Int (us)
                     latencyVal = String(format: "%.1f", Double(pathLat) / 1000.0)
                }
                
                fetchedPeers.append(PeerInfo(
                    sessionID: self.currentSessionID,
                    ipv4: pair.route.ipv4Addr?.description ?? "",
                    hostname: pair.route.hostname,
                    cost: pair.route.cost == 1 ? "P2P" : "Relay(\(pair.route.cost))",
                    latency: latencyVal, loss: lossVal, rx: rxVal, tx: txVal, tunnel: tunnelVal,
                    nat: pair.route.stunInfo?.udpNATType.description ?? "Unknown",
                    version: pair.route.version,
                    fullData: pair
                ))
            }
        }
        
        // --- 全局流量更新 (无论可见性，保证历史图表平滑) ---
        if let lastT = lastPollTime {
            let d = now.timeIntervalSince(lastT)
            if d > 0.1 {
                let rSpeed = max(0, Double(totalRx - lastTotalRx) / d)
                let tSpeed = max(0, Double(totalTx - lastTotalTx) / d)
                DispatchQueue.main.async {
                    if self.isWindowVisible {
                        self.downloadSpeed = self.formatSpeed(rSpeed)
                        self.uploadSpeed = self.formatSpeed(tSpeed)
                    }
                    self.downloadHistory.removeFirst(); self.downloadHistory.append(rSpeed)
                    self.uploadHistory.removeFirst(); self.uploadHistory.append(tSpeed)
                }
            }
        }
        self.lastTotalRx = totalRx
        self.lastTotalTx = totalTx
        self.lastPollTime = now
        
        // --- 性能分支：如果不可见，到此为止 ---
        guard isWindowVisible else { return }
        
        // 5. 排序并发布 UI 列表
        let sorted = fetchedPeers.sorted { p1, p2 in
            // 优先级 1: 本机始终第一
            let is1L = p1.cost == "本机"; let is2L = p2.cost == "本机"
            if is1L != is2L { return is1L }
            
            // 优先级 2: 有虚拟 IP 的排前面，Public (IP 为空) 的排后面
            let is1Empty = p1.ipv4.isEmpty; let is2Empty = p2.ipv4.isEmpty
            if is1Empty != is2Empty { return !is1Empty }
            
            // 优先级 3: 正常的按 IP 排序
            return p1.ipv4.localizedStandardCompare(p2.ipv4) == .orderedAscending
        }
        
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { self.peers = sorted }
            self.peerCount = "\(sorted.count)"
        }
    }
    
    private func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 { return String(format: "%.0f B/s", bytesPerSec) }
        let kb = bytesPerSec / 1024.0
        if kb < 1024 { return String(format: "%.1f KB/s", kb) }
        let mb = kb / 1024.0
        return String(format: "%.1f MB/s", mb)
    }
    
    // REMOVED: private func natTypeString
    
    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024.0
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024.0)
    }

    private func startUptimeTimer() {
        uptimeTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, self.isWindowVisible, let sAt = self.startedAt else { return }
                let interval = Int(Date().timeIntervalSince(sAt))
                let h = interval / 3600; let m = (interval % 3600) / 60; let s = interval % 60
                let newText = String(format: "%02d:%02d:%02d", h, m, s)
                if self.uptimeText != newText { self.uptimeText = newText }
        }
    }
}

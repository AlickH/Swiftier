//
//  SwiftierRunner.swift
//  Swiftier
//
//  Created by Alick on 2024.
//

import Foundation
import Combine
import AppKit
import SwiftUI
import NetworkExtension

final class SwiftierRunner: ObservableObject {
    static let shared = SwiftierRunner()

    @Published var isRunning = false
    @Published var peers: [PeerInfo] = []
    @Published var peerCount: String = "0"
    @Published var downloadSpeed: String = "0 KB/s"
    @Published var uploadSpeed: String = "0 KB/s"
    @Published var maxHistorySpeed: Double = 1_048_576.0 // 缓存最大网速计算结果
    @Published var isWindowVisible = true
    @Published var uptimeText: String = "00:00:00"
    
    // 公开最后一次数据更新的时间戳，供 UI 层做动画相位对齐
    @Published private(set) var lastDataTime: Date = Date.distantPast
    
    private var startedAt: Date?
    private var timer: AnyCancellable?
    @Published private(set) var sessionID = UUID()
    private var currentSessionID = UUID()
    private var lastConfigPath: String?
    
    // Speed calculation
    private var lastTotalRx: Int = 0
    private var lastTotalTx: Int = 0
    private var lastPollTime: Date?
    private var lastProcessingTime: Date = .distantPast // 用于频率限制
    
    // Peer-level speed tracking
    private var lastPeerStats: [Int: (rx: Int, tx: Int, time: Date)] = [:]
    private let jsonDecoder = JSONDecoder()
    
    @Published var virtualIP: String = "-"
    
    // Speed history for graphs
    @Published var downloadHistory: [Double] = Array(repeating: 0.0, count: 20)
    @Published var uploadHistory: [Double] = Array(repeating: 0.0, count: 20)
    
    // Subscriber & Polling Control
    private var subscriberCount = 0
    private var isAppActive = true
    private var pollingTimer: AnyCancellable?
    private let activeInterval: TimeInterval = 1.0
    private let lowPowerInterval: TimeInterval = 5.0
    
    @Published var isProcessing = false
    
    private var statusObserver: AnyCancellable?

    private init() {
        // App Lifecycle Monitoring
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppWillResignActive), name: NSApplication.willResignActiveNotification, object: nil)
        
        // Listen to VPNManager status changes
        statusObserver = VPNManager.shared.$status.sink { [weak self] status in
            self?.handleVPNStatusChange(status)
        }
        
        // Check initial state
        syncWithVPNState()
    }
    
    @objc private func handleAppDidBecomeActive() {
        // print("[Runner] App Active -> High Perf Mode")
        isAppActive = true
        updatePollingMode()
    }
    
    @objc private func handleAppWillResignActive() {
        // print("[Runner] App Background -> Low Power Mode")
        isAppActive = false
        updatePollingMode()
    }
    
    func addSubscriber() {
        subscriberCount += 1
        updatePollingMode()
    }
    
    func removeSubscriber() {
        subscriberCount = max(0, subscriberCount - 1)
        updatePollingMode()
    }
    
    private func updatePollingMode() {
        guard isRunning else {
            pollingTimer?.cancel()
            return
        }
        
        let interval: TimeInterval
        if subscriberCount > 0 {
            interval = activeInterval
        } else {
            interval = lowPowerInterval
        }
        
        pollingTimer?.cancel()
        pollingTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshPeersOnce()
            }
    }
    
    private func handleVPNStatusChange(_ status: NEVPNStatus) {
        DispatchQueue.main.async {
            switch status {
            case .connected:
                if !self.isRunning {
                    self.isRunning = true
                    // 使用 NE 的实际连接时间，而非 App 启动时间
                    self.startedAt = VPNManager.shared.connectedDate ?? Date()
                    self.startUptimeTimer()
                    self.startMonitoring()
                }
                self.isProcessing = false
            case .disconnected, .invalid:
                if self.isRunning {
                    self.isRunning = false
                    self.stopUptimeTimer()
                    self.peers = []
                    self.uptimeText = "00:00:00"
                    self.downloadSpeed = "0 KB/s"
                    self.uploadSpeed = "0 KB/s"
                    self.virtualIP = "-"
                    self.downloadHistory = Array(repeating: 0.0, count: 20)
                    self.uploadHistory = Array(repeating: 0.0, count: 20)
                }
                self.isProcessing = false
            case .connecting, .disconnecting, .reasserting:
                self.isProcessing = true
            @unknown default:
                break
            }
        }
    }

    func syncWithVPNState() {
        let status = VPNManager.shared.status
        print("[Runner] syncWithVPNState: status = \(status.rawValue)")
        handleVPNStatusChange(status)
    }
    
    // MARK: - Control Actions

    func toggleService(configPath: String) {
        if isProcessing { return }
        
        if isRunning {
            // Stop
            VPNManager.shared.stopVPN()
        } else {
            // Start
            // 使用 ConfigManager 读取（处理安全域）
            do {
                let configURL = URL(fileURLWithPath: configPath)
                let configContent = try ConfigManager.shared.readConfigContent(configURL)
                VPNManager.shared.startVPN(configContent: configContent)
                
                // 缓存路径用于重启
                self.lastConfigPath = configPath
            } catch {
                print("Failed to read config for VPN: \(error)")
                let alert = NSAlert()
                alert.messageText = "配置读取失败"
                alert.informativeText = "无法读取配置文件：\(error.localizedDescription)"
                // alert.runModal() // 不要在 toggle 中阻塞 UI，尤其是自动连接时
                // 而是发送通知或者只是 log?
                // 如果是手动点击，modal 是可以的。如果是自动启动...
                // 暂时保留，但在主线程操作
                DispatchQueue.main.async {
                    if self.isWindowVisible {
                        alert.runModal()
                    }
                }
            }
        }
    }
    
    func restartService() {
        guard isRunning else { return }
        VPNManager.shared.stopVPN()
        
        // 监听 VPN 断开后再重连，而非使用固定延迟
        guard let path = lastConfigPath else { return }
        var restartObserver: AnyCancellable?
        restartObserver = VPNManager.shared.$status
            .filter { $0 == .disconnected }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.toggleService(configPath: path)
                restartObserver?.cancel()
            }
    }

    func openLogFile() {
        // Logs for NE are different. They might be in the Console.app or a shared file.
        // If we implement file logging in PacketTunnelProvider to a shared container:
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.alick.swiftier") {
            let logURL = containerURL.appendingPathComponent("easytier.log")
            if FileManager.default.fileExists(atPath: logURL.path) {
                NSWorkspace.shared.open(logURL)
            } else {
                print("Log file not found at \(logURL.path)")
            }
        }
    }

    private func startMonitoring() {
        resetSpeedCounters()
        updatePollingMode()
        refreshPeersOnce()
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
        guard isRunning else { return }
        
        // Request running info directly from NE via IPC
        VPNManager.shared.requestRunningInfo { [weak self] json in
            guard let self = self, let json = json else { return }
            self.processRunningInfo(json)
        }
    }
    
    // ... processRunningInfo, formatSpeed, formatBytes, Uptime Timer logic remains mostly the same ...
    // Copying the rest of the logic to ensure it works.

    private var throttleInterval: TimeInterval = 0.8
    
    func setWarmUpMode(_ enabled: Bool) {
        self.throttleInterval = enabled ? 0.05 : 0.8
    }
    
    func forceRefresh() {
        refreshPeersOnce()
    }

    private func processRunningInfo(_ jsonStr: String) {
        let now = Date()
        guard now.timeIntervalSince(lastProcessingTime) >= throttleInterval else {
            return
        }
        
        lastProcessingTime = now
        guard let data = jsonStr.data(using: .utf8) else { return }
        
        var totalRx = 0
        var totalTx = 0
        var fetchedPeers: [PeerInfo] = []
        
            guard let status = try? jsonDecoder.decode(SwiftierStatus.self, from: data) else { return }
            
            // 1. IP & Events
            LogParser.shared.updateEventsFromRunningInfo(status.events)
            if let myIp = status.myNodeInfo?.virtualIPv4?.description, self.virtualIP != myIp {
                DispatchQueue.main.async { self.virtualIP = myIp }
            }
            
            // 2. Stats
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
            
            // 3. Local Node
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
            
            // 4. Remote Nodes
            for pair in status.peerRoutePairs {
                var rxVal = "0 B", txVal = "0 B", latencyVal = "", lossVal = "", tunnelVal = ""
                
                if let peer = pair.peer {
                    var cRx = 0, cTx = 0, latSum = 0, latCount = 0, lossSum = 0.0, lossCount = 0, tunnels = Set<String>()
                    for conn in peer.conns {
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
        
        // Traffic update
        if let lastT = lastPollTime {
            let d = now.timeIntervalSince(lastT)
            if d > 0.1 {
                let rSpeed = max(0, Double(totalRx - lastTotalRx) / d)
                let tSpeed = max(0, Double(totalTx - lastTotalTx) / d)
                DispatchQueue.main.async {
                    self.downloadSpeed = self.formatSpeed(rSpeed)
                    self.uploadSpeed = self.formatSpeed(tSpeed)
                    self.downloadHistory.removeFirst(); self.downloadHistory.append(rSpeed)
                    self.uploadHistory.removeFirst(); self.uploadHistory.append(tSpeed)
                    
                    self.maxHistorySpeed = max(
                        (self.downloadHistory.max() ?? 0.0),
                        (self.uploadHistory.max() ?? 0.0),
                        1_048_576.0
                    )
                }
            }
        }
        self.lastTotalRx = totalRx
        self.lastTotalTx = totalTx
        self.lastPollTime = now
        
        DispatchQueue.main.async {
            self.lastDataTime = now
            
            let sorted = fetchedPeers.sorted { p1, p2 in
                let is1L = p1.cost == "本机"; let is2L = p2.cost == "本机"
                if is1L != is2L { return is1L }
                let is1Empty = p1.ipv4.isEmpty; let is2Empty = p2.ipv4.isEmpty
                if is1Empty != is2Empty { return !is1Empty }
                return p1.ipv4.localizedStandardCompare(p2.ipv4) == .orderedAscending
            }
            
            let oldIDs = self.peers.map(\.id)
            let newIDs = sorted.map(\.id)
            
            if oldIDs != newIDs {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                    self.peers = sorted
                }
            } else {
                self.peers = sorted
            }
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
    
    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024.0
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024.0)
    }

    private var uptimeTimer: Timer?
    
    private func startUptimeTimer() {
        guard uptimeTimer == nil else { return }
        updateUptimeText()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateUptimeText()
        }
        RunLoop.main.add(t, forMode: .common)
        uptimeTimer = t
    }
    
    private func stopUptimeTimer() {
        uptimeTimer?.invalidate()
        uptimeTimer = nil
    }
    
    private func updateUptimeText() {
        guard let sAt = startedAt else { return }
        let interval = Int(Date().timeIntervalSince(sAt))
        let h = interval / 3600; let m = (interval % 3600) / 60; let s = interval % 60
        let newText = String(format: "%02d:%02d:%02d", h, m, s)
        if uptimeText != newText { uptimeText = newText }
    }
}

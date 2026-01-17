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
    
    // 【修改点】不再需要 isFirstLoad 逻辑，交给 sessionID 控制
    private var timer: AnyCancellable?
    private let rpcPort = "15888"
    private let cliClient: CliClient
    
    // 【关键点】定义 sessionID
    // 【关键点】定义 sessionID
    private var currentSessionID = UUID()
    private var lastConfigPath: String?

    private init() {
        cliClient = CliClient(rpcPort: rpcPort)
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
            alert.informativeText = "EasyTier 需要该权限来读取受保护文件夹中的配置文件。\n\n请在『系统设置 -> 隐私与安全性 -> 完整磁盘访问权限』中手动勾选此 App。"
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

    // --- 修改点：Toggle 逻辑中刷新 sessionID ---
    func toggleService(configPath: String) {
        if isRunning {
            CoreService.shared.stop()
            DispatchQueue.main.async {
                self.isRunning = false
                self.startedAt = nil
                self.uptimeText = "00:00:00"
                self.uptimeTimer?.cancel()
                self.timer?.cancel()
                self.peers = []
                // 停止时清空，为下次生成新 ID 做准备
            }
        } else {
            // 【核心】：每次启动前生成全新的 SessionID
            self.currentSessionID = UUID()
            self.lastConfigPath = configPath
            
            CoreService.shared.start(configPath: configPath, rpcPort: rpcPort) { [weak self] success in
                guard let self = self, success else { return }
                DispatchQueue.main.async {
                    self.isRunning = true
                    self.startedAt = Date()
                    self.startUptimeTimer()
                    self.startMonitoring()
                }
            }
        }
    }

    func restartService() {
        guard let path = lastConfigPath, isRunning else { return }
        // Stop
        toggleService(configPath: path)
        // Wait and Start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !self.isRunning {
                self.toggleService(configPath: path)
            }
        }
    }

    // --- 保留功能：日志操作 ---
    func openLogFile() {
        CoreService.shared.openLogFile()
    }

    private func startMonitoring() {
        timer?.cancel()
        refreshPeersOnce()

        // 从 UserDefaults 读取刷新间隔，默认为 1s
        let interval = UserDefaults.standard.double(forKey: "refreshInterval")
        let finalInterval = interval > 0 ? interval : 1.0
        
        timer = Timer.publish(every: finalInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshPeersOnce()
            }
    }

    // --- 核心修正：传参 sessionID 并优化排序 ---
    private func refreshPeersOnce() {
        Task { [weak self] in
            guard let self = self else { return }
            
            // 【关键】：传入当前 sessionID 到 CliClient
            let fetchedPeers = await self.cliClient.fetchPeers(sessionID: self.currentSessionID)
            
            // 排序逻辑保持不变
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

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
    func syncWithCoreState() {
        CoreService.shared.getStatus { [weak self] running, pid in
            guard let self = self else { return }
            
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
                    }
                }
            } else {
                // Core 未运行，清理状态
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.startedAt = nil
                    self.uptimeText = "00:00:00"
                    self.peers = []
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
            }
        } else {
            let newSessionID = UUID()
            self.currentSessionID = newSessionID
            self.lastConfigPath = configPath
            
            CoreService.shared.start(configPath: configPath, rpcPort: rpcPort) { [weak self] success in
                guard let self = self, success else { return }
                DispatchQueue.main.async {
                    self.isRunning = true
                    self.startedAt = Date()
                    self.startUptimeTimer()
                    
                    // 延迟 1.5 秒再开始监控，给 Core 足够时间初始化 RPC 并发现节点
                    // 捕获 sessionID，确保在延迟期间如果用户停止了服务，任务会被忽略
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self = self,
                              self.isRunning,
                              self.currentSessionID == newSessionID else { return }
                        self.startMonitoring()
                    }
                }
            }
        }
    }

    func restartService() {
        guard let path = lastConfigPath, isRunning else { return }
        toggleService(configPath: path)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !self.isRunning {
                self.toggleService(configPath: path)
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

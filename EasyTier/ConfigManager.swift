import Foundation
import Combine
import SwiftUI
import AppKit

class ConfigManager: ObservableObject {
    static let shared = ConfigManager()
    
    @Published var configFiles: [URL] = []
    @AppStorage("custom_config_path") var customPathString: String = ""
    @AppStorage("custom_config_bookmark") var customPathBookmark: Data?

    var currentDirectory: URL? {
        if let bookmark = customPathBookmark {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                if isStale {
                    // Update stale bookmark if needed
                    if let newBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                        DispatchQueue.main.async { self.customPathBookmark = newBookmark }
                    }
                }
                return url
            }
        }
        
        if !customPathString.isEmpty {
            return URL(fileURLWithPath: customPathString)
        }
        
        // 自动探测 iCloud 路径作为默认值
        if let drive = iCloudDriveURL {
            let targetDir = drive.appendingPathComponent("Swiftier")
            // 确保目录存在
            if !FileManager.default.fileExists(atPath: targetDir.path) {
                try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            }
            return targetDir
        }
        
        return nil
    }

    private init() {
        // 首次运行或未设置路径时，自动尝试初始化 iCloud
        if customPathString.isEmpty {
            if let drive = iCloudDriveURL {
                let targetDir = drive.appendingPathComponent("Swiftier")
                if !FileManager.default.fileExists(atPath: targetDir.path) {
                    try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
                }
                // 自动将 iCloud 路径设为默认路径
                self.customPathString = targetDir.path
            }
        }
        refreshConfigs()
    }

    func selectCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            if let url = panel.url {
                self.customPathString = url.path
                
                // 沙盒适配：保存安全域书签 (Security Scoped Bookmark)
                if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    self.customPathBookmark = bookmark
                }
                
                self.refreshConfigs()
            }
        }
    }

    func openiCloudFolder() {
        guard let url = currentDirectory else { return }
        NSWorkspace.shared.open(url)
    }

    func editConfigFile(url: URL) {
        NSWorkspace.shared.open(url)
    }

    // 尝试获取 iCloud Drive 路径
    private var iCloudDriveURL: URL? {
        // 尝试标准路径 (适用于带有 iCloud 权限的 App)
        if let url = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents") {
            return url
        }
        // 尝试用户目录路径 (适用于非沙盒 App 或调试)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let drive = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: drive.path) {
            return drive
        }
        return nil
    }

    func migrateToiCloud() {
        guard let drive = iCloudDriveURL else {
            // TODO: 可以添加回调通知 UI 显示错误，这里暂时打印
            print("未找到 iCloud Drive，请确保已登录 iCloud。")
            return
        }
        
        let targetDir = drive.appendingPathComponent("Swiftier")
        let oldDir = drive.appendingPathComponent("EasyTier")
        
        do {
            // 0. 自动迁移旧 EasyTier 文件夹（如果存在且新 Swiftier 不存在）
            if FileManager.default.fileExists(atPath: oldDir.path) && 
               !FileManager.default.fileExists(atPath: targetDir.path) {
                try FileManager.default.moveItem(at: oldDir, to: targetDir)
                print("已将旧 EasyTier 文件夹迁移到 Swiftier")
            }
            
            // 1. 创建目标目录
            if !FileManager.default.fileExists(atPath: targetDir.path) {
                try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            }
            
            // 2. 复制当前配置文件
            if let currentDir = currentDirectory {
                let items = try FileManager.default.contentsOfDirectory(at: currentDir, includingPropertiesForKeys: nil)
                let configs = items.filter { $0.pathExtension == "toml" }
                
                for file in configs {
                    let destUrl = targetDir.appendingPathComponent(file.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: destUrl.path) {
                        try FileManager.default.copyItem(at: file, to: destUrl)
                    }
                }
            }
            
            // 3. 切换目录并刷新
            DispatchQueue.main.async {
                self.customPathString = targetDir.path
                self.refreshConfigs()
                // 打开 Finder 确认
                NSWorkspace.shared.open(targetDir)
            }
            
        } catch {
            print("迁移到 iCloud 失败: \(error)")
        }
    }

    @discardableResult
    func refreshConfigs() -> [URL] {
        guard let url = currentDirectory else {
            DispatchQueue.main.async { self.configFiles = [] }
            return []
        }
        
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        
        do {
            let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            let tomlFiles = items.filter { $0.pathExtension == "toml" }.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            
            DispatchQueue.main.async {
                self.configFiles = tomlFiles
            }
            return tomlFiles
        } catch {
            print("读取文件夹失败: \(error)")
            return []
        }
    }
}

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
        // 1. 优先尝试从书签恢复（支持沙盒访问）
        if let bookmark = customPathBookmark {
            var isStale = false
            do {
                let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
                
                if isStale {
                    // Update stale bookmark if needed
                    if let newBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                        DispatchQueue.main.async { self.customPathBookmark = newBookmark }
                    }
                }
                return url
            } catch {
                print("解析书签失败: \(error)")
                // 书签失效，清除
                DispatchQueue.main.async { self.customPathBookmark = nil }
            }
        }
        
        // 2. 尝试使用路径字符串（非沙盒或已授权路径）
        if !customPathString.isEmpty {
            return URL(fileURLWithPath: customPathString)
        }
        
        // 3. 自动探测 iCloud 路径作为默认值
        if let drive = iCloudDriveURL {
            let targetDir = drive
            if !FileManager.default.fileExists(atPath: targetDir.path) {
                try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            }
            return targetDir
        }
        
        // 4. Fallback to local Application Support
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
             let targetDir = appSupport.appendingPathComponent("Spotier")
             if !FileManager.default.fileExists(atPath: targetDir.path) {
                 try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
             }
             return targetDir
        }
        
        return nil
    }

    private init() {
        // 修正：如果 customPathString 已指向 iCloud 容器，清除可能残留的旧书签
        // （旧书签可能指向桌面等非 iCloud 路径，导致 currentDirectory 返回错误位置）
        if let bookmark = customPathBookmark, !customPathString.isEmpty {
            var isStale = false
            if let bookmarkURL = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                let bookmarkPath = bookmarkURL.path
                // 书签路径与当前设置路径不一致，说明书签是残留的旧数据
                if bookmarkPath != customPathString {
                    print("[ConfigManager] 清除残留书签: \(bookmarkPath) != \(customPathString)")
                    self.customPathBookmark = nil
                }
            }
        }
        
        // 首次运行或未设置路径时，自动尝试初始化 iCloud
        if customPathString.isEmpty {
            if let drive = iCloudDriveURL {
                let targetDir = drive
                if !FileManager.default.fileExists(atPath: targetDir.path) {
                    try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
                }
                // 自动将 iCloud 路径设为默认路径
                self.customPathString = targetDir.path
            } else {
                // Fallback to local Application Support
                if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                    let targetDir = appSupport.appendingPathComponent("Spotier")
                    if !FileManager.default.fileExists(atPath: targetDir.path) {
                        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
                    }
                    self.customPathString = targetDir.path
                }
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
        var targetURL: URL?
        
        // 优先从书签恢复带权限的 URL
        if let bookmark = customPathBookmark {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                _ = url.startAccessingSecurityScopedResource()
                targetURL = url
            }
        }
        
        // Fallback: iCloud 容器路径
        if targetURL == nil, let drive = iCloudDriveURL {
            targetURL = drive
        }
        
        // 最终 fallback
        if targetURL == nil {
            targetURL = currentDirectory
        }
        
        guard let url = targetURL else { return }
        // 使用 selectFile 在 Finder 中显示目录，避免沙盒权限问题
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    func editConfigFile(url: URL) {
        NSWorkspace.shared.open(url)
    }

    // 尝试获取 iCloud Drive 路径
    private var iCloudDriveURL: URL? {
        // Debug: Check ubiquity identity
        if FileManager.default.ubiquityIdentityToken == nil {
            print("ConfigManager: Ubiquity Identity Token is nil. User might not be logged in or iCloud is disabled for this app.")
        }
        
        // 尝试标准路径 (适用于带有 iCloud 权限的 App)
        if let url = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents") {
            return url
        }
        
        // Removed hardcoded fallback to Mobile Documents as it violates sandbox and causes crashes.
        return nil
    }

    func migrateToiCloud() {
        guard let drive = iCloudDriveURL else {
            // TODO: 可以添加回调通知 UI 显示错误，这里暂时打印
            print("未找到 iCloud Drive，请确保已登录 iCloud。")
            return
        }
        
        let targetDir = drive
        let oldDir = drive.appendingPathComponent("EasyTier")
        
        do {
            // 0a. 自动迁移旧 EasyTier 文件夹内容
            if FileManager.default.fileExists(atPath: oldDir.path) {
                let oldItems = try? FileManager.default.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil)
                if let oldItems = oldItems {
                    for item in oldItems {
                        let dest = targetDir.appendingPathComponent(item.lastPathComponent)
                        if !FileManager.default.fileExists(atPath: dest.path) {
                            try FileManager.default.moveItem(at: item, to: dest)
                        }
                    }
                    try? FileManager.default.removeItem(at: oldDir)
                    print("已迁移 EasyTier 内容到跟目录")
                }
            }

            // 0b. 自动迁移错误的 nested Spotier 文件夹 (修复之前的 Bug)
            let nestedSpotierDir = drive.appendingPathComponent("Spotier")
            if FileManager.default.fileExists(atPath: nestedSpotierDir.path) {
                 let nestedItems = try? FileManager.default.contentsOfDirectory(at: nestedSpotierDir, includingPropertiesForKeys: nil)
                 if let nestedItems = nestedItems {
                     for item in nestedItems {
                         let dest = targetDir.appendingPathComponent(item.lastPathComponent)
                         if !FileManager.default.fileExists(atPath: dest.path) {
                             try FileManager.default.moveItem(at: item, to: dest)
                         }
                     }
                     try? FileManager.default.removeItem(at: nestedSpotierDir)
                     print("已修复嵌套的 Spotier 文件夹")
                 }
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
            
            // 3. 切换目录并刷新（清除旧书签，iCloud 容器路径 App 自身有权限）
            DispatchQueue.main.async {
                self.customPathBookmark = nil
                self.customPathString = targetDir.path
                self.refreshConfigs()
                // 打开 Finder 确认
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: targetDir.path)
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
        
        // 关键修复：必须在访问前请求权限
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        
        do {
            // 再次确保目录存在（防止被外部删除）
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            
            let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            let tomlFiles = items.filter { $0.pathExtension == "toml" }.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            
            DispatchQueue.main.async {
                self.configFiles = tomlFiles
            }
            return tomlFiles
        } catch {
            print("读取配置文件列表失败: \(error) 路径: \(url.path)")
            // 如果读取失败，尝试清空列表
            DispatchQueue.main.async {
                self.configFiles = []
            }
            return []
        }
    }

    func readConfigContent(_ fileURL: URL) throws -> String {
        // 如果有书签，说明是用户选定的安全域目录
        if let _ = customPathBookmark, let dirURL = currentDirectory {
            let isScoped = dirURL.startAccessingSecurityScopedResource()
            defer { if isScoped { dirURL.stopAccessingSecurityScopedResource() } }
            
            return try String(contentsOf: fileURL, encoding: .utf8)
        }
        
        // 普通路径直接读取
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}

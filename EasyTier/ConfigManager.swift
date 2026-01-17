import Foundation
import Combine
import SwiftUI
import AppKit

class ConfigManager: ObservableObject {
    static let shared = ConfigManager()
    
    @Published var configFiles: [URL] = []
    @AppStorage("custom_config_path") var customPathString: String = ""
    
    var currentDirectory: URL? {
        if customPathString.isEmpty { return nil }
        return URL(fileURLWithPath: customPathString)
    }

    func selectCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            if let url = panel.url {
                self.customPathString = url.path
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
        
        let targetDir = drive.appendingPathComponent("EasyTier")
        
        do {
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

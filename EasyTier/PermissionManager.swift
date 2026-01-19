import Foundation
import AppKit
import Combine

class PermissionManager: ObservableObject {
    static let shared = PermissionManager()
    
    @Published var isFDAGranted: Bool
    
    private init() {
        // Synchronous initial check to prevent UI flash
        let protectedPath = "/Library/Application Support/com.apple.TCC"
        var granted = false
        if let _ = try? FileManager.default.contentsOfDirectory(atPath: protectedPath) {
            granted = true
        }
        self.isFDAGranted = granted
    }
    
    func checkFullDiskAccess() {
        // 对于非沙盒应用，尝试访问 TCC 数据库是触发系统将其加入列表的最佳方式
        // 我们尝试列出这个目录，如果成功说明有权限，如果失败（Permission Denied），
        // 系统也会因为这次尝试而将 APP 自动登记到“完全磁盘访问权限”列表中。
        let protectedPath = "/Library/Application Support/com.apple.TCC"
        
        DispatchQueue.global(qos: .userInitiated).async {
            var granted = false
            if let _ = try? FileManager.default.contentsOfDirectory(atPath: protectedPath) {
                granted = true
            }
            
            DispatchQueue.main.async {
                if self.isFDAGranted != granted {
                    self.isFDAGranted = granted
                }
            }
        }
    }
    
    func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
    
    func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}

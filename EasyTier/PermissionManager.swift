import Foundation
import AppKit
import Combine

class PermissionManager: ObservableObject {
    static let shared = PermissionManager()
    
    @Published var isFDAGranted: Bool = false
    
    private init() {
        checkFullDiskAccess()
    }
    
    func checkFullDiskAccess() {
        // 对于非沙盒应用，尝试访问 TCC 数据库是触发系统将其加入列表的最佳方式
        // 我们尝试列出这个目录，如果成功说明有权限，如果失败（Permission Denied），
        // 系统也会因为这次尝试而将 APP 自动登记到“完全磁盘访问权限”列表中。
        let protectedPath = "/Library/Application Support/com.apple.TCC"
        
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: protectedPath)
            if !isFDAGranted {
                DispatchQueue.main.async { self.isFDAGranted = true }
            }
        } catch {
            if isFDAGranted {
                DispatchQueue.main.async { self.isFDAGranted = false }
            }
            // 这里虽然 catch 了错误，但“访问尝试”已经完成了，系统已经记住了 Swiftier
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

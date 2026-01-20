import Foundation
import AppKit

final class CoreService {

    static let shared = CoreService()
    
    private init() {}
    
    // MARK: - Public API
    
    func start(configPath: String, completion: @escaping (Bool) -> Void) {
        if #available(macOS 13.0, *) {
            let logLevel = UserDefaults.standard.string(forKey: "logLevel")?.lowercased() ?? "info"
            HelperManager.shared.startCore(configPath: configPath, consoleLevel: logLevel) { success, error in
                if !success {
                    print("CoreService start failed: \(error ?? "Unknown")")
                }
                completion(success)
            }
        } else {
            print("CoreService: Unsupported macOS version")
            completion(false)
        }
    }
    
    func stop(completion: @escaping (Bool) -> Void = { _ in }) {
        if #available(macOS 13.0, *) {
            HelperManager.shared.stopCore { success in
                completion(success)
            }
        } else {
            completion(true)
        }
    }
    
    /// Get core running status
    func getStatus(completion: @escaping (Bool, Int32) -> Void) {
        if #available(macOS 13.0, *) {
            HelperManager.shared.getCoreStatus { pid in
                completion(pid > 0, pid)
            }
        } else {
            completion(false, 0)
        }
    }
    
    // MARK: - Helper Management (macOS 13+)
    
    @available(macOS 13.0, *)
    func installHelper(completion: @escaping (Bool, String?) -> Void) {
        HelperManager.shared.installHelper(completion: completion)
    }
    
    @available(macOS 13.0, *)
    func uninstallHelper(completion: @escaping (Bool, String?) -> Void) {
        HelperManager.shared.uninstallHelper(completion: completion)
    }
    
    @available(macOS 13.0, *)
    var isHelperInstalled: Bool {
        return HelperManager.shared.isHelperInstalled
    }
    
    @available(macOS 13.0, *)
    var helperStatus: String {
        return HelperManager.shared.serviceStatus
    }
    
    @available(macOS 13.0, *)
    func quitHelper(completion: @escaping () -> Void) {
        HelperManager.shared.quitHelper(completion: completion)
    }
}

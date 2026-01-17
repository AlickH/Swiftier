import Foundation

/// XPC 协议：主应用与 Helper 之间的通信接口
/// 注意：此协议需要在主应用和 Helper 中保持一致
@objc(HelperProtocol)
public protocol HelperProtocol {
    
    /// 启动 easytier-core
    /// - Parameters:
    ///   - configPath: 配置文件路径
    ///   - rpcPort: RPC 监听端口
    ///   - corePath: easytier-core 可执行文件路径
    ///   - reply: 回调，返回是否成功和错误信息
    func startCore(configPath: String, rpcPort: String, corePath: String, consoleLevel: String, reply: @escaping (Bool, String?) -> Void)
    
    /// 停止 easytier-core
    /// - Parameter reply: 回调，返回是否成功
    func stopCore(reply: @escaping (Bool) -> Void)
    
    /// 获取 core 运行状态
    /// - Parameter reply: 回调，返回 PID（0 表示未运行）
    func getCoreStatus(reply: @escaping (Int32) -> Void)
    
    /// 获取 Helper 版本（用于版本检查和升级）
    /// - Parameter reply: 回调，返回版本字符串
    func getVersion(reply: @escaping (String) -> Void)
    
    /// 退出 Helper 进程
    func quitHelper(reply: @escaping (Bool) -> Void)
}

/// Helper 的 Mach 服务名称
public let kHelperMachServiceName = "com.alick.swiftier.helper"
/// Helper 的目标版本号 (Helper Protocol 版本)
public let kTargetHelperVersion = "1.1.0"

import Foundation

/// XPC 协议：主应用与 Helper 之间的通信接口
/// 注意：此协议需要在主应用和 Helper 中保持一致
/// XPC 协议：主应用与 Helper 之间的通信接口
/// 注意：此协议需要在主应用和 Helper 中保持一致
/// 客户端监听协议：Helper 主动调用此协议的方法向 App 推送数据
@objc(HelperClientListener)
public protocol HelperClientListener {
    /// 推送最新的运行信息（JSON 字符串）
    func runningInfoUpdated(_ info: String)
    
    /// 推送最新的日志行
    func logUpdated(_ lines: [String])
}

/// XPC 协议：主应用与 Helper 之间的通信接口
/// 注意：此协议需要在主应用和 Helper 中保持一致
@objc(HelperProtocol)
public protocol HelperProtocol {
    
    /// 注册客户端监听器，用于双向通信
    /// - Parameter endpoint: 客户端创建的匿名监听器端点
    func registerListener(endpoint: NSXPCListenerEndpoint)
    
    /// 启动 easytier-core
    /// - Parameters:
    ///   - configPath: 配置文件路径
    ///   - rpcPort: RPC 监听端口
    ///   - corePath: easytier-core 可执行文件路径
    ///   - reply: 回调，返回是否成功和错误信息
    func startCore(configPath: String, corePath: String, consoleLevel: String, reply: @escaping (Bool, String?) -> Void)
    
    /// 停止 easytier-core
    /// - Parameter reply: 回调，返回是否成功
    func stopCore(reply: @escaping (Bool) -> Void)
    
    /// 获取 core 运行状态
    /// - Parameter reply: 回调，返回 PID（0 表示未运行）
    func getCoreStatus(reply: @escaping (Int32) -> Void)
    
    /// 获取 Core 启动时间戳（Unix timestamp，0 表示未运行）
    func getCoreStartTime(reply: @escaping (Double) -> Void)
    
    /// 获取 Helper 版本（用于版本检查和升级）
    /// - Parameter reply: 回调，返回版本字符串
    func getVersion(reply: @escaping (String) -> Void)
    
    /// 获取最近的 JSON 事件（用于实时事件流）
    /// - Parameters:
    ///   - sinceIndex: 从哪个索引开始获取（0 表示获取所有缓存的事件）
    ///   - reply: 回调，返回 (JSON 事件数组, 下一个索引)
    func getRecentEvents(sinceIndex: Int, reply: @escaping ([String], Int) -> Void)
    
    /// 退出 Helper 进程
    func quitHelper(reply: @escaping (Bool) -> Void)
    
    /// 获取运行时信息（包含 peers、routes 等）
    /// - Parameter reply: 回调，返回 JSON 字符串（nil 表示未运行或出错）
    func getRunningInfo(reply: @escaping (String?) -> Void)
}

/// Helper 的 Mach 服务名称
public let kHelperMachServiceName = "com.alick.swiftier.helper"
/// Helper 的目标版本号 (Helper Protocol 版本) - 升级以触发自动更新
public let kTargetHelperVersion = "1.3.8"


import Foundation

enum EasyTierError: Error {
    case initializationFailed(String)
    case executionFailed(String)
}

// 封装 Rust FFI 调用
struct EasyTierCore {
    // 提取 Rust 返回的错误信息
    static func extractRustError(_ errPtr: UnsafePointer<CChar>?) -> String? {
        guard let errPtr = errPtr else { return nil }
        let message = String(cString: errPtr)
        free_string(errPtr)
        return message
    }
    
    // 初始化日志
    static func initLogger(path: String, level: String, subsystem: String) throws {
        var errPtr: UnsafePointer<CChar>? = nil
        let ret = path.withCString { pathPtr in
            level.withCString { levelPtr in
                subsystem.withCString { subsystemPtr in
                    init_logger(pathPtr, levelPtr, subsystemPtr, &errPtr)
                }
            }
        }
        
        if ret != 0 {
            let msg = extractRustError(errPtr) ?? "Unknown logger error"
            throw EasyTierError.initializationFailed(msg)
        }
    }
    
    // 启动网络实例
    static func runNetworkInstance(config: String) throws {
        var errPtr: UnsafePointer<CChar>? = nil
        let ret = config.withCString { configPtr in
            run_network_instance(configPtr, &errPtr)
        }
        
        if ret != 0 {
            let msg = extractRustError(errPtr) ?? "Unknown network start error"
            throw EasyTierError.executionFailed(msg)
        }
    }
    
    // 停止网络实例
    static func stopNetworkInstance() {
        stop_network_instance()
    }
    
    // 设置 TUN 文件描述符
    static func setTunFd(_ fd: Int32) throws {
        var errPtr: UnsafePointer<CChar>? = nil
        let ret = set_tun_fd(fd, &errPtr)
        
        if ret != 0 {
            let msg = extractRustError(errPtr) ?? "Unknown tun fd error"
            throw EasyTierError.executionFailed(msg)
        }
    }
    
    // 注册停止回调
    static func registerStopCallback(_ callback: @convention(c) () -> Void) throws {
        var errPtr: UnsafePointer<CChar>? = nil
        let ret = register_stop_callback(callback, &errPtr)
        if ret != 0 {
            let msg = extractRustError(errPtr) ?? "Failed to register stop callback"
            throw EasyTierError.initializationFailed(msg)
        }
    }
    
    // 获取最新错误信息
    static func getLatestErrorMessage() -> String? {
        var msgPtr: UnsafePointer<CChar>? = nil
        var errPtr: UnsafePointer<CChar>? = nil
        
        let ret = get_latest_error_msg(&msgPtr, &errPtr)
        
        if ret == 0, let ptr = msgPtr {
            let msg = String(cString: ptr)
            free_string(ptr)
            return msg
        }
        
        if let ptr = errPtr {
            free_string(ptr)
        }
        return nil
    }
    
    // 注册运行信息变化回调
    static func registerRunningInfoCallback(_ callback: @convention(c) () -> Void) throws {
        var errPtr: UnsafePointer<CChar>? = nil
        let ret = register_running_info_callback(callback, &errPtr)
        if ret != 0 {
            let msg = extractRustError(errPtr) ?? "Failed to register running info callback"
            throw EasyTierError.initializationFailed(msg)
        }
    }
    
    // 获取运行状态 JSON
    static func getRunningInfo() -> String? {
        var jsonPtr: UnsafePointer<CChar>? = nil
        var errPtr: UnsafePointer<CChar>? = nil
        
        let ret = get_running_info(&jsonPtr, &errPtr)
        
        if ret == 0, let ptr = jsonPtr {
            let json = String(cString: ptr)
            free_string(ptr)
            return json
        }
        
        if let ptr = errPtr {
            free_string(ptr)
        }
        return nil
    }
}

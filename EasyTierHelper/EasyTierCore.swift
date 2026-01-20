import Foundation

@_silgen_name("init_logger")
func c_init_logger(_ path: UnsafePointer<CChar>, _ level: UnsafePointer<CChar>, _ err_msg: UnsafeMutablePointer<UnsafePointer<CChar>?>) -> Int32

@_silgen_name("run_network_instance")
func c_run_network_instance(_ cfg_str: UnsafePointer<CChar>, _ err_msg: UnsafeMutablePointer<UnsafePointer<CChar>?>) -> Int32

@_silgen_name("stop_network_instance")
func c_stop_network_instance() -> Int32

@_silgen_name("get_running_info")
func c_get_running_info(_ json: UnsafeMutablePointer<UnsafePointer<CChar>?>, _ err_msg: UnsafeMutablePointer<UnsafePointer<CChar>?>) -> Int32

@_silgen_name("free_string")
func c_free_string(_ s: UnsafePointer<CChar>)

class EasyTierCore {
    static let shared = EasyTierCore()
    
    private init() {}
    
    /// Initialize logger
    func initLogger(path: String, level: String) {
        var errMsg: UnsafePointer<CChar>? = nil
        let _ = path.withCString { pPath in
            level.withCString { pLevel in
                c_init_logger(pPath, pLevel, &errMsg)
            }
        }
        if let err = errMsg {
            print("[EasyTierCore] Logger Init Error: \(String(cString: err))")
            c_free_string(err)
        }
    }
    
    /// Start Network Instance
    func startNetwork(config: String) throws {
        print("[EasyTierCore] Starting network...")
        var errMsg: UnsafePointer<CChar>? = nil
        let res = config.withCString { ptr in
            c_run_network_instance(ptr, &errMsg)
        }
        
        if res != 0 {
            let msg: String
            if let err = errMsg {
                msg = String(cString: err)
                c_free_string(err)
            } else {
                msg = "Unknown error"
            }
            throw NSError(domain: "EasyTierCore", code: Int(res), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        print("[EasyTierCore] Network started successfully.")
    }
    
    /// Stop Network Instance
    func stopNetwork() {
        print("[EasyTierCore] Stopping network...")
        let _ = c_stop_network_instance()
    }
    
    /// Get Running Info (JSON)
    func getRunningInfo() -> String? {
        var json: UnsafePointer<CChar>? = nil
        var errMsg: UnsafePointer<CChar>? = nil
        let res = c_get_running_info(&json, &errMsg)
        
        if res == 0, let j = json {
            let str = String(cString: j)
            c_free_string(j)
            return str
        }
        
        if let e = errMsg {
            c_free_string(e)
        }
        
        return nil
    }
}

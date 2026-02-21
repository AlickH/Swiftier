import Foundation
import NetworkExtension
import os

// MARK: - TUN File Descriptor Discovery

func tunnelFileDescriptor() -> Int32? {
    let CTLIOCGINFO_VALUE: UInt = 0xc0644e03
    logger.warning("tunnelFileDescriptor() use fallback")
    var ctlInfo = ctl_info()
    withUnsafeMutablePointer(to: &ctlInfo.ctl_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) {
            _ = strcpy($0, "com.apple.net.utun_control")
        }
    }
    for fd: Int32 in 0...1024 {
        var addr = sockaddr_ctl()
        var ret: Int32 = -1
        var len = socklen_t(MemoryLayout.size(ofValue: addr))
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                ret = getpeername(fd, $0, &len)
            }
        }
        if ret != 0 || addr.sc_family != AF_SYSTEM {
            continue
        }
        if ctlInfo.ctl_id == 0 {
            ret = ioctl(fd, CTLIOCGINFO_VALUE, &ctlInfo)
            if ret != 0 {
                continue
            }
        }
        if addr.sc_id == ctlInfo.ctl_id {
            let dupFd = dup(fd)
            logger.info("tunnelFileDescriptor() found fd: \(fd, privacy: .public), dup to: \(dupFd, privacy: .public)")
            return dupFd
        }
    }
    return nil
}

func initRustLogger(level: LogLevel) {
    guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: APP_GROUP_ID) else {
        logger.error("initRustLogger() failed: App Group container not found")
        return
    }
    let path = containerURL.appendingPathComponent(LOG_FILENAME).path
    logger.info("initRustLogger() write to: \(path, privacy: .public)")
    
    var errPtr: UnsafePointer<CChar>? = nil
    let ret = path.withCString { pathPtr in
        level.rawValue.withCString { levelPtr in
            loggerSubsystem.withCString { subsystemPtr in
                return init_logger(pathPtr, levelPtr, subsystemPtr, &errPtr)
            }
        }
    }
    if ret != 0 {
        let err = extractRustString(errPtr)
        logger.error("initRustLogger() failed to init: \(err ?? "Unknown", privacy: .public)")
    }
}

func extractRustString(_ strPtr: UnsafePointer<CChar>?) -> String? {
    guard let strPtr else {
        logger.error("extractRustString(): nullptr")
        return nil
    }
    let str = String(cString: strPtr)
    free_string(strPtr)
    return str
}

func fetchRunningInfo() -> RunningInfo? {
    var infoPtr: UnsafePointer<CChar>? = nil
    var errPtr: UnsafePointer<CChar>? = nil
    if get_running_info(&infoPtr, &errPtr) == 0, let info = extractRustString(infoPtr) {
        guard let data = info.data(using: .utf8) else {
            logger.error("fetchRunningInfo() invalid utf8 data")
            return nil
        }
        do {
            let decoded = try JSONDecoder().decode(RunningInfo.self, from: data)
            logger.info("fetchRunningInfo() routes: \(decoded.routes.count)")
            return decoded
        } catch {
            logger.error("fetchRunningInfo() json decode failed: \(error, privacy: .public)")
        }
    } else if let err = extractRustString(errPtr) {
        logger.error("fetchRunningInfo() failed: \(err, privacy: .public)")
    }
    return nil
}

//
//  main.swift
//  SwiftierHelper
//
//  Created by A. Lick on 2026-01-15 22:14.
//

import Foundation

// MARK: - Constants

/// Helper 的 Mach 服务名称
let kHelperMachServiceName = "com.alick.swiftier.helper"

/// Helper 版本号（用于检测是否需要升级）
let kHelperVersion = "1.3.5"

// MARK: - Logger

let logPath = "/var/log/swiftier-helper.log"

func setupLogging() {
    // Log Rotation: Check if size > 10MB only at startup
    // This avoids conflict with Rust core which keeps the file handle open
    if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
       let size = attrs[.size] as? UInt64, size > 10 * 1024 * 1024 {
        let bakPath = logPath + ".bak"
        try? FileManager.default.removeItem(atPath: bakPath)
        try? FileManager.default.moveItem(atPath: logPath, toPath: bakPath)
    }
}

func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] [Helper] \(message)\n"
    
    // Also print to stdout for debugging
    // print(line, terminator: "")
    
    let url = URL(fileURLWithPath: logPath)
    
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
    } else {
        // File doesn't exist, create it
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Core Process Manager

class CoreProcessManager {
    static let shared = CoreProcessManager()
    
    private var isVPNActive = false
    private var coreStartTime: Date?
    private let stateLock = NSLock()
    
    // Event buffer for JSON events from Core
    private var eventBuffer: [String] = []
    private var eventIndex: Int = 0 
    private let eventLock = NSLock()
    private let maxEventBufferSize = 500
    
    // Log monitoring
    private var logFileHandle: FileHandle?
    private var lastLogOffset: UInt64 = 0
    private var logMonitorTimer: Timer?
    
    private var loggerInitialized = false
    
    private init() {
         // Setup Log Monitor
         startLogMonitor()
    }
    
    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isVPNActive
    }
    
    var pid: Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        // Return Helper's PID if VPN is active, else 0
        return isVPNActive ? ProcessInfo.processInfo.processIdentifier : 0
    }
    
    var startTime: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isVPNActive, let start = coreStartTime else { return 0 }
        return start.timeIntervalSince1970
    }
    
    // MARK: - Event Handling
    
    func getEvents(sinceIndex: Int) -> ([String], Int) {
        eventLock.lock()
        defer { eventLock.unlock() }
        
        let bufferStartIndex = max(0, eventIndex - eventBuffer.count)
        
        if sinceIndex >= eventIndex { return ([], eventIndex) }
        
        if sinceIndex < bufferStartIndex {
            return (eventBuffer, eventIndex)
        }
        
        let offsetInBuffer = sinceIndex - bufferStartIndex
        let events = Array(eventBuffer.dropFirst(offsetInBuffer))
        return (events, eventIndex)
    }
    
    private func addEvent(_ jsonLine: String) {
        eventLock.lock()
        defer { eventLock.unlock() }
        
        eventBuffer.append(jsonLine)
        eventIndex += 1
        
        if eventBuffer.count > maxEventBufferSize {
            eventBuffer.removeFirst(eventBuffer.count - maxEventBufferSize)
        }
    }
    
    private func clearEvents() {
        eventLock.lock()
        defer { eventLock.unlock() }
        eventBuffer.removeAll()
    }
    
    // MARK: - Core Control
    
    private func initRustLogger(level: String) {
        if !loggerInitialized {
            // Rust will write to the same log file as we do
            // To avoid corruption, usually you'd want independent files, but O_APPEND often works.
            // Or better: Let Rust write to its own file? No, we unified it.
            // Let's assume Rust uses the file path we give.
            EasyTierCore.shared.initLogger(path: logPath, level: level)
            loggerInitialized = true
        }
    }

    func start(configPath: String, consoleLevel: String) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        // 1. Setup Logger
        initRustLogger(level: consoleLevel)
        clearEvents()
        
        // 2. Read Config
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw NSError(domain: "HelperError", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Config file not found: \(configPath)"])
        }
        let configStr = try String(contentsOfFile: configPath, encoding: .utf8)
        
        // 3. Start Core
        if isVPNActive {
             EasyTierCore.shared.stopNetwork()
        }
        
        try EasyTierCore.shared.startNetwork(config: configStr)
        
        isVPNActive = true
        coreStartTime = Date()
        log("Started EasyTier Core via FFI with config: \(configPath)")
    }
    
    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        if !isVPNActive { return }
        
        EasyTierCore.shared.stopNetwork()
        isVPNActive = false
        coreStartTime = nil
        log("Stopped EasyTier Core")
    }
    
    // MARK: - Log Monitoring
    
    private func startLogMonitor() {
        // Poll log file every 0.5s for new content
        // We can't use RunLoop.main in init easily? Yes we can if called after main loop starts or on bg queue.
        // But main.swift runs RunLoop.main.
        
        DispatchQueue.main.async {
             self.logMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                 self?.checkLogFile()
             }
        }
    }
    
    private func checkLogFile() {
        // If handle closed or not open, try open
        if logFileHandle == nil {
            if FileManager.default.fileExists(atPath: logPath) {
                do {
                    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: logPath))
                    // Seek to end initially? Or start? 
                    // If we just started Helper, we might want to see recent logs.
                    // But usually we only care about new logs generated by Core.
                    // Let's seek to current end if it's the first time we open it AND we assume old logs are old.
                    // But if we just restarted Helper, maybe we want to catch up?
                    // Let's rely on `lastLogOffset`.
                    if lastLogOffset == 0 {
                        // First time open, maybe seek to end to avoid parsing GBs of logs?
                        // But then we miss startup logs if Rust started fast.
                        // Tradeoff: seek to end.
                        // Wait, if Rust started before we opened handle?
                        // Let's seek to end.
                        lastLogOffset = handle.seekToEndOfFile()
                    } else {
                        handle.seek(toFileOffset: lastLogOffset)
                    }
                    logFileHandle = handle
                } catch {
                    return
                }
            } else {
                return
            }
        }
        
        guard let handle = logFileHandle else { return }
        
        // Read new data
        let data = handle.readDataToEndOfFile()
        if !data.isEmpty {
            lastLogOffset += UInt64(data.count)
            if let str = String(data: data, encoding: .utf8) {
                processLogChunk(str)
            }
        }
    }
    
    private func processLogChunk(_ chunk: String) {
        // Split by newline
        // Note: Simple split might break lines if chunk ends in middle of line.
        // Ideally we should buffer incomplete lines.
        // For MVP, assuming line buffering or lucky chunking.
        // (A robust solution tracks a residual buffer)
        
        let lines = chunk.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            
            // Check for JSON event
            if trimmed.contains("\"event\"") && trimmed.contains("{") {
                // Determine if it's a JSON line. 
                // Rust tracing logs might look like: "TIMESTAMP INFO ... {event...}"
                // We need to extract the JSON part if it's mixed.
                // But easytier-core usually prints pure JSON lines for events if configured?
                // `register_running_info_callback` logic suggests we pull state.
                // But here we rely on log.
                // If the log is JSON structured (e.g. `tracing_subscriber::fmt::format::Json`), then the whole line is JSON.
                // Our `init_logger` uses `OsLogger` (os_log) and a File writer with `tracing_subscriber::fmt::layer()`.
                // Default fmt is not JSON. So we see text logs.
                // Unless EasyTier prints events to stdout explicitly via `println!`.
                
                // If raw JSON is inside the log message:
                // [2023-...] INFO ... msg={"event":...}
                
                // Try to find first '{'
                if let firstBrace = trimmed.firstIndex(of: "{") {
                    let jsonPart = String(trimmed[firstBrace...])
                    addEvent(jsonPart)
                }
            }
        }
    }
}

// MARK: - XPC Protocol

/// XPC 协议：主应用与 Helper 之间的通信接口
@objc(HelperProtocol)
protocol HelperProtocol {
    func startCore(configPath: String, corePath: String, consoleLevel: String, reply: @escaping (Bool, String?) -> Void)
    func stopCore(reply: @escaping (Bool) -> Void)
    func getCoreStatus(reply: @escaping (Int32) -> Void)
    func getCoreStartTime(reply: @escaping (Double) -> Void)
    func getVersion(reply: @escaping (String) -> Void)
    func getRecentEvents(sinceIndex: Int, reply: @escaping ([String], Int) -> Void)
    func quitHelper(reply: @escaping (Bool) -> Void)
    func getRunningInfo(reply: @escaping (String?) -> Void)
}

// MARK: - XPC Service Delegate

class HelperDelegate: NSObject, NSXPCListenerDelegate, HelperProtocol {
    
    // ... (listener implementation unchanged)
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        log("New XPC connection from PID: \(newConnection.processIdentifier)")
        
        // 验证连接来源（可选：添加代码签名验证）
        
        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = self
        
        newConnection.invalidationHandler = {
            log("XPC connection invalidated")
        }
        
        newConnection.interruptionHandler = {
            log("XPC connection interrupted")
        }
        
        newConnection.resume()
        return true
    }
    
    // MARK: - HelperProtocol Implementation
    
    func startCore(configPath: String, corePath: String, consoleLevel: String, reply: @escaping (Bool, String?) -> Void) {
        log("XPC: startCore(configPath: \(configPath), consoleLevel: \(consoleLevel))")
        
        do {
            try CoreProcessManager.shared.start(configPath: configPath, consoleLevel: consoleLevel)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }
    
    func stopCore(reply: @escaping (Bool) -> Void) {
        log("Received stopCore request")
        CoreProcessManager.shared.stop()
        reply(true)
    }
    
    func getCoreStatus(reply: @escaping (Int32) -> Void) {
        let pid = CoreProcessManager.shared.pid
        log("getCoreStatus: PID = \(pid)")
        reply(pid)
    }
    
    func getCoreStartTime(reply: @escaping (Double) -> Void) {
        let startTime = CoreProcessManager.shared.startTime
        log("getCoreStartTime: \(startTime)")
        reply(startTime)
    }
    
    func getVersion(reply: @escaping (String) -> Void) {
        reply(kHelperVersion)
    }
    
    func getRecentEvents(sinceIndex: Int, reply: @escaping ([String], Int) -> Void) {
        let (events, nextIndex) = CoreProcessManager.shared.getEvents(sinceIndex: sinceIndex)
        reply(events, nextIndex)
    }
    
    func quitHelper(reply: @escaping (Bool) -> Void) {
        log("Received quitHelper request. Goodbye!")
        // 先停止 core
        CoreProcessManager.shared.stop()
        reply(true)
        
        // 延迟一秒退出，确保 reply 能发回去
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            exit(0)
        }
    }
    
    func getRunningInfo(reply: @escaping (String?) -> Void) {
        log("getRunningInfo called")
        let info = EasyTierCore.shared.getRunningInfo()
        if let info = info {
            log("getRunningInfo returned \(info.prefix(200))...")
        } else {
            log("getRunningInfo returned nil")
        }
        reply(info)
    }
}

// MARK: - Main Entry Point

setupLogging()
log("=== Swiftier Helper Starting ===")
log("Version: \(kHelperVersion)")
log("Running as UID: \(getuid())")

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: kHelperMachServiceName)
listener.delegate = delegate
listener.resume()

log("XPC Listener started on: \(kHelperMachServiceName)")

// 保持运行
RunLoop.main.run()

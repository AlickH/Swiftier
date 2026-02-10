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
let kHelperVersion = "1.3.9"

// MARK: - Logger

let logPath = "/var/log/swiftier-helper.log"

func setupLogging() {
    // 强制截断日志，开始全新的 Helper 生命周期
    let url = URL(fileURLWithPath: logPath)
    try? "".write(to: url, atomically: true, encoding: .utf8)
    
    // 同时清空处理器缓存
    LogProcessor.shared.clear()
    
    log("Helper process started, log truncated.")
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
        
        // 1. Reset logs and events for THIS core session
        let url = URL(fileURLWithPath: logPath)
        try? "".write(to: url, atomically: true, encoding: .utf8)
        lastLogOffset = 0
        if let handle = logFileHandle {
            try? handle.seek(toOffset: 0)
        }
        
        LogProcessor.shared.clear()
        
        // 2. Setup Logger
        initRustLogger(level: consoleLevel)
        clearEvents() // Clear the old String buffer too
        
        // 3. Read Config
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw NSError(domain: "HelperError", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Config file not found: \(configPath)"])
        }
        let configStr = try String(contentsOfFile: configPath, encoding: .utf8)
        
        // 4. Start Core
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
        
        // Use a background queue to call stopNetwork, as FFI calls might block
        DispatchQueue.global(qos: .userInitiated).async {
            log("Calling stopNetwork FFI...")
            EasyTierCore.shared.stopNetwork()
            log("stopNetwork FFI returned.")
        }
        
        isVPNActive = false
        coreStartTime = nil
        log("EasyTier Core stop initiated")
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
        let lines = chunk.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            
            // Feed to LogProcessor for sophisticated parsing and highlighting
            LogProcessor.shared.processRawLine(trimmed)
            
            // Legacy internal event tracking (optional, kept for now if you revert)
            // if trimmed.contains("\"event\"") && trimmed.contains("{") { ... }
        }
    }
}

// MARK: - XPC Protocol

/// 客户端监听协议：Helper 主动调用此协议的方法向 App 推送数据
@objc(HelperClientListener)
protocol HelperClientListener {
    func runningInfoUpdated(_ info: String)
    func logUpdated(_ lines: [String])
}

/// XPC 协议：主应用与 Helper 之间的通信接口
@objc(HelperProtocol)
protocol HelperProtocol {
    func registerListener(endpoint: NSXPCListenerEndpoint)
    func startCore(configPath: String, corePath: String, consoleLevel: String, reply: @escaping (Bool, String?) -> Void)
    func stopCore(reply: @escaping (Bool) -> Void)
    func getCoreStatus(reply: @escaping (Int32) -> Void)
    func getCoreStartTime(reply: @escaping (Double) -> Void)
    func getVersion(reply: @escaping (String) -> Void)
    func getRecentEvents(sinceIndex: Int, reply: @escaping (Data, Int) -> Void)
    func quitHelper(reply: @escaping (Bool) -> Void)
    func getRunningInfo(reply: @escaping (String?) -> Void)
}

// MARK: - XPC Service Delegate

class HelperDelegate: NSObject, NSXPCListenerDelegate, HelperProtocol {
    
    // Manage client connection
    private var clientConnection: NSXPCConnection?
    private let clientLock = NSLock()
    
    // Push Loop
    private var pushTimer: Timer?
    private var lastPushedInfo: String?
    
    // ... (listener implementation unchanged)
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        log("New XPC connection from PID: \(newConnection.processIdentifier)")
        
        // 1. Helper 提供的接口
        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = self
        
        // 2. App 侧提供的接口（用于推送数据）
        newConnection.remoteObjectInterface = NSXPCInterface(with: HelperClientListener.self)
        
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            log("XPC connection invalidated")
            self?.clientLock.lock()
            if self?.clientConnection == newConnection {
                self?.clientConnection = nil
            }
            self?.clientLock.unlock()
        }
        
        newConnection.interruptionHandler = {
            log("XPC connection interrupted")
        }
        
        // 保存连接用于推送
        clientLock.lock()
        self.clientConnection = newConnection
        clientLock.unlock()
        
        newConnection.resume()
        
        // 连接建立后启动心跳推送
        startPushLoop()
        
        return true
    }
    
    // MARK: - HelperProtocol Implementation
    
    func registerListener(endpoint: NSXPCListenerEndpoint) {
        log("registerListener called (legacy). New architecture uses direct bi-directional connection.")
    }
    
    private func startPushLoop() {
        DispatchQueue.main.async {
            // 防止重复启动定时器
            if self.pushTimer?.isValid == true { return }
            
            self.pushTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.pushUpdates()
            }
        }
    }
    
    private func pushUpdates() {
        guard let connection = clientConnection else { return }
        
        // 获取运行时信息
        let info = EasyTierCore.shared.getRunningInfo()
        
        if let info = info {
            // 通过同一个 XPC 连接将数据推回 App
            if let proxy = connection.remoteObjectProxy as? HelperClientListener {
                proxy.runningInfoUpdated(info)
            }
        }
    }
    
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
    
    func getRecentEvents(sinceIndex: Int, reply: @escaping (Data, Int) -> Void) {
        // Now delegating to LogProcessor for structured data
        let (data, nextIndex) = LogProcessor.shared.getSerializedEvents(sinceIndex: sinceIndex)
        reply(data, nextIndex)
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

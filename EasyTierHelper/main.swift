//
//  main.swift
//  EasyTierHelper
//
//  Created by A. Lick on 2026-01-15 22:14.
//

import Foundation

// MARK: - Constants

/// Helper 的 Mach 服务名称
let kHelperMachServiceName = "com.alick.swiftier.helper"

/// Helper 版本号（用于检测是否需要升级）
let kHelperVersion = "1.1.0"

// MARK: - Logger

let logPath = "/var/log/swiftier-helper.log"

func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] [Helper] \(message)\n"
    
    let url = URL(fileURLWithPath: logPath)
    
    // Log Rotation: Check if size > 10MB
    if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
       let size = attrs[.size] as? UInt64, size > 10 * 1024 * 1024 {
        let bakPath = logPath + ".bak"
        try? FileManager.default.removeItem(atPath: bakPath)
        try? FileManager.default.moveItem(atPath: logPath, toPath: bakPath)
        // File moved, next write will create new one
    }
    
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
    } else {
        // 文件不存在，创建新文件
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Core Process Manager

class CoreProcessManager {
    static let shared = CoreProcessManager()
    
    private var coreProcess: Process?
    private let processLock = NSLock()
    
    private init() {}
    
    var isRunning: Bool {
        processLock.lock()
        defer { processLock.unlock() }
        return coreProcess?.isRunning ?? false
    }
    
    var pid: Int32 {
        processLock.lock()
        defer { processLock.unlock() }
        return coreProcess?.isRunning == true ? coreProcess!.processIdentifier : 0
    }
    
    func start(corePath: String, configPath: String, rpcPort: String, consoleLevel: String) throws {
        processLock.lock()
        defer { processLock.unlock() }
        
        // 先停止已有进程
        if coreProcess?.isRunning == true {
            coreProcess?.terminate()
            coreProcess?.waitUntilExit()
        }
        
        // 验证可执行文件存在
        guard FileManager.default.fileExists(atPath: corePath) else {
            throw NSError(domain: "HelperError", code: 1, 
                         userInfo: [NSLocalizedDescriptionKey: "Core executable not found: \(corePath)"])
        }
        
        // 验证配置文件存在
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw NSError(domain: "HelperError", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Config file not found: \(configPath)"])
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: corePath)
        process.arguments = ["-c", configPath, "--rpc-portal", "127.0.0.1:\(rpcPort)", "--console-log-level", consoleLevel]
        
        // 设置输出重定向
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        
        // 异步读取输出并记录日志
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                log("Core output: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        
        // 设置进程终止处理
        process.terminationHandler = { [weak self] proc in
            log("Core process terminated with exit code: \(proc.terminationStatus)")
            self?.processLock.lock()
            self?.coreProcess = nil
            self?.processLock.unlock()
        }
        
        try process.run()
        coreProcess = process
        
        log("Started easytier-core (PID: \(process.processIdentifier)) with config: \(configPath)")
    }
    
    func stop() {
        processLock.lock()
        defer { processLock.unlock() }
        
        guard let process = coreProcess, process.isRunning else {
            log("No running core process to stop")
            return
        }
        
        process.terminate()
        
        // 给进程一些时间优雅退出
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.processLock.lock()
            defer { self?.processLock.unlock() }
            
            if self?.coreProcess?.isRunning == true {
                log("Force killing core process")
                self?.coreProcess?.interrupt()
            }
        }
        
        log("Stopped easytier-core")
    }
}

// MARK: - XPC Protocol

/// XPC 协议：主应用与 Helper 之间的通信接口
@objc(HelperProtocol)
protocol HelperProtocol {
    func startCore(configPath: String, rpcPort: String, corePath: String, consoleLevel: String, reply: @escaping (Bool, String?) -> Void)
    func stopCore(reply: @escaping (Bool) -> Void)
    func getCoreStatus(reply: @escaping (Int32) -> Void)
    func getVersion(reply: @escaping (String) -> Void)
    // 新增：退出 Helper 自身
    func quitHelper(reply: @escaping (Bool) -> Void)
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
    
    func startCore(configPath: String, rpcPort: String, corePath: String, consoleLevel: String, reply: @escaping (Bool, String?) -> Void) {
        log("Received startCore request: config=\(configPath), port=\(rpcPort), core=\(corePath), level=\(consoleLevel)")
        
        do {
            try CoreProcessManager.shared.start(corePath: corePath, configPath: configPath, rpcPort: rpcPort, consoleLevel: consoleLevel)
            reply(true, nil)
        } catch {
            log("Failed to start core: \(error.localizedDescription)")
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
    
    func getVersion(reply: @escaping (String) -> Void) {
        reply(kHelperVersion)
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
}

// MARK: - Main Entry Point

log("=== EasyTier Helper Starting ===")
log("Version: \(kHelperVersion)")
log("Running as UID: \(getuid())")

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: kHelperMachServiceName)
listener.delegate = delegate
listener.resume()

log("XPC Listener started on: \(kHelperMachServiceName)")

// 保持运行
RunLoop.main.run()

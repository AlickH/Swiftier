import Foundation
import AppKit

struct PeerInfo: Identifiable, Equatable {
    // 使用 sessionID 加上业务字段组合成唯一 ID
    // 这样每次启动生成新 sessionID 时，ID 都会变，从而强制触发 SwiftUI 的滑动进入动画
    let sessionID: UUID
    let ipv4: String
    let hostname: String
    let cost: String
    let latency: String
    let loss: String
    let rx: String
    let tx: String
    let tunnel: String
    let nat: String
    let version: String
    
    // 扩展字段：存储完整 JSON 信息中的所有键值对
    var extraInfo: [String: String] = [:]
    
    // 便捷访问器 (基于 Rust 常见命名惯例 snake_case)
    var nodeId: String? { extraInfo["id"] } // JSON key is 'id'
    var instanceId: String? { extraInfo["instance_id"] }
    // Route info (prefixed with route_)
    var nextHopHostname: String? { extraInfo["route_next_hop_hostname"] }
    var nextHopLatency: String? { extraInfo["route_next_hop_lat"] }
    var pathLen: String? { extraInfo["route_path_len"] }
    // Add more as needed based on observation
    
    // 只要业务数据不变，SwiftUI 就不会在运行中刷新卡片视图（防止闪烁）
    var id: String { "\(sessionID.uuidString)-\(ipv4)-\(hostname)-\(tunnel)" }

    static func == (lhs: PeerInfo, rhs: PeerInfo) -> Bool {
        return lhs.ipv4 == rhs.ipv4 &&
               lhs.hostname == rhs.hostname &&
               lhs.latency == rhs.latency &&
               lhs.rx == rhs.rx &&
               lhs.tx == rhs.tx &&
               lhs.loss == rhs.loss &&
               lhs.cost == rhs.cost &&
               lhs.tunnel == rhs.tunnel &&
               lhs.nat == rhs.nat &&
               lhs.version == rhs.version &&
               lhs.extraInfo == rhs.extraInfo
    }
}

actor CliClient {
    private let rpcPort: String
    private var cachedBinaryPath: String?

    init(rpcPort: String) {
        self.rpcPort = rpcPort
    }

    /// 获取节点列表，必须传入当前运行周期的 sessionID
    func fetchPeers(sessionID: UUID) async -> [PeerInfo] {
        // 1. 尝试通过 JSON 获取完整信息 (优先)
        // 使用 -o json peer
        if let peerJson = runCLI(arguments: ["-o", "json", "peer"]),
           let parsedPeers = parseCLIJSON(peerJson, sessionID: sessionID), !parsedPeers.isEmpty {
            
            var peers = parsedPeers
            
            // 尝试获取路由信息并合并
            if let routeJson = runCLI(arguments: ["-o", "json", "route"]),
               let data = routeJson.data(using: .utf8),
               let routes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                
                var routeMap: [String: [String: Any]] = [:]
                for r in routes {
                    if let h = r["hostname"] as? String { routeMap[h] = r }
                }
                
                for i in 0..<peers.count {
                    let h = peers[i].hostname
                    if let r = routeMap[h] {
                        for (k, v) in r {
                            peers[i].extraInfo["route_" + k] = anyToString(v)
                        }
                    }
                }
            }
            return peers
        }
        
        // 2. 尝试 rpc-portal (Table)
        if let output = runCLI(arguments: ["--rpc-portal", "127.0.0.1:\(rpcPort)", "peer"]) {
            let peers = parseCLITable(output, sessionID: sessionID)
            if !peers.isEmpty { return peers }
        }

        // 3. 回退逻辑 (Table)
        if let output = runCLI(arguments: ["peer"]) {
            return parseCLITable(output, sessionID: sessionID)
        }

        return []
    }

    private func runCLI(arguments: [String]) -> String? {
        guard let cliBin = getBinaryPath(name: "easytier-cli") else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: cliBin)
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func parseCLITable(_ output: String, sessionID: UUID) -> [PeerInfo] {
        let lines = output.components(separatedBy: .newlines)
        var peers: [PeerInfo] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 过滤掉表头和空行
            guard trimmed.hasPrefix("|"), trimmed.contains("|") else { continue }
            if trimmed.localizedCaseInsensitiveContains("ipv4") || trimmed.hasPrefix("|---") { continue }

            var cols = trimmed.components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }

            // 处理表格边界切分出的多余空元素
            if !cols.isEmpty { cols.removeFirst() }
            if !cols.isEmpty { cols.removeLast() }

            // 清理不间断空格
            cols = cols.map { $0.replacingOccurrences(of: "\u{00A0}", with: " ") }
            
            // 确保表格列数足够
            guard cols.count >= 10 else { continue }

            let ipv4 = cols[0]
            let hostname = cols[1]
            let finalIPv4 = ipv4.isEmpty ? "Public Peer" : ipv4

            let peer = PeerInfo(
                sessionID: sessionID,
                ipv4: finalIPv4,
                hostname: hostname,
                cost: cols[2],
                latency: cols[3],
                loss: cols[4],
                rx: cols[5],
                tx: cols[6],
                tunnel: cols[7],
                nat: cols[8],
                version: cols[9]
            )
            peers.append(peer)
        }
        return peers
    }
    
    private func parseCLIJSON(_ jsonString: String, sessionID: UUID) -> [PeerInfo]? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        
        do {
            if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return array.compactMap { dict in
                    // Extract basic fields based on actual CLI JSON output
                    let rawIPv4 = (dict["ipv4"] as? String) ?? ""
                    let ipv4 = rawIPv4.isEmpty ? "Public Peer" : rawIPv4
                    let hostname = (dict["hostname"] as? String) ?? ""
                    let cost = anyToString(dict["cost"])
                    let latency = anyToString(dict["lat_ms"]) 
                    let loss = anyToString(dict["loss_rate"])
                    let rx = anyToString(dict["rx_bytes"])
                    let tx = anyToString(dict["tx_bytes"])
                    let tunnel = (dict["tunnel_proto"] as? String) ?? ""
                    let nat = (dict["nat_type"] as? String) ?? ""
                    let version = (dict["version"] as? String) ?? ""
                    
                    // Fallback keys check if primary guess fails
                    // ... This is tricky without schema. best effort.
                    
                    // Create basic info
                    var extra: [String: String] = [:]
                    for (k, v) in dict {
                        extra[k] = anyToString(v)
                    }
                    
                    // Refined parsing from extra if direct dict access failed or to normalize units?
                    // Table parser deals with "10 ms" strings. JSON might be raw numbers (ms, bytes).
                    // If JSON returns raw numbers, we might need to format them (e.g. bytes to KB).
                    // For now, store raw. UI might need update if format changes.
                    
                    return PeerInfo(
                        sessionID: sessionID,
                        ipv4: ipv4,
                        hostname: hostname,
                        cost: cost,
                        latency: latency,
                        loss: loss,
                        rx: rx, 
                        tx: tx,
                        tunnel: tunnel,
                        nat: nat,
                        version: version,
                        extraInfo: extra
                    )
                }
            }
        } catch {
            print("JSON Parse Error: \(error)")
        }
        return nil
    }
    
    private func anyToString(_ value: Any?) -> String {
        guard let v = value else { return "" }
        if let str = v as? String { return str }
        if let num = v as? NSNumber { return num.stringValue }
        return String(describing: v)
    }

    private func getBinaryPath(name: String) -> String? {
        if name == "easytier-cli", let cached = cachedBinaryPath {
            return cached
        }
        
        // 1. Check Application Support
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
             let customPath = appSupport.appendingPathComponent("Swiftier/bin/\(name)").path
             if FileManager.default.fileExists(atPath: customPath) {
                 if name == "easytier-cli" { cachedBinaryPath = customPath }
                 return customPath
             }
        }
        
        let bundlePath = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent(name).path
            
        if let path = bundlePath, FileManager.default.fileExists(atPath: path) {
             if name == "easytier-cli" { cachedBinaryPath = path }
             return path
        }
        
        return bundlePath
    }
}

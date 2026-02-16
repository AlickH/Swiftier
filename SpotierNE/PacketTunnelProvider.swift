import NetworkExtension
import os


let debounceInterval: TimeInterval = 0.5

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    // Hold a weak reference for C callback bridging
    private static weak var current: PacketTunnelProvider?

    
    private var lastAppliedSettings: SettingsSnapshot?
    private var needReapplySettings = false
    private var debounceWorkItem: DispatchWorkItem?
    private var parsedIPv4: String?      // from config.toml
    private var parsedSubnet: String?     // e.g. "255.255.255.0"
    private var parsedMTU: Int?
    
    // MARK: - Config Loading
    
    private func loadConfig() -> String? {
        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: APP_GROUP_ID) else {
            logger.error("无法访问 App Group 容器: \(APP_GROUP_ID)")
            return nil
        }
        let configURL = groupURL.appendingPathComponent("config.toml")
        do {
            let content = try String(contentsOf: configURL, encoding: .utf8)
            logger.info("成功从 App Group 读取配置文件")
            return content
        } catch {
            logger.error("读取配置文件失败: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Parse ipv4 and mtu from TOML config for initial network settings
    private func parseConfigHints(_ toml: String) {
        for line in toml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            
            let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let val = parts[1].replacingOccurrences(of: "\"", with: "")
            
            switch key {
            case "ipv4":
                // e.g. "10.126.126.1/24"
                let cidrParts = val.split(separator: "/")
                if cidrParts.count == 2 {
                    parsedIPv4 = String(cidrParts[0])
                    if let cidr = Int(cidrParts[1]) {
                        parsedSubnet = cidrToSubnetMask(cidr)
                    }
                }
            case "mtu":
                parsedMTU = Int(val)
            default:
                break
            }
        }
    }
    
    // MARK: - Running Info Callback
    
    private func registerRunningInfoCallback() {
        let callback: @convention(c) () -> Void = {
            PacketTunnelProvider.current?.handleRunningInfoChanged()
        }
        do {
            try EasyTierCore.registerRunningInfoCallback(callback)
            logger.info("已注册 running info callback")
        } catch {
            logger.error("注册 running info callback 失败: \(error)")
        }
    }
    
    private func handleRunningInfoChanged() {
        logger.info("Running info 已变化，触发网络设置更新")
        enqueueSettingsUpdate()
    }
    
    // MARK: - Stop Callback
    
    private func registerStopCallback() {
        let callback: @convention(c) () -> Void = {
            PacketTunnelProvider.current?.handleRustStop()
        }
        do {
            try EasyTierCore.registerStopCallback(callback)
            logger.info("已注册 stop callback")
        } catch {
            logger.error("注册 stop callback 失败: \(error)")
        }
    }
    
    private func handleRustStop() {
        let msg = EasyTierCore.getLatestErrorMessage() ?? "Unknown"
        logger.error("Rust Core 已停止: \(msg)")
        
        // Save error to App Group for host app
        if let defaults = UserDefaults(suiteName: APP_GROUP_ID) {
            defaults.set(msg, forKey: "TunnelLastError")
            defaults.synchronize()
        }
        
        DispatchQueue.main.async {
            self.cancelTunnelWithError(NSError(
                domain: "SwiftierNE", code: 2,
                userInfo: [NSLocalizedDescriptionKey: msg]
            ))
        }
    }
    
    // MARK: - Dynamic Network Settings
    
    private func enqueueSettingsUpdate() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            
            // Cancel previous pending debounce to batch rapid changes
            self.debounceWorkItem?.cancel()
            
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.reasserting {
                    logger.info("设置更新已在进行中，排队等待")
                    self.needReapplySettings = true
                    return
                }
                self.applyNetworkSettings { error in
                    if let error {
                        logger.error("设置更新失败: \(error)")
                    }
                }
            }
            self.debounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
        }
    }
    
    private func applyNetworkSettings(_ completion: @escaping (Error?) -> Void) {
        guard !reasserting else {
            completion(NSError(domain: "SwiftierNE", code: 3, userInfo: [NSLocalizedDescriptionKey: "still in progress"]))
            return
        }
        reasserting = true
        
        needReapplySettings = false
        let settings = buildSettings()
        let newSnapshot = SettingsSnapshot(from: settings)
        
        let wrappedCompletion: (Error?) -> Void = { error in
            DispatchQueue.main.async {
                if error == nil {
                    self.lastAppliedSettings = newSnapshot
                }
                completion(error)
                self.reasserting = false
                if self.needReapplySettings {
                    self.needReapplySettings = false
                    self.applyNetworkSettings(completion)
                }
            }
        }
        
        // Skip if settings haven't changed
        if newSnapshot == lastAppliedSettings {
            logger.info("网络设置未变化，跳过更新")
            wrappedCompletion(nil)
            return
        }
        
        let needSetTunFd = shouldUpdateTunFd(old: lastAppliedSettings, new: newSnapshot)
        logger.info("应用网络设置, needTunFd=\(needSetTunFd)")
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else {
                wrappedCompletion(error)
                return
            }
            if let error {
                logger.error("setTunnelNetworkSettings 失败: \(error)")
                wrappedCompletion(error)
                return
            }
            
            // Pass TUN fd to Rust Core
            if needSetTunFd {
                // Prefer packetFlow fd (the correct NE-created utun)
                let packetFlowFd = self.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32
                let scanFd = self.findTunnelFileDescriptor()
                let tunFd = packetFlowFd ?? scanFd
                
                logger.error("TUN fd 诊断: packetFlow=\(packetFlowFd.map { String($0) } ?? "nil", privacy: .public), scan=\(scanFd.map { String($0) } ?? "nil", privacy: .public), chosen=\(tunFd.map { String($0) } ?? "nil", privacy: .public)")
                
                if let fd = tunFd {
                    do {
                        try EasyTierCore.setTunFd(fd)
                        logger.error("TUN fd 已设置: \(fd, privacy: .public)")
                    } catch {
                        logger.error("设置 TUN fd 失败: \(error, privacy: .public)")
                        wrappedCompletion(error)
                        return
                    }
                } else {
                    logger.error("无法获取 TUN fd（packetFlow 和 scan 均失败）")
                }
            }
            
            logger.info("网络设置已应用")
            wrappedCompletion(nil)
        }
    }
    
    /// Build NEPacketTunnelNetworkSettings dynamically from get_running_info()
    private func buildSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let runningInfo = fetchRunningInfo()
        
        // Determine IPv4 address: prefer running info, fallback to config
        let ipv4Address: String
        let subnetMask: String

        
        if let info = runningInfo,
           let nodeIp = info.myNodeInfo?.virtualIPv4 {
            ipv4Address = nodeIp.address.description

            subnetMask = cidrToSubnetMask(nodeIp.networkLength) ?? "255.255.255.0"
        } else if let configIp = parsedIPv4, let configMask = parsedSubnet {
            ipv4Address = configIp
            subnetMask = configMask
        } else {
            logger.warning("无 IPv4 地址可用，返回空设置")
            return settings
        }
        
        let ipv4Settings = NEIPv4Settings(addresses: [ipv4Address], subnetMasks: [subnetMask])
        
        // Build routes from running info
        var routes: [NEIPv4Route] = []
        
        if let info = runningInfo {
            // Add routes from peer proxy CIDRs
            for route in info.routes {
                for cidrStr in route.proxyCIDRs {
                    if let parsed = parseCIDR(cidrStr) {
                        routes.append(NEIPv4Route(
                            destinationAddress: parsed.address,
                            subnetMask: parsed.mask
                        ))
                    }
                }
            }
            
            // Add the virtual network route
            if let nodeIp = info.myNodeInfo?.virtualIPv4 {
                let networkAddr = maskedAddress(nodeIp.address, networkLength: nodeIp.networkLength)
                let netMask = cidrToSubnetMask(nodeIp.networkLength) ?? "255.255.255.0"
                routes.append(NEIPv4Route(destinationAddress: networkAddr, subnetMask: netMask))
            }
        }
        
        // Fallback: if no routes from running info, use config subnet
        if routes.isEmpty {
            if let configIp = parsedIPv4, let configMask = parsedSubnet {
                // Route only the virtual subnet, not all traffic
                let networkAddr = maskedAddressFromStrings(configIp, mask: configMask)
                routes.append(NEIPv4Route(destinationAddress: networkAddr, subnetMask: configMask))
            } else {
                // Last resort: still don't route all traffic to avoid breaking connectivity
                routes.append(NEIPv4Route(destinationAddress: ipv4Address, subnetMask: "255.255.255.255"))
            }
        }
        
        ipv4Settings.includedRoutes = routes
        settings.ipv4Settings = ipv4Settings
        settings.mtu = NSNumber(value: parsedMTU ?? 1380)
        
        return settings
    }
    
    // MARK: - Tunnel Lifecycle
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        logger.info("正在启动 VPN Tunnel...")
        PacketTunnelProvider.current = self
        
        // 1. 读取配置
        guard let configToml = loadConfig() else {
            let error = NSError(domain: "SwiftierNE", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取 VPN 配置"])
            completionHandler(error)
            return
        }
        
        // 2. 解析配置中的 IPv4 和 MTU 信息
        parseConfigHints(configToml)
        
        // 3. 初始化 Logger（从 App Group 读取用户设置的日志等级）
        let savedLevel: LogLevel = {
            if let defaults = UserDefaults(suiteName: APP_GROUP_ID),
               let raw = defaults.string(forKey: "logLevel"),
               let level = LogLevel(rawValue: raw.lowercased()) {
                return level
            }
            return .info
        }()
        initRustLogger(level: savedLevel)
        
        // 4. 启动 Core（macOS cfg 已 patch，不会自动创建 TUN，通过 set_tun_fd 传入）
        do {
            try EasyTierCore.runNetworkInstance(config: configToml)
            logger.info("EasyTier Core 启动成功")
        } catch {
            logger.error("EasyTier Core 启动失败: \(error)")
            completionHandler(error)
            return
        }
        
        // 5. 注册回调
        registerStopCallback()
        registerRunningInfoCallback()
        
        // 6. 应用网络设置并传入 TUN fd
        applyNetworkSettings(completionHandler)
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("正在停止 VPN Tunnel, reason: \(reason.rawValue)")
        EasyTierCore.stopNetworkInstance()
        PacketTunnelProvider.current = nil
        completionHandler()
    }
    
    // MARK: - App IPC (handleAppMessage)
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let handler = completionHandler else { return }
        
        // Command: "running_info" -> return get_running_info JSON
        if let command = String(data: messageData, encoding: .utf8) {
            switch command {
            case "running_info":
                if let json = EasyTierCore.getRunningInfo(),
                   let data = json.data(using: .utf8) {
                    handler(data)
                } else {
                    handler(nil)
                }
            default:
                handler(nil)
            }
        } else {
            handler(nil)
        }
    }
    
    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }
    
    override func wake() {
        // Trigger a settings refresh on wake
        enqueueSettingsUpdate()
    }
    
    // MARK: - Helpers
    
    private func fetchRunningInfo() -> RunningInfo? {
        guard let json = EasyTierCore.getRunningInfo(),
              let data = json.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(RunningInfo.self, from: data)
        } catch {
            logger.error("解析 running info 失败: \(error)")
            return nil
        }
    }
    
    /// Find the utun file descriptor by scanning open FDs
    /// Delegates to the shared implementation in TunnelHelper.swift
    private func findTunnelFileDescriptor() -> Int32? {
        logger.info("尝试通过 FD 扫描查找 TUN 接口")
        return tunnelFileDescriptor()
    }
    
    private func shouldUpdateTunFd(old: SettingsSnapshot?, new: SettingsSnapshot) -> Bool {
        // 只要有 IP 地址就应该设置 TUN fd
        guard new.hasIPAddresses else {
            logger.info("shouldUpdateTunFd: new snapshot has no IP addresses")
            return false
        }
        // 每次 setTunnelNetworkSettings 成功后都应该重新设置 TUN fd，
        // 因为系统可能会重建 utun 接口，导致之前的 fd 失效。
        // 只有当设置完全相同时（会被上层 skip），才不需要更新。
        logger.info("shouldUpdateTunFd: hasIP=true, always update tun fd")
        return true
    }
}

// MARK: - Helper Models



// MARK: - Settings Snapshot (for change detection)

struct SettingsSnapshot: Equatable {
    var ipv4Addresses: [String]
    var ipv4SubnetMasks: [String]
    var routes: [(String, String)]  // (destination, mask)
    var mtu: Int?
    
    var hasIPAddresses: Bool {
        !ipv4Addresses.isEmpty && ipv4Addresses.first?.isEmpty == false
    }
    
    init(from settings: NEPacketTunnelNetworkSettings) {
        ipv4Addresses = settings.ipv4Settings?.addresses ?? []
        ipv4SubnetMasks = settings.ipv4Settings?.subnetMasks ?? []
        routes = settings.ipv4Settings?.includedRoutes?.map {
            ($0.destinationAddress, $0.destinationSubnetMask)
        } ?? []
        mtu = settings.mtu?.intValue
    }
    
    static func == (lhs: SettingsSnapshot, rhs: SettingsSnapshot) -> Bool {
        lhs.ipv4Addresses == rhs.ipv4Addresses &&
        lhs.ipv4SubnetMasks == rhs.ipv4SubnetMasks &&
        lhs.routes.count == rhs.routes.count &&
        zip(lhs.routes, rhs.routes).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 } &&
        lhs.mtu == rhs.mtu
    }
}

// MARK: - Network Utility Functions



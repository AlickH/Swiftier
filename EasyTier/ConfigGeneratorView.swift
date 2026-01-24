import SwiftUI
import AppKit

// MARK: - Configuration Models

struct PortForwardRule: Identifiable, Equatable {
    let id = UUID()
    var protocolType: String = "TCP" // TCP/UDP
    var bindIp: String = "0.0.0.0"
    var bindPort: String = ""
    var targetIp: String = "10.126.126.1"
    var targetPort: String = ""
}

struct EasyTierConfigModel: Equatable {
    var instanceName: String = Host.current().localizedName ?? "swiftier-node"
    var instanceId: String = UUID().uuidString.lowercased()
    
    mutating func regenerateInstanceId() {
        instanceId = UUID().uuidString.lowercased()
    }
    
    var dhcp: Bool = true
    var ipv4: String = "10.126.126.4"
    var cidr: String = "24"
    var mtu: Int = 1380
    
    var networkName: String = "easytier"
    var networkSecret: String = ""
    
    var peerMode: PeerMode = .publicServer
    var manualPeers: [String] = [
        "tcp://public.easytier.top:11010"
    ]
    
    var listeners: [String] = [
        "tcp://0.0.0.0:11010",
        "udp://0.0.0.0:11010", 
        "wg://0.0.0.0:11011"
    ]
    
    var portForwards: [PortForwardRule] = []
    
    // Flags
    var latencyFirst: Bool = false
    var enableIPv6: Bool = true
    var enableEncryption: Bool = true
    var useSmoltcp: Bool = false
    var noTun: Bool = false
    // var privateMode: Bool = false // Removed as not clearly in latest screenshot or redundant
    var disableP2P: Bool = false
    var disableUdpHolePunching: Bool = false
    var enableExitNode: Bool = false
    var enableKcpProxy: Bool = false
    var enableQuicProxy: Bool = false
    var rpcPort: Int = 15888
    
    // New Flags from Screenshot
    var disableKcpInput: Bool = false
    var disableQuicInput: Bool = false
    var disableUdp: Bool = false
    var relayAllPeerRpc: Bool = false
    var disableEntryNode: Bool = false // 禁用入口节点
    var enableSocks5: Bool = false // SOCKS5
    var socks5Port: Int = 1080
    var foreignNetworkWhitelist: String = "" // 网络白名单? Toggle only for now
    
    // MARK: - Advanced Features (Missing from previous version)
    
    // VPN Portal
    var enableVpnPortal: Bool = false
    var vpnPortalClientCidr: String = "10.14.14.0/24" // Default
    var vpnPortalListenPort: Int = 22022
    
    // Proxy Networks (Subnet Proxy)
    struct ProxySubnet: Identifiable, Equatable {
        let id = UUID()
        var cidr: String = "192.168.1.0/24"
    }
    var proxySubnets: [ProxySubnet] = []
    
    // Manual Routes
    var enableManualRoutes: Bool = false
    var manualRoutes: [String] = []
    
    // Exit Nodes (Use explicit nodes)
    var exitNodes: [String] = []
    
    // Relay Network Whitelist
    var enableRelayNetworkWhitelist: Bool = false
    var relayNetworkWhitelist: [String] = []
    
    // Listener Mappings
    var mappedListeners: [String] = []
    
    // DNS
    var enableOverrideDns: Bool = false
    var overrideDns: [String] = []
    
    // Flags
    var bindDevice: Bool = false
    var multiThread: Bool = true
    var proxyForwardBySystem: Bool = false
    var disableSymHolePunching: Bool = false
    var enableMagicDns: Bool = false
    var enablePrivateMode: Bool = false
    var onlyP2P: Bool = false
}
    
extension EasyTierConfigModel {
    var vpnPortalIpBinding: String {
        get {
            let parts = vpnPortalClientCidr.split(separator: "/")
            return parts.count > 0 ? String(parts[0]) : ""
        }
        set {
            let cidr = vpnPortalCidrBinding
            vpnPortalClientCidr = "\(newValue)/\(cidr)"
        }
    }
    
    var vpnPortalCidrBinding: String {
        get {
            let parts = vpnPortalClientCidr.split(separator: "/")
            return parts.count > 1 ? String(parts[1]) : "24"
        }
        set {
            let ip = vpnPortalIpBinding
            vpnPortalClientCidr = "\(ip)/\(newValue)"
        }
    }
}

enum PeerMode: String, CaseIterable, Identifiable {
    case publicServer = "公共服务器"
    case manual = "手动"
    case standalone = "独立"
    var id: String { rawValue }
    
    var localizedTitle: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}
// MARK: - Draft Manager
class ConfigDraftManager {
    static let shared = ConfigDraftManager()
    
    // Support multiple drafts for different files
    // Key nil represents "New Config" draft
    private var drafts: [URL?: EasyTierConfigModel] = [:]
    
    func getDraft(for url: URL?) -> EasyTierConfigModel? {
        return drafts[url]
    }
    
    func saveDraft(for url: URL?, model: EasyTierConfigModel) {
        drafts[url] = model
    }
    
    func clearDraft(for url: URL? = nil) {
        // If specific URL provided, clear that. 
        // NOTE: Our previous usage was clearDraft() implying current.
        // We should update call sites to pass URL or handle "current" context if needed.
        // But wait, clearDraft is called after save. We know the URL there.
        // So we should change the signature to require URL or context.
        // However, to keep it simple and compatible with the single-draft thought process:
        // Actually, let's just make it clear specific draft.
        if let url = url {
            drafts.removeValue(forKey: url)
        } else {
             // If nil passed, clear "New Config" draft (key nil)
             drafts.removeValue(forKey: nil)
        }
    }
    
    // Helper to clear all if needed (optional)
    func clearAll() {
        drafts.removeAll()
    }
}

enum ConfigScreen {
    case main
    case advanced
    case portForwarding
}

struct ConfigGeneratorView: View {
    @Binding var isPresented: Bool
    var editingFileURL: URL? = nil // 支持传入文件进行编辑
    var onSave: () -> Void
    
    @State private var model = EasyTierConfigModel()
    
    // Track if we've already loaded to avoid resetting user edits
    @State private var hasLoadedInitially = false
    @State private var lastLoadedURL: URL? = nil
    
    // Alerts
    @State private var saveMessage: String?
    @State private var showSaveError = false
    
    // Navigation
    @State private var path: [ConfigScreen] = [.main]
    
    var body: some View {
        ZStack {
            mainView
                .zIndex(0)
                .allowsHitTesting(path.last == .main)
            
            if let screen = path.last, screen != .main {
                
                Group {
                    switch screen {
                    case .advanced: advancedView
                    case .portForwarding: portForwardingView
                    default: EmptyView()
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .zIndex(1)
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.default, value: path.last)
        .animation(.default, value: path.last)
        .animation(.default, value: path.last)
        .onAppear {
            // Initial load (e.g. preview or first render)
            // If already visible, don't force reset unless necessary logic dictates
            if isPresented && !hasLoadedInitially {
               loadContent(forceReset: true)
               hasLoadedInitially = true
            }
        }
        .onChange(of: editingFileURL) { _ in
             // File changed underneath (unlikely in modal) but handle it
             loadContent(forceReset: true)
        }
        .onChange(of: isPresented) { presented in
            if presented {
                // Fresh session: Always clear old drafts and load from disk/new
                loadContent(forceReset: true)
            }
        }
        // Save draft on every change
        .onChange(of: model) { newModel in
            if isPresented {
                ConfigDraftManager.shared.saveDraft(for: editingFileURL, model: newModel)
            }
        }
    }
    
    private func loadContent(forceReset: Bool = false) {
        if forceReset {
            ConfigDraftManager.shared.clearDraft(for: editingFileURL)
            self.lastLoadedURL = nil // Force reload check
        }
    
        // 1. Try to restore draft (memory cache)
        if !forceReset, let draft = ConfigDraftManager.shared.getDraft(for: editingFileURL) {
            // Only restore if our current model is different
            if model != draft {
                self.model = draft
            }
            self.lastLoadedURL = editingFileURL
            return
        }
        
        // 2. If no draft, load from file if needed
        // We load if:
        // - We haven't loaded this URL yet (lastLoadedURL != editingFileURL)
        // - Or editingFileURL is nil (New Config) AND we want to ensure fresh start if no draft
        if editingFileURL != lastLoadedURL {
            if editingFileURL == nil {
                 // New file without draft -> Reset
                 model = EasyTierConfigModel()
            } else {
                loadFromFile()
            }
            lastLoadedURL = editingFileURL
        }
    }
    
    // MARK: - Advanced View
    var advancedView: some View {
        VStack(spacing: 0) {
            header(title: LocalizedStringKey("高级设置"), leftBtn: LocalizedStringKey("返回"), leftRole: .cancel) { pop() }
            
            Form {
                // 1. 通用 (General)
                SwiftUI.Section(header: Text(LocalizedStringKey("通用"))) {
                    HStack {
                        Text(LocalizedStringKey("主机名称"))
                        TextField(LocalizedStringKey("默认"), text: $model.instanceName)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.plain)
                            .labelsHidden()
                            .textContentType(.none)
                            .disableAutocorrection(true)
                    }
                    
                    HStack {
                        Text("实例 ID")
                            .fixedSize()
                        Spacer()
                        Text(model.instanceId)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .monospaced()
                        
                        Button {
                            model.regenerateInstanceId()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.plain)
                        .help("重新生成 UUID")
                    }
                    
                    HStack {
                        Text("MTU")
                        Spacer()
                        TextField("默认", value: Binding<Int?>(
                            get: { self.model.mtu == 1380 ? nil : self.model.mtu },
                            set: { self.model.mtu = $0 ?? 1380 }
                        ), format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .textContentType(.none)
                    }
                }
                
                // 2. 覆盖 DNS (Override DNS)
                SwiftUI.Section(header: Text("覆盖 DNS"), footer: Text("覆盖系统 DNS。如果也同时启用了魔法 DNS，需要手动添加。")) {
                    Toggle("启用", isOn: $model.enableOverrideDns)
                    if model.enableOverrideDns {
                        ForEach($model.overrideDns.indices, id: \.self) { i in
                            HStack {
                                Text("地址")
                                Spacer()
                                IPv4Field(ip: Binding(
                                    get: {
                                        if i < model.overrideDns.count { return model.overrideDns[i] }
                                        return ""
                                    },
                                    set: { val in
                                        if i < model.overrideDns.count { model.overrideDns[i] = val }
                                    }
                                ))
                                .fixedSize()
                                
                                Button {
                                    if model.overrideDns.indices.contains(i) {
                                        model.overrideDns.remove(at: i)
                                    }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        
                        Button {
                            model.overrideDns.append("")
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("添加 DNS")
                            }
                            .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                // 3. 代理网段 (Proxy CIDR)
                SwiftUI.Section(header: Text(LocalizedStringKey("代理网段"))) {
                    ForEach($model.proxySubnets) { $subnet in
                        HStack {
                            Text(LocalizedStringKey("代理："))
                                .foregroundColor(.secondary)
                            Spacer()
                            IPv4CidrField(ip: Binding(
                                get: { subnet.cidr.split(separator: "/").first.map(String.init) ?? "" },
                                set: { 
                                   let oldCidr = subnet.cidr.split(separator: "/").last.map(String.init) ?? "0"
                                   subnet.cidr = "\($0)/\(oldCidr)"
                                }
                            ), cidr: Binding(
                                get: { subnet.cidr.split(separator: "/").last.map(String.init) ?? "" },
                                set: {
                                   let oldIp = subnet.cidr.split(separator: "/").first.map(String.init) ?? ""
                                   subnet.cidr = "\(oldIp)/\($0)"
                                }
                            ))
                            .fixedSize()
                            
                            Button {
                                if let idx = model.proxySubnets.firstIndex(of: subnet) {
                                    model.proxySubnets.remove(at: idx)
                                }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button { model.proxySubnets.append(EasyTierConfigModel.ProxySubnet(cidr: "0.0.0.0/0")) } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("添加代理网段")
                        }
                        .foregroundColor(.blue)
                    }.buttonStyle(.plain)
                }
                
                // 4. VPN 门户配置 (VPN Portal)
                SwiftUI.Section("VPN 门户配置") {
                    Toggle("启用", isOn: $model.enableVpnPortal)
                    if model.enableVpnPortal {
                        HStack {
                            Text("客户端网段")
                            Spacer()
                            IPv4CidrField(ip: $model.vpnPortalIpBinding, cidr: $model.vpnPortalCidrBinding)
                                .fixedSize()
                        }
                        HStack {
                            Text("监听端口")
                            Spacer()
                            TextField("22022", value: $model.vpnPortalListenPort, format: .number.grouping(.never))
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                                .labelsHidden()
                                .textContentType(.none)
                        }
                    }
                }
                
                // 5. 监听地址 (Listening Addresses)
                // 5. 监听地址 (Listening Addresses)
                SwiftUI.Section("监听地址") {
                    ForEach($model.listeners.indices, id: \.self) { i in
                        HStack {
                            TextField("如：tcp://1.1.1.1:11010", text: Binding(
                                get: { model.listeners[i] },
                                set: { model.listeners[i] = $0 }
                            ))
                            .textFieldStyle(.plain)
                            .labelsHidden()
                            .textContentType(.none)
                            .disableAutocorrection(true)
                            
                            Spacer()
                            
                            Button {
                                model.listeners.remove(at: i)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button { model.listeners.append("") } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("添加监听地址")
                        }
                        .foregroundColor(.blue)
                    }.buttonStyle(.plain)
                }
                
                // 6. 网络白名单 (Network Whitelist)
                SwiftUI.Section(header: Text("网络白名单"), footer: Text("仅转发白名单网络的流量，支持通配符字符串。多个网络名称间可以使用英文空格间隔。如果该参数为空，则禁用转发。默认允许所有网络。例如：* (所有网络), def* (以 def 为前缀的网络), net1 net2 (只允许 net1 和 net2)。")) {
                    Toggle("启用", isOn: $model.enableRelayNetworkWhitelist)
                    if model.enableRelayNetworkWhitelist {
                        stringListSection(list: $model.relayNetworkWhitelist, placeholder: "CIDR (e.g. 10.0.0.0/24)")
                    }
                }
                
                // 7. 自定义路由 (Custom Routes)
                SwiftUI.Section(header: Text("自定义路由"), footer: Text("手动分配路由 CIDR，将禁用子网代理和从对等节点传播的 wireguard 路由。例如：192.168.0.0/16")) {
                    Toggle("启用", isOn: $model.enableManualRoutes)
                    if model.enableManualRoutes {
                        ForEach($model.manualRoutes.indices, id: \.self) { i in
                            HStack {
                                Text("路由：")
                                    .foregroundColor(.secondary)
                                Spacer()
                                IPv4CidrField(ip: Binding(
                                    get: { model.manualRoutes[i].split(separator: "/").first.map(String.init) ?? "" },
                                    set: {
                                        let oldCidr = model.manualRoutes[i].split(separator: "/").last.map(String.init) ?? "24"
                                        model.manualRoutes[i] = "\($0)/\(oldCidr)"
                                    }
                                ), cidr: Binding(
                                    get: { model.manualRoutes[i].split(separator: "/").last.map(String.init) ?? "24" },
                                    set: {
                                        let oldIp = model.manualRoutes[i].split(separator: "/").first.map(String.init) ?? ""
                                        model.manualRoutes[i] = "\(oldIp)/\($0)"
                                    }
                                ))
                                .fixedSize()
                                
                                Button {
                                    model.manualRoutes.remove(at: i)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Button { model.manualRoutes.append("0.0.0.0/0") } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("添加路由")
                            }
                            .foregroundColor(.blue)
                        }.buttonStyle(.plain)
                    }
                }
                
                // 8. SOCKS5 服务器 (SOCKS5 Server)
                SwiftUI.Section(header: Text(LocalizedStringKey("SOCKS5 服务器")), footer: Text(LocalizedStringKey("开启 SOCKS5 代理功能，Surge 等外部程序可通过此端口连接 EasyTier 网络。"))) {
                    Toggle(LocalizedStringKey("启用"), isOn: $model.enableSocks5)
                    if model.enableSocks5 {
                        HStack {
                            Text(LocalizedStringKey("监听端口"))
                            Spacer()
                            TextField("", value: $model.socks5Port, format: .number.grouping(.never))
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                                .textContentType(.none)
                        }
                    }
                }
                
                // 9. 出口节点列表 (Exit Nodes)
                SwiftUI.Section(header: Text(LocalizedStringKey("出口节点列表")), footer: Text(LocalizedStringKey("转发所有流量的出口节点，虚拟 IPv4 地址，优先级由列表顺序决定。"))) {
                    ForEach($model.exitNodes.indices, id: \.self) { i in
                        HStack {
                            Text(LocalizedStringKey("节点："))
                                .foregroundColor(.secondary)
                            Spacer()
                            IPv4Field(ip: Binding(
                                get: { model.exitNodes[i] },
                                set: { model.exitNodes[i] = $0 }
                            ))
                            .fixedSize()
                            
                            Button {
                                model.exitNodes.remove(at: i)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button { model.exitNodes.append("") } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text(LocalizedStringKey("添加出口节点"))
                        }
                        .foregroundColor(.blue)
                    }.buttonStyle(.plain)
                }
                
                // 10. 监听映射 (Listener Mapping)
                SwiftUI.Section(header: Text(LocalizedStringKey("监听映射")), footer: Text(LocalizedStringKey("手动指定监听器的公网地址，其他节点可以使用该地址连接到本节点。例如：tcp://123.123.123.123:11223，可以指定多个。"))) {
                    stringListSection(list: $model.mappedListeners, placeholder: "URI (e.g. tcp://...)")
                }
                
                // 11. 功能开关 (Feature Toggles)
                SwiftUI.Section(header: Text(LocalizedStringKey("功能开关"))) {
                    toggleRow("延迟优先模式", "忽略中转跳数，选择总延迟最低的路径。", isOn: $model.latencyFirst)
                    toggleRow("使用用户态协议栈", "使用用户态 TCP/IP 协议栈，避免操作系统防火墙问题导致无法子网代理 / KCP 代理。", isOn: $model.useSmoltcp)
                    
                    toggleRow("禁用 IPv6", "禁用此节点的 IPv6 功能，仅使用 IPv4 进行网络通信。", isOn: Binding(
                        get: { !self.model.enableIPv6 },
                        set: { self.model.enableIPv6 = !$0 }
                    ))
                    
                    toggleRow("启用 KCP 代理", "将 TCP 流量转为 KCP 流量，降低传输延迟，提升传输速度。", isOn: $model.enableKcpProxy)
                    toggleRow("禁用 KCP 输入", "禁用 KCP 入站流量，其他开启 KCP 代理的节点仍然使用 TCP 连接到本节点。", isOn: $model.disableKcpInput)
                    toggleRow("启用 QUIC 代理", "将 TCP 流量转为 QUIC 流量，降低传输延迟，提升传输速度。", isOn: $model.enableQuicProxy)
                    toggleRow("禁用 QUIC 输入", "禁用 QUIC 入站流量，其他开启 QUIC 代理的节点仍然使用 TCP 连接到本节点。", isOn: $model.disableQuicInput)
                    
                    toggleRow("禁用 P2P", "禁用 P2P 模式，所有流量通过手动指定的服务器中转。", isOn: $model.disableP2P)
                    toggleRow("仅 P2P", "仅与已经建立 P2P 连接的对等节点通信，不通过其他节点中转。", isOn: $model.onlyP2P)
                    
                    toggleRow("仅使用物理网卡", "仅使用物理网卡，避免 EasyTier 通过其他虚拟网建立连接。", isOn: $model.bindDevice)
                    toggleRow("无 TUN 模式", "不使用 TUN 网卡，适合无管理员权限时使用。本节点仅允许被访问。访问其他节点需要使用 SOCKS5。", isOn: $model.noTun)
                    
                    toggleRow("启用出口节点", "允许此节点成为出口节点。", isOn: $model.enableExitNode)
                    
                    toggleRow("转发 RPC 包", "允许转发所有对等节点的 RPC 数据包，即使对等节点不在转发网络白名单中。这可以帮助白名单外网络中的对等节点建立 P2P 连接。", isOn: $model.relayAllPeerRpc)
                    
                    toggleRow("启用多线程", "使用多线程运行时。", isOn: $model.multiThread)
                    toggleRow("系统转发", "通过系统内核转发子网代理数据包，禁用内置 NAT。", isOn: $model.proxyForwardBySystem)
                    
                    toggleRow("禁用加密", "禁用对等节点通信的加密，默认为 false，必须与对等节点相同。", isOn: Binding(
                        get: { !self.model.enableEncryption },
                        set: { self.model.enableEncryption = !$0 }
                    ))
                    
                    toggleRow("禁用 UDP 打洞", "禁用 UDP 打洞功能。", isOn: $model.disableUdpHolePunching)
                    toggleRow("禁用对称 NAT 打洞", "禁用对标 NAT 的打洞 (生日攻击)，将对称 NAT 视为锥形 NAT 处理。", isOn: $model.disableSymHolePunching)
                    
                    toggleRow("启用 Magic DNS", "启用魔法 DNS，允许通过 EasyTier 的 DNS 服务器访问其他节点的虚拟 IPv4 地址，例如：node1.et.net。", isOn: $model.enableMagicDns)
                    toggleRow("启用私有模式", "启用私有模式，则不允许使用了与本网络不同的网络名称和密码的节点通过本节点进行握手或中转。", isOn: $model.enablePrivateMode)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
    
    // Helper for List Sections
    private func stringListSection(list: Binding<[String]>, placeholder: String) -> some View {
        Group {
            ForEach(list.wrappedValue.indices, id: \.self) { i in
                HStack {
                    TextField(placeholder, text: Binding(
                        get: {
                            if i < list.wrappedValue.count { return list.wrappedValue[i] }
                            return ""
                        },
                        set: {
                            if i < list.wrappedValue.count { list.wrappedValue[i] = $0 }
                        }
                    ))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .textContentType(.none)
                    .disableAutocorrection(true)
                    
                    Spacer()
                    
                    Button {
                        if list.wrappedValue.indices.contains(i) {
                            list.wrappedValue.remove(at: i)
                        }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button { list.wrappedValue.append("") } label: {
                Label(LocalizedStringKey("添加"), systemImage: "plus.circle.fill").foregroundColor(.blue)
            }.buttonStyle(.plain)
        }
    }
    
    private func toggleRow(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
    
    // 安全绑定：防止删除操作导致的越界崩溃
    private func safePeerBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                if index >= 0 && index < model.manualPeers.count {
                    return model.manualPeers[index]
                }
                return ""
            },
            set: {
                if index >= 0 && index < model.manualPeers.count {
                    model.manualPeers[index] = $0
                }
            }
        )
    }
    
    // MARK: - Main View
    var mainView: some View {
        VStack(spacing: 0) {
            header(title: LocalizedStringKey("配置生成器"), leftBtn: LocalizedStringKey("取消"), leftRole: .destructive, rightBtn: LocalizedStringKey("生成")) {
                // Clear draft on cancel so next open reads from disk
                ConfigDraftManager.shared.clearDraft(for: editingFileURL)
                withAnimation { isPresented = false }
            } rightAction: {
                generateAndSave()
            }
            
            Form {
                // Section 1: Virtual IPv4
                Section(header: Text(LocalizedStringKey("虚拟 IPv4 地址"))) {
                    Toggle(LocalizedStringKey("DHCP"), isOn: $model.dhcp)
                    
                    if !model.dhcp {
                        HStack(spacing: 0) {
                            Text(LocalizedStringKey("地址"))
                            Spacer()
                            IPv4CidrField(ip: $model.ipv4, cidr: $model.cidr)
                                .fixedSize() // 关键：使用固有尺寸，防止被拉伸，确保 Spacer 能将其推至最右
                        }
                    }
                }
                
                // Section 2: Network & Peers (Merged as per screenshot)
                Section(header: Text(LocalizedStringKey("网络"))) {
                    HStack {
                        Text(LocalizedStringKey("名称"))
                        TextField("easytier", text: $model.networkName)
                            .multilineTextAlignment(.trailing)
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                            .textContentType(.none)
                            .disableAutocorrection(true)
                    }
                    
                    HStack {
                        Text(LocalizedStringKey("密码"))
                        TextField(LocalizedStringKey("选填"), text: $model.networkSecret)
                            .multilineTextAlignment(.trailing)
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                            .textContentType(.none)
                            .disableAutocorrection(true)
                    }
                    
                    Picker(LocalizedStringKey("节点模式"), selection: $model.peerMode) {
                        ForEach(PeerMode.allCases) { mode in
                            Text(mode.localizedTitle).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 4)
                    
                    // Inline Peers List (Image 2 style)
                    if model.peerMode == .manual {
                        ForEach(model.manualPeers.indices, id: \.self) { i in
                            HStack {
                                TextField("tcp://...", text: safePeerBinding(at: i))
                                    .textFieldStyle(.plain)
                                    .labelsHidden()
                                    .textContentType(.none)
                                    .disableAutocorrection(true)
                                
                                Spacer()
                                
                                Button {
                                    if model.manualPeers.indices.contains(i) {
                                        model.manualPeers.remove(at: i)
                                    }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        
                        Button {
                            model.manualPeers.append("tcp://")
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text(LocalizedStringKey("添加节点"))
                            }
                            .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                        
                    } else if model.peerMode == .publicServer {
                        HStack {
                            Text(LocalizedStringKey("服务器"))
                            Spacer()
                            Text("tcp://public.easytier.top:11010")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                }
                
                // Section 3: Navigation Entries
                Section {
                    Button { push(.advanced) } label: {
                        HStack {
                            Text(LocalizedStringKey("高级设置"))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .contentShape(Rectangle()) // Make entire row clickable
                    }
                    .buttonStyle(.plain)
                    
                    Button { push(.portForwarding) } label: {
                        HStack {
                            Text(LocalizedStringKey("端口转发"))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .contentShape(Rectangle()) // Make entire row clickable
                    }
                    .buttonStyle(.plain)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Port Forwarding (Image 1)
    var portForwardingView: some View {
        VStack(spacing: 0) {
            header(title: LocalizedStringKey("端口转发"), leftBtn: LocalizedStringKey("返回"), leftRole: .cancel) { pop() }
            
            Form {
                ForEach($model.portForwards) { $rule in
                    Section {
                        VStack(spacing: 12) {
                            // Protocol Row
                            HStack {
                                Text(LocalizedStringKey("协议"))
                                Spacer()
                                Picker("", selection: $rule.protocolType) {
                                    Text("TCP").tag("TCP")
                                    Text("UDP").tag("UDP")
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 120)
                            }
                            
                            Divider()
                            
                            // Bind Row
                            HStack {
                                Text(LocalizedStringKey("绑定地址"))
                                Spacer()
                                IPv4Field(ip: $rule.bindIp)
                                    .fixedSize()
                                Text(":")
                                TextField("0", text: $rule.bindPort)
                                    .frame(width: 50)
                            }
                            .textFieldStyle(.plain)
                            .labelsHidden()
                            
                            // Arrow
                            HStack {
                                Spacer()
                                Image(systemName: "arrow.down")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(LocalizedStringKey("转发到"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            
                            // Target Row
                            HStack {
                                Text(LocalizedStringKey("目标地址"))
                                Spacer()
                                IPv4Field(ip: $rule.targetIp)
                                    .fixedSize()
                                Text(":")
                                TextField("0", text: $rule.targetPort)
                                    .frame(width: 50)
                            }
                            .textFieldStyle(.plain)
                            .labelsHidden()
                        }
                        .padding(.vertical, 4)
                    } header: {
                        HStack {
                            Spacer()
                            Button("删除") {
                                if let idx = model.portForwards.firstIndex(of: rule) {
                                    model.portForwards.remove(at: idx)
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.red)
                            .buttonStyle(.plain)
                        }
                    }
                }
                
                Section {
                    Button {
                        model.portForwards.append(PortForwardRule())
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text(LocalizedStringKey("添加端口转发"))
                        }
                        .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
    
    
    
    // MARK: - Components
    
    private func header(title: LocalizedStringKey, leftBtn: LocalizedStringKey, leftRole: ButtonRole? = .cancel, rightBtn: LocalizedStringKey? = nil, leftAction: @escaping () -> Void, rightAction: (() -> Void)? = nil) -> some View {
        UnifiedHeader(title: title) {
            Button(leftBtn, role: leftRole, action: leftAction)
                .buttonStyle(.bordered)
        } right: {
            if let rightBtn = rightBtn, let rightAction = rightAction {
                Button(rightBtn, action: rightAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.networkName.isEmpty)
            } else {
                Button(leftBtn) {}.buttonStyle(.bordered).hidden()
            }
        }
    }
    
    // MARK: - Logic
    
    private func push(_ screen: ConfigScreen) {
        // No animation block here, the state change triggers body animation
        path.append(screen)
    }
    
    private func pop() {
        _ = path.popLast()
    }
    
    private func generateAndSave() {
        let fileURL: URL
        if let editing = editingFileURL {
            fileURL = editing
        } else {
            // Should not happen as we pass URL for new files too in ContentView, 
            // but just in case:
            guard let cur = ConfigManager.shared.currentDirectory else { return }
            let name = model.instanceName.isEmpty ? "easytier.toml" : "\(model.instanceName).toml"
            fileURL = cur.appendingPathComponent(name)
        }
        
        // Prepare peers based on mode
        var peersToSave = model.manualPeers
        if model.peerMode == .publicServer { peersToSave = ["tcp://public.easytier.top:11010"] }
        else if model.peerMode == .standalone { peersToSave = [] }
        
        let content = generateTOML(peers: peersToSave)
        
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            
            // Clear draft on successful save, so next open reads from file (which is now same as draft)
            ConfigDraftManager.shared.clearDraft(for: editingFileURL)
            
            onSave()
            isPresented = false
        } catch {
            saveMessage = "保存失败: \(error.localizedDescription)"
            showSaveError = true
        }
    }
    
    private func loadFromFile() {
        guard let url = editingFileURL else { return }
        guard let content = try? String(contentsOf: url) else { return }
        self.model = parseTOML(content)
    }
    
    private func parseTOML(_ content: String) -> EasyTierConfigModel {
        var m = EasyTierConfigModel()
        let lines = content.components(separatedBy: .newlines)
        var currentSection = ""
        
        m.manualPeers = []
        m.listeners = []
        m.mappedListeners = []
        m.relayNetworkWhitelist = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            
            if trimmed.hasPrefix("[") {
                if trimmed.hasPrefix("[[") {
                    currentSection = String(trimmed.dropFirst(2).dropLast(2))
                    if currentSection == "proxy_network" { m.proxySubnets.append(EasyTierConfigModel.ProxySubnet()) }
                    if currentSection == "port_forward" { m.portForwards.append(PortForwardRule()) }
                } else {
                    currentSection = String(trimmed.dropFirst(1).dropLast(1))
                    if currentSection == "vpn_portal_config" { m.enableVpnPortal = true }
                }
                continue
            }
            
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count != 2 { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            var val = parts[1].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") { val = String(val.dropFirst().dropLast()) }
            
            // Root & Sections
            if currentSection == "" || currentSection == "network_identity" || currentSection == "flags" {
                switch key {
                case "instance_name": m.instanceName = val
                case "instance_id": m.instanceId = val
                case "ipv4":
                    let c = val.split(separator: "/")
                    if c.count == 2 { m.ipv4 = String(c[0]); m.cidr = String(c[1]) }
                case "dhcp": m.dhcp = (val == "true")
                case "mtu": m.mtu = Int(val) ?? 1380
                case "network_name": m.networkName = val
                case "network_secret": m.networkSecret = val
                case "listeners":
                    if val.hasPrefix("[") && val.hasSuffix("]") {
                        let inner = val.dropFirst().dropLast()
                        m.listeners = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "") }
                    }
                case "mapped_listeners":
                    if val.hasPrefix("[") && val.hasSuffix("]") {
                        let inner = val.dropFirst().dropLast()
                        m.mappedListeners = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "") }
                    }
                case "socks5_proxy":
                    m.enableSocks5 = true
                    if let portStr = val.split(separator: ":").last, let p = Int(portStr) {
                        m.socks5Port = p
                    }
                case "exit_nodes":
                    if val.hasPrefix("[") && val.hasSuffix("]") {
                        let inner = val.dropFirst().dropLast()
                        m.exitNodes = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "") }
                    }
                case "routes":
                    m.enableManualRoutes = true
                    if val.hasPrefix("[") && val.hasSuffix("]") {
                        let inner = val.dropFirst().dropLast()
                        m.manualRoutes = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "") }
                    }
                    
                    // Flags
                case "latency_first": m.latencyFirst = (val == "true")
                case "disable_ipv6": m.enableIPv6 = (val != "true")
                case "disable_encryption": m.enableEncryption = (val != "true")
                case "use_smoltcp": m.useSmoltcp = (val == "true")
                case "no_tun": m.noTun = (val == "true")
                case "disable_p2p": m.disableP2P = (val == "true")
                case "p2p_only": m.onlyP2P = (val == "true")
                case "disable_udp_hole_punching": m.disableUdpHolePunching = (val == "true")
                case "enable_exit_node": m.enableExitNode = (val == "true")
                case "bind_device": m.bindDevice = (val == "true")
                case "enable_kcp_proxy": m.enableKcpProxy = (val == "true")
                case "disable_kcp_input": m.disableKcpInput = (val == "true")
                case "enable_quic_proxy": m.enableQuicProxy = (val == "true")
                case "disable_quic_input": m.disableQuicInput = (val == "true")
                case "relay_all_peer_rpc": m.relayAllPeerRpc = (val == "true")
                    
                case "multi_thread": m.multiThread = (val == "true")
                case "proxy_forward_by_system": m.proxyForwardBySystem = (val == "true")
                case "disable_sym_hole_punching": m.disableSymHolePunching = (val == "true")
                case "enable_magic_dns": m.enableMagicDns = (val == "true")
                case "enable_private_mode": m.enablePrivateMode = (val == "true")
                    
                case "relay_network_whitelist":
                    m.enableRelayNetworkWhitelist = true
                    m.relayNetworkWhitelist = val.replacingOccurrences(of: "\"", with: "").components(separatedBy: " ").filter{!$0.isEmpty}
                    
                default: break
                }
            } else if currentSection == "peer" {
                if key == "uri" { m.manualPeers.append(val); m.peerMode = .manual }
            } else if currentSection == "vpn_portal_config" {
                if key == "client_cidr" { m.vpnPortalClientCidr = val }
                if key == "wireguard_listen" {
                    let p = val.split(separator: ":").last
                    if let p = p, let post = Int(p) { m.vpnPortalListenPort = post }
                }
            } else if currentSection == "proxy_network" {
                if !m.proxySubnets.isEmpty {
                    var last = m.proxySubnets.removeLast()
                    if key == "cidr" { last.cidr = val }
                    m.proxySubnets.append(last)
                }
            } else if currentSection == "port_forward" {
                if !m.portForwards.isEmpty {
                    var last = m.portForwards.removeLast()
                    if key == "proto" { last.protocolType = val.uppercased() }
                    if key == "bind_addr" {
                        let parts = val.split(separator: ":")
                        if parts.count >= 2 {
                            last.bindPort = String(parts.last!)
                            last.bindIp = parts.dropLast().joined(separator: ":")
                        }
                    }
                    if key == "dst_addr" {
                        let parts = val.split(separator: ":")
                        if parts.count >= 2 {
                            last.targetPort = String(parts.last!)
                            last.targetIp = parts.dropLast().joined(separator: ":")
                        }
                    }
                    m.portForwards.append(last)
                }
            }
        }
        if m.listeners.isEmpty { m.listeners = ["tcp://0.0.0.0:11010", "udp://0.0.0.0:11010", "wg://0.0.0.0:11011"] }
        return m
    }
    
    private func generateTOML(peers: [String]) -> String {
        var toml = """
        instance_name = "\(model.instanceName)"
        instance_id = "\(model.instanceId)"
        dhcp = \(model.dhcp)
        """
        // Listeners
        if !model.listeners.isEmpty {
            let lList = model.listeners.filter{!$0.isEmpty}.map { "\"\($0)\"" }.joined(separator: ", ")
            toml += "\nlisteners = [\(lList)]"
        }
        
        // Mapped Listeners
        if !model.mappedListeners.isEmpty {
            let mlList = model.mappedListeners.filter{!$0.isEmpty}.map { "\"\($0)\"" }.joined(separator: ", ")
            toml += "\nmapped_listeners = [\(mlList)]"
        }
        
        if !model.dhcp && !model.ipv4.isEmpty {
            // FIX: Key should be 'ipv4', not 'ipv4_cidr'
            toml += "\nipv4 = \"\(model.ipv4)/\(model.cidr)\""
        }
        
        if model.enableSocks5 {
            toml += "\nsocks5_proxy = \"socks5://0.0.0.0:\(model.socks5Port)\""
        }
        
        // Exit Nodes
        if !model.exitNodes.isEmpty {
            let exits = model.exitNodes.filter{!$0.isEmpty}.map { "\"\($0)\"" }.joined(separator: ", ")
            if !exits.isEmpty {
                toml += "\nexit_nodes = [\(exits)]"
            }
        }
        
        // Manual Routes
        if model.enableManualRoutes && !model.manualRoutes.isEmpty {
            let rts = model.manualRoutes.filter{!$0.isEmpty}.map { "\"\($0)\"" }.joined(separator: ", ")
            if !rts.isEmpty {
                toml += "\nroutes = [\(rts)]"
            }
        }
        toml += """
        
        [network_identity]
        network_name = "\(model.networkName)"
        network_secret = "\(model.networkSecret)"
        """
        for peer in peers {
            if !peer.isEmpty {
                toml += "\n\n[[peer]]\nuri = \"\(peer)\""
            }
        }
        
        
        
        // Flags
        var flags = ""
        flags += "\nmtu = \(model.mtu)"
        
        if model.latencyFirst { flags += "\nlatency_first = true" }
        // Logic inversion for disable flags (default false means enabled)
        if !model.enableIPv6 { flags += "\ndisable_ipv6 = true" }
        if !model.enableEncryption { flags += "\ndisable_encryption = true" }
        
        if model.useSmoltcp { flags += "\nuse_smoltcp = true" }
        if model.noTun { flags += "\nno_tun = true" }
        if model.disableP2P { flags += "\ndisable_p2p = true" }
        if model.onlyP2P { flags += "\np2p_only = true" }
        
        if model.disableUdpHolePunching { flags += "\ndisable_udp_hole_punching = true" }
        if model.enableExitNode { flags += "\nenable_exit_node = true" }
        
        if model.enableKcpProxy { flags += "\nenable_kcp_proxy = true" }
        if model.disableKcpInput { flags += "\ndisable_kcp_input = true" }
        if model.enableQuicProxy { flags += "\nenable_quic_proxy = true" }
        if model.disableQuicInput { flags += "\ndisable_quic_input = true" }
        
        if model.relayAllPeerRpc { flags += "\nrelay_all_peer_rpc = true" }
        
        // New Flags
        if model.bindDevice { flags += "\nbind_device = true" }
        if !model.multiThread { flags += "\nmulti_thread = false" } // Default true?
        // Wait, current Model says `multiThread: Bool = true`.
        // If default is true, we write false if model is false.
        // If user wants to FORCE turn it on (if core default is false), we write true.
        // Let's assume default is false in Core (to be safe) or simply write it if true.
        // iOS: `init() { multiThread = true }`. So default is true.
        // So we write `multi_thread = true` if it is true, or `multi_thread = false` if false?
        // Let's write it if it deviates from a "False" default? Or write explicit?
        // Let's stick to "Write if True" for safety unless we know strict defaults.
        // Actually, if iOS defaults to true, and user toggles it off, we must write `multi_thread = false`.
        // But if user keeps it true, and core default is false, we must write `multi_thread = true`.
        // Suggestion: Write `multi_thread = true` since model defaults to true.
        if model.multiThread { flags += "\nmulti_thread = true" }
        
        if model.proxyForwardBySystem { flags += "\nproxy_forward_by_system = true" }
        if model.disableSymHolePunching { flags += "\ndisable_sym_hole_punching = true" }
        if model.enableMagicDns { flags += "\nenable_magic_dns = true" }
        if model.enablePrivateMode { flags += "\nenable_private_mode = true" }
        
        if model.enableRelayNetworkWhitelist && !model.relayNetworkWhitelist.isEmpty {
            let wl = model.relayNetworkWhitelist.joined(separator: " ")
            flags += "\nrelay_network_whitelist = \"\(wl)\""
        }
        
        if !flags.isEmpty {
            toml += "\n\n[flags]" + flags
        }
        
        // VPN Portal
        if model.enableVpnPortal {
            toml += """
            
            [vpn_portal_config]
            client_cidr = "\(model.vpnPortalClientCidr)"
            wireguard_listen = "0.0.0.0:\(model.vpnPortalListenPort)"
            """
        }
        
        // Proxy Networks (Subnet Proxy)
        for subnet in model.proxySubnets {
            if !subnet.cidr.isEmpty {
                toml += """
                
                [[proxy_network]]
                cidr = "\(subnet.cidr)"
                """
            }
        }
        
        // Port Forwarding (Port Forward)
        for rule in model.portForwards {
            if !rule.bindPort.isEmpty && !rule.targetPort.isEmpty {
                toml += """
                
                [[port_forward]]
                proto = "\(rule.protocolType.lowercased())"
                bind_addr = "\(rule.bindIp.isEmpty ? "0.0.0.0" : rule.bindIp):\(rule.bindPort)"
                dst_addr = "\(rule.targetIp):\(rule.targetPort)"
                """
            }
        }
        
        return toml
    }
    
    
    // MARK: - Native IPv4 + CIDR Input (NSViewRepresentable)
    
    struct IPv4CidrField: NSViewRepresentable {
        @Binding var ip: String
        @Binding var cidr: String
        
        func makeNSView(context: Context) -> NSStackView {
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 1
            stack.alignment = .centerY
            stack.distribution = .fill // 改回默认 fill，因为我们希望它尽量紧凑
            
            // 关键：让 StackView 尽可能收缩宽度，不要被拉伸，这样 Spacer 才能把它推到右边
            stack.setHuggingPriority(.required, for: .horizontal)
            
            // --- 4 Octets ---
            for i in 0..<4 {
                let tf = MacOctetTextField()
                tf.tag = i // 0, 1, 2, 3
                tf.placeholderString = "0"
                tf.isBordered = false
                tf.drawsBackground = false
                tf.focusRingType = .none
                tf.alignment = .center
                tf.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
                tf.delegate = context.coordinator
                tf.backspaceDelegate = context.coordinator
                
                // 增加宽度以容纳 3 位数字。固定宽度 36pt 比较稳妥且整齐。
                tf.widthAnchor.constraint(equalToConstant: 36).isActive = true
                
                stack.addArrangedSubview(tf)
                
                // Dot separator
                if i < 3 {
                    let dot = NSTextField(labelWithString: ".")
                    dot.textColor = .secondaryLabelColor
                    dot.font = NSFont.systemFont(ofSize: 13)
                    stack.addArrangedSubview(dot)
                }
            }
            
            // --- Divider ---
            let slash = NSTextField(labelWithString: " / ")
            slash.textColor = .secondaryLabelColor
            slash.font = NSFont.systemFont(ofSize: 13)
            stack.addArrangedSubview(slash)
            
            // --- CIDR Menu ---
            let popup = NSPopUpButton()
            popup.bezelStyle = .inline
            popup.isBordered = false
            popup.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            popup.addItems(withTitles: ["0", "8", "16", "24", "32"])
            popup.target = context.coordinator
            popup.action = #selector(Coordinator.cidrChanged(_:))
            
            stack.addArrangedSubview(popup)
            
            context.coordinator.stackView = stack
            return stack
        }
        
        func updateNSView(_ nsView: NSStackView, context: Context) {
            context.coordinator.updateFields(from: ip, cidr: cidr)
        }
        
        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }
        
        // MARK: - Coordinator
        class Coordinator: NSObject, NSTextFieldDelegate, OctetTextFieldDelegate {
            var parent: IPv4CidrField
            weak var stackView: NSStackView?
            var isInternalUpdate = false
            
            init(parent: IPv4CidrField) {
                self.parent = parent
            }
            
            // Sync Data -> View
            func updateFields(from ip: String, cidr: String) {
                guard !isInternalUpdate, let stack = stackView else { return }
                
                let parts = ip.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                var tfIndex = 0
                
                for view in stack.arrangedSubviews {
                    if let tf = view as? NSTextField, view is MacOctetTextField {
                        let val = tfIndex < parts.count ? parts[tfIndex] : ""
                        if tf.stringValue != val {
                            tf.stringValue = val
                        }
                        tfIndex += 1
                    } else if let popup = view as? NSPopUpButton {
                        let title = cidr.isEmpty ? "24" : cidr
                        if popup.titleOfSelectedItem != title {
                            popup.selectItem(withTitle: title)
                        }
                    }
                }
            }
            
            // Sync View -> Data
            func syncToModel() {
                guard let stack = stackView else { return }
                isInternalUpdate = true
                
                var parts = [String]()
                for view in stack.arrangedSubviews {
                    if let tf = view as? MacOctetTextField {
                        parts.append(tf.stringValue)
                    }
                }
                // 补齐 4 位，避免 "10.." 导致数组越界或格式错误
                while parts.count < 4 { parts.append("") }
                
                parent.ip = parts.joined(separator: ".")
                
                // 稍微延迟重置标志，以防 SwiftUI updateNSView 立即触发
                DispatchQueue.main.async {
                    self.isInternalUpdate = false
                }
            }
            
            @objc func cidrChanged(_ sender: NSPopUpButton) {
                parent.cidr = sender.titleOfSelectedItem ?? "24"
            }
            
            // MARK: - Field Edit Logic
            
            func controlTextDidChange(_ obj: Notification) {
                guard let tf = obj.object as? MacOctetTextField else { return }
                
                // 1. 过滤非数字
                let filtered = tf.stringValue.filter { "0123456789".contains($0) }
                if filtered != tf.stringValue {
                    tf.stringValue = filtered
                }
                
                // 2. 限制长度 3 位
                if tf.stringValue.count > 3 {
                    tf.stringValue = String(tf.stringValue.prefix(3))
                }
                
                // 3. 范围限制 0-255 (可选：如果想允许用户输入过程中暂存大于255的值，可以等 end editing 再校验。但为了体验，这里做实时截断或校验)
                if let num = Int(tf.stringValue), num > 255 {
                    tf.stringValue = "255"
                }
                
                syncToModel()
                
                // 4. 自动跳转：输入满 3 位且不是最后一个框 -> 跳下一个
                if tf.stringValue.count == 3 {
                    focusField(at: tf.tag + 1)
                }
            }
            
            // Handle Backspace on Empty Field
            func didPressBackspaceOnEmpty(in textField: MacOctetTextField) {
                let prevIndex = textField.tag - 1
                if prevIndex >= 0 {
                    focusField(at: prevIndex, placeCursorAtEnd: true, deleteLastChar: true)
                }
            }
            
            // MARK: - Focus Helper
            func focusField(at index: Int, placeCursorAtEnd: Bool = false, deleteLastChar: Bool = false) {
                guard let stack = stackView, index >= 0 && index < 4 else { return }
                
                // 找到对应的 TextField
                let targetView = stack.arrangedSubviews.compactMap { $0 as? MacOctetTextField }.first { $0.tag == index }
                
                if let tf = targetView {
                    tf.window?.makeFirstResponder(tf)
                    
                    if deleteLastChar && !tf.stringValue.isEmpty {
                        tf.stringValue = String(tf.stringValue.dropLast())
                        syncToModel()
                    }
                    
                    // 关键修复：防止全选。将光标移动到末尾。
                    if let editor = tf.currentEditor() {
                        let length = tf.stringValue.count
                        editor.selectedRange = NSRange(location: length, length: 0)
                    }
                }
            }
            
            // MARK: - NSTextFieldDelegate (Handle Special Keys)
            func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
                if commandSelector == #selector(NSStandardKeyBindingResponding.deleteBackward(_:)) {
                    if let tf = control as? MacOctetTextField, tf.stringValue.isEmpty {
                        didPressBackspaceOnEmpty(in: tf)
                        return true // Consume event
                    }
                }
                return false
            }
        }
    }
    
    // MARK: - Native IPv4 Input (No CIDR)
    struct IPv4Field: NSViewRepresentable {
        @Binding var ip: String
        
        func makeNSView(context: Context) -> NSStackView {
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 1
            stack.alignment = .centerY
            stack.distribution = .fill
            stack.setHuggingPriority(.required, for: .horizontal)
            
            for i in 0..<4 {
                let tf = MacOctetTextField()
                tf.tag = i
                tf.placeholderString = "0"
                tf.isBordered = false
                tf.drawsBackground = false
                tf.focusRingType = .none
                tf.alignment = .center
                tf.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
                tf.delegate = context.coordinator
                tf.backspaceDelegate = context.coordinator
                tf.widthAnchor.constraint(equalToConstant: 36).isActive = true
                stack.addArrangedSubview(tf)
                
                if i < 3 {
                    let dot = NSTextField(labelWithString: ".")
                    dot.textColor = .secondaryLabelColor
                    dot.font = NSFont.systemFont(ofSize: 13)
                    stack.addArrangedSubview(dot)
                }
            }
            
            context.coordinator.stackView = stack
            return stack
        }
        
        func updateNSView(_ nsView: NSStackView, context: Context) {
            context.coordinator.updateFields(from: ip)
        }
        
        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }
        
        class Coordinator: NSObject, NSTextFieldDelegate, OctetTextFieldDelegate {
            var parent: IPv4Field
            weak var stackView: NSStackView?
            var isInternalUpdate = false
            
            init(parent: IPv4Field) {
                self.parent = parent
            }
            
            func updateFields(from ip: String) {
                guard !isInternalUpdate, let stack = stackView else { return }
                let parts = ip.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                var tfIndex = 0
                for view in stack.arrangedSubviews {
                    if let tf = view as? NSTextField, view is MacOctetTextField {
                        let val = tfIndex < parts.count ? parts[tfIndex] : ""
                        if tf.stringValue != val { tf.stringValue = val }
                        tfIndex += 1
                    }
                }
            }
            
            func syncToModel() {
                guard let stack = stackView else { return }
                isInternalUpdate = true
                var parts = [String]()
                for view in stack.arrangedSubviews {
                    if let tf = view as? MacOctetTextField {
                        parts.append(tf.stringValue)
                    }
                }
                while parts.count < 4 { parts.append("") }
                parent.ip = parts.joined(separator: ".")
                DispatchQueue.main.async { self.isInternalUpdate = false }
            }
            
            func controlTextDidChange(_ obj: Notification) {
                guard let tf = obj.object as? MacOctetTextField else { return }
                let filtered = tf.stringValue.filter { "0123456789".contains($0) }
                if filtered != tf.stringValue { tf.stringValue = filtered }
                if tf.stringValue.count > 3 { tf.stringValue = String(tf.stringValue.prefix(3)) }
                if let num = Int(tf.stringValue), num > 255 { tf.stringValue = "255" }
                syncToModel()
                if tf.stringValue.count == 3 { focusField(at: tf.tag + 1) }
            }
            
            func didPressBackspaceOnEmpty(in textField: MacOctetTextField) {
                let prevIndex = textField.tag - 1
                if prevIndex >= 0 { focusField(at: prevIndex, placeCursorAtEnd: true, deleteLastChar: true) }
            }
            
            func focusField(at index: Int, placeCursorAtEnd: Bool = false, deleteLastChar: Bool = false) {
                guard let stack = stackView, index >= 0 && index < 4 else { return }
                let targetView = stack.arrangedSubviews.compactMap { $0 as? MacOctetTextField }.first { $0.tag == index }
                if let tf = targetView {
                    tf.window?.makeFirstResponder(tf)
                    if deleteLastChar && !tf.stringValue.isEmpty {
                        tf.stringValue = String(tf.stringValue.dropLast())
                        syncToModel()
                    }
                    if let editor = tf.currentEditor() {
                        let length = tf.stringValue.count
                        editor.selectedRange = NSRange(location: length, length: 0)
                    }
                }
            }
            
            func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
                if commandSelector == #selector(NSStandardKeyBindingResponding.deleteBackward(_:)) {
                    if let tf = control as? MacOctetTextField, tf.stringValue.isEmpty {
                        didPressBackspaceOnEmpty(in: tf)
                        return true
                    }
                }
                return false
            }
        }
    }
    
    // 代理协议：用于传递 Backspace 事件
    protocol OctetTextFieldDelegate: AnyObject {
        func didPressBackspaceOnEmpty(in textField: MacOctetTextField)
    }
    
    // 自定义 NSTextField 捕获 Backspace
    class MacOctetTextField: NSTextField {
        weak var backspaceDelegate: OctetTextFieldDelegate?
        // Delegate handles doCommandBy for backspace
    }
    
}



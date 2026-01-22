import SwiftUI

struct PeerCard: View, Equatable {
    let peer: PeerInfo
    
    static func == (lhs: PeerCard, rhs: PeerCard) -> Bool {
        lhs.peer == rhs.peer
    }
    @State private var isHovering = false
    @State private var showDetail = false
    @Environment(\.colorScheme) var colorScheme
    
    private var shortVersion: String {
        peer.version.split(separator: "-").first.map(String.init) ?? peer.version
    }
    
    private func formatSpeed(_ speedStr: String) -> String {
        // If it already has units (from Table output), e.g. "10.5 KB"
        if speedStr.contains(" ") {
            return speedStr
        }
        
        // If it is a raw number (from JSON output), e.g. "10240"
        if let bytes = Double(speedStr) {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB] // Adjust as needed
            formatter.countStyle = .binary // 1024
            formatter.includesUnit = true
            return formatter.string(fromByteCount: Int64(bytes))
        }
        
        return speedStr
    }

    // MARK: - Helpers

    private func clean(_ text: String) -> String {
        // Strip ANSI codes and whitespace
        text.replacingOccurrences(of: "\\x1b\\[[0-9;]*m", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Translation & Color Helpers
    
    private func translateTunnel(_ raw: String) -> String {
        let text = clean(raw)
        let lower = text.lowercased()
        
        if lower == "local" { return "本机" }
        if lower == "p2p" { return "直连" }
        if lower.contains("p2p") { return text.replacingOccurrences(of: "p2p", with: "直连", options: .caseInsensitive) }
        
        if lower == "relay" { return "中转" }
        if lower.contains("relay") {
            return text.replacingOccurrences(of: "relay", with: "中转", options: .caseInsensitive)
        }
        
        return text
    }
    
    private func translateNAT(_ raw: String) -> String {
        let text = clean(raw)
        let lower = text.lowercased()
        
        if lower == "unknown" { return "未知" }
        if lower == "nopat" { return "一对一" }
        
        if lower.hasPrefix("openinternet") { return "开放" }
        if lower.hasPrefix("fullcone") { return "全锥形" }
        if lower.hasPrefix("symmetric") { return "对称" }
        
        // Checking PortRestricted before Restricted to avoid partial match overlap
        if lower.contains("portrestricted") { return "端口受限" }
        if lower.contains("restricted") { return "受限" }
        
        return text
    }
    
    private func natColor(for text: String) -> Color {
        if text.contains("全锥形") || text.contains("开放") || text.contains("一对一") { return .blue }
        if text.contains("对称") { return .red }
        if text.contains("端口受限") { return .orange }
        if text.contains("受限") { return .yellow }
        return .gray
    }
    
    private func tagColor(for text: String) -> Color {
        // Tunnel Colors
        if text.contains("直连") { return .blue }
        if text.contains("中转") { return .purple }
        if text.contains("本机") { return .gray }
        return .gray
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 1. Title
            HStack(alignment: .center, spacing: 0) {
                ScrollingText(text: peer.hostname.isEmpty ? "未知节点" : peer.hostname)
                    .frame(height: 18)
                
                Spacer(minLength: 8)
                
                Button(action: { showDetail = true }) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showDetail) {
                    PeerDetailView(peer: peer)
                        .frame(width: 320, height: 450)
                }
            }

            // 2. IP & Latency
            HStack {
                Text(peer.ipv4.isEmpty ? "Public Peer" : peer.ipv4)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(peer.latency.isEmpty || peer.latency == "-" ? "- ms" : "\(peer.latency) ms")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.green)
            }

            // 3. Speed & Loss
            HStack(spacing: 0) {
                HStack(spacing: 1) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8))
                    Text(formatSpeed(peer.rx))
                        .minimumScaleFactor(0.7)
                }
                .foregroundColor(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                
                HStack(spacing: 1) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 8))
                    Text(formatSpeed(peer.tx))
                        .minimumScaleFactor(0.7)
                }
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Text(peer.loss.isEmpty ? "0.0%" : peer.loss)
                    .foregroundColor(.secondary)
                    .frame(width: 45, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .lineLimit(1)

            // 4. Tags
            GeometryReader { geo in
                let spacing: CGFloat = 6
                let totalWidth = geo.size.width - (spacing * 3)
                
                let rawTunnel = translateTunnel(peer.tunnel.isEmpty ? "-" : peer.tunnel)
                let tTunnel = (rawTunnel.uppercased().contains("TCP") || rawTunnel.uppercased().contains("UDP")) ? rawTunnel : "-"
                let tNat = translateNAT(peer.nat)
                let tCost = translateTunnel(peer.cost) // Cost column also contains p2p/local info
                
                // Adjusted Ratios: Cost 22%, Tunnel 18%, NAT 40%, Version 20%
                HStack(spacing: spacing) {
                    Tag(text: tCost, color: tagColor(for: tCost))
                        .frame(width: totalWidth * 0.22)
                    
                    Tag(text: tTunnel, color: tagColor(for: tTunnel))
                        .frame(width: totalWidth * 0.18)
                    
                    Tag(text: tNat, color: natColor(for: tNat))
                        .frame(width: totalWidth * 0.40)
                    
                    Tag(text: shortVersion, color: .gray)
                        .frame(width: totalWidth * 0.20)
                }
            }
            .frame(height: 22)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }
    
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6)) // Match SpeedCard background
            .background(borderColor.opacity(0.05)) // Add subtle tint to match SpeedCard's visual weight
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(borderColor.opacity(0.6), lineWidth: 1) // Increased opacity for better visibility
            )
            .clipShape(RoundedRectangle(cornerRadius: 12)) // Ensure background tint is clipped
    }
    
    // Logic to determine border color based on Peer Type
    private var borderColor: Color {
        // 1. Local (本机)
        let tunnelLower = peer.tunnel.lowercased()
        if tunnelLower == "local" || peer.ipv4.lowercased().contains("local") {
            return .blue
        }
        
        // 2. Public Peer (Public)
        if peer.ipv4.isEmpty || 
           peer.ipv4.lowercased().contains("public") || 
           peer.hostname.lowercased().contains("public") {
            return .red
        }
        
        // 3. Remote (远端机器) - Changed from .yellow to .green for visibility
        return .green
    }
}

// MARK: - Scrolling Text
struct ScrollingText: View {
    let text: String
    @State private var offset: CGFloat = 0
    @State private var isHovering = false
    @State private var containerWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Text(text)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: true, vertical: false)
                    .background(GeometryReader { textGeo in
                        Color.clear.onAppear { textWidth = textGeo.size.width }
                    })
                    .opacity(0)

                Text(text)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: offset)
                    .animation(shouldAnimate ? .linear(duration: Double(textWidth / 60)).repeatForever(autoreverses: true) : .default, value: offset)
            }
            .onAppear { containerWidth = geo.size.width }
            .onChange(of: isHovering) { hovering in
                if hovering && textWidth > containerWidth {
                    offset = -(textWidth - containerWidth + 8)
                } else {
                    offset = 0
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .clipped()
    }

    private var shouldAnimate: Bool {
        isHovering && textWidth > containerWidth
    }
}

struct Tag: View {
    let text: String
    var color: Color = .gray
    
    var body: some View {
        Text(text)
            .font(.system(size: 9)) // Reduced to 9
            .foregroundColor(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
    }
}

// MARK: - Peer Detail View
struct PeerDetailView: View {
    let peer: PeerInfo
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        VStack(spacing: 0) {
            Text("点击条目以复制内容")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.vertical, 8)
            
            Form {
                if let myNode = peer.myNodeData {
                    localNodeSections(myNode)
                } else if let pair = peer.fullData {
                    remotePeerSections(pair)
                } else {
                    basicSections
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 320, height: 450)
    }
    
    @ViewBuilder
    private func localNodeSections(_ node: EasyTierStatus.NodeInfo) -> some View {
        Section("节点") {
            DetailRow(label: "主机名", value: node.hostname)
            DetailRow(label: "版本", value: node.version)
            DetailRow(label: "虚拟 IP", value: node.virtualIPv4?.description ?? "-")
            DetailRow(label: "UDP NAT 类型", value: node.stunInfo?.udpNATType.description ?? "-")
            DetailRow(label: "TCP NAT 类型", value: node.stunInfo?.tcpNATType.description ?? "-")
        }
        
        if let listeners = node.listeners, !listeners.isEmpty {
            Section("监听地址") {
                ForEach(listeners.indices, id: \.self) { i in
                    DetailRow(label: "监听 \(i+1)", value: listeners[i].url)
                }
            }
        }
    }
    
    @ViewBuilder
    private func remotePeerSections(_ pair: EasyTierStatus.PeerRoutePair) -> some View {
        let route = pair.route
        
        Section("节点") {
            DetailRow(label: "主机名", value: route.hostname)
            DetailRow(label: "节点 ID", value: "\(route.peerId)", isMonospaced: true)
            DetailRow(label: "实例 ID", value: route.instId, isMonospaced: true)
            DetailRow(label: "版本", value: route.version)
            DetailRow(label: "下一跳 ID", value: "\(route.nextHopPeerId)", isMonospaced: true)
            DetailRow(label: "代价", value: "\(route.cost)")
            DetailRow(label: "路径延迟", value: "\(route.pathLatency/1000) ms")
            
            if let nhLatFirst = route.nextHopPeerIdLatencyFirst {
                DetailRow(label: "下一跳 (延迟优先)", value: "\(nhLatFirst)", isMonospaced: true)
                DetailRow(label: "代价 (延迟优先)", value: "\(route.costLatencyFirst ?? 0)")
                DetailRow(label: "路径延迟 (延迟优先)", value: "\((route.pathLatencyLatencyFirst ?? 0)/1000) ms")
            }
            
            if let flags = route.featureFlag {
                DetailRow(label: "特性标志", value: formatFlags(flags))
            }
        }
        
        if let pInfo = pair.peer {
            Section("连接状态") {
                DetailRow(label: "默认连接", value: pInfo.defaultConnId?.description ?? "-")
            }
            
            ForEach(pInfo.conns.indices, id: \.self) { i in
                let conn = pInfo.conns[i]
                Section("连接 \(i + 1) [\(conn.tunnel?.tunnelType ?? "Unknown")]") {
                    DetailRow(label: "角色", value: conn.isClient ? "Client" : "Server")
                    DetailRow(label: "丢包率", value: String(format: "%.2f%%", conn.lossRate * 100))
                    DetailRow(label: "本地地址", value: conn.tunnel?.localAddr.url ?? "-")
                    DetailRow(label: "远程地址", value: conn.tunnel?.remoteAddr.url ?? "-")
                    
                    if let s = conn.stats {
                        DetailRow(label: "接收", value: formatBytes(s.rxBytes))
                        DetailRow(label: "发送", value: formatBytes(s.txBytes))
                        DetailRow(label: "延迟", value: String(format: "%.1f ms", Double(s.latencyUs)/1000.0))
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var basicSections: some View {
        Section("基础信息") {
            DetailRow(label: "主机名", value: peer.hostname)
            DetailRow(label: "虚拟 IP", value: peer.ipv4)
            DetailRow(label: "版本", value: peer.version)
        }
        Section("网络信息") {
            DetailRow(label: "代价", value: peer.cost)
            DetailRow(label: "延迟", value: peer.latency + " ms")
            DetailRow(label: "丢包率", value: peer.loss)
            DetailRow(label: "隧道方式", value: peer.tunnel)
        }
    }
    
    private func formatFlags(_ flags: EasyTierStatus.PeerFeatureFlag) -> String {
        var parts = [String]()
        if flags.isPublicServer { parts.append("public_server") }
        if flags.avoidRelayData { parts.append("avoid_relay") }
        if flags.kcpInput { parts.append("kcp_input") }
        if flags.noRelayKcp { parts.append("no_relay_kcp") }
        if flags.supportConnListSync { parts.append("conn_list_sync") }
        return parts.isEmpty ? "None" : parts.joined(separator: ", ")
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024.0
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024.0)
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var isMonospaced: Bool = false
    
    @State private var isCopied = false

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            
            Spacer(minLength: 8)
            
            Text(value.isEmpty ? "-" : value)
                .font(isMonospaced ? .system(size: 13, weight: .regular, design: .monospaced) : .system(size: 13))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)
                .opacity(isCopied ? 0.5 : 1.0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            copyToClipboard(value)
            withAnimation(.easeInOut(duration: 0.1)) {
                isCopied = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation {
                    isCopied = false
                }
            }
        }
        .help(value)
    }
    
    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

struct ScrollingTextValue: View {
    let text: String
    let isMonospaced: Bool
    
    @State private var offset: CGFloat = 0
    @State private var isHovering = false
    @State private var containerWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                // Invisible text to measure width
                Text(text)
                    .font(isMonospaced ? .system(size: 13, weight: .regular, design: .monospaced) : .system(size: 13))
                    .fixedSize(horizontal: true, vertical: false)
                    .background(GeometryReader { textGeo in
                        Color.clear.onAppear { textWidth = textGeo.size.width }
                    })
                    .opacity(0)

                // Visible text
                Text(text)
                    .font(isMonospaced ? .system(size: 13, weight: .regular, design: .monospaced) : .system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: offset)
                    .animation(shouldAnimate ? .linear(duration: Double(textWidth / 40)).repeatForever(autoreverses: true) : .default, value: offset)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onAppear { containerWidth = geo.size.width }
            .onChange(of: isHovering) { hovering in
                if hovering && textWidth > containerWidth {
                    offset = -(textWidth - containerWidth + 10)
                } else {
                    offset = 0
                }
            }
        }
        .frame(height: 18)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .clipped()
    }

    private var shouldAnimate: Bool {
        isHovering && textWidth > containerWidth
    }
}

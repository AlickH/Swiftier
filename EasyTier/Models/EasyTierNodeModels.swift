import Foundation

// MARK: - API Response Models

struct EasyTierStatus: Codable {
    var myNodeInfo: NodeInfo?
    var events: [String]
    var peerRoutePairs: [PeerRoutePair]
    var running: Bool
    var errorMsg: String?

    enum CodingKeys: String, CodingKey {
        case myNodeInfo = "my_node_info"
        case events
        case peerRoutePairs = "peer_route_pairs"
        case running
        case errorMsg = "error_msg"
    }
}

struct NodeInfo: Codable {
    var virtualIPv4: IPv4CIDR?
    var hostname: String
    var version: String
    var stunInfo: STUNInfo?
    
    enum CodingKeys: String, CodingKey {
        case virtualIPv4 = "virtual_ipv4"
        case hostname, version
        case stunInfo = "stun_info"
    }
}

struct PeerRoutePair: Codable {
    var route: Route
    var peer: PeerDetails?
}

struct Route: Codable {
    var peerId: Int
    var ipv4Addr: IPv4CIDR?
    var hostname: String
    var cost: Int
    var pathLatency: Int?
    var version: String
    var stunInfo: STUNInfo?

    enum CodingKeys: String, CodingKey {
        case peerId = "peer_id"
        case ipv4Addr = "ipv4_addr"
        case hostname, cost, version
        case pathLatency = "path_latency"
        case stunInfo = "stun_info"
    }
}

struct PeerDetails: Codable {
    var peerId: Int
    var conns: [PeerConnInfo]
    
    enum CodingKeys: String, CodingKey {
        case peerId = "peer_id"
        case conns
    }
}

struct PeerConnInfo: Codable {
    var connId: String
    var tunnel: TunnelInfo?
    var stats: PeerConnStats?
    var lossRate: Double
    
    enum CodingKeys: String, CodingKey {
        case connId = "conn_id"
        case tunnel, stats
        case lossRate = "loss_rate"
    }
}

struct TunnelInfo: Codable {
    var tunnelType: String
    var localAddr: Url?
    var remoteAddr: Url?

    enum CodingKeys: String, CodingKey {
        case tunnelType = "tunnel_type"
        case localAddr = "local_addr"
        case remoteAddr = "remote_addr"
    }
}

struct PeerConnStats: Codable {
    var rxBytes: Int
    var txBytes: Int
    var latencyUs: Int
    
    enum CodingKeys: String, CodingKey {
        case rxBytes = "rx_bytes"
        case txBytes = "tx_bytes"
        case latencyUs = "latency_us"
    }
}

struct STUNInfo: Codable {
    var udpNATType: Int
    
    enum CodingKeys: String, CodingKey {
        case udpNATType = "udp_nat_type"
    }
}

struct Url: Codable {
    var url: String
}

// MARK: - Attribute Types

struct IPv4CIDR: Codable {
    var address: IPv4Addr
    var networkLength: Int

    enum CodingKeys: String, CodingKey {
        case address
        case networkLength = "network_length"
    }
    
    var description: String {
        return "\(address.description)/\(networkLength)"
    }
}

struct IPv4Addr: Codable {
    var addr: UInt32
    
    var description: String {
        return "\((addr >> 24) & 0xFF).\((addr >> 16) & 0xFF).\((addr >> 8) & 0xFF).\(addr & 0xFF)"
    }
}

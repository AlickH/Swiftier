import Foundation

func normalizeCIDR(_ cidr: String) -> RunningIPv4CIDR? {
    guard var cidrStruct = RunningIPv4CIDR(from: cidr) else { return nil }
    cidrStruct.address = ipv4MaskedSubnet(cidrStruct)
    return cidrStruct
}

func cidrToSubnetMask(_ cidr: Int) -> String? {
    guard cidr >= 0 && cidr <= 32 else { return nil }
    
    let mask: UInt32 = cidr == 0 ? 0 : UInt32.max << (32 - cidr)
    
    let octet1 = (mask >> 24) & 0xFF
    let octet2 = (mask >> 16) & 0xFF
    let octet3 = (mask >> 8) & 0xFF
    let octet4 = mask & 0xFF
    
    return "\(octet1).\(octet2).\(octet3).\(octet4)"
}

func ipv4MaskedSubnet(_ cidr: RunningIPv4CIDR) -> RunningIPv4Addr {
    let mask: UInt32 = cidr.networkLength == 0 ? 0 : UInt32.max << (32 - cidr.networkLength)
    return RunningIPv4Addr(addr: cidr.address.addr & mask)
}

func ipv4SubnetsOverlap(bigger: RunningIPv4CIDR, smaller: RunningIPv4CIDR) -> Bool {
    if bigger.networkLength > smaller.networkLength {
        return ipv4SubnetsOverlap(bigger: smaller, smaller: bigger)
    }
    let mask: UInt32 = bigger.networkLength == 0 ? 0 : UInt32.max << (32 - bigger.networkLength)
    return (bigger.address.addr & mask) == (smaller.address.addr & mask)
}

// Added from PacketTunnelProvider.swift to centralize logic

func maskedAddress(_ addr: RunningIPv4Addr, networkLength: Int) -> String {
    let mask = networkLength == 0 ? UInt32(0) : UInt32.max << (32 - networkLength)
    let network = addr.addr & mask
    return "\((network >> 24) & 0xFF).\((network >> 16) & 0xFF).\((network >> 8) & 0xFF).\(network & 0xFF)"
}

func maskedAddressFromStrings(_ ip: String, mask: String) -> String {
    let ipParts = ip.split(separator: ".").compactMap { UInt32($0) }
    let maskParts = mask.split(separator: ".").compactMap { UInt32($0) }
    guard ipParts.count == 4, maskParts.count == 4 else { return ip }
    return "\(ipParts[0] & maskParts[0]).\(ipParts[1] & maskParts[1]).\(ipParts[2] & maskParts[2]).\(ipParts[3] & maskParts[3])"
}

func parseCIDR(_ cidrStr: String) -> (address: String, mask: String)? {
    let parts = cidrStr.split(separator: "/")
    guard parts.count == 2,
          let cidr = Int(parts[1]),
          let mask = cidrToSubnetMask(cidr) else { return nil }
    
    // Apply mask to get network address
    let ipParts = String(parts[0]).split(separator: ".").compactMap { UInt32($0) }
    let maskParts = mask.split(separator: ".").compactMap { UInt32($0) }
    guard ipParts.count == 4, maskParts.count == 4 else { return nil }
    
    let networkAddr = "\(ipParts[0] & maskParts[0]).\(ipParts[1] & maskParts[1]).\(ipParts[2] & maskParts[2]).\(ipParts[3] & maskParts[3])"
    return (networkAddr, mask)
}

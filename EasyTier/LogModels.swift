import SwiftUI

struct LogEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: String
    let cleanContent: String
    let fullText: String
    let level: LogLevel
    
    init(id: UUID = UUID(), timestamp: String, cleanContent: String, fullText: String, level: LogLevel) {
        self.id = id
        self.timestamp = timestamp
        self.cleanContent = cleanContent
        self.fullText = fullText
        self.level = level
    }

    static func == (lhs: LogEntry, rhs: LogEntry) -> Bool {
        lhs.id == rhs.id
    }
}

enum LogLevel: String {
    case trace, debug, info, warn, error
    
    var color: Color {
        switch self {
        case .error: return .red
        case .warn: return .orange
        case .info: return .green
        case .debug: return .cyan
        case .trace: return .gray
        }
    }
}

struct EventEntry: Identifiable, Equatable, Codable {
    let id: UUID
    let timestamp: String
    let date: Date?
    let type: EventType
    let details: String
    let highlights: [HighlightRange]?
    
    init(id: UUID = UUID(), timestamp: String, date: Date?, type: EventType, details: String, highlights: [HighlightRange]? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.date = date
        self.type = type
        self.details = details
        self.highlights = highlights
    }
    
    enum EventType: String, Codable {
        case peerAdded = "PeerAdded"
        case peerConnAdded = "PeerConnAdded"
        case peerRemoved = "PeerRemoved"
        case connecting = "Connecting"
        case connected = "Connected"
        case connectError = "ConnectError"
        case routeChanged = "RouteChanged"
        case tunDeviceReady = "TunDeviceReady"
        case listenerAdded = "ListenerAdded"
        case handshake = "Handshake"
        case unknown = "Event"
        
        var color: Color {
            switch self {
            case .peerAdded, .peerConnAdded, .connected, .tunDeviceReady, .listenerAdded: return .green
            case .peerRemoved, .connectError: return .red
            case .connecting, .handshake: return .yellow
            case .routeChanged: return .orange
            case .unknown: return .yellow
            }
        }
    }
}

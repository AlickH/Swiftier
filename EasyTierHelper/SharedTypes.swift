// SharedTypes.swift
// Helper-side definitions that MUST mirror EasyTier/HelperProtocol.swift
// When updating these types, make sure to update both files!

import Foundation

/// 高亮范围元数据 (镜像 HelperProtocol.swift 中的定义)
public struct HighlightRange: Codable, Equatable {
    public let start: Int
    public let length: Int
    public let color: String
    public let bold: Bool
    
    public init(start: Int, length: Int, color: String, bold: Bool) {
        self.start = start
        self.length = length
        self.color = color
        self.bold = bold
    }
}

/// 已处理的事件格式 (镜像 HelperProtocol.swift 中的定义)
public struct ProcessedEvent: Codable {
    public let id: UUID
    public let timestamp: String
    public let time: Date?
    public let type: String
    public let details: String
    public let highlights: [HighlightRange]
    
    public init(id: UUID, timestamp: String, time: Date?, type: String, details: String, highlights: [HighlightRange]) {
        self.id = id
        self.timestamp = timestamp
        self.time = time
        self.type = type
        self.details = details
        self.highlights = highlights
    }
}

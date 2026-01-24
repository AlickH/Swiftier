import Foundation

/// 高亮范围元数据 (与 App 侧对齐)
struct HighlightRange: Codable {
    let start: Int
    let length: Int
    let color: String
    let bold: Bool
}

/// 已处理的事件格式 (与 App 侧 EventEntry 对齐)
struct ProcessedEvent: Codable {
    let id: UUID
    let timestamp: String
    let time: Date?
    let type: String
    let details: String
    let highlights: [HighlightRange]
}

class LogProcessor {
    static let shared = LogProcessor()
    
    private let maxEventItems = 500
    private var processedEvents: [ProcessedEvent] = []
    private let lock = NSLock()
    
    // 之前在 App 里打磨好的正则规则
    private let ansiRegex = try! NSRegularExpression(pattern: "(\\x1B\\[[0-9;]*[a-zA-Z])|(\\[[0-9;]+m)", options: [])
    
    private init() {}
    
    func getEvents() -> [ProcessedEvent] {
        lock.lock()
        defer { lock.unlock() }
        return processedEvents
    }

    /// 处理从日志中提取的原始行
    func processRawLine(_ rawLine: String) {
        let cleanLine = removeAnsiCodes(rawLine)
        
        // 尝试解析 JSON 事件
        if let jsonRange = cleanLine.range(of: "\\{.*\\}", options: .regularExpression),
           let data = String(cleanLine[jsonRange]).data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            
            parseAndAddEvent(json: json, rawLine: cleanLine)
        }
    }
    
    private func parseAndAddEvent(json: [String: Any], rawLine: String) {
        let timeStr = json["time"] as? String ?? ""
        let displayTimestamp = timeStr.replacingOccurrences(of: "Z", with: "").replacingOccurrences(of: "T", with: " ")
        
        guard let eventData = json["event"] else { return }
        
        let eventName: String?
        if let eventDict = eventData as? [String: Any], let firstKey = eventDict.keys.first {
            eventName = firstKey
        } else {
            eventName = eventData as? String
        }
        
        let type = eventName ?? "unknown"
        let detailsStr = collapsePrettyPrintedArrays(formatAsJson(eventData))
        let highlights = calculateHighlights(for: detailsStr)
        
        let event = ProcessedEvent(
            id: UUID(),
            timestamp: displayTimestamp,
            time: ISO8601DateFormatter().date(from: timeStr),
            type: type,
            details: detailsStr,
            highlights: highlights
        )
        
        lock.lock()
        processedEvents.append(event)
        if processedEvents.count > maxEventItems {
            processedEvents.removeFirst()
        }
        lock.unlock()
    }
    
    private func removeAnsiCodes(_ text: String) -> String {
        let range = NSRange(location: 0, length: text.utf16.count)
        return ansiRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
    
    private func collapsePrettyPrintedArrays(_ input: String) -> String {
        var res = input
        let pattern = #"(?s)\[\s*([^\[\]{}]*?)\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return res }
        
        let nsString = res as NSString
        let matches = regex.matches(in: res, options: [], range: NSRange(location: 0, length: nsString.length))
        
        for match in matches.reversed() {
            let content = nsString.substring(with: match.range(at: 1))
            let collapsedContent = content.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
                .trimmingCharacters(in: .whitespaces)
            
            res = (res as NSString).replacingCharacters(in: match.range, with: "[\(collapsedContent)]")
        }
        return res
    }

    private func formatAsJson(_ value: Any) -> String {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: options),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\(value)"
    }

    private func calculateHighlights(for json: String) -> [HighlightRange] {
        var ranges: [HighlightRange] = []
        let nsString = json as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        
        // 1. Strings (Green)
        if let regex = try? NSRegularExpression(pattern: #""([^"\\]|\\.)*""#) {
            let matches = regex.matches(in: json, range: fullRange)
            for match in matches {
                ranges.append(HighlightRange(start: match.range.location, length: match.range.length, color: "green", bold: false))
            }
        }

        // 2. Keys (Blue)
        if let regex = try? NSRegularExpression(pattern: #"("[^"]+"|\b[a-zA-Z_][a-zA-Z0-9_]*\b)\s*:"#) {
            let matches = regex.matches(in: json, range: fullRange)
            for match in matches {
                if let keyRange = Range(match.range, in: json) {
                    let fullMatchStr = String(json[keyRange])
                    if let colonIndex = fullMatchStr.firstIndex(of: ":") {
                        let keyPartLength = fullMatchStr[..<colonIndex].utf16.count
                        ranges.append(HighlightRange(start: match.range.location, length: keyPartLength, color: "blue", bold: true))
                    }
                }
            }
        }
        
        // 3. Numbers (Orange)
        if let regex = try? NSRegularExpression(pattern: #"(?<![a-zA-Z0-9_])\d+(\.\d+)?(?![a-zA-Z0-9_])"#) {
            let matches = regex.matches(in: json, range: fullRange)
            for match in matches {
                ranges.append(HighlightRange(start: match.range.location, length: match.range.length, color: "orange", bold: false))
            }
        }
        
        // 4. Keywords/Booleans (Purple)
        if let regex = try? NSRegularExpression(pattern: #"\b(true|false|null|None|Some|Ok|Err)\b"#) {
            let matches = regex.matches(in: json, range: fullRange)
            for match in matches {
                ranges.append(HighlightRange(start: match.range.location, length: match.range.length, color: "purple", bold: true))
            }
        }
        
        return ranges
    }
}

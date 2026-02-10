import SwiftUI
import Combine

class LogParser: ObservableObject {
    static let shared = LogParser()
    
    @Published var logs: [LogEntry] = []
    @Published var events: [EventEntry] = []
    
    var isPaused = false
    private var pendingLogs: [LogEntry] = []
    
    // Persistence
    private var eventsFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Swiftier")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("events.json")
    }
    
    private var fileHandle: FileHandle?
    private init() {
        self.events = []
    }
    
    private func saveEvents() {
        // Disabled: We no longer persist events to disk to ensure Core-driven lifecycle.
    }

    private var timer: Timer?
    private var xpcEventTimer: Timer?
    var xpcEventIndex: Int = 0
    private let logPath = "/var/log/swiftier-helper.log"
    private var isReading = false
    private var lastReadOffset: UInt64 = 0
    private var trailingRemainder = ""
    
    private let maxFullTextLength = 20000
    private let maxLogItems = 1000
    private let maxEventItems = 200
    
    private var seenEventHashes: Set<Int> = []
    
    private let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func startMonitoring() {
        // Source 1: XPC Events (Structured, Real-time)
        // In Sandbox mode, we cannot read /var/log/ directly.
        // We rely entirely on XPC to get logs from the Helper.
        if #available(macOS 13.0, *) {
            startXPCEventPolling()
        }
    }
    
    @available(macOS 13.0, *)
    private func startXPCEventPolling() {
        xpcEventTimer?.invalidate()
        // Frequency back to 1.0s
        xpcEventTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollXPCEvents()
        }
        pollXPCEvents()
    }
    
    @available(macOS 13.0, *)
    private func pollXPCEvents() {
        HelperManager.shared.getRecentEvents(sinceIndex: xpcEventIndex) { [weak self] processedEvents, nextIndex in
            guard let self = self else { return }
            
            // Core Restart Detection
            if nextIndex < self.xpcEventIndex {
                DispatchQueue.main.async {
                    self.events.removeAll()
                    self.logs.removeAll()
                    self.seenEventHashes.removeAll()
                }
            }
            
            self.xpcEventIndex = nextIndex
            if processedEvents.isEmpty { return }
            
            let newEntries = processedEvents.map { pe -> EventEntry in
                let type = EventEntry.EventType(rawValue: pe.type) ?? .unknown
                return EventEntry(
                    id: pe.id,
                    timestamp: pe.timestamp,
                    date: pe.time,
                    type: type,
                    details: pe.details,
                    highlights: self.calculateHighlights(for: pe.details)
                )
            }
            
            DispatchQueue.main.async {
                self.events.append(contentsOf: newEntries)
                if self.events.count > self.maxEventItems {
                    self.events.removeFirst(self.events.count - self.maxEventItems)
                }
            }
        }
    }

    private func startRawLogMonitoring() {
        // Removed for Sandbox compatibility
    }
    
    // MARK: - Pre-compiled Regex Cache (Optimized for performance)
    private enum Regex {
        static let ansi = try! NSRegularExpression(pattern: "(\\x1B\\[[0-9;]*[a-zA-Z])|(\\[[0-9;]+m)", options: [])
        static let timestamp = try! NSRegularExpression(pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?", options: [])
        static let levelPrefix = try! NSRegularExpression(pattern: "^(INFO|WARN|ERROR|DEBUG|TRACE)\\b", options: [.caseInsensitive])
        static let helperPrefix = try! NSRegularExpression(pattern: "^(\\[.*?\\] )?\\[Helper\\]( Core output:)?", options: [])
        
        static let highlightStrings = try! NSRegularExpression(pattern: #""([^"\\]|\\.)*""#, options: [])
        static let highlightKeys = try! NSRegularExpression(pattern: #"("[^"]+"|\b[a-zA-Z_][a-zA-Z0-9_]*\b)\s*:"#, options: [])
        static let highlightNumbers = try! NSRegularExpression(pattern: #"\b\d+(\.\d+)?\b"#, options: [])
        static let highlightKeywords = try! NSRegularExpression(pattern: #"\b(true|false|null|None|Some|Ok|Err)\b"#, options: [])
    }

    private func removeAnsiCodes(_ text: String) -> String {
        let range = NSRange(location: 0, length: text.utf16.count)
        return Regex.ansi.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    private func quickParseLogs(_ content: String) -> [LogEntry] {
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var result: [LogEntry] = []
        let now = ISO8601DateFormatter().string(from: Date())
        
        // 获取全局设置级别
        let settingLevelStr = UserDefaults.standard.string(forKey: "logLevel") ?? "INFO"
        let levelMap: [String: Int] = ["OFF": 0, "ERROR": 1, "WARN": 2, "INFO": 3, "DEBUG": 4, "TRACE": 5]
        let currentLevelValue = levelMap[settingLevelStr.uppercased()] ?? 5
        
        for line in lines {
            let raw = removeAnsiCodes(line).replacingOccurrences(of: "\0", with: "")
            if raw.isEmpty { continue }
            
            var content = raw
            let fullRange = NSRange(location: 0, length: content.utf16.count)
            if let match = Regex.helperPrefix.firstMatch(in: content, range: fullRange) {
                content = (content as NSString).replacingCharacters(in: match.range, with: "").trimmingCharacters(in: .whitespaces)
            }
            if content.isEmpty { continue }
            
            var timestamp = ""
            var level: LogLevel = .info
            var lineLevelValue = 3 // Default INFO
            
            let contentRange = NSRange(location: 0, length: content.utf16.count)
            if let match = Regex.timestamp.firstMatch(in: content, range: contentRange) {
                timestamp = (content as NSString).substring(with: match.range)
                content = (content as NSString).replacingCharacters(in: match.range, with: "").trimmingCharacters(in: .whitespaces)
            } else {
                timestamp = now
            }
            
            let levelSearchArea = content.prefix(20).uppercased()
            if levelSearchArea.contains("ERROR") { level = .error; lineLevelValue = 1 }
            else if levelSearchArea.contains("WARN") { level = .warn; lineLevelValue = 2 }
            else if levelSearchArea.contains("DEBUG") { level = .debug; lineLevelValue = 4 }
            else if levelSearchArea.contains("TRACE") { level = .trace; lineLevelValue = 5 }
            
            // 硬性过滤：如果行级别超过了设置级别，则不显示 (注: 数值越小级别越高)
            // 在我们的逻辑里，ERROR=1, WARN=2... 
            // 所以如果 lineLevelValue > currentLevelValue，就不应该显示
            if lineLevelValue > currentLevelValue {
                continue
            }
            
            if let match = Regex.levelPrefix.firstMatch(in: content, range: NSRange(location: 0, length: content.utf16.count)) {
                content = (content as NSString).replacingCharacters(in: match.range, with: "").trimmingCharacters(in: .whitespaces)
            }
            
            result.append(LogEntry(
                timestamp: timestamp,
                cleanContent: content,
                fullText: raw,
                level: level
            ))
        }
        return result
    }
    
    private struct ParseResults {
        let logs: [LogEntry]
        let events: [EventEntry]
        let restartDetected: Bool
    }
    
    private func readNewRawLines() {
        // Removed for Sandbox compatibility
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        xpcEventTimer?.invalidate()
        xpcEventTimer = nil
        isReading = false
        fileHandle = nil // Release handle
    }
    
    func resetForNewCoreSession() {
        stopMonitoring()
        DispatchQueue.main.async {
            self.events.removeAll()
            self.logs.removeAll()
        }
        xpcEventIndex = 0
        isReading = false
    }

    /// Update events from get_running_info response
    func updateEventsFromRunningInfo(_ eventsAnyArray: [Any]) {
        var newEvents: [EventEntry] = []
        
        for item in eventsAnyArray {
            guard let event = parseEventEntry(from: item) else { continue }
            let dedupKey = "\(event.type.rawValue)|\(event.timestamp)|\(event.details)"
            let eventHash = dedupKey.hashValue
            if seenEventHashes.contains(eventHash) { continue }
            seenEventHashes.insert(eventHash)
            
            newEvents.append(event)
        }
        
        guard !newEvents.isEmpty else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.events.append(contentsOf: newEvents)
            // Sort by date (oldest first)
            self.events.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            if self.events.count > self.maxEventItems {
                self.events = Array(self.events.suffix(self.maxEventItems))
            }
        }
    }
    
    func flushPending() {
        // Now optional as logs are simpler
    }

    // MARK: - Legacy Cleanup (Keeping it tidy)

    
    private func applyResults(_ results: ParseResults) {
        if results.restartDetected { self.events.removeAll() }
        let validLogs = results.logs.filter { !$0.cleanContent.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty }
        if isPaused { pendingLogs.append(contentsOf: validLogs) }
        else {
            self.logs.append(contentsOf: validLogs)
            if self.logs.count > maxLogItems { self.logs.removeFirst(self.logs.count - maxLogItems) }
        }
        if !results.events.isEmpty {
            self.events.append(contentsOf: results.events)
            if self.events.count > maxEventItems { self.events.removeFirst(self.events.count - maxEventItems) }
        }
    }
    
    private func capString(_ s: String, limit: Int) -> String {
        return s.count > limit ? String(s.prefix(limit)) + "\n... [已自动截断]" : s
    }

    private func cleanLogContent(_ text: String) -> String {
         return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
    
    private func parseEventEntry(from input: Any) -> EventEntry? {
        let json: [String: Any]?
        if let dict = input as? [String: Any] { json = dict }
        else if let str = input as? String, let data = str.data(using: .utf8) { json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
        else { return nil }
        guard let j = json else { return nil }
        
        let timeStr = j["time"] as? String ?? ""
        let eventDate = iso8601Formatter.date(from: timeStr)
        let displayTimestamp = timeStr.replacingOccurrences(of: "Z", with: "").replacingOccurrences(of: "T", with: " ")
        guard let eventData = j["event"] else { return nil }
        
        let eventName: String?
        let eventPayload: Any
        if let eventDict = eventData as? [String: Any], eventDict.count == 1, let firstKey = eventDict.keys.first {
            eventName = firstKey
            eventPayload = eventDict[firstKey] ?? eventData
        } else {
            eventName = eventData as? String
            eventPayload = eventData
        }
        
        let type = mapEventType(eventName ?? "unknown")
        let cleanedPayload = recursiveJsonClean(eventPayload, depth: 0)
        let detailsStr = formatAsJson(cleanedPayload)
        let highlights = calculateHighlights(for: detailsStr)
        
        return EventEntry(timestamp: displayTimestamp, date: eventDate, type: type, details: detailsStr, highlights: highlights)
    }

    private func parseTextEvent(content: String, timestamp: String, dateParser: (String) -> Date?, into newEvents: inout [EventEntry]) {
        var eventType: EventEntry.EventType?
        var eventPayload: Any?
        if content.contains("PeerConnAdded") { eventType = .peerConnAdded; eventPayload = ["raw": content] }
        else if content.contains("PeerAdded") { eventType = .peerAdded; eventPayload = ["event": "PeerAdded", "raw": content] }
        else if content.contains("PeerRemoved") { eventType = .peerRemoved; eventPayload = ["event": "PeerRemoved", "raw": content] }
        else if content.contains("Connecting") { eventType = .connecting; eventPayload = ["event": "Connecting", "raw": content] }
        
        if let type = eventType {
            let detailsStr = formatAsJson(recursiveJsonClean(eventPayload, depth: 0))
            newEvents.append(EventEntry(timestamp: timestamp, date: dateParser(timestamp), type: type, details: detailsStr, highlights: calculateHighlights(for: detailsStr)))
        }
    }

    private func recursiveJsonClean(_ value: Any?, depth: Int) -> Any? {
        guard let value = value, depth < 5 else { return value }
        if let dict = value as? [String: Any] {
            var newDict = [String: Any]()
            for (k, v) in dict { newDict[k] = recursiveJsonClean(v, depth: depth + 1) }
            return newDict
        } else if let arr = value as? [Any] {
            return arr.map { recursiveJsonClean($0, depth: depth + 1) }
        }
        return value
    }

    private func mapEventType(_ name: String) -> EventEntry.EventType {
        switch name {
        case "Connecting", "ConnectingTo": return .connecting
        case "Connected", "ConnectionAccepted": return .connected
        case "ConnectError", "ConnectionError": return .connectError
        case "PeerConnAdded": return .peerConnAdded
        case "PeerAdded", "NewPeer": return .peerAdded
        case "PeerRemoved", "PeerLost": return .peerRemoved
        case "RouteChanged", "RouteUpdate": return .routeChanged
        case "TunDeviceReady": return .tunDeviceReady
        case "ListenerAdded": return .listenerAdded
        case "Handshake": return .handshake
        default: return .unknown
        }
    }

    private func collapsePrettyPrintedArrays(_ input: String) -> String {
        var res = input
        let pattern = #"(?s)\[\s*([^\[\]{}]*?)\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return res }
        let matches = regex.matches(in: res, options: [], range: NSRange(location: 0, length: (res as NSString).length))
        for match in matches.reversed() {
            let content = (res as NSString).substring(with: match.range(at: 1))
            let collapsed = "[\(content.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", "))]"
            res = (res as NSString).replacingCharacters(in: match.range, with: collapsed)
        }
        return res
    }

    private func formatAsJson(_ value: Any?) -> String {
        guard let v = value else { return "null" }
        
        // JSONSerialization requires Array or Dictionary as top-level type.
        // If it's a simple type, just return its string representation to avoid crash.
        if !(v is [String: Any]) && !(v is [Any]) {
            return "\(v)"
        }
        
        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        if #available(macOS 10.13, *) {
            options.insert(.prettyPrinted)
        }
        if #available(macOS 10.15, *) {
            options.insert(.withoutEscapingSlashes)
        }
        
        if let data = try? JSONSerialization.data(withJSONObject: v, options: options),
           let str = String(data: data, encoding: .utf8) {
            return collapsePrettyPrintedArrays(str)
        }
        return "\(v)"
    }

    private func calculateHighlights(for json: String) -> [HighlightRange] {
        var ranges: [HighlightRange] = []
        let nsString = json as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        
        // 1. Strings (Green)
        if let regex = try? NSRegularExpression(pattern: #""([^"\\]|\\.)*""#) {
            let matches = regex.matches(in: json, range: fullRange)
            for m in matches { ranges.append(HighlightRange(start: m.range.location, length: m.range.length, color: "green", bold: false)) }
        }
        
        // 2. Keys (Blue)
        if let regex = try? NSRegularExpression(pattern: #"("[^"]+"|\b[a-zA-Z_][a-zA-Z0-9_]*\b)\s*:"#) {
            let matches = regex.matches(in: json, range: fullRange)
            for m in matches { ranges.append(HighlightRange(start: m.range.location, length: m.range.length, color: "blue", bold: true)) }
        }
        
        // 3. Numbers (Orange)
        if let regex = try? NSRegularExpression(pattern: #"\b\d+(\.\d+)?\b"#) {
            let matches = regex.matches(in: json, range: fullRange)
            for m in matches { ranges.append(HighlightRange(start: m.range.location, length: m.range.length, color: "orange", bold: false)) }
        }
        
        // 4. Keywords (Purple)
        if let regex = try? NSRegularExpression(pattern: #"\b(true|false|null|None|Some|Ok|Err)\b"#) {
            let matches = regex.matches(in: json, range: fullRange)
            for m in matches { ranges.append(HighlightRange(start: m.range.location, length: m.range.length, color: "purple", bold: true)) }
        }
        
        return ranges
    }
}

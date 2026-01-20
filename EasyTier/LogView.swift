import SwiftUI
import Combine


struct LogEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: String
    let cleanContent: String // Pre-calculated (truncated)
    let fullText: String     // Raw content (capped for memory)
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
    let details: String // Capped JSON string
    
    init(id: UUID = UUID(), timestamp: String, date: Date?, type: EventType, details: String) {
        self.id = id
        self.timestamp = timestamp
        self.date = date
        self.type = type
        self.details = details
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

struct LogView: View {
    @Binding var isPresented: Bool
    
    @ObservedObject private var logParser = LogParser.shared
    @State private var selectedLog: LogEntry?
    @State private var viewMode: ViewMode = .events
    @State private var logLevelFilter: LogLevel? = nil // nil = show all
    
    private let logPath = "/var/log/swiftier-helper.log"
    
    enum ViewMode: Int {
        case events = 0
        case logs = 1
    }

    var body: some View {
        VStack(spacing: 0) {
            // Custom Header to avoid layout issues with UnifiedHeader
            VStack(spacing: 0) {
                HStack {
                    Picker("", selection: $viewMode) {
                        Text("交互事件").tag(ViewMode.events)
                        Text("调试日志").tag(ViewMode.logs)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    
                    Spacer()
                    
                    HStack(spacing: 12) {
                        // Log Level Filter (only show in logs mode)
                        if viewMode == .logs {
                            Picker("", selection: $logLevelFilter) {
                                Text("全部").tag(nil as LogLevel?)
                                Text("ERROR").tag(LogLevel.error as LogLevel?)
                                Text("WARN").tag(LogLevel.warn as LogLevel?)
                                Text("INFO").tag(LogLevel.info as LogLevel?)
                                Text("DEBUG").tag(LogLevel.debug as LogLevel?)
                                Text("TRACE").tag(LogLevel.trace as LogLevel?)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 100)
                        }
                        
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
                        } label: {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.title3)
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)
                        .help("在系统控制台中打开完整日志")
                        
                        Button {
                            withAnimation {
                                isPresented = false
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(Color(nsColor: .windowBackgroundColor))
                
                Divider()
            }
            
            if viewMode == .events {
                EventListView(events: logParser.events)
            } else {
                LogListView(
                    logs: logParser.logs,
                    selectedLog: $selectedLog,
                    levelFilter: logLevelFilter
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .textContentType(.none)
        .disableAutocorrection(true)
        .compositingGroup()
        .shadow(radius: 16)
        .task {
            // Delay log loading until the slide-up animation completes (0.4s).
            // This prevents "content flashing before background" artifacts and reduces animation hitching.
            try? await Task.sleep(nanoseconds: 400_000_000)
            logParser.startMonitoring()
        }
        .onDisappear {
            logParser.stopMonitoring()
        }
    }
}


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
        loadEvents()
    }
    
    private func loadEvents() {
        if let data = try? Data(contentsOf: eventsFileURL),
           let saved = try? JSONDecoder().decode([EventEntry].self, from: data) {
            // Migration: Repair formatting for old events (Fixes array splitting [0,\n 0])
            self.events = saved.map { event in
                var newDetails = event.details
                // Regex: Replace ",\n <spaces><digit>" with ", <digit>" to flatten arrays
                if let r = try? NSRegularExpression(pattern: ",\\n\\s+(\\d)") {
                     let range = NSRange(location: 0, length: newDetails.utf16.count)
                     newDetails = r.stringByReplacingMatches(in: newDetails, options: [], range: range, withTemplate: ", $1")
                }
                return EventEntry(id: event.id, timestamp: event.timestamp, date: event.date, type: event.type, details: newDetails)
            }
        }
    }
    
    private func saveEvents() {
        if let data = try? JSONEncoder().encode(events) {
            try? data.write(to: eventsFileURL)
        }
    }

    private var timer: Timer?
    private var xpcEventTimer: Timer? // Timer for polling XPC events
    private var xpcEventIndex: Int = 0 // Track which events we've already fetched
    private let logPath = "/var/log/swiftier-helper.log"
    private var isReading = false
    private var lastReadOffset: UInt64 = 0
    private var trailingRemainder = "" // Buffer for partial lines at the end of a chunk
    
    private let maxFullTextLength = 20000 // 20KB per entry max
    private let maxLogItems = 1000 // Increased to prevent UI jumping when scrolling (removing items causes shift)
    private let maxEventItems = 200
    
    // Track seen events to avoid duplicates when using get_running_info
    private var seenEventHashes: Set<Int> = []
    
    /// Update events from get_running_info response (like EasyTier-iOS)
    /// The events array from running info contains JSON strings
    func updateEventsFromRunningInfo(_ eventsArray: [String]) {
        var newEvents: [EventEntry] = []
        
        for jsonStr in eventsArray {
            // Use hash to track duplicates
            let hash = jsonStr.hashValue
            if seenEventHashes.contains(hash) { continue }
            seenEventHashes.insert(hash)
            
            // Parse the JSON event
            if let event = parseRunningInfoEvent(jsonStr) {
                newEvents.append(event)
            }
        }
        
        guard !newEvents.isEmpty else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.events.append(contentsOf: newEvents)
            // Sort by date (oldest first) so newest is at the end, consistent with log append logic
            self.events.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            if self.events.count > self.maxEventItems {
                self.events = Array(self.events.prefix(self.maxEventItems))
            }
            self.saveEvents()
            
            // Limit seen hashes to prevent memory growth
            if self.seenEventHashes.count > 5000 {
                self.seenEventHashes.removeAll()
                // Re-add current events
                for event in self.events {
                    self.seenEventHashes.insert(event.details.hashValue)
                }
            }
        }
    }
    
    /// Parse a single event JSON string from get_running_info
    private func parseRunningInfoEvent(_ jsonStr: String) -> EventEntry? {
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        // Extract time
        var eventTime = ""
        var eventDate: Date?
        if let timeStr = json["time"] as? String {
            eventTime = timeStr.replacingOccurrences(of: "Z", with: "")
            eventDate = parseEventDate(timeStr)
        }
        
        // Extract event type and payload
        var eventType: EventEntry.EventType?
        var eventPayload: Any?
        
        if let eventData = json["event"] {
            if let eventDict = eventData as? [String: Any], let key = eventDict.keys.first {
                eventType = mapEventType(key)
                eventPayload = eventDict[key]
            } else if let eventStr = eventData as? String {
                eventType = mapEventType(eventStr)
                eventPayload = eventStr
            }
        }
        
        guard let type = eventType else { return nil }
        
        let cleanedPayload = recursiveJsonClean(eventPayload, depth: 0)
        let detailsStr = capString(formatAsJson(cleanedPayload), limit: maxFullTextLength)
        
        return EventEntry(
            timestamp: eventTime,
            date: eventDate,
            type: type,
            details: detailsStr
        )
    }


    func startMonitoring() {
        // Restore events from disk to memory
        loadEvents()
        
        if timer != nil { return } // Already running
        
        // Start XPC event polling (macOS 13+)
        if #available(macOS 13.0, *) {
            startXPCEventPolling()
        }
        
        guard FileManager.default.fileExists(atPath: logPath) else { return }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: self.logPath))
                let endOffset = handle.seekToEndOfFile()
                
                // Always read larger history (2MB) on fresh start to catch historical events
                // This ensures the list isn't empty if the previous offset was at the very end
                let readSize: UInt64 = 2 * 1024 * 1024
                let startOffset = (endOffset > readSize) ? (endOffset - readSize) : 0
                try handle.seek(toOffset: startOffset)
                
                let data = handle.readDataToEndOfFile()
                if let chunk = String(data: data, encoding: .utf8) {
                    // Prepend remainder (though usually 0 on start) and find the last newline
                    let fullContent = self.trailingRemainder + chunk
                    if let lastNewline = fullContent.lastIndex(of: "\n") {
                        let toProcess = String(fullContent[..<lastNewline])
                        self.trailingRemainder = String(fullContent[fullContent.index(after: lastNewline)...])
                        
                        let results = self.processChunkInBackground(toProcess)
                        DispatchQueue.main.async { [weak self] in
                            self?.applyResults(results)
                            self?.fileHandle = handle
                            self?.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                                self?.readNewData()
                            }
                        }
                    } else {
                        // No newline found yet, keep buffering
                        self.trailingRemainder = fullContent
                        DispatchQueue.main.async { [weak self] in
                            self?.fileHandle = handle
                            self?.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                                self?.readNewData()
                            }
                        }
                    }
                }
            } catch {
                print("Failed to open log: \(error)")
            }
        }
    }
    
    @available(macOS 13.0, *)
    private func startXPCEventPolling() {
        xpcEventTimer?.invalidate()
        xpcEventTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollXPCEvents()
        }
        // Initial poll
        pollXPCEvents()
    }
    
    @available(macOS 13.0, *)
    private func pollXPCEvents() {
        HelperManager.shared.getRecentEvents(sinceIndex: xpcEventIndex) { [weak self] jsonEvents, nextIndex in
            guard let self = self, !jsonEvents.isEmpty else {
                if let next = self {
                    next.xpcEventIndex = nextIndex
                }
                return
            }
            
            // Parse JSON events and add to events list
            var newEvents: [EventEntry] = []
            for jsonStr in jsonEvents {
                if let event = self.parseXPCJsonEvent(jsonStr) {
                    newEvents.append(event)
                }
            }
            
            if !newEvents.isEmpty {
                DispatchQueue.main.async {
                    self.events.append(contentsOf: newEvents)
                    if self.events.count > self.maxEventItems {
                        self.events.removeFirst(self.events.count - self.maxEventItems)
                    }
                    self.saveEvents()
                }
            }
            
            self.xpcEventIndex = nextIndex
        }
    }
    
    /// Parse a JSON event string from XPC into an EventEntry
    private func parseXPCJsonEvent(_ jsonStr: String) -> EventEntry? {
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        var eventTime = ""
        var eventType: EventEntry.EventType?
        var eventPayload: Any?
        
        if let timeStr = json["time"] as? String {
            eventTime = timeStr.replacingOccurrences(of: "Z", with: "")
        }
        
        if let eventData = json["event"] {
            if let eventDict = eventData as? [String: Any], let key = eventDict.keys.first {
                eventType = mapEventType(key)
                eventPayload = eventDict[key]
            } else if let eventStr = eventData as? String {
                eventType = mapEventType(eventStr)
                eventPayload = eventStr
            }
        }
        
        guard let type = eventType else { return nil }
        
        let cleanedPayload = recursiveJsonClean(eventPayload, depth: 0)
        let detailsStr = capString(formatAsJson(cleanedPayload), limit: maxFullTextLength)
        
        // Parse date
        let date = parseEventDate(eventTime)
        
        return EventEntry(
            timestamp: eventTime,
            date: date,
            type: type,
            details: detailsStr
        )
    }
    
    private func parseEventDate(_ ts: String) -> Date? {
        let formats = [
            "yyyy-MM-dd HH:mm:ss.SSSSSSZ", "yyyy-MM-dd HH:mm:ss.SSSZ", "yyyy-MM-dd HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"
        ]
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .iso8601)
        parser.locale = Locale(identifier: "en_US_POSIX")
        
        for fmt in formats {
            parser.dateFormat = fmt
            if let d = parser.date(from: ts) { return d }
        }
        return nil
    }
    
    func stopMonitoring() {
        // Save verification offset before closing
        if let handle = fileHandle {
            lastReadOffset = handle.offsetInFile
        }
        
        timer?.invalidate()
        timer = nil
        xpcEventTimer?.invalidate()
        xpcEventTimer = nil
        try? fileHandle?.close()
        fileHandle = nil
        isReading = false
        
        // Aggressively clear ALL data from RAM.
        // Events are already persisted to disk (via saveEvents in applyResults or here), so we can safely unload them.
        saveEvents()
        logs.removeAll()
        events.removeAll()
        pendingLogs.removeAll()
    }
    
    func flushPending() {
        guard !pendingLogs.isEmpty else { return }
        self.logs.append(contentsOf: pendingLogs)
        if self.logs.count > maxLogItems {
            self.logs.removeFirst(self.logs.count - maxLogItems)
        }
        pendingLogs.removeAll()
    }
    
    func readNewData() {
        guard let handle = fileHandle, !isReading else { return }
        isReading = true
        
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { 
                DispatchQueue.main.async { self?.isReading = false }
                return 
            }
            
            let data = handle.readData(ofLength: 1024 * 1024)
            if data.isEmpty {
                DispatchQueue.main.async { self.isReading = false }
                return
            }
            
            if let chunk = String(data: data, encoding: .utf8) {
                // Combine with remainder from previous read
                let fullContent = self.trailingRemainder + chunk
                
                // Only process up to the last visible newline to avoid cutting log lines in half
                if let lastNewline = fullContent.lastIndex(of: "\n") {
                    let toProcess = String(fullContent[..<lastNewline])
                    self.trailingRemainder = String(fullContent[fullContent.index(after: lastNewline)...])
                    
                    let results = self.processChunkInBackground(toProcess)
                    DispatchQueue.main.async { [weak self] in
                        self?.applyResults(results)
                        self?.isReading = false
                    }
                } else {
                    // No newline in this chunk, just buffer it
                    self.trailingRemainder = fullContent
                    DispatchQueue.main.async { self.isReading = false }
                }
            } else {
                DispatchQueue.main.async { self.isReading = false }
            }
        }
    }
    
    // Regex for stripping ANSI escape codes
    // 1. Standard escape sequence: \x1B[ ... letter
    // 2. Fragmented/Raw color code: [ ... m (Must contain digits to avoid matching [Helper])
    private let ansiRegex = try! NSRegularExpression(pattern: "(\\x1B\\[[0-9;]*[a-zA-Z])|(\\[[0-9;]+m)", options: [])

    private func removeAnsiCodes(_ text: String) -> String {
        let range = NSRange(location: 0, length: text.utf16.count)
        return ansiRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    private struct ParseResults {
        let logs: [LogEntry]
        let events: [EventEntry]
        let restartDetected: Bool
    }
    
    private func processChunkInBackground(_ chunk: String) -> ParseResults {
        var newEntries: [LogEntry] = []
        var newEvents: [EventEntry] = []
        var restartDetected = false
        
        let localParser = DateFormatter()
        localParser.calendar = Calendar(identifier: .iso8601)
        localParser.locale = Locale(identifier: "en_US_POSIX")
        
        func localParseDate(_ ts: String) -> Date? {
             let formats = [
                "yyyy-MM-dd HH:mm:ss.SSSSSSZ", "yyyy-MM-dd HH:mm:ss.SSSZ", "yyyy-MM-dd HH:mm:ssZ",
                "yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss",
                "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ",
                "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"
            ]
            for fmt in formats {
                localParser.dateFormat = fmt
                if let d = localParser.date(from: ts) { return d }
            }
            return nil
        }

        let lines = chunk.components(separatedBy: .newlines)
        for line in lines {
            autoreleasepool {
                let rawContent = line.replacingOccurrences(of: "\0", with: "")
                if rawContent.isEmpty { return }
                
                var content = removeAnsiCodes(rawContent)
                
                // STRIP WRAPPER PREFIXES to reveal real Core log
                // Matches: "[2026-...] [Helper] Core output:" OR "[Helper]"
                if let range = content.range(of: "^(\\[.*?\\] )?\\[Helper\\]( Core output:)?", options: .regularExpression) {
                    content.removeSubrange(range)
                }
                content = content.trimmingCharacters(in: .whitespaces)
                
                // Detect Core Restart to clear old events
                // "Service started" is the wrapper log
                // "Easytier ... version ..." is often the first core log
                if content.contains("Service started") || content.contains("EasyTier version") {
                     restartDetected = true
                }
                
                if content.isEmpty { return }
                
                // 1. Check for JSON Event
                if let jsonRange = content.range(of: "\\{.*\\}", options: .regularExpression),
                   let data = String(content[jsonRange]).data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    
                    var eventTime = ""
                    var eventType: EventEntry.EventType?
                    var eventPayload: Any?
                    
                    if let timeStr = json["time"] as? String {
                         eventTime = timeStr.replacingOccurrences(of: "Z", with: "")
                    }
                    
                    if let eventData = json["event"] {
                        if let eventDict = eventData as? [String: Any], let key = eventDict.keys.first {
                            eventType = mapEventType(key)
                            eventPayload = eventDict[key]
                        } else if let eventStr = eventData as? String {
                            eventType = mapEventType(eventStr)
                            eventPayload = eventStr
                        }
                    }
                    
                    if let type = eventType {
                        let cleanedPayload = recursiveJsonClean(eventPayload, depth: 0)
                        let detailsStr = capString(formatAsJson(cleanedPayload), limit: maxFullTextLength)
                        newEvents.append(EventEntry(
                            timestamp: eventTime,
                            date: localParseDate(eventTime),
                            type: type, 
                            details: detailsStr
                        ))
                    }
                    
                    newEntries.append(LogEntry(
                        timestamp: eventTime, 
                        cleanContent: cleanLogContent(content),
                        fullText: capString(content, limit: maxFullTextLength), 
                        level: .info
                    ))
                    return
                }
                
                // 2. Regular Text Log
                var timestamp = ""
                var cleanContent = content
                var isNewLogLine = false
                
                // Robust Regex for Timestamp detection (Includes fractional .123 and Timezone +08:00)
                if let range = content.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?", options: .regularExpression) {
                    // Extract full timestamp token (until space)
                    let start = range.lowerBound
                    // Find end of timestamp (space or end of string)
                    let remainder = content[start...]
                    if let spaceIndex = remainder.firstIndex(of: " ") {
                         timestamp = String(remainder[..<spaceIndex])
                    } else {
                         timestamp = String(remainder)
                    }
                    
                    cleanContent = String(content[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    
                    // Strip Level (INFO, WARN...) from the start of the message body
                    if let levelRange = cleanContent.range(of: "^(INFO|WARN|ERROR|DEBUG|TRACE)\\b", options: [.regularExpression, .caseInsensitive]) {
                        cleanContent = String(cleanContent[levelRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    }

                    isNewLogLine = true
                }
                
                if isNewLogLine {
                    var level: LogLevel = .info
                    let lower = cleanContent.lowercased()
                    if lower.contains("error") { level = .error }
                    else if lower.contains("warn") { level = .warn }
                    else if lower.contains("debug") { level = .debug }
                    else if lower.contains("trace") { level = .trace }
                    
                    newEntries.append(LogEntry(
                        timestamp: timestamp, 
                        cleanContent: cleanLogContent(cleanContent),
                        fullText: capString(content, limit: maxFullTextLength), 
                        level: level
                    ))
                    
                    parseTextEvent(content: cleanContent, timestamp: timestamp, dateParser: localParseDate, into: &newEvents)
                } else if let last = newEntries.last {
                    let updatedFull = capString(last.fullText + "\n" + content, limit: maxFullTextLength)
                    let updatedClean = cleanLogContent(last.cleanContent + "\n" + content)
                    newEntries[newEntries.count - 1] = LogEntry(
                        id: last.id,
                        timestamp: last.timestamp,
                        cleanContent: updatedClean,
                        fullText: updatedFull,
                        level: last.level
                    )
                } else {
                    newEntries.append(LogEntry(
                        timestamp: "", 
                        cleanContent: cleanLogContent(content),
                        fullText: capString(content, limit: maxFullTextLength), 
                        level: .info
                    ))
                }
            }
        }
        return ParseResults(logs: newEntries, events: newEvents, restartDetected: restartDetected)
    }
    
    private func applyResults(_ results: ParseResults) {
        if results.restartDetected {
            self.events.removeAll()
        }
        
        // Filter out effectively empty results to prevent visual gaps in the list
        let validLogs = results.logs.filter { !$0.cleanContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        if isPaused {
            pendingLogs.append(contentsOf: validLogs)
        } else {
            self.logs.append(contentsOf: validLogs)
            if self.logs.count > maxLogItems {
                self.logs.removeFirst(self.logs.count - maxLogItems)
            }
        }
        
        if !results.events.isEmpty {
            self.events.append(contentsOf: results.events)
            if self.events.count > maxEventItems {
                self.events.removeFirst(self.events.count - maxEventItems)
            }
            // Save on change
            saveEvents()
        } else if results.restartDetected {
            saveEvents()
        }
    }
    
    private func capString(_ s: String, limit: Int) -> String {
        if s.count > limit {
            return String(s.prefix(limit)) + "\n... [已自动截断过长内容]"
        }
        return s
    }

    private func cleanLogContent(_ text: String) -> String {
         let lines = text.components(separatedBy: .newlines)
         var resultLines: [String] = []
         
         for line in lines {
             var t = line.trimmingCharacters(in: .whitespaces)
             
             // Fix: Just strip the prefix, do NOT skip the line
             if t.contains("[Helper] Core output") { 
                 t = t.replacingOccurrences(of: "[Helper] Core output", with: "").trimmingCharacters(in: .whitespaces)
             } else if t.contains("[Helper]") {
                 t = t.replacingOccurrences(of: "[Helper]", with: "").trimmingCharacters(in: .whitespaces)
             }
             
             // Restore: Do not strip timestamps or levels to keep the "previous format"
             
             if !t.isEmpty { resultLines.append(t) }
         }
         let joined = resultLines.joined(separator: "\n")
         return joined.count > 1000 ? String(joined.prefix(1000)) + "..." : joined
    }
    
    // Updated parseTextEvent to accept closure for date parsing
    private func parseTextEvent(content: String, timestamp: String, dateParser: (String) -> Date?, into newEvents: inout [EventEntry]) {
        var eventType: EventEntry.EventType?
        var eventPayload: Any?
        let lower = content.lowercased()
        
        // Clean content for display (strip [Helper] and Timestamps)
        let cleaned = cleanLogContent(content)
        
        // Format Rust Structs with proper indentation
        let formatted = formatRustStruct(cleaned)

        if content.contains("PeerConnAdded") {
            eventType = .peerConnAdded
            eventPayload = ["raw": formatted]
        } else if content.contains("PeerAdded") || content.contains("NewPeer") {
            eventType = .peerAdded
            eventPayload = ["event": "PeerAdded", "raw": formatted]
        } else if content.contains("PeerRemoved") || content.contains("PeerLost") {
            eventType = .peerRemoved
            eventPayload = ["event": "PeerRemoved", "raw": formatted]
        } else if content.contains("Connecting") || content.contains("ConnectingTo") {
            eventType = .connecting
            let url = extractUrl(from: content) ?? formatted
            eventPayload = ["event": "Connecting", "url": url]
        } else if (content.contains("ConnectError") || content.contains("ConnectionError")) && !lower.contains("ignore") {
            eventType = .connectError
            eventPayload = ["event": "ConnectError", "message": formatted]
        } else if content.contains("ListenerAdded") {
            eventType = .listenerAdded
            let url = extractUrl(from: content) ?? formatted
            eventPayload = ["event": "ListenerAdded", "url": url]
        } else if content.contains("TunDeviceReady") {
            eventType = .tunDeviceReady
            eventPayload = ["event": "TunDeviceReady", "info": formatted]
        } else if content.contains("Handshake") && !lower.contains("error") {
            eventType = .handshake
            eventPayload = ["event": "Handshake", "info": formatted]
        } else if content.contains("RouteChanged") || content.contains("RouteUpdate") {
            eventType = .routeChanged
            eventPayload = ["event": "RouteChanged", "info": formatted]
        }
        
        if let type = eventType {
            let cleanedPayload = recursiveJsonClean(eventPayload, depth: 0)
            let detailsStr = capString(formatAsJson(cleanedPayload), limit: maxFullTextLength)
            newEvents.append(EventEntry(
                timestamp: timestamp, 
                date: dateParser(timestamp),
                type: type, 
                details: detailsStr
            ))
        }
    }
    
    /// Format Rust debug output with proper indentation
    /// Handles nested { } and preserves arrays [0, 1, 2] on single lines
    private func formatRustStruct(_ text: String) -> String {
        var result = ""
        var indentLevel = 0
        let indentStr = "    " // 4 spaces per level
        var i = text.startIndex
        var insideString = false
        
        while i < text.endIndex {
            let char = text[i]
            
            // Track string boundaries to avoid formatting inside strings
            if char == "\"" {
                // Check if escaped
                if i > text.startIndex {
                    let prevIndex = text.index(before: i)
                    if text[prevIndex] != "\\" {
                        insideString.toggle()
                    }
                } else {
                    insideString.toggle()
                }
                result.append(char)
            } else if insideString {
                result.append(char)
            } else if char == "{" {
                indentLevel += 1
                result.append("{")
                result.append("\n")
                result.append(String(repeating: indentStr, count: indentLevel))
            } else if char == "}" {
                indentLevel = max(0, indentLevel - 1)
                result.append("\n")
                result.append(String(repeating: indentStr, count: indentLevel))
                result.append("}")
            } else if char == "," {
                result.append(",")
                // Only add newline if not inside brackets []
                let remaining = String(text[i...])
                if !isInsideArrayContext(remaining) {
                    result.append("\n")
                    result.append(String(repeating: indentStr, count: indentLevel))
                } else {
                    result.append(" ")
                }
            } else {
                result.append(char)
            }
            
            i = text.index(after: i)
        }
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Check if we're likely inside an array context (don't split array elements)
    private func isInsideArrayContext(_ text: String) -> Bool {
        var bracketCount = 0
        var braceCount = 0
        for char in text.prefix(50) { // Look ahead 50 chars
            if char == "[" { bracketCount += 1 }
            if char == "]" { bracketCount -= 1 }
            if char == "{" { braceCount += 1 }
            if char == "}" { braceCount -= 1 }
            if braceCount < 0 || (bracketCount <= 0 && braceCount == 0) {
                break
            }
        }
        return bracketCount > 0
    }
    
    // Heuristic parser for Rust Debug format -> JSON Object
    // e.g. "Some(TunnelInfo { type: "udp", ... })" -> ["type": "udp", ...]

    
    // Recursive function to try parsing any string values as JSON
    private func recursiveJsonClean(_ value: Any?, depth: Int) -> Any? {
        guard let value = value, depth < 5 else { return value }
        
        if let dict = value as? [String: Any] {
            var newDict = dict
            for (k, v) in dict {
                newDict[k] = recursiveJsonClean(v, depth: depth + 1)
            }
            return newDict
        } else if let arr = value as? [Any] {
            return arr.map { recursiveJsonClean($0, depth: depth + 1) }
        } else if let str = value as? String {
            // Try to parse string as JSON object or array
            if str.count < 5000 && (str.starts(with: "{") || str.starts(with: "[")) {
                 if let data = str.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: data) {
                     return recursiveJsonClean(json, depth: depth + 1)
                 }
            }
            return str
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
    
    private func extractUrl(from text: String) -> String? {
        if let range = text.range(of: "tcp://") ?? text.range(of: "udp://") ?? text.range(of: "wg://") {
            let start = text.index(range.lowerBound, offsetBy: 0)
            let end = text[start...].firstIndex(of: " ") ?? text.endIndex
            return String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"',"))
        }
        return nil
    }
    
    private func formatAsJson(_ value: Any?) -> String {
        guard let value = value else { return "null" }
        
        // JSONSerialization requires Array or Dictionary as top-level type.
        // If it's a simple type, just return its string representation.
        if !(value is [String: Any]) && !(value is [Any]) {
            return "\(value)"
        }
        
        var options: JSONSerialization.WritingOptions = [.prettyPrinted]
        if #available(macOS 10.15, *) {
            options.insert(.withoutEscapingSlashes)
        }
        
        if let data = try? JSONSerialization.data(withJSONObject: value, options: options),
           let str = String(data: data, encoding: .utf8) {
            var res = str
            
            // Compact simple arrays (e.g., lists of strings/numbers) to single line
            // Matches [ content ] where content doesn't contain { or [ (nested structures)
            let pattern = "\\[\\s*([^\\{\\[\\]]*?)\\s*\\]"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) {
                // Find all matches
                let range = NSRange(location: 0, length: res.utf16.count)
                let matches = regex.matches(in: res, options: [], range: range)
                
                // Process in reverse to avoid invalidating ranges
                for match in matches.reversed() {
                    if let contentRange = Range(match.range(at: 1), in: res) {
                        let content = String(res[contentRange])
                        // Collapse whitespace: split by newline and rejoin with space
                        let collapsed = content
                            .components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .joined(separator: " ")
                            .trimmingCharacters(in: .whitespaces)
                        
                        let fullMatchRange = match.range(at: 0)
                        if let targetRange = Range(fullMatchRange, in: res) {
                            res.replaceSubrange(targetRange, with: "[\(collapsed)]")
                        }
                    }
                }
            }
            
            // Unescape characters for better human readability in the log view
            return res
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\t", with: "\t")
                // Double check to remove any remaining escaped slashes
                .replacingOccurrences(of: "\\/", with: "/")
        }
        return "\(value)"
    }
}

struct EventListView: View {
    let events: [EventEntry]
    
    // Track the last known event count to detect new arrivals
    @State private var lastEventCount: Int = 0
    @State private var userHasScrolled: Bool = false
    
    // Display: HH:mm:ss (Large Bold)
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    
    // Display: yyyy年MM月dd日 (Small Gray)
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy年MM月dd日"
        return f
    }()
    
    var body: some View {
        if events.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("暂无交互事件")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text("启动服务后，节点连接、断开等事件将显示在这里")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    List {
                        ForEach(events.reversed()) { event in
                            HStack(alignment: .top, spacing: 0) {
                                
                                // 1. Time Column
                                VStack(alignment: .trailing, spacing: 2) {
                                    if let date = event.date {
                                        Text(timeFormatter.string(from: date))
                                            .font(.system(size: 16, weight: .black, design: .rounded))
                                            .foregroundColor(.primary)
                                        Text(dateFormatter.string(from: date))
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    } else {
                                        // Fallback
                                        Text(event.timestamp.prefix(8))
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .frame(width: 90, alignment: .trailing)
                                .padding(.trailing, 10)
                                .padding(.vertical, 10)
                                
                                // 2. Timeline (Continuous line)
                                ZStack(alignment: .top) {
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.2))
                                        .frame(width: 2)
                                        .frame(maxHeight: .infinity)
                                    
                                    Circle()
                                        .fill(event.type.color)
                                        .frame(width: 10, height: 10)
                                        .background(Color(NSColor.windowBackgroundColor))
                                        .padding(.top, 14) // Adjusted for new column padding
                                }
                                .frame(width: 16)
                                .padding(.trailing, 12)
                                
                                // 3. Content
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(event.type.rawValue)
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.primary)
                                    
                                    // Properly unescape and display the formatted text
                                    Text(event.details
                                            .replacingOccurrences(of: "\\\"", with: "\"")
                                            .replacingOccurrences(of: "\\t", with: "    "))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .textSelection(.enabled)
                                        .padding(16)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color(nsColor: .controlBackgroundColor))
                                        .cornerRadius(8)
                                }
                                .padding(.vertical, 10)
                                .padding(.bottom, 6)
                            }
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .id(event.id) // Stable ID for the row
                        }
                    }
                    .listStyle(.inset)
                    .id("event-list-stable")
                    
                    // Floating "Scroll to Top" Button with Liquid Glass effect (macOS 26+)
                    Button {
                        // Since we use .reversed(), the first item in UI is events.last
                        if let topEvent = events.last {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(topEvent.id, anchor: .top)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 20, weight: .bold))
                    }
                    .modifier(GlassButtonModifier())
                    .padding(16)
                    .help("回到顶部")
                }
            }
        }
    }
}

// Improved LogListView with date formatting and level filter
struct LogListView: View {
    let logs: [LogEntry]
    @Binding var selectedLog: LogEntry?
    var levelFilter: LogLevel? = nil
    
    private let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    private func formatTimestamp(_ ts: String) -> String {
        // 1. Try strict ISO 8601
        if let date = isoFormatter.date(from: ts) {
            return fullDateFormatter.string(from: date)
        }
        
        // 2. Fallback: Parse T-separator manually but keep date
        // Raw: 2026-01-19T00:50:34.xxxx+08:00
        // Want: 2026-01-19 00:50:34
        
        // Replace 'T' with ' '
        let proper = ts.replacingOccurrences(of: "T", with: " ")
        if proper.count >= 19 {
             return String(proper.prefix(19))
        }
        
        return ts
    }
    
    // Filtered logs based on level
    private var filteredLogs: [LogEntry] {
        guard let filter = levelFilter else {
            return logs
        }
        return logs.filter { $0.level == filter }
    }
    
    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                HStack(spacing: 0) {
                    // Sidebar List
                    List {
                        ForEach(Array(filteredLogs.reversed().enumerated()), id: \.element.id) { index, log in
                            LogListRow(log: log, timestampFormatted: formatTimestamp(log.timestamp), isSelected: selectedLog?.id == log.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        selectedLog = (selectedLog?.id == log.id) ? nil : log
                                    }
                                }
                                .listRowSeparator(.hidden) // Cleaner zebra look
                                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                                .listRowBackground(
                                    ZStack {
                                        if selectedLog?.id == log.id {
                                            Color.blue.opacity(0.15)
                                        } else if index % 2 == 1 {
                                            Color.primary.opacity(0.03) // Subtle zebra stripe
                                        } else {
                                            Color.clear
                                        }
                                    }
                                )
                                .id(log.id)
                        }
                    }
                    .listStyle(.sidebar)
                    .background(Color(nsColor: .textBackgroundColor))
                    .frame(width: selectedLog == nil ? nil : 180) // Collapse to sidebar width when detail is open
                    
                    // Detail Column (The "Systems Settings" Style Detail)
                    if let entry = selectedLog {
                        Divider()
                        VStack(spacing: 0) {
                            LogDetailView(log: .constant(entry))
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                        .frame(maxWidth: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
                .id("log-list-stable")
                .onChange(of: selectedLog) { val in
                    // When inspecting a log, pause UI updates to prevent the anchored row from shifting/jumping
                    if val != nil {
                        LogParser.shared.isPaused = true
                    } else {
                        LogParser.shared.isPaused = false
                        LogParser.shared.flushPending()
                    }
                }
                
                // Floating "Scroll to Top" Button with Liquid Glass effect (macOS 26+)
                Button {
                    // Since we use .reversed(), the first item in UI is filteredLogs.last
                    if let topLog = filteredLogs.last {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(topLog.id, anchor: .top)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 20, weight: .bold))
                }
                .modifier(GlassButtonModifier())
                .padding(16)
                .help("回到顶部")
            }
        }
    }
}

struct LogListRow: View {
    let log: LogEntry
    let timestampFormatted: String
    var isSelected: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Content
            Text(log.cleanContent) // Use pre-calculated clean content
                .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .monospaced))
                .foregroundColor(isSelected ? .blue : .primary)
                .lineLimit(isSelected ? 3 : 2, reservesSpace: true)
            
            // Bottom Bar: Time | Level Tag
            HStack(spacing: 4) {
                // Time
                Text(timestampFormatted.suffix(8)) // Show only time to save space in sidebar
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if !isSelected {
                    LogListTagView(
                        text: log.level.rawValue.uppercased(),
                        color: log.level.color
                    )
                    .scaleEffect(0.8)
                }
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
    }
}

struct LogListTagView: View {
    let text: String
    let color: Color
    
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(color)
            )
    }
}

struct LogDetailView: View {
    @Binding var log: LogEntry?
    
    var body: some View {
        VStack(spacing: 0) {
            if let entry = log {
                CodeEditor(text: .constant(entry.fullText), mode: .log, isEditable: false)
            }
        }
    }
}

// Custom Modifier to handle OS version check for Glass Effect
struct GlassButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white) // 图标始终白色
            .padding(12) // 按钮大小由内边距控制
            .background(
                Circle()
                    .fill(Color.blue) // 使用系统标准蓝色
                    .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2) // 经典悬浮阴影
            )
            .contentShape(Circle())
            .buttonStyle(.plain)
            // 添加简单的悬停变色效果（可选，提升交互感）
            .onHover { isHovering in
                if isHovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}
